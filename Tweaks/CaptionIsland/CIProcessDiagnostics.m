#import "CIProcessDiagnostics.h"
#import "CIConstants.h"
#import "CILogStore.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <float.h>
#import <mach-o/dyld.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

static const NSUInteger CIDiagnosticsMaximumDescriptionLength = 900;
static const NSUInteger CIRetainedLaunchPrefetchAssertionLimit = 4;

typedef void (*CIRBSAssertionInvalidateImplementation)(id, SEL);
typedef void (*CIAppLaunchMeasurementReleaseImplementation)(void);

static CIRBSAssertionInvalidateImplementation
    CIOriginalRBSAssertionInvalidate;
static CIAppLaunchMeasurementReleaseImplementation
    CIOriginalAppLaunchMeasurementRelease;
static NSMutableArray *CIRetainedLaunchPrefetchAssertions;
static BOOL CILaunchPrefetchRetentionProbeInstalled;
static BOOL CILaunchPrefetchRetentionProbeEnabled;
static BOOL CIDirectLaunchPrefetchReleaseHookInstalled;
static BOOL CIRBSAssertionRetentionFallbackInstalled;
static BOOL CILaunchPrefetchReleaseWasSuppressed;
static BOOL CILaunchPrefetchRetentionProbeReleasing;
static NSUInteger CILaunchPrefetchSuppressedReleaseCount;

static void CILoadRunningBoardServices(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!NSClassFromString(@"RBSProcessHandle") ||
            !NSClassFromString(@"RBSAssertion")) {
            dlopen(
                "/System/Library/PrivateFrameworks/RunningBoardServices.framework"
                "/RunningBoardServices",
                RTLD_LAZY
            );
        }
    });
}

/// Returns RunningBoard's current state object for this process, or nil when
/// the private framework or its selectors are not available. RunningBoard is
/// the component that decides which background endowments a process holds, so
/// its view is the one `liveactivitiesd` ultimately consults.
static id CICurrentRunningBoardProcessState(void) {
    // UIKit apps normally have this linked already; load it explicitly so the
    // diagnostic still works if it happens not to be resident.
    CILoadRunningBoardServices();

    Class handleClass = NSClassFromString(@"RBSProcessHandle");
    SEL currentProcessSelector = NSSelectorFromString(@"currentProcess");
    if (![handleClass respondsToSelector:currentProcessSelector]) return nil;

    id handle = nil;
    @try {
        handle = ((id (*)(id, SEL))objc_msgSend)(
            handleClass,
            currentProcessSelector
        );
    } @catch (__unused NSException *exception) {
        return nil;
    }

    SEL currentStateSelector = NSSelectorFromString(@"currentState");
    if (![handle respondsToSelector:currentStateSelector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(handle, currentStateSelector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id CIAssertionValue(id object, NSString *key) {
    if (!object || key.length == 0) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL CITextContainsCaseInsensitive(
    NSString *text,
    NSString *needle
) {
    if (text.length == 0 || needle.length == 0) return NO;
    return [text rangeOfString:needle
                      options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL CITextContainsCurrentPIDToken(NSString *text) {
    if (text.length == 0) return NO;
    NSString *pidText = [NSString stringWithFormat:@"%d", getpid()];
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    NSRange searchRange = NSMakeRange(0, text.length);
    while (searchRange.length > 0) {
        NSRange match = [text rangeOfString:pidText
                                   options:0
                                     range:searchRange];
        if (match.location == NSNotFound) return NO;
        BOOL validPrefix = match.location == 0 ||
            ![digits characterIsMember:[text characterAtIndex:
                match.location - 1]];
        NSUInteger end = NSMaxRange(match);
        BOOL validSuffix = end == text.length ||
            ![digits characterIsMember:[text characterAtIndex:end]];
        if (validPrefix && validSuffix) return YES;
        NSUInteger next = match.location + 1;
        searchRange = NSMakeRange(next, text.length - next);
    }
    return NO;
}

static BOOL CITargetRepresentsCurrentProcess(
    id target,
    NSString *descriptorText
) {
    NSArray<NSString *> *pidKeys = @[
        @"pid",
        @"processIdentifier",
        @"targetPid",
    ];
    for (NSString *key in pidKeys) {
        id value = CIAssertionValue(target, key);
        if ([value respondsToSelector:@selector(intValue)] &&
            [value intValue] == getpid()) {
            return YES;
        }
    }

    NSString *targetText = [target description];
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    if (bundleIdentifier.length > 0 &&
        (CITextContainsCaseInsensitive(targetText, bundleIdentifier) ||
         CITextContainsCaseInsensitive(
             descriptorText,
             bundleIdentifier))) {
        return YES;
    }

    // On iOS 26 the target returned by RBSAssertion can describe itself as a
    // bare decimal PID (for example "20063"), rather than the app<pid>
    // representation printed by runningboardd. Treat a bounded decimal token
    // as a PID, but only after the caller has already matched the exact Apple
    // LaunchPrefetch explanation and attributes.
    return CITextContainsCurrentPIDToken(targetText) ||
        CITextContainsCurrentPIDToken(descriptorText);
}

/// Matches only Apple's page-in recording assertion for this exact process.
/// Matching all three fields matters because `RBSAssertion` is also used for
/// unrelated UIKit, audio and other-process assertions in the same address
/// space; retaining any of those would make the experiment unsafe and muddy
/// its result.
static BOOL CIIsCurrentProcessLaunchPrefetchAssertion(id assertion) {
    id descriptor = CIAssertionValue(assertion, @"descriptor");
    NSString *descriptorText = [descriptor description];
    NSString *explanation = [CIAssertionValue(
        assertion,
        @"explanation"
    ) description];
    NSString *combinedExplanation = [NSString stringWithFormat:
        @"%@ %@", explanation ?: @"", descriptorText ?: @""];
    if (!CITextContainsCaseInsensitive(
            combinedExplanation,
            @"app_launch_measurement") ||
        !CITextContainsCaseInsensitive(
            combinedExplanation,
            @"pageins recording enabled")) {
        return NO;
    }

    NSString *attributesText = [CIAssertionValue(
        assertion,
        @"attributes"
    ) description];
    NSString *combinedAttributes = [NSString stringWithFormat:
        @"%@ %@", descriptorText ?: @"", attributesText ?: @""];
    if (!CITextContainsCaseInsensitive(
            combinedAttributes,
            @"pagein-prefetching") ||
        !CITextContainsCaseInsensitive(
            combinedAttributes,
            @"LaunchPrefetch")) {
        return NO;
    }

    id target = CIAssertionValue(assertion, @"target");
    if (!target) target = CIAssertionValue(descriptor, @"target");
    return CITargetRepresentsCurrentProcess(target, descriptorText);
}

static BOOL CIAssertionIsValid(id assertion) {
    id value = CIAssertionValue(assertion, @"valid");
    return !value || ![value respondsToSelector:@selector(boolValue)] ||
        [value boolValue];
}

static void CIReleaseLaunchPrefetchAssertions(
    NSArray *assertions,
    NSString *reason
) {
    NSUInteger releasedCount = 0;
    for (id assertion in assertions) {
        if (!CIAssertionIsValid(assertion)) continue;
        CIRBSAssertionInvalidateImplementation invalidate =
            CIOriginalRBSAssertionInvalidate;
        if (!invalidate) continue;
        invalidate(assertion, NSSelectorFromString(@"invalidate"));
        releasedCount++;
    }
    [CILogStore.sharedStore
        recordLevel:CILogLevelInfo
           category:@"LaunchPrefetch"
             format:@"Released %lu retained LaunchPrefetch assertion(s): %@.",
                    (unsigned long)releasedCount,
                    reason.length > 0 ? reason : @"requested"];
}

static void CILaunchPrefetchAssertionInvalidate(id assertion, SEL selector) {
    CIRBSAssertionInvalidateImplementation original =
        CIOriginalRBSAssertionInvalidate;
    if (!original) return;

    // Every RBSAssertion invalidation in the process arrives here once the
    // hooks are live, so get the common case out of the way before taking any
    // lock. Reading the flag unsynchronized can only lose an assertion
    // invalidated in the same instant the switch is flipped, which is a far
    // better trade than serialising unrelated audio and PiP teardown.
    if (!CILaunchPrefetchRetentionProbeEnabled) {
        original(assertion, selector);
        return;
    }

    BOOL shouldRetain = NO;
    BOOL rejectedCandidate = NO;
    NSUInteger retainedCount = 0;
    NSString *rejectedTarget = nil;
    @synchronized (CIRetainedLaunchPrefetchAssertions) {
        if (CILaunchPrefetchRetentionProbeEnabled &&
            !CILaunchPrefetchRetentionProbeReleasing &&
            CIIsCurrentProcessLaunchPrefetchAssertion(assertion)) {
            if ([CIRetainedLaunchPrefetchAssertions
                    containsObject:assertion]) {
                // An already-retained assertion can be invalidated more than
                // once by defensive cleanup paths. Keep swallowing those
                // duplicate client calls or the second call would undo the
                // experiment.
                shouldRetain = YES;
                retainedCount =
                    CIRetainedLaunchPrefetchAssertions.count;
            } else if (CIRetainedLaunchPrefetchAssertions.count <
                           CIRetainedLaunchPrefetchAssertionLimit) {
                [CIRetainedLaunchPrefetchAssertions addObject:assertion];
                retainedCount =
                    CIRetainedLaunchPrefetchAssertions.count;
                shouldRetain = YES;
            }
        } else if (CILaunchPrefetchRetentionProbeEnabled &&
                   !CILaunchPrefetchRetentionProbeReleasing) {
            id descriptor = CIAssertionValue(assertion, @"descriptor");
            NSString *descriptorText = [descriptor description];
            if (CITextContainsCaseInsensitive(
                    descriptorText,
                    @"LaunchPrefetch") ||
                CITextContainsCaseInsensitive(
                    descriptorText,
                    @"pageins recording enabled")) {
                rejectedCandidate = YES;
                id target = CIAssertionValue(assertion, @"target");
                if (!target) {
                    target = CIAssertionValue(descriptor, @"target");
                }
                rejectedTarget = [[target description] copy] ?: @"<nil>";
            }
        }
    }

    if (!shouldRetain) {
        if (rejectedCandidate) {
            [CILogStore.sharedStore
                recordLevel:CILogLevelWarning
                   category:@"LaunchPrefetch"
                     format:@"Observed a LaunchPrefetch invalidation candidate, but the RBS safety matcher rejected it (target=%@, currentPID=%d).",
                            rejectedTarget,
                            getpid()];
        }
        original(assertion, selector);
        return;
    }

    [CILogStore.sharedStore
        recordLevel:CILogLevelInfo
           category:@"LaunchPrefetch"
             format:@"Intercepted client invalidation for this process's LaunchPrefetch assertion; retained count=%lu.",
                    (unsigned long)retainedCount];
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            CILogProcessBackgroundEligibility(
                @"LaunchPrefetch retention probe intercepted invalidation"
            );
        }
    );
}

static void CIAppLaunchMeasurementReleaseReplacement(void) {
    CIAppLaunchMeasurementReleaseImplementation original =
        CIOriginalAppLaunchMeasurementRelease;
    BOOL shouldSuppress = NO;
    NSUInteger suppressedCount = 0;
    @synchronized (CIRetainedLaunchPrefetchAssertions) {
        shouldSuppress = CILaunchPrefetchRetentionProbeEnabled &&
            !CILaunchPrefetchRetentionProbeReleasing;
        if (shouldSuppress) {
            CILaunchPrefetchReleaseWasSuppressed = YES;
            CILaunchPrefetchSuppressedReleaseCount++;
            suppressedCount = CILaunchPrefetchSuppressedReleaseCount;
        }
    }

    if (!shouldSuppress) {
        if (original) original();
        return;
    }

    [CILogStore.sharedStore
        recordLevel:CILogLevelInfo
           category:@"LaunchPrefetch"
             format:@"Intercepted app_launch_measurement release directly; its LaunchPrefetch assertion remains owned (suppressed calls=%lu).",
                    (unsigned long)suppressedCount];
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            CILogProcessBackgroundEligibility(
                @"Direct LaunchPrefetch release interception"
            );
        }
    );
}

void CIReleaseRetainedLaunchPrefetchAssertions(NSString *reason) {
    NSArray *assertions = nil;
    BOOL releaseDirectOwnership = NO;
    @synchronized (CIRetainedLaunchPrefetchAssertions) {
        CILaunchPrefetchRetentionProbeReleasing = YES;
        releaseDirectOwnership =
            CILaunchPrefetchReleaseWasSuppressed &&
            CIOriginalAppLaunchMeasurementRelease != NULL;
        CILaunchPrefetchReleaseWasSuppressed = NO;
        assertions = CIRetainedLaunchPrefetchAssertions.copy;
        [CIRetainedLaunchPrefetchAssertions removeAllObjects];
    }
    if (releaseDirectOwnership) {
        CIOriginalAppLaunchMeasurementRelease();
        [CILogStore.sharedStore
            recordLevel:CILogLevelInfo
               category:@"LaunchPrefetch"
                 format:@"Released the directly retained app_launch_measurement assertion: %@.",
                        reason.length > 0 ? reason : @"requested"];
    }
    if (assertions.count > 0) {
        CIReleaseLaunchPrefetchAssertions(assertions, reason);
    }
    @synchronized (CIRetainedLaunchPrefetchAssertions) {
        CILaunchPrefetchRetentionProbeReleasing = NO;
    }
}

/// Confirms `-[RBSAssertion invalidate]` really is `void (id, SEL)` before
/// replacing it.
///
/// This check is not paranoia about a private API drifting; it is about what
/// happens if the assumption is already wrong. `method_setImplementation`
/// redirects the method for **every** `RBSAssertion` in the process, and
/// YouTube holds them for audio, PiP, background tasks and extensions. A
/// replacement that returns nothing where the real method returns a value never
/// writes the return register, so every unrelated caller in the process reads
/// whatever happened to be left there. Refusing to install is the only safe
/// response, and the offending encoding is worth logging so the next iOS
/// release can be handled deliberately.
/// Steps past ObjC method-encoding type qualifiers.
///
/// `-[RBSAssertion invalidate]` is declared `oneway void`, which encodes as
/// "Vv16@0:8": the leading `V` is a qualifier, not part of the return type.
/// `oneway` exists for distributed-object messaging and has no effect on the
/// local calling convention, so a plain `void (id, SEL)` replacement is
/// ABI-compatible — but comparing the raw encoding against `v` rejects it.
static const char *CISkipTypeQualifiers(const char *encoding) {
    if (!encoding) return NULL;
    // r const, n in, N inout, o out, O bycopy, R byref, V oneway.
    while (*encoding && strchr("rnNoORV", *encoding)) encoding++;
    return encoding;
}

static BOOL CIAssertionInvalidateHasExpectedSignature(Method method) {
    if (!method) return NO;
    BOOL returnsVoid = NO;
    char *returnType = method_copyReturnType(method);
    if (returnType) {
        const char *bare = CISkipTypeQualifiers(returnType);
        returnsVoid = bare && bare[0] == _C_VOID && bare[1] == '\0';
        free(returnType);
    }
    // self and _cmd only: an extra parameter would mean the caller passes a
    // value this replacement silently drops.
    return returnsVoid && method_getNumberOfArguments(method) == 2;
}

static const char *const CIAppLaunchMeasurementReleaseSymbolName =
    "alm_release_pageins_recording_assertion";

/// Locates the page-in recording release function anywhere in the process.
///
/// The previous hardcoded `/usr/lib/libapp_launch_measurement.dylib` produced
/// `directReleaseHook=no` on iOS 26, and a wrong path is indistinguishable from
/// a missing symbol in the log. Searching every loaded image first removes the
/// guesswork; the explicit paths remain only as a fallback for the case where
/// the symbol exists but its image is not yet loaded.
static void *CIFindAppLaunchMeasurementRelease(NSString **resolvedImage) {
    void *symbol = dlsym(RTLD_DEFAULT,
                         CIAppLaunchMeasurementReleaseSymbolName);
    if (symbol) {
        Dl_info info;
        if (resolvedImage && dladdr(symbol, &info) && info.dli_fname) {
            *resolvedImage = @(info.dli_fname);
        }
        return symbol;
    }
    for (NSString *path in @[
        @"/usr/lib/libapp_launch_measurement.dylib",
        @"/usr/lib/system/libsystem_launch_measurement.dylib",
        // Single line: an implicitly concatenated literal inside an array
        // literal trips -Wobjc-string-concatenation, and this target is -Werror.
        @"/System/Library/PrivateFrameworks/AppLaunchMeasurement.framework/AppLaunchMeasurement",
    ]) {
        void *handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY);
        if (!handle) continue;
        symbol = dlsym(handle, CIAppLaunchMeasurementReleaseSymbolName);
        if (symbol) {
            if (resolvedImage) *resolvedImage = path;
            return symbol;
        }
    }
    return NULL;
}

/// Lists loaded images whose name hints at launch measurement, so a failed
/// lookup still reports where to look next instead of just saying "no".
static NSString *CIDescribeMeasurementImages(void) {
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *name = _dyld_get_image_name(index);
        if (name && strcasestr(name, "measurement")) {
            [matches addObject:[@(name) lastPathComponent]];
        }
    }
    return matches.count > 0
        ? [matches componentsJoinedByString:@", "] : @"none";
}

/// Installs the interception points. Separate from the launch-time entry point
/// so the hooks can also be installed the moment the experiment is switched on
/// mid-session: the observed release happens at the first background-to-
/// foreground return rather than during launch, so arming later is still in
/// time to catch it.
static void CIInstallLaunchPrefetchHooksIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CILoadRunningBoardServices();

        NSString *resolvedImage = nil;
        void *releaseSymbol =
            CIFindAppLaunchMeasurementRelease(&resolvedImage);
        if (!releaseSymbol) {
            [CILogStore.sharedStore
                recordLevel:CILogLevelWarning
                   category:@"LaunchPrefetch"
                     format:@"Could not resolve %s in any loaded image. Images hinting at launch measurement: %@.",
                            CIAppLaunchMeasurementReleaseSymbolName,
                            CIDescribeMeasurementImages()];
        }
        if (releaseSymbol) {
            // Unlike the Objective-C method below, a C symbol carries no type
            // information, so `void (void)` cannot be verified — it is inferred
            // from the name. The blast radius is much smaller: this symbol has
            // one caller inside Apple's launch measurement library, not the
            // whole process. Still, if a future iOS gives it a parameter or a
            // return value, this is where the resulting misbehaviour starts.
            void *originalRelease = NULL;
            MSHookFunction(
                releaseSymbol,
                (void *)CIAppLaunchMeasurementReleaseReplacement,
                &originalRelease
            );
            CIOriginalAppLaunchMeasurementRelease =
                (CIAppLaunchMeasurementReleaseImplementation)
                    originalRelease;
            CIDirectLaunchPrefetchReleaseHookInstalled =
                originalRelease != NULL;
        }

        Class assertionClass = NSClassFromString(@"RBSAssertion");
        Method method = class_getInstanceMethod(
            assertionClass,
            NSSelectorFromString(@"invalidate")
        );
        if (method && !CIAssertionInvalidateHasExpectedSignature(method)) {
            const char *encoding = method_getTypeEncoding(method);
            [CILogStore.sharedStore
                recordLevel:CILogLevelError
                   category:@"LaunchPrefetch"
                     format:@"Refusing to hook -[RBSAssertion invalidate]: its signature is \"%s\", not void (id, SEL). Replacing it would corrupt every unrelated assertion call in this process.",
                            encoding ?: "unknown"];
        } else if (method) {
            IMP previous = method_setImplementation(
                method,
                (IMP)CILaunchPrefetchAssertionInvalidate
            );
            CIOriginalRBSAssertionInvalidate =
                (CIRBSAssertionInvalidateImplementation)previous;
            CIRBSAssertionRetentionFallbackInstalled = previous != NULL;
        }
        CILaunchPrefetchRetentionProbeInstalled =
            CIDirectLaunchPrefetchReleaseHookInstalled ||
            CIRBSAssertionRetentionFallbackInstalled;
        if (!CILaunchPrefetchRetentionProbeInstalled) {
            [CILogStore.sharedStore
                recordLevel:CILogLevelWarning
                   category:@"LaunchPrefetch"
                    message:@"The LaunchPrefetch retention probe is unavailable: neither the direct app_launch_measurement release symbol nor RBSAssertion.invalidate could be hooked on this iOS version."];
        }
        [CILogStore.sharedStore
            recordLevel:CILogLevelInfo
               category:@"LaunchPrefetch"
                 format:@"LaunchPrefetch hooks installed=%@ directReleaseHook=%@ (image %@) rbsFallback=%@.",
                        CILaunchPrefetchRetentionProbeInstalled
                            ? @"yes" : @"no",
                        CIDirectLaunchPrefetchReleaseHookInstalled
                            ? @"yes" : @"no",
                        resolvedImage.lastPathComponent ?: @"unresolved",
                        CIRBSAssertionRetentionFallbackInstalled
                            ? @"yes" : @"no"];
    });
}

void CIInstallLaunchPrefetchRetentionProbe(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CIRetainedLaunchPrefetchAssertions = [NSMutableArray array];
        CILaunchPrefetchRetentionProbeEnabled = CIPreferenceBool(
            CILaunchPrefetchRetentionProbeEnabledKey,
            NO
        );
        if (!CILaunchPrefetchRetentionProbeEnabled) {
            // Nothing is hooked while the experiment is off. Installing
            // regardless would route every RBSAssertion invalidation in the
            // process — audio, PiP, background tasks, extensions — through this
            // file and take a lock on each one, which is not a cost a
            // default-off probe should impose. The hooks go in if and when the
            // switch is turned on.
            [CILogStore.sharedStore
                recordLevel:CILogLevelDebug
                   category:@"LaunchPrefetch"
                    message:@"LaunchPrefetch retention probe is off; no hooks were installed."];
            return;
        }
        CIInstallLaunchPrefetchHooksIfNeeded();
    });
}

void CIReloadLaunchPrefetchRetentionProbe(void) {
    CIInstallLaunchPrefetchRetentionProbe();
    BOOL enabled = CIPreferenceBool(
        CILaunchPrefetchRetentionProbeEnabledKey,
        NO
    );
    // Install before arming, so the flag is never on while the interception
    // points are still missing.
    if (enabled) CIInstallLaunchPrefetchHooksIfNeeded();
    @synchronized (CIRetainedLaunchPrefetchAssertions) {
        CILaunchPrefetchRetentionProbeEnabled = enabled;
    }
    if (!enabled) {
        CIReleaseRetainedLaunchPrefetchAssertions(
            @"the experiment was disabled"
        );
        return;
    }

    [CILogStore.sharedStore
        recordLevel:CILaunchPrefetchRetentionProbeInstalled
            ? CILogLevelInfo : CILogLevelWarning
           category:@"LaunchPrefetch"
            message:CILaunchPrefetchRetentionProbeInstalled
                ? @"LaunchPrefetch retention is armed. For the launch-time release path, fully terminate and reopen YouTube; the hooks are already live for a release that happens later in this session."
                : @"LaunchPrefetch retention was enabled, but no usable interception point exists on this iOS version."];
}

/// Reads one property off an RBS state object via KVC.
///
/// KVC is deliberate here: several of these properties return enums or
/// collection types whose exact signatures shift between iOS releases, and
/// guessing wrong with objc_msgSend would corrupt the stack. KVC boxes the
/// value safely and simply throws when the key is absent.
static NSString *CIDescribeStateKey(id state, NSString *key) {
    if (!state || key.length == 0) return nil;
    @try {
        id value = [state valueForKey:key];
        if (!value) return nil;
        // objc_msgSend rather than performSelector: the latter trips
        // -Warc-performSelector-leaks, and this target builds with -Werror.
        if ([value respondsToSelector:@selector(allObjects)]) {
            value = ((id (*)(id, SEL))objc_msgSend)(
                value,
                @selector(allObjects)
            );
        }
        if ([value isKindOfClass:NSArray.class]) {
            NSArray *items = (NSArray *)value;
            if (items.count == 0) return @"none";
            NSMutableArray<NSString *> *described =
                [NSMutableArray arrayWithCapacity:items.count];
            for (id item in items) {
                [described addObject:[item description] ?: @"?"];
            }
            return [described componentsJoinedByString:@", "];
        }
        return [value description];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

/// Summarises `rbAssertions` as a list of the assertion domains holding this
/// process up.
///
/// This is the field that matters: "Process is only playing background media"
/// is a statement about which assertions exist, and the raw description of the
/// assertion array is far too long to log intact. Each element is an
/// `RBSProcessAssertionInfo`, so pull just its domain (falling back to `name`).
static NSString *CIDescribeAssertionDomains(id state) {
    if (!state) return nil;
    // `rbAssertions` is reachable by KVC but does not hand back an NSArray, and
    // the element type is private, so parse the domains out of the state's own
    // description instead. That text is the one representation RunningBoard
    // guarantees, which makes it the sturdier choice for a diagnostic.
    NSString *description = [state description];
    if (description.length == 0) return nil;
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression
            regularExpressionWithPattern:@"domain:\"([^\"]*)\""
                                 options:0
                                   error:nil];
    });
    if (!expression) return nil;

    NSCountedSet<NSString *> *domains = [NSCountedSet set];
    [expression enumerateMatchesInString:description
                                options:0
                                  range:NSMakeRange(0, description.length)
                             usingBlock:^(NSTextCheckingResult *match,
                                          __unused NSMatchingFlags flags,
                                          __unused BOOL *stop) {
        if (match.numberOfRanges < 2) return;
        NSString *domain =
            [description substringWithRange:[match rangeAtIndex:1]];
        if (domain.length == 0) return;
        // Strip the ubiquitous prefix so the line stays readable.
        if ([domain hasPrefix:@"com.apple."]) {
            domain = [domain substringFromIndex:@"com.apple.".length];
        }
        [domains addObject:domain];
    }];
    if (domains.count == 0) return @"none";

    NSMutableArray<NSString *> *described =
        [NSMutableArray arrayWithCapacity:domains.count];
    for (NSString *domain in domains) {
        NSUInteger count = [domains countForObject:domain];
        [described addObject:count > 1
            ? [NSString stringWithFormat:@"%@ x%lu",
                domain, (unsigned long)count]
            : domain];
    }
    [described sortUsingSelector:@selector(compare:)];
    return [described componentsJoinedByString:@", "];
}

static NSString *CIClippedDescription(NSString *value) {
    NSString *text = value ?: @"";
    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (text.length <= CIDiagnosticsMaximumDescriptionLength) return text;
    NSRange range = [text rangeOfComposedCharacterSequencesForRange:
        NSMakeRange(0, CIDiagnosticsMaximumDescriptionLength)];
    return [[text substringWithRange:range] stringByAppendingString:@"…"];
}

void CILogProcessBackgroundEligibility(NSString *reason) {
    if (!NSThread.isMainThread) {
        NSString *copiedReason = [reason copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            CILogProcessBackgroundEligibility(copiedReason);
        });
        return;
    }

    UIApplication *application = UIApplication.sharedApplication;
    NSTimeInterval remaining = application.backgroundTimeRemaining;
    // UIKit reports an effectively infinite allowance while a background mode
    // such as audio is keeping the process alive, so report that distinctly
    // rather than printing a meaningless very large number.
    NSString *remainingText = remaining >= DBL_MAX / 2
        ? @"unlimited"
        : [NSString stringWithFormat:@"%.1fs", remaining];

    id state = CICurrentRunningBoardProcessState();
    NSString *endowments =
        CIDescribeStateKey(state, @"endowmentNamespaces") ?: @"none";
    NSString *taskState =
        CIDescribeStateKey(state, @"taskState") ?: @"unavailable";
    NSString *tags = CIDescribeStateKey(state, @"tags") ?: @"none";
    NSString *cpuRole =
        CIDescribeStateKey(state, @"cpuRole") ?: @"unavailable";
    // The assertion list is the field that actually decides whether the
    // process counts as "only playing background media".
    NSString *assertions =
        CIDescribeAssertionDomains(state) ?: @"unavailable";

    [CILogStore.sharedStore
        recordLevel:CILogLevelInfo
           category:@"Eligibility"
             format:@"%@ | appState=%ld bgTimeRemaining=%@ | taskState=%@ cpuRole=%@ tags=[%@] endowments=[%@] | assertions=[%@]",
                    reason.length > 0 ? reason : @"snapshot",
                    (long)application.applicationState,
                    remainingText,
                    taskState,
                    cpuRole,
                    tags,
                    endowments,
                    assertions];

    // The property names above are not contractual. Keep the raw description
    // as a debug-only fallback so a future iOS release that renames them still
    // leaves something diagnosable in the log.
    if (state) {
        [CILogStore.sharedStore
            recordLevel:CILogLevelDebug
               category:@"Eligibility"
                 format:@"RunningBoard raw state: %@",
                        CIClippedDescription([state description])];
    } else {
        [CILogStore.sharedStore
            recordLevel:CILogLevelDebug
               category:@"Eligibility"
                message:@"RunningBoard process state was unavailable; only the public background allowance was sampled."];
    }
}
