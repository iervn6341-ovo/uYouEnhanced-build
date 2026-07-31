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
static const NSInteger CIContinuedSubmissionStrategyFail = 0;

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
@property (nonatomic, strong, nullable) id runningTask;
@property (nonatomic, copy) NSString *taskIdentifier;
@property (nonatomic, copy) NSString *permittedTaskIdentifier;
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSString *videoTitle;
@property (nonatomic, copy) NSString *captionLine;
@property (nonatomic, copy) NSString *nextCaptionLine;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) NSTimeInterval playbackTime;
@property (nonatomic) BOOL videoIsShorts;
@property (nonatomic) NSTimeInterval lastProgressUptime;
@property (nonatomic) BOOL registered;
@property (nonatomic) BOOL requestPending;
@property (nonatomic) BOOL needsForegroundRestart;
@property (nonatomic) BOOL playing;
@property (nonatomic) BOOL suppressed;
@property (nonatomic) BOOL didLogBackgroundStartRejection;
@property (nonatomic) BOOL applicationEnteredBackground;
- (BOOL)registerTaskIfNeeded;
- (void)handleLaunchedTask:(id)task;
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
        _taskIdentifier = [taskPrefix
            stringByAppendingString:@".current"];
        _permittedTaskIdentifier = [taskPrefix
            stringByAppendingString:@".*"];
        _videoID = @"";
        _videoTitle = @"";
        _captionLine = @"";
        _nextCaptionLine = @"";
        _playing = YES;
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
    return self.runningTask != nil || self.requestPending;
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
        if ((self.taskActive || self.needsForegroundRestart) &&
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
        if (self.taskActive || self.needsForegroundRestart) {
            [self endWithReason:exclusion ==
                    CIVideoExclusionReasonShorts
                    ? @"the active video is a Short"
                    : @"the active video exceeds the configured duration limit"
                       success:YES];
        }
        return;
    }

    BOOL sameVideo = [self.videoID isEqualToString:videoID];
    BOOL existingSession = self.taskActive;
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
            self.lastProgressUptime = 0;
            [CILogStore.sharedStore
                recordLevel:CILogLevelInfo
                   category:@"ContinuedTask"
                     format:@"Retargeted the active iOS 26 background caption task to video %@.",
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

    if (![self registerTaskIfNeeded]) return;

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
        [CILogStore.sharedStore
            recordLevel:CILogLevelError
               category:@"ContinuedTask"
                 format:@"iOS 26 rejected creation of the background caption request: %@",
                        exception.reason ?: exception.name];
        return;
    }
    if (!request) {
        [CILogStore.sharedStore
            recordLevel:CILogLevelError
               category:@"ContinuedTask"
                message:@"Unable to create the iOS 26 continued processing request."];
        return;
    }
    SEL strategySelector =
        NSSelectorFromString(@"setStrategy:");
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
        [CILogStore.sharedStore
            recordLevel:CILogLevelError
               category:@"ContinuedTask"
                 format:@"iOS 26 rejected submission of the background caption task: %@",
                        exception.reason ?: exception.name];
        return;
    }
    if (!submitted) {
        self.requestPending = NO;
        [CILogStore.sharedStore
            recordLevel:CILogLevelError
               category:@"ContinuedTask"
                 format:@"Unable to submit the iOS 26 background caption task: %@",
                        error.localizedDescription ?: @"unknown error"];
        return;
    }

    [CILogStore.sharedStore
        recordLevel:CILogLevelInfo
           category:@"ContinuedTask"
             format:@"Submitted an iOS 26 continued background caption task for video %@.",
                    videoID];
}

- (BOOL)registerTaskIfNeeded {
    if (self.registered && self.scheduler) return YES;

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

    Class schedulerClass = NSClassFromString(@"BGTaskScheduler");
    SEL sharedSelector = NSSelectorFromString(@"sharedScheduler");
    id scheduler = [schedulerClass respondsToSelector:sharedSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(
            schedulerClass,
            sharedSelector
        ) : nil;
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
                    self.taskIdentifier,
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
                        self.taskIdentifier];
        return NO;
    }

    self.scheduler = scheduler;
    self.registered = YES;
    [CILogStore.sharedStore
        recordLevel:CILogLevelDebug
           category:@"ContinuedTask"
             format:@"Registered iOS 26 background task identifier %@.",
                    self.taskIdentifier];
    return YES;
}

- (void)handleLaunchedTask:(id)task {
    if (!task) return;
    self.requestPending = NO;
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
    self.lastProgressUptime = 0;

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
    self.needsForegroundRestart = YES;
    [CILogStore.sharedStore
        recordLevel:CILogLevelWarning
           category:@"ContinuedTask"
            message:@"iOS 26 expired the continued background caption task and it was completed as unsuccessful; reopen YouTube to request a fresh task."];
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
    if ((!returnedFromBackground && !self.needsForegroundRestart) ||
        (!self.needsForegroundRestart && !self.taskActive) ||
        self.videoID.length == 0 ||
        !CIPreferenceBool(
            CIContinuedBackgroundProcessingEnabledKey,
        NO
    )) return;

    NSString *videoID = [self.videoID copy];
    NSString *title = [self.videoTitle copy];
    NSTimeInterval duration = self.duration;
    BOOL isShorts = self.videoIsShorts;
    NSTimeInterval playbackTime = self.playbackTime;
    NSString *captionLine = [self.captionLine copy];
    NSString *nextCaptionLine = [self.nextCaptionLine copy];
    BOOL playing = self.playing;
    BOOL suppressed = self.suppressed;

    // A BGContinuedProcessingTask represents one finite user-initiated
    // session. Returning to YouTube ends that background session. Complete or
    // cancel it here and submit a fresh request while the app is active, so a
    // second Home -> Lock cycle does not depend on an already-consumed task.
    [self endWithReason:
        @"YouTube returned to the foreground; preparing the next background session"
              success:YES];
    [CILogStore.sharedStore
        recordLevel:CILogLevelInfo
           category:@"ContinuedTask"
            message:@"YouTube became active; requesting a fresh continued caption task for the next background transition."];
    [self beginForVideoID:videoID
                    title:title
                 duration:duration
                   shorts:isShorts];
    self.playbackTime = playbackTime;
    self.captionLine = captionLine ?: @"";
    self.nextCaptionLine = nextCaptionLine ?: @"";
    self.playing = playing;
    self.suppressed = suppressed;
}

- (void)applicationDidEnterBackground:
    (__unused NSNotification *)notification {
    self.applicationEnteredBackground = YES;
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
    if (!self.taskActive || self.suppressed ||
        !isfinite(playbackTime) || playbackTime < 0) return;
    self.playbackTime = playbackTime;
    if (isfinite(duration) && duration > 0) {
        self.duration = duration;
    }
    BOOL playingChanged = self.playing != playing;
    self.playing = playing;
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

    BOOL hadTask = self.taskActive;
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

    self.videoID = @"";
    self.videoTitle = @"";
    self.captionLine = @"";
    self.nextCaptionLine = @"";
    self.duration = 0;
    self.playbackTime = 0;
    self.videoIsShorts = NO;
    self.lastProgressUptime = 0;
    self.playing = YES;
    self.suppressed = NO;
    if (hadTask) {
        [CILogStore.sharedStore
            recordLevel:CILogLevelInfo
               category:@"ContinuedTask"
                 format:@"Ended the iOS 26 background caption task: %@.",
                        reason.length > 0 ? reason : @"session ended"];
    }
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

    int64_t totalUnits = self.duration > 0
        ? MAX((int64_t)1, (int64_t)llround(self.duration * 10.0))
        : 1;
    int64_t completedUnits = self.duration > 0
        ? MAX((int64_t)0, MIN(
            totalUnits,
            (int64_t)llround(self.playbackTime * 10.0)
        )) : 0;
    progress.totalUnitCount = totalUnits;
    progress.completedUnitCount = completedUnits;
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
