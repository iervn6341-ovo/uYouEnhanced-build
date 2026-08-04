#import "CIProcessDiagnostics.h"
#import "CIConstants.h"
#import "CILogStore.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <float.h>
#import <unistd.h>

static const NSUInteger CIDiagnosticsMaximumDescriptionLength = 900;
static const NSUInteger CIRetainedLaunchPrefetchAssertionLimit = 4;

typedef void (*CIRBSAssertionInvalidateImplementation)(id, SEL);

static CIRBSAssertionInvalidateImplementation
    CIOriginalRBSAssertionInvalidate;
static NSMutableArray *CIRetainedLaunchPrefetchAssertions;
static BOOL CILaunchPrefetchRetentionProbeInstalled;
static BOOL CILaunchPrefetchRetentionProbeEnabled;

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

/// Matches only Apple's page-in recording assertion for this exact process.
/// Matching all three fields matters because `RBSAssertion` is also used for
/// unrelated UIKit, audio and other-process assertions in the same address
/// space; retaining any of those would make the experiment unsafe and muddy
/// its result.
static BOOL CIIsCurrentProcessLaunchPrefetchAssertion(id assertion) {
    NSString *explanation = [CIAssertionValue(
        assertion,
        @"explanation"
    ) description];
    if (!CITextContainsCaseInsensitive(
            explanation,
            @"app_launch_measurement") ||
        !CITextContainsCaseInsensitive(
            explanation,
            @"pageins recording enabled")) {
        return NO;
    }

    id descriptor = CIAssertionValue(assertion, @"descriptor");
    NSString *descriptorText = [descriptor description];
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
    NSString *targetText = [target description];
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    BOOL bundleMatches = bundleIdentifier.length > 0 &&
        CITextContainsCaseInsensitive(targetText, bundleIdentifier);
    NSString *pidToken = [NSString stringWithFormat:@":%d", getpid()];
    BOOL pidMatches = [targetText containsString:pidToken];
    return bundleMatches || pidMatches;
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

    BOOL shouldRetain = NO;
    NSUInteger retainedCount = 0;
    @synchronized (CIRetainedLaunchPrefetchAssertions) {
        if (CILaunchPrefetchRetentionProbeEnabled &&
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
        }
    }

    if (!shouldRetain) {
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

void CIReleaseRetainedLaunchPrefetchAssertions(NSString *reason) {
    NSArray *assertions = nil;
    @synchronized (CIRetainedLaunchPrefetchAssertions) {
        assertions = CIRetainedLaunchPrefetchAssertions.copy;
        [CIRetainedLaunchPrefetchAssertions removeAllObjects];
    }
    if (assertions.count == 0) return;
    CIReleaseLaunchPrefetchAssertions(assertions, reason);
}

void CIInstallLaunchPrefetchRetentionProbe(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CILaunchPrefetchRetentionProbeEnabled = CIPreferenceBool(
            CILaunchPrefetchRetentionProbeEnabledKey,
            NO
        );
        CIRetainedLaunchPrefetchAssertions = [NSMutableArray array];
        CILoadRunningBoardServices();

        Class assertionClass = NSClassFromString(@"RBSAssertion");
        Method method = class_getInstanceMethod(
            assertionClass,
            NSSelectorFromString(@"invalidate")
        );
        if (!method) {
            [CILogStore.sharedStore
                recordLevel:CILogLevelWarning
                   category:@"LaunchPrefetch"
                    message:@"The LaunchPrefetch retention probe is unavailable because RBSAssertion.invalidate was not found on this iOS version."];
            return;
        }

        IMP previous = method_setImplementation(
            method,
            (IMP)CILaunchPrefetchAssertionInvalidate
        );
        CIOriginalRBSAssertionInvalidate =
            (CIRBSAssertionInvalidateImplementation)previous;
        CILaunchPrefetchRetentionProbeInstalled = previous != NULL;
        [CILogStore.sharedStore
            recordLevel:CILaunchPrefetchRetentionProbeEnabled
                ? CILogLevelInfo : CILogLevelDebug
               category:@"LaunchPrefetch"
                 format:@"LaunchPrefetch retention probe installed=%@ enabled=%@.",
                        CILaunchPrefetchRetentionProbeInstalled
                            ? @"yes" : @"no",
                        CILaunchPrefetchRetentionProbeEnabled
                            ? @"yes" : @"no"];
    });
}

void CIReloadLaunchPrefetchRetentionProbe(void) {
    CIInstallLaunchPrefetchRetentionProbe();
    BOOL enabled = CIPreferenceBool(
        CILaunchPrefetchRetentionProbeEnabledKey,
        NO
    );
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
                ? @"LaunchPrefetch retention is armed. Fully terminate and reopen YouTube so app_launch_measurement can acquire a fresh assertion."
                : @"LaunchPrefetch retention was enabled, but the RBSAssertion interception point is unavailable on this iOS version."];
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
