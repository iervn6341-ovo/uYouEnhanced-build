#import "CIProcessDiagnostics.h"
#import "CILogStore.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <float.h>

static const NSUInteger CIDiagnosticsMaximumDescriptionLength = 900;

/// Returns RunningBoard's current state object for this process, or nil when
/// the private framework or its selectors are not available. RunningBoard is
/// the component that decides which background endowments a process holds, so
/// its view is the one `liveactivitiesd` ultimately consults.
static id CICurrentRunningBoardProcessState(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // UIKit apps normally have this linked already; load it explicitly so
        // the diagnostic still works if it happens not to be resident.
        if (!NSClassFromString(@"RBSProcessHandle")) {
            dlopen(
                "/System/Library/PrivateFrameworks/RunningBoardServices.framework"
                "/RunningBoardServices",
                RTLD_LAZY
            );
        }
    });

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
    @try {
        id assertions = [state valueForKey:@"rbAssertions"];
        if ([assertions respondsToSelector:@selector(allObjects)]) {
            assertions = ((id (*)(id, SEL))objc_msgSend)(
                assertions,
                @selector(allObjects)
            );
        }
        if (![assertions isKindOfClass:NSArray.class]) return nil;
        NSArray *items = (NSArray *)assertions;
        if (items.count == 0) return @"none";
        NSCountedSet<NSString *> *domains = [NSCountedSet set];
        for (id item in items) {
            NSString *domain = nil;
            @try {
                domain = [item valueForKey:@"domain"];
                if (domain.length == 0) domain = [item valueForKey:@"name"];
            } @catch (__unused NSException *exception) {
                domain = nil;
            }
            [domains addObject:domain.length > 0 ? domain : @"?"];
        }
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
    } @catch (__unused NSException *exception) {
        return nil;
    }
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
