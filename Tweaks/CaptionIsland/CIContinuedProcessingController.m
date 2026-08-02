#import "CIContinuedProcessingController.h"
#import "CIConstants.h"
#import "CILogStore.h"
#import "CIVideoEligibility.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <math.h>

static NSString *const CIContinuedTaskIdentifierSuffix =
    @".captionisland.background-captions";
static const NSTimeInterval CIContinuedProgressMinimumInterval = 0.75;
static const NSUInteger CIContinuedSubmissionMaximumAttempts = 4;
// BGContinuedProcessingTaskRequestSubmissionStrategyFail is zero on iOS 26.
// Keep the value local because this target intentionally builds with the iOS
// 17.5 SDK and resolves the iOS 26 API dynamically.
static const NSInteger CIContinuedSubmissionStrategyFail = 0;

NSNotificationName const
    CIContinuedProcessingRuntimeDidChangeNotification =
        @"CIContinuedProcessingRuntimeDidChangeNotification";

static NSString *CIContinuedClippedText(
    NSString *value,
    NSUInteger maximumCharacters
) {
    NSString *text = value ?: @"";
    if (text.length <= maximumCharacters) return text;
    NSRange range = [text rangeOfComposedCharacterSequencesForRange:
        NSMakeRange(0, maximumCharacters)];
    return [[text substringWithRange:range]
        stringByAppendingString:@"…"];
}

BOOL CIContinuedBackgroundProcessingSupported(void) {
    if (@available(iOS 26.0, *)) {
        Class requestClass =
            NSClassFromString(@"BGContinuedProcessingTaskRequest");
        Class taskClass =
            NSClassFromString(@"BGContinuedProcessingTask");
        Class schedulerClass = NSClassFromString(@"BGTaskScheduler");
        return requestClass && taskClass && schedulerClass &&
            [requestClass instancesRespondToSelector:
                NSSelectorFromString(@"initWithIdentifier:title:subtitle:")] &&
            [taskClass instancesRespondToSelector:
                NSSelectorFromString(@"updateTitle:subtitle:")];
    }
    return NO;
}

@interface CIContinuedProcessingController ()
@property (nonatomic, strong, nullable) id scheduler;
@property (atomic, strong, nullable) id runningTask;
@property (atomic) BOOL runtimeLeaseValid;
@property (nonatomic, copy) NSString *taskIdentifier;
@property (nonatomic, copy) NSString *taskIdentifierPrefix;
@property (nonatomic, copy) NSString *permittedTaskIdentifier;
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSString *videoTitle;
@property (nonatomic, copy) NSString *captionLine;
@property (nonatomic, copy) NSString *nextCaptionLine;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) NSTimeInterval playbackTime;
@property (nonatomic) BOOL videoIsShorts;
@property (nonatomic) NSTimeInterval lastProgressUptime;
@property (atomic) BOOL requestPending;
@property (nonatomic) NSTimeInterval requestSubmittedUptime;
@property (nonatomic) BOOL needsForegroundRestart;
@property (nonatomic) BOOL playing;
@property (nonatomic) BOOL suppressed;
@property (nonatomic) BOOL didLogBackgroundStartRejection;
@property (atomic) BOOL applicationEnteredBackground;
@property (atomic) NSUInteger requestGeneration;
@property (atomic) NSUInteger grantedGeneration;
@property (atomic) NSUInteger backgroundGeneration;
@property (nonatomic) BOOL submissionRetryScheduled;
@property (nonatomic, copy) NSString *progressVideoID;
@property (nonatomic) int64_t progressBaseUnitCount;
@property (nonatomic) int64_t progressVideoMaximumUnitCount;
@property (nonatomic) int64_t lastReportedCompletedUnitCount;
@property (nonatomic) int64_t lastReportedTotalUnitCount;
@property (nonatomic) NSUInteger backgroundCycleCount;
@property (nonatomic) BOOL registeredWildcardHandler;
- (BOOL)hasTaskSession;
- (BOOL)submitRequestForCurrentVideoAttempt:(NSUInteger)attempt;
- (void)rollOverForNextBackgroundCycle;
- (void)cancelPendingRequestWithIdentifier:(NSString *)taskIdentifier;
- (void)completeTask:(nullable id)task success:(BOOL)success;
- (void)schedulePendingRequestDiagnosticForGeneration:(NSUInteger)generation;
- (void)scheduleSubmissionRetryForGeneration:(NSUInteger)generation
                                      attempt:(NSUInteger)attempt
                                        error:(nullable NSError *)error;
- (void)prepareProgressSegmentForVideoID:(NSString *)videoID;
- (void)resetProgressAccounting;
- (void)notifyRuntimeChanged;
- (BOOL)ensureWildcardTaskHandlerRegistered;
- (void)handleLaunchedTask:(id)task;
- (void)handleTaskExpiration:(id)task
                  generation:(NSUInteger)generation;
- (void)updateRunningTaskUI;
- (void)updateRunningTaskProgressForce:(BOOL)force;
- (void)applicationDidBecomeActive:(NSNotification *)notification;
- (void)applicationDidEnterBackground:(NSNotification *)notification;
@end

@implementation CIContinuedProcessingController

+ (instancetype)sharedController {
    static CIContinuedProcessingController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [CIContinuedProcessingController new];
    });
    return controller;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSString *bundleID =
            NSBundle.mainBundle.bundleIdentifier ?: @"";
        NSString *taskPrefix = [bundleID
            stringByAppendingString:CIContinuedTaskIdentifierSuffix];
        _taskIdentifierPrefix = taskPrefix;
        _taskIdentifier = @"";
        _permittedTaskIdentifier = [taskPrefix
            stringByAppendingString:@".*"];
        _videoID = @"";
        _videoTitle = @"";
        _captionLine = @"";
        _nextCaptionLine = @"";
        _progressVideoID = @"";
        _playing = YES;
        _applicationEnteredBackground =
            UIApplication.sharedApplication.applicationState ==
                UIApplicationStateBackground;
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(applicationDidBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(applicationDidEnterBackground:)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)isTaskActive {
    NSUInteger generation = self.requestGeneration;
    return self.runtimeLeaseValid && self.runningTask != nil &&
        generation != 0 && self.grantedGeneration == generation;
}

- (BOOL)isTaskPending {
    return self.requestPending;
}

- (BOOL)hasTaskSession {
    return self.runningTask != nil || self.requestPending ||
        self.submissionRetryScheduled;
}

- (BOOL)localActivityUpdatesPermitted {
    BOOL applicationIsBackgrounded = self.applicationEnteredBackground ||
        UIApplication.sharedApplication.applicationState ==
            UIApplicationStateBackground;
    if (!CIContinuedBackgroundProcessingSupported() ||
        !CIPreferenceBool(
            CIContinuedBackgroundProcessingEnabledKey,
            NO
        ) ||
        !applicationIsBackgrounded) {
        return YES;
    }
    NSUInteger backgroundGeneration = self.backgroundGeneration;
    return backgroundGeneration != 0 && self.taskActive &&
        self.grantedGeneration == backgroundGeneration;
}

- (void)beginForVideoID:(NSString *)videoID
                  title:(NSString *)title
               duration:(NSTimeInterval)duration
                 shorts:(BOOL)isShorts {
    if (!NSThread.isMainThread) {
        NSString *copiedVideoID = [videoID copy];
        NSString *copiedTitle = [title copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self beginForVideoID:copiedVideoID
                            title:copiedTitle
                         duration:duration
                           shorts:isShorts];
        });
        return;
    }

    BOOL preferenceEnabled = CIPreferenceBool(
        CIContinuedBackgroundProcessingEnabledKey,
        NO
    );
    BOOL captionIslandEnabled =
        CIPreferenceBool(CIEnabledKey, YES);
    if (!captionIslandEnabled || !preferenceEnabled ||
        !CIContinuedBackgroundProcessingSupported() ||
        videoID.length == 0) {
        if (([self hasTaskSession] || self.needsForegroundRestart) &&
            (!captionIslandEnabled || !preferenceEnabled)) {
            [self endWithReason:
                !captionIslandEnabled
                    ? @"Caption Island was disabled"
                    : @"the iOS 26 continued background caption option was disabled"
                       success:YES];
        }
        return;
    }

    CIVideoExclusionReason exclusion =
        CIVideoExclusionReasonForPlayback(
            isShorts,
            CIPreferenceBool(CIDisableForShortsKey, YES),
            duration,
            CIMaximumVideoDurationMinutes()
        );
    if (exclusion != CIVideoExclusionReasonNone) {
        if ([self hasTaskSession] || self.needsForegroundRestart) {
            [self endWithReason:exclusion ==
                    CIVideoExclusionReasonShorts
                    ? @"the active video is a Short"
                    : @"the active video exceeds the configured duration limit"
                       success:YES];
        }
        return;
    }

    BOOL sameVideo = [self.videoID isEqualToString:videoID];
    BOOL existingSession = [self hasTaskSession];
    BOOL retryOnly = self.submissionRetryScheduled &&
        !self.runningTask && !self.requestPending;
    if (retryOnly && !sameVideo) {
        // The delayed block belongs to the previous video's failed request.
        // Revoke it before retargeting so it cannot keep the controller in a
        // phantom "session" with no submitted or granted task.
        self.submissionRetryScheduled = NO;
        self.requestGeneration++;
        self.taskIdentifier = @"";
        existingSession = NO;
    }
    if (existingSession && !sameVideo) {
        [self prepareProgressSegmentForVideoID:videoID];
    }
    self.videoID = [videoID copy];
    self.videoTitle =
        title.length > 0 ? [title copy] : @"YouTube";
    self.videoIsShorts = isShorts;
    if (isfinite(duration) && duration > 0) {
        self.duration = duration;
    }

    if (existingSession) {
        if (!sameVideo) {
            self.playbackTime = 0;
            self.captionLine = @"";
            self.nextCaptionLine = @"";
            [CILogStore.sharedStore
                recordLevel:CILogLevelInfo
                   category:@"ContinuedTask"
                     format:@"Retargeted the existing iOS 26 background caption session to video %@ without replacing its runtime lease.",
                            videoID];
        }
        [self updateRunningTaskProgressForce:!sameVideo];
        [self updateRunningTaskUI];
        return;
    }

    if (UIApplication.sharedApplication.applicationState !=
        UIApplicationStateActive) {
        if (!self.didLogBackgroundStartRejection) {
            self.didLogBackgroundStartRejection = YES;
            [CILogStore.sharedStore
                recordLevel:CILogLevelWarning
                   category:@"ContinuedTask"
                    message:@"iOS 26 requires a continued processing task to begin from an explicit foreground action; the background video could not start a new task."];
        }
        return;
    }
    self.didLogBackgroundStartRejection = NO;

    [self submitRequestForCurrentVideoAttempt:1];
}

- (BOOL)submitRequestForCurrentVideoAttempt:(NSUInteger)attempt {
    if (self.videoID.length == 0 ||
        UIApplication.sharedApplication.applicationState !=
            UIApplicationStateActive) {
        self.submissionRetryScheduled = NO;
        self.needsForegroundRestart = YES;
        return NO;
    }
    self.submissionRetryScheduled = NO;

    // Continued-processing identifiers represent individual jobs. Reusing a
    // completed identifier makes scheduler state from an earlier foreground /
    // background cycle ambiguous, so every request still gets a generation
    // and a unique suffix under the permitted wildcard. The launch handler
    // itself, however, is registered exactly once for the wildcard pattern
    // (see ensureWildcardTaskHandlerRegistered) — BGTaskScheduler expects a
    // single registration per identifier for the process lifetime, and
    // re-registering a fresh concrete identifier on every submission was
    // rejected outright by the scheduler on every attempt.
    NSUInteger generation = self.requestGeneration + 1;
    NSString *taskIdentifier = [self.taskIdentifierPrefix
        stringByAppendingFormat:@".%@",
            NSUUID.UUID.UUIDString.lowercaseString];
    if (![self ensureWildcardTaskHandlerRegistered]) {
        self.needsForegroundRestart = YES;
        return NO;
    }

    self.requestGeneration = generation;
    self.taskIdentifier = taskIdentifier;
    self.runtimeLeaseValid = NO;
    self.grantedGeneration = 0;

    Class requestClass =
        NSClassFromString(@"BGContinuedProcessingTaskRequest");
    SEL initializer =
        NSSelectorFromString(@"initWithIdentifier:title:subtitle:");
    NSString *requestTitle = CILocalized(
        @"CONTINUED_TASK_SYSTEM_TITLE",
        @"Background captions"
    );
    id request = nil;
    @try {
        request = ((id (*)(id, SEL, NSString *, NSString *, NSString *))
            objc_msgSend)(
                [requestClass alloc],
                initializer,
                taskIdentifier,
                requestTitle,
                self.videoTitle
            );
    } @catch (NSException *exception) {
        if (self.requestGeneration == generation) {
            self.taskIdentifier = @"";
        }
        [CILogStore.sharedStore
            recordLevel:CILogLevelError
               category:@"ContinuedTask"
                 format:@"iOS 26 rejected creation of the background caption request: %@",
                        exception.reason ?: exception.name];
        self.needsForegroundRestart = YES;
        return NO;
    }
    if (!request) {
        if (self.requestGeneration == generation) {
            self.taskIdentifier = @"";
        }
        [CILogStore.sharedStore
            recordLevel:CILogLevelError
               category:@"ContinuedTask"
                message:@"Unable to create the iOS 26 continued processing request."];
        self.needsForegroundRestart = YES;
        return NO;
    }
    // This workload is useful only when it starts during the current
    // foreground visit. Queueing can leave a stale request that launches in a
    // later background cycle and makes an old Objective-C task look valid.
    // Ask for immediate execution and retry briefly while YouTube is active.
    SEL strategySelector = NSSelectorFromString(@"setStrategy:");
    if ([request respondsToSelector:strategySelector]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(
            request,
            strategySelector,
            CIContinuedSubmissionStrategyFail
        );
    }

    NSError *error = nil;
    SEL submitSelector =
        NSSelectorFromString(@"submitTaskRequest:error:");
    BOOL submitted = NO;
    self.requestPending = YES;
    self.requestSubmittedUptime =
        NSProcessInfo.processInfo.systemUptime;
    @try {
        submitted =
            [self.scheduler respondsToSelector:submitSelector] &&
            ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(
                self.scheduler,
                submitSelector,
                request,
                &error
            );
    } @catch (NSException *exception) {
        self.requestPending = NO;
        self.requestSubmittedUptime = 0;
        if (self.requestGeneration == generation) {
            self.taskIdentifier = @"";
        }
        self.needsForegroundRestart = YES;
        [CILogStore.sharedStore
            recordLevel:CILogLevelError
               category:@"ContinuedTask"
                 format:@"iOS 26 rejected submission of the background caption task: %@",
                        exception.reason ?: exception.name];
        return NO;
    }
    if (!submitted) {
        self.requestPending = NO;
        self.requestSubmittedUptime = 0;
        if (self.requestGeneration == generation) {
            self.taskIdentifier = @"";
        }
        self.needsForegroundRestart = YES;
        [CILogStore.sharedStore
            recordLevel:attempt < CIContinuedSubmissionMaximumAttempts
                ? CILogLevelWarning : CILogLevelError
               category:@"ContinuedTask"
                 format:@"Immediate iOS 26 continued caption submission attempt %lu failed (code=%ld): %@",
                        (unsigned long)attempt,
                        (long)error.code,
                        error.localizedDescription ?: @"unknown error"];
        [self scheduleSubmissionRetryForGeneration:generation
                                           attempt:attempt
                                             error:error];
        return NO;
    }
    self.needsForegroundRestart = NO;

    [CILogStore.sharedStore
        recordLevel:CILogLevelInfo
           category:@"ContinuedTask"
             format:@"Submitted immediate iOS 26 continued caption task generation %lu (%@) for video %@ on attempt %lu; authorization still waits for its launch handler.",
                    (unsigned long)generation,
                    taskIdentifier,
                    self.videoID,
                    (unsigned long)attempt];
    [self schedulePendingRequestDiagnosticForGeneration:generation];
    return YES;
}

// BGTaskScheduler expects registerForTaskWithIdentifier:usingQueue:
// launchHandler: to be called exactly once per identifier for the process's
// lifetime. BGContinuedProcessingTaskRequest identifiers are declared in
// Info.plist as a single wildcard prefix (ending in ".*"), and Apple's own
// model registers ONE handler for that wildcard string itself — individual
// jobs only need their own unique identifier at *submission* time via
// submitTaskRequest:. Registering a fresh concrete identifier here on every
// submission (the previous implementation) is a different, unsupported
// pattern: BGTaskScheduler rejected it outright on every single attempt,
// including the very first one, which matches "register once per job" not
// being valid usage rather than any transient scheduler capacity limit.
- (BOOL)ensureWildcardTaskHandlerRegistered {
    if (self.registeredWildcardHandler) return YES;

    NSArray<NSString *> *permittedIdentifiers =
        [NSBundle.mainBundle objectForInfoDictionaryKey:
            @"BGTaskSchedulerPermittedIdentifiers"];
    if (![permittedIdentifiers isKindOfClass:NSArray.class] ||
        ![permittedIdentifiers containsObject:
            self.permittedTaskIdentifier]) {
        [CILogStore.sharedStore
            recordLevel:CILogLevelError
               category:@"ContinuedTask"
                 format:@"The installed app is missing BGTaskSchedulerPermittedIdentifiers entry %@; rebuild the IPA with Caption Island metadata injection.",
                        self.permittedTaskIdentifier];
        return NO;
    }

    id scheduler = self.scheduler;
    if (!scheduler) {
        Class schedulerClass = NSClassFromString(@"BGTaskScheduler");
        SEL sharedSelector = NSSelectorFromString(@"sharedScheduler");
        scheduler = [schedulerClass respondsToSelector:sharedSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(
                schedulerClass,
                sharedSelector
            ) : nil;
    }
    if (!scheduler) {
        [CILogStore.sharedStore
            recordLevel:CILogLevelError
               category:@"ContinuedTask"
                message:@"BGTaskScheduler is unavailable in the installed target."];
        return NO;
    }

    __weak typeof(self) weakSelf = self;
    void (^launchHandler)(id) = ^(id task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleLaunchedTask:task];
        });
    };
    NSString *wildcardIdentifier = self.permittedTaskIdentifier;
    SEL registerSelector = NSSelectorFromString(
        @"registerForTaskWithIdentifier:usingQueue:launchHandler:"
    );
    BOOL registered = NO;
    @try {
        registered =
            [scheduler respondsToSelector:registerSelector] &&
            ((BOOL (*)(id, SEL, NSString *, dispatch_queue_t, void (^)(id)))
                objc_msgSend)(
                    scheduler,
                    registerSelector,
                    wildcardIdentifier,
                    dispatch_get_main_queue(),
                    launchHandler
                );
    } @catch (NSException *exception) {
        [CILogStore.sharedStore
            recordLevel:CILogLevelError
               category:@"ContinuedTask"
                 format:@"iOS 26 rejected background task registration: %@",
                        exception.reason ?: exception.name];
        return NO;
    }
    if (!registered) {
        [CILogStore.sharedStore
            recordLevel:CILogLevelError
               category:@"ContinuedTask"
                 format:@"BGTaskScheduler rejected registration for %@.",
                        wildcardIdentifier];
        return NO;
    }

    self.scheduler = scheduler;
    self.registeredWildcardHandler = YES;
    [CILogStore.sharedStore
        recordLevel:CILogLevelDebug
           category:@"ContinuedTask"
             format:@"Registered iOS 26 background task wildcard handler %@.",
                    wildcardIdentifier];
    return YES;
}

- (void)handleLaunchedTask:(id)task {
    if (!task) return;
    NSString *taskIdentifier = @"";
    @try {
        id candidate = [task valueForKey:@"identifier"];
        if ([candidate isKindOfClass:NSString.class]) {
            taskIdentifier = candidate;
        }
    } @catch (__unused NSException *exception) {
        taskIdentifier = @"";
    }
    // The handler is now shared across every job (registered once for the
    // wildcard), so the generation this launch corresponds to is resolved by
    // matching the task's own identifier against whichever concrete
    // identifier is currently outstanding, rather than a value captured at
    // registration time.
    NSUInteger generation = self.requestGeneration;
    if (taskIdentifier.length == 0 ||
        ![taskIdentifier isEqualToString:self.taskIdentifier]) {
        [self completeTask:task success:NO];
        [CILogStore.sharedStore
            recordLevel:CILogLevelWarning
               category:@"ContinuedTask"
                 format:@"Rejected delayed launch for superseded continued task (%@); current identifier is %@.",
                        taskIdentifier,
                        self.taskIdentifier];
        return;
    }
    self.requestPending = NO;
    self.requestSubmittedUptime = 0;
    if (!CIPreferenceBool(
            CIContinuedBackgroundProcessingEnabledKey,
            NO) ||
        self.videoID.length == 0) {
        [self completeTask:task success:NO];
        self.taskIdentifier = @"";
        self.needsForegroundRestart = NO;
        return;
    }

    if (self.runningTask && self.runningTask != task) {
        [self completeTask:self.runningTask success:YES];
    }
    self.runningTask = task;
    self.runtimeLeaseValid = YES;
    self.grantedGeneration = generation;
    self.needsForegroundRestart = NO;
    [self resetProgressAccounting];

    __weak typeof(self) weakSelf = self;
    __weak id weakTask = task;
    void (^expirationHandler)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleTaskExpiration:weakTask
                                generation:generation];
        });
    };
    SEL expirationSelector =
        NSSelectorFromString(@"setExpirationHandler:");
    if ([task respondsToSelector:expirationSelector]) {
        ((void (*)(id, SEL, void (^)(void)))objc_msgSend)(
            task,
            expirationSelector,
            expirationHandler
        );
    }

    [self updateRunningTaskProgressForce:YES];
    [self updateRunningTaskUI];
    [CILogStore.sharedStore
        recordLevel:CILogLevelInfo
           category:@"ContinuedTask"
             format:@"iOS 26 granted continued background runtime for generation %lu (%@); background generation is %lu.",
                    (unsigned long)generation,
                    taskIdentifier,
                    (unsigned long)self.backgroundGeneration];
    [self notifyRuntimeChanged];
}

- (void)handleTaskExpiration:(id)task
                  generation:(NSUInteger)generation {
    if (!task || task != self.runningTask ||
        generation != self.grantedGeneration) return;
    SEL expirationSelector =
        NSSelectorFromString(@"setExpirationHandler:");
    if ([task respondsToSelector:expirationSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            task,
            expirationSelector,
            nil
        );
    }
    SEL completeSelector =
        NSSelectorFromString(@"setTaskCompletedWithSuccess:");
    if ([task respondsToSelector:completeSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            task,
            completeSelector,
            NO
        );
    }
    self.runningTask = nil;
    self.runtimeLeaseValid = NO;
    self.grantedGeneration = 0;
    self.requestPending = NO;
    self.requestSubmittedUptime = 0;
    self.taskIdentifier = @"";
    self.needsForegroundRestart = YES;
    [CILogStore.sharedStore
        recordLevel:CILogLevelWarning
           category:@"ContinuedTask"
             format:@"iOS 26 expired continued caption runtime generation %lu; local ActivityKit updates are revoked until a fresh foreground request is granted.",
                    (unsigned long)generation];
    [self notifyRuntimeChanged];
}

- (void)rollOverForNextBackgroundCycle {
    id predecessorTask = self.runningTask;
    NSString *predecessorIdentifier = [self.taskIdentifier copy];
    NSUInteger predecessorGeneration = self.requestGeneration;
    BOOL predecessorWasGranted = self.taskActive;

    // Invalidate the old generation before submitting its successor. The
    // Objective-C task object can outlive its RunningBoard assertion, so no
    // caller may use pointer presence as proof that the next background cycle
    // is authorized.
    self.runningTask = nil;
    self.runtimeLeaseValid = NO;
    self.grantedGeneration = 0;
    if (self.requestPending) {
        [self cancelPendingRequestWithIdentifier:predecessorIdentifier];
    }
    self.requestPending = NO;
    self.requestSubmittedUptime = 0;
    self.submissionRetryScheduled = NO;
    self.taskIdentifier = @"";
    self.needsForegroundRestart = YES;
    if (predecessorWasGranted) [self notifyRuntimeChanged];

    // Finish the old scheduler job before asking for the next cycle. The new
    // request uses the fail strategy, so a still-draining scheduler slot is
    // visible immediately and handled by bounded foreground retries instead
    // of becoming a stale queued request.
    [self completeTask:predecessorTask success:YES];
    BOOL submitted = [self submitRequestForCurrentVideoAttempt:1];

    if (submitted || self.submissionRetryScheduled) {
        [CILogStore.sharedStore
            recordLevel:CILogLevelInfo
               category:@"ContinuedTask"
                 format:@"Retired foreground-return generation %lu and prepared generation %lu for the next background cycle%@.",
                        (unsigned long)predecessorGeneration,
                        (unsigned long)self.requestGeneration,
                        submitted ? @"" : @" with a bounded retry"];
    } else {
        [CILogStore.sharedStore
            recordLevel:CILogLevelWarning
               category:@"ContinuedTask"
                 format:@"Retired foreground-return generation %lu, but its replacement could not be submitted while YouTube was active.",
                        (unsigned long)predecessorGeneration];
    }
}

- (void)scheduleSubmissionRetryForGeneration:(NSUInteger)generation
                                      attempt:(NSUInteger)attempt
                                        error:(NSError *)error {
    if (attempt >= CIContinuedSubmissionMaximumAttempts) return;
    BOOL schedulerCapacityFailure = !error ||
        ([error.domain isEqualToString:@"BGTaskSchedulerErrorDomain"] &&
            (error.code == 2 || error.code == 4));
    if (!schedulerCapacityFailure) return;

    self.submissionRetryScheduled = YES;
    NSTimeInterval delay = attempt == 1 ? 0.15 :
        (attempt == 2 ? 0.45 : 0.90);
    NSString *videoID = [self.videoID copy];
    __weak typeof(self) weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.requestGeneration ||
                !strongSelf.submissionRetryScheduled) return;
            strongSelf.submissionRetryScheduled = NO;
            if (![strongSelf.videoID isEqualToString:videoID]) {
                strongSelf.needsForegroundRestart = YES;
                return;
            }
            if (UIApplication.sharedApplication.applicationState !=
                    UIApplicationStateActive) {
                strongSelf.needsForegroundRestart = YES;
                [CILogStore.sharedStore
                    recordLevel:CILogLevelWarning
                       category:@"ContinuedTask"
                        message:@"Skipped the continued caption retry because YouTube left the foreground before a fresh runtime was granted."];
                return;
            }
            [strongSelf submitRequestForCurrentVideoAttempt:attempt + 1];
        }
    );
}

- (void)cancelPendingRequestWithIdentifier:(NSString *)taskIdentifier {
    if (taskIdentifier.length == 0 || !self.scheduler) return;
    SEL cancelSelector =
        NSSelectorFromString(@"cancelTaskRequestWithIdentifier:");
    if ([self.scheduler respondsToSelector:cancelSelector]) {
        ((void (*)(id, SEL, NSString *))objc_msgSend)(
            self.scheduler,
            cancelSelector,
            taskIdentifier
        );
    }
}

- (void)completeTask:(id)task success:(BOOL)success {
    if (!task) return;
    SEL expirationSelector =
        NSSelectorFromString(@"setExpirationHandler:");
    if ([task respondsToSelector:expirationSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            task,
            expirationSelector,
            nil
        );
    }
    SEL completeSelector =
        NSSelectorFromString(@"setTaskCompletedWithSuccess:");
    if ([task respondsToSelector:completeSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            task,
            completeSelector,
            success
        );
    }
}

- (void)schedulePendingRequestDiagnosticForGeneration:
    (NSUInteger)generation {
    __weak typeof(self) weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.requestGeneration ||
                !strongSelf.requestPending) return;
            NSTimeInterval pendingSeconds = MAX(
                0,
                NSProcessInfo.processInfo.systemUptime -
                    strongSelf.requestSubmittedUptime
            );
            [CILogStore.sharedStore
                recordLevel:CILogLevelWarning
                   category:@"ContinuedTask"
                     format:@"Continued caption generation %lu still awaits its launch handler after %.1fs (applicationState=%ld); it is not considered authorized yet.",
                            (unsigned long)generation,
                            pendingSeconds,
                            (long)UIApplication.sharedApplication.applicationState];
        }
    );
}

- (void)applicationDidBecomeActive:
    (__unused NSNotification *)notification {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self applicationDidBecomeActive:nil];
        });
        return;
    }
    BOOL returnedFromBackground = self.applicationEnteredBackground;
    self.applicationEnteredBackground = NO;
    self.backgroundGeneration = 0;
    if (self.videoID.length == 0 ||
        !CIPreferenceBool(
            CIContinuedBackgroundProcessingEnabledKey,
        NO
    )) return;

    if (returnedFromBackground) {
        [self rollOverForNextBackgroundCycle];
        return;
    }

    if (self.taskActive) {
        [self updateRunningTaskProgressForce:YES];
        [self updateRunningTaskUI];
        return;
    }

    if (self.taskPending || self.submissionRetryScheduled) return;

    if (!self.needsForegroundRestart) return;
    [CILogStore.sharedStore
        recordLevel:CILogLevelInfo
           category:@"ContinuedTask"
            message:@"YouTube is active without a valid continued runtime; requesting a fresh generation for the next background cycle."];
    [self submitRequestForCurrentVideoAttempt:1];
}

- (void)applicationDidEnterBackground:
    (__unused NSNotification *)notification {
    [self prepareForApplicationBackground];
}

- (void)prepareForApplicationBackground {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self prepareForApplicationBackground];
        });
        return;
    }
    if (self.applicationEnteredBackground) return;
    self.applicationEnteredBackground = YES;
    self.backgroundCycleCount++;
    self.backgroundGeneration = self.requestGeneration;
    if (![self hasTaskSession]) {
        [CILogStore.sharedStore
            recordLevel:CILogLevelWarning
               category:@"ContinuedTask"
                 format:@"Background cycle %lu has no submitted continued caption task generation; local ActivityKit updates will remain deferred.",
                        (unsigned long)self.backgroundCycleCount];
        return;
    }
    BOOL grantedForCycle = self.taskActive &&
        self.grantedGeneration == self.backgroundGeneration;
    [CILogStore.sharedStore
        recordLevel:grantedForCycle
            ? CILogLevelInfo : CILogLevelWarning
           category:@"ContinuedTask"
             format:grantedForCycle
                ? @"Background cycle %lu is authorized by freshly granted generation %lu (%@)."
                : @"Background cycle %lu began before generation %lu received a launch handler (%@); local ActivityKit updates are deferred until the system grants it.",
                    (unsigned long)self.backgroundCycleCount,
                    (unsigned long)self.backgroundGeneration,
                    self.taskIdentifier];
}

- (void)updatePlaybackTime:(NSTimeInterval)playbackTime
                  duration:(NSTimeInterval)duration
                   playing:(BOOL)playing {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updatePlaybackTime:playbackTime
                            duration:duration
                             playing:playing];
        });
        return;
    }
    if (self.videoID.length == 0 ||
        !isfinite(playbackTime) || playbackTime < 0) return;
    self.playbackTime = playbackTime;
    if (isfinite(duration) && duration > 0) {
        self.duration = duration;
    }
    BOOL playingChanged = self.playing != playing;
    self.playing = playing;
    if (!self.taskActive || self.suppressed) return;
    [self updateRunningTaskProgressForce:playingChanged];
    if (playingChanged) [self updateRunningTaskUI];
}

- (void)updateCaptionLine:(NSString *)line
                 nextLine:(NSString *)nextLine {
    if (!NSThread.isMainThread) {
        NSString *copiedLine = [line copy];
        NSString *copiedNextLine = [nextLine copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateCaptionLine:copiedLine
                           nextLine:copiedNextLine];
        });
        return;
    }
    NSString *safeLine = line ?: @"";
    NSString *safeNextLine = nextLine ?: @"";
    if ([self.captionLine isEqualToString:safeLine] &&
        [self.nextCaptionLine isEqualToString:safeNextLine]) return;
    self.captionLine = [safeLine copy];
    self.nextCaptionLine = [safeNextLine copy];
    [self updateRunningTaskUI];
}

- (void)setPlaybackSuppressed:(BOOL)suppressed {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setPlaybackSuppressed:suppressed];
        });
        return;
    }
    if (self.suppressed == suppressed) return;
    self.suppressed = suppressed;
    [self updateRunningTaskUI];
}

- (void)finishVideoWillTransition:(BOOL)willTransition {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishVideoWillTransition:willTransition];
        });
        return;
    }
    if (willTransition) {
        self.playing = NO;
        self.captionLine = CILocalized(
            @"CONTINUED_TASK_TRANSITIONING",
            @"Preparing the next video…"
        );
        self.nextCaptionLine = @"";
        [self updateRunningTaskProgressForce:YES];
        [self updateRunningTaskUI];
        return;
    }
    [self endWithReason:@"video playback finished" success:YES];
}

- (void)endWithReason:(NSString *)reason success:(BOOL)success {
    if (!NSThread.isMainThread) {
        NSString *copiedReason = [reason copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self endWithReason:copiedReason success:success];
        });
        return;
    }

    BOOL hadTask = [self hasTaskSession];
    BOOL hadGrantedRuntime = self.taskActive;
    if (self.requestPending) {
        [self cancelPendingRequestWithIdentifier:self.taskIdentifier];
    }

    id task = self.runningTask;
    self.runningTask = nil;
    self.runtimeLeaseValid = NO;
    self.grantedGeneration = 0;
    self.backgroundGeneration = 0;
    self.requestPending = NO;
    self.requestSubmittedUptime = 0;
    self.submissionRetryScheduled = NO;
    self.needsForegroundRestart = NO;
    [self completeTask:task success:success];
    self.taskIdentifier = @"";

    self.videoID = @"";
    self.videoTitle = @"";
    self.captionLine = @"";
    self.nextCaptionLine = @"";
    self.duration = 0;
    self.playbackTime = 0;
    self.videoIsShorts = NO;
    self.backgroundCycleCount = 0;
    [self resetProgressAccounting];
    self.playing = YES;
    self.suppressed = NO;
    if (hadTask) {
        [CILogStore.sharedStore
            recordLevel:CILogLevelInfo
               category:@"ContinuedTask"
                 format:@"Ended the iOS 26 background caption task: %@.",
                        reason.length > 0 ? reason : @"session ended"];
    }
    if (hadGrantedRuntime) [self notifyRuntimeChanged];
}

- (void)prepareProgressSegmentForVideoID:(NSString *)videoID {
    NSString *safeVideoID = videoID ?: @"";
    if ([self.progressVideoID isEqualToString:safeVideoID]) return;
    self.progressBaseUnitCount =
        self.lastReportedCompletedUnitCount;
    self.progressVideoMaximumUnitCount = 0;
    self.progressVideoID = safeVideoID;
    self.lastProgressUptime = 0;
}

- (void)resetProgressAccounting {
    self.progressVideoID = self.videoID ?: @"";
    self.progressBaseUnitCount = 0;
    self.progressVideoMaximumUnitCount = 0;
    self.lastReportedCompletedUnitCount = 0;
    self.lastReportedTotalUnitCount = 0;
    self.lastProgressUptime = 0;
}

- (void)notifyRuntimeChanged {
    [NSNotificationCenter.defaultCenter
        postNotificationName:
            CIContinuedProcessingRuntimeDidChangeNotification
                      object:self];
}

- (void)updateRunningTaskProgressForce:(BOOL)force {
    id task = self.runningTask;
    if (!task) return;
    NSTimeInterval uptime =
        NSProcessInfo.processInfo.systemUptime;
    if (!force && self.lastProgressUptime > 0 &&
        uptime - self.lastProgressUptime <
            CIContinuedProgressMinimumInterval) return;

    NSProgress *progress = nil;
    @try {
        id candidate = [task valueForKey:@"progress"];
        if ([candidate isKindOfClass:NSProgress.class]) {
            progress = candidate;
        }
    } @catch (__unused NSException *exception) {
        progress = nil;
    }
    if (!progress) return;

    [self prepareProgressSegmentForVideoID:self.videoID];
    int64_t currentVideoTotalUnits = self.duration > 0
        ? MAX((int64_t)1, (int64_t)llround(self.duration * 10.0))
        : 1;
    int64_t currentVideoUnits = MAX(
        (int64_t)0,
        (int64_t)llround(self.playbackTime * 10.0)
    );
    currentVideoUnits = MIN(currentVideoTotalUnits, currentVideoUnits);
    self.progressVideoMaximumUnitCount = MAX(
        self.progressVideoMaximumUnitCount,
        currentVideoUnits
    );
    int64_t completedUnits = self.progressBaseUnitCount +
        self.progressVideoMaximumUnitCount;
    completedUnits = MAX(
        self.lastReportedCompletedUnitCount,
        completedUnits
    );
    int64_t totalUnits = MAX(
        self.progressBaseUnitCount + currentVideoTotalUnits,
        completedUnits + 1
    );
    totalUnits = MAX(self.lastReportedTotalUnitCount, totalUnits);
    progress.totalUnitCount = totalUnits;
    progress.completedUnitCount = completedUnits;
    self.lastReportedCompletedUnitCount = completedUnits;
    self.lastReportedTotalUnitCount = totalUnits;
    self.lastProgressUptime = uptime;
}

- (void)updateRunningTaskUI {
    id task = self.runningTask;
    if (!task) return;
    NSString *title = @"";
    NSString *subtitle = @"";
    if (self.suppressed) {
        title = CILocalized(
            @"CONTINUED_TASK_ADVERTISEMENT",
            @"Advertisement playing"
        );
        subtitle = CILocalized(
            @"CONTINUED_TASK_ADVERTISEMENT_DESCRIPTION",
            @"Caption synchronization is paused"
        );
    } else if (self.captionLine.length > 0) {
        title = self.captionLine;
        if (self.nextCaptionLine.length > 0) {
            subtitle = [NSString stringWithFormat:
                CILocalized(
                    @"CONTINUED_TASK_NEXT_LINE_FORMAT",
                    @"Next: %@"
                ),
                self.nextCaptionLine
            ];
        } else if (!self.playing) {
            subtitle = CILocalized(
                @"CONTINUED_TASK_PAUSED",
                @"Paused"
            );
        } else {
            subtitle = self.videoTitle;
        }
    } else {
        title = CILocalized(
            @"CONTINUED_TASK_SYSTEM_TITLE",
            @"Background captions"
        );
        subtitle = self.videoTitle;
    }

    title = CIContinuedClippedText(title, 180);
    subtitle = CIContinuedClippedText(subtitle, 220);
    SEL updateSelector =
        NSSelectorFromString(@"updateTitle:subtitle:");
    if ([task respondsToSelector:updateSelector]) {
        ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(
            task,
            updateSelector,
            title,
            subtitle
        );
    }
}

@end
