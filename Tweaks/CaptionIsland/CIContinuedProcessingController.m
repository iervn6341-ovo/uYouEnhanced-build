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
@property (nonatomic, copy) NSString *progressVideoID;
@property (nonatomic) int64_t progressBaseUnitCount;
@property (nonatomic) int64_t progressVideoMaximumUnitCount;
@property (nonatomic) int64_t lastReportedCompletedUnitCount;
@property (nonatomic) int64_t lastReportedTotalUnitCount;
@property (nonatomic) NSUInteger backgroundCycleCount;
- (BOOL)hasTaskSession;
- (void)prepareProgressSegmentForVideoID:(NSString *)videoID;
- (void)resetProgressAccounting;
- (void)notifyRuntimeChanged;
- (BOOL)registerTaskIdentifier:(NSString *)taskIdentifier;
- (void)handleLaunchedTask:(id)task
                 identifier:(NSString *)taskIdentifier;
- (void)handleTaskExpiration:(id)task;
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
    return self.runningTask != nil;
}

- (BOOL)isTaskPending {
    return self.requestPending;
}

- (BOOL)hasTaskSession {
    return self.runningTask != nil || self.requestPending;
}

- (BOOL)localActivityUpdatesPermitted {
    if (!CIContinuedBackgroundProcessingSupported() ||
        !CIPreferenceBool(
            CIContinuedBackgroundProcessingEnabledKey,
            NO
        ) ||
        !self.applicationEnteredBackground) {
        return YES;
    }
    return self.taskActive;
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

    // Continued-processing identifiers represent individual jobs. Reusing a
    // single ".current" identifier leaves the next request competing with a
    // completed or still-draining predecessor. Give every foreground session
    // its own dynamic suffix under the permitted wildcard.
    self.taskIdentifier = [self.taskIdentifierPrefix
        stringByAppendingFormat:@".%@",
            NSUUID.UUID.UUIDString.lowercaseString];
    self.backgroundCycleCount = 0;
    if (![self registerTaskIdentifier:self.taskIdentifier]) {
        self.taskIdentifier = @"";
        self.needsForegroundRestart = YES;
        return;
    }

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
                self.taskIdentifier,
                requestTitle,
                self.videoTitle
            );
    } @catch (NSException *exception) {
        self.taskIdentifier = @"";
        [CILogStore.sharedStore
            recordLevel:CILogLevelError
               category:@"ContinuedTask"
                 format:@"iOS 26 rejected creation of the background caption request: %@",
                        exception.reason ?: exception.name];
        self.needsForegroundRestart = YES;
        return;
    }
    if (!request) {
        self.taskIdentifier = @"";
        [CILogStore.sharedStore
            recordLevel:CILogLevelError
               category:@"ContinuedTask"
                message:@"Unable to create the iOS 26 continued processing request."];
        self.needsForegroundRestart = YES;
        return;
    }
    // Keep the framework's default queue strategy. A third background cycle
    // can begin while the previous task is still draining; failing an
    // otherwise valid request merely because it cannot start immediately
    // makes the next AOD session lose its execution lease.

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
        self.taskIdentifier = @"";
        self.needsForegroundRestart = YES;
        [CILogStore.sharedStore
            recordLevel:CILogLevelError
               category:@"ContinuedTask"
                 format:@"iOS 26 rejected submission of the background caption task: %@",
                        exception.reason ?: exception.name];
        return;
    }
    if (!submitted) {
        self.requestPending = NO;
        self.requestSubmittedUptime = 0;
        self.taskIdentifier = @"";
        self.needsForegroundRestart = YES;
        [CILogStore.sharedStore
            recordLevel:CILogLevelError
               category:@"ContinuedTask"
                 format:@"Unable to submit the iOS 26 background caption task: %@",
                        error.localizedDescription ?: @"unknown error"];
        return;
    }
    self.needsForegroundRestart = NO;

    [CILogStore.sharedStore
        recordLevel:CILogLevelInfo
           category:@"ContinuedTask"
             format:@"Submitted queued iOS 26 continued caption task %@ for video %@.",
                    self.taskIdentifier, videoID];
}

- (BOOL)registerTaskIdentifier:(NSString *)taskIdentifier {
    if (taskIdentifier.length == 0) return NO;
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
    NSString *registeredIdentifier = [taskIdentifier copy];
    void (^launchHandler)(id) = ^(id task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleLaunchedTask:task
                              identifier:registeredIdentifier];
        });
    };
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
                    taskIdentifier,
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
                        taskIdentifier];
        return NO;
    }

    self.scheduler = scheduler;
    [CILogStore.sharedStore
        recordLevel:CILogLevelDebug
           category:@"ContinuedTask"
             format:@"Registered iOS 26 background task identifier %@.",
                    taskIdentifier];
    return YES;
}

- (void)handleLaunchedTask:(id)task
                 identifier:(NSString *)taskIdentifier {
    if (!task) return;
    if (![taskIdentifier isEqualToString:self.taskIdentifier]) {
        SEL completeSelector =
            NSSelectorFromString(@"setTaskCompletedWithSuccess:");
        if ([task respondsToSelector:completeSelector]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                task,
                completeSelector,
                NO
            );
        }
        [CILogStore.sharedStore
            recordLevel:CILogLevelWarning
               category:@"ContinuedTask"
                 format:@"Rejected a delayed launch for superseded continued task %@.",
                        taskIdentifier];
        return;
    }
    self.requestPending = NO;
    self.requestSubmittedUptime = 0;
    if (!CIPreferenceBool(
            CIContinuedBackgroundProcessingEnabledKey,
            NO) ||
        self.videoID.length == 0) {
        SEL completeSelector =
            NSSelectorFromString(@"setTaskCompletedWithSuccess:");
        if ([task respondsToSelector:completeSelector]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                task,
                completeSelector,
                NO
            );
        }
        self.taskIdentifier = @"";
        self.needsForegroundRestart = NO;
        return;
    }

    if (self.runningTask && self.runningTask != task) {
        SEL completeSelector =
            NSSelectorFromString(@"setTaskCompletedWithSuccess:");
        if ([self.runningTask respondsToSelector:completeSelector]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                self.runningTask,
                completeSelector,
                NO
            );
        }
    }
    self.runningTask = task;
    self.needsForegroundRestart = NO;
    [self resetProgressAccounting];

    __weak typeof(self) weakSelf = self;
    __weak id weakTask = task;
    void (^expirationHandler)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleTaskExpiration:weakTask];
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
            message:@"iOS 26 granted continued background runtime for caption synchronization."];
    [self notifyRuntimeChanged];
}

- (void)handleTaskExpiration:(id)task {
    if (!task || task != self.runningTask) return;
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
    self.requestPending = NO;
    self.requestSubmittedUptime = 0;
    self.taskIdentifier = @"";
    self.needsForegroundRestart = YES;
    [CILogStore.sharedStore
        recordLevel:CILogLevelWarning
           category:@"ContinuedTask"
            message:@"iOS 26 expired the continued background caption task and it was completed as unsuccessful; reopen YouTube to request a fresh task."];
    [self notifyRuntimeChanged];
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
    if (self.videoID.length == 0 ||
        !CIPreferenceBool(
            CIContinuedBackgroundProcessingEnabledKey,
        NO
    )) return;

    // Foregrounding boosts an existing BGContinuedProcessingTask. Completing
    // it here would discard that lease and make each Home -> Lock cycle race a
    // newly queued request. Keep one task for the finite playback session.
    if (self.taskActive) {
        [self updateRunningTaskProgressForce:YES];
        [self updateRunningTaskUI];
        if (returnedFromBackground) {
            [CILogStore.sharedStore
                recordLevel:CILogLevelInfo
                   category:@"ContinuedTask"
                    message:@"Retained the granted iOS 26 continued caption task across the foreground return; the same lease will cover the next background cycle."];
        }
        return;
    }

    if (self.taskPending) {
        if (returnedFromBackground) {
            NSTimeInterval pendingSeconds = MAX(
                0,
                NSProcessInfo.processInfo.systemUptime -
                    self.requestSubmittedUptime
            );
            [CILogStore.sharedStore
                recordLevel:CILogLevelInfo
                   category:@"ContinuedTask"
                     format:@"Kept the queued iOS 26 continued caption request across the foreground return (pending %.1fs); avoiding cancel/resubmit churn.",
                            pendingSeconds];
        }
        return;
    }

    if (!self.needsForegroundRestart) return;
    [CILogStore.sharedStore
        recordLevel:CILogLevelInfo
           category:@"ContinuedTask"
            message:@"YouTube became active after the previous continued task expired; requesting one replacement for the current playback session."];
    [self beginForVideoID:self.videoID
                    title:self.videoTitle
                 duration:self.duration
                   shorts:self.videoIsShorts];
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
    if (![self hasTaskSession]) return;
    self.backgroundCycleCount++;
    [CILogStore.sharedStore
        recordLevel:self.taskActive
            ? CILogLevelInfo : CILogLevelWarning
           category:@"ContinuedTask"
             format:self.taskActive
                ? @"Background cycle %lu is reusing the granted continued caption runtime lease (%@)."
                : @"Background cycle %lu began while the continued caption request is still queued (%@).",
                    (unsigned long)self.backgroundCycleCount,
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
    if (self.requestPending && self.scheduler) {
        SEL cancelSelector =
            NSSelectorFromString(@"cancelTaskRequestWithIdentifier:");
        if ([self.scheduler respondsToSelector:cancelSelector]) {
            ((void (*)(id, SEL, NSString *))objc_msgSend)(
                self.scheduler,
                cancelSelector,
                self.taskIdentifier
            );
        }
    }

    id task = self.runningTask;
    self.runningTask = nil;
    self.requestPending = NO;
    self.requestSubmittedUptime = 0;
    self.needsForegroundRestart = NO;
    if (task) {
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
