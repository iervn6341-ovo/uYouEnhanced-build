#import "CIBackgroundPlaybackMonitor.h"
#import "CIActivityPresenter.h"
#import "CICaptionCoordinator.h"
#import "CIContinuedProcessingController.h"
#import "CIConstants.h"
#import "CILogStore.h"
#import "CIPlaybackState.h"
#import "CIYouTubeInspector.h"
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <YouTubeHeader/YTPlayerViewController.h>
#import <math.h>

static const NSTimeInterval CIBackgroundClockInterval = 0.75;
static const NSTimeInterval CIBackgroundClockLeeway = 0.15;
static const NSTimeInterval CIBackgroundMinimumTimeChange = 0.04;
static const NSTimeInterval CIBackgroundHeartbeatInterval = 30.0;
static const NSTimeInterval CINowPlayingSynchronizationInterval = 12.0;
static const NSTimeInterval CINowPlayingRetryInterval = 3.0;

static double CIQuantizedPlaybackRate(double rate) {
    if (!isfinite(rate) || rate <= 0) return 0;
    static const double commonRates[] = {
        0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0, 4.0
    };
    double closest = 1.0;
    double smallestDifference = HUGE_VAL;
    for (NSUInteger index = 0;
         index < sizeof(commonRates) / sizeof(commonRates[0]);
         index++) {
        double difference = fabs(rate - commonRates[index]);
        if (difference < smallestDifference) {
            smallestDifference = difference;
            closest = commonRates[index];
        }
    }
    return closest;
}

@interface CIBackgroundPlaybackMonitor ()
@property (nonatomic, weak, nullable) YTPlayerViewController *playerController;
@property (nonatomic, strong, nullable) YTPlayerViewController *backgroundControllerLease;
@property (nonatomic, weak, nullable) YTPlayerViewController *pictureInPicturePreparedController;
@property (atomic, strong, nullable) dispatch_source_t timer;
@property (nonatomic) BOOL applicationIsBackgrounded;
@property (nonatomic) BOOL hasSuppressionState;
@property (nonatomic) BOOL lastSuppressed;
@property (nonatomic) BOOL hasPlaybackTime;
@property (nonatomic) NSTimeInterval lastPlaybackTime;
@property (nonatomic, copy) NSString *lastVideoID;
@property (nonatomic, copy) NSString *durationPolicyVideoID;
@property (nonatomic) BOOL didLogAvailability;
@property (nonatomic) BOOL didLogClockProgress;
@property (nonatomic) BOOL didWarnAboutMissingClock;
@property (nonatomic) BOOL didLogNowPlayingSynchronization;
@property (nonatomic) BOOL didWarnAboutMissingNowPlayingInfo;
@property (nonatomic) BOOL didLogNativeBackgroundClock;
@property (nonatomic) BOOL hasNativePlaybackTime;
@property (nonatomic) NSTimeInterval lastNativePlaybackTime;
@property (nonatomic) NSTimeInterval lastNativePlaybackUptime;
@property (nonatomic) NSTimeInterval lastHeartbeatUptime;
@property (nonatomic) NSTimeInterval lastTimerCallbackUptime;
@property (nonatomic) NSTimeInterval lastNowPlayingSynchronizationUptime;
@property (nonatomic) NSTimeInterval lastNowPlayingAttemptUptime;
@property (nonatomic) NSTimeInterval lastPlaybackProgressUptime;
@property (nonatomic) NSTimeInterval lastPlaybackAdvanceUptime;
@property (nonatomic) BOOL hasPublishedNowPlayingRate;
@property (nonatomic) double lastPublishedNowPlayingRate;
@property (nonatomic) NSUInteger controllerLeaseGeneration;
@property (nonatomic) NSTimeInterval lastPiPPreparationUptime;
@property (nonatomic) BOOL didSuppressAutomaticPiPForBackgroundTransition;
- (void)youPiPSuppressedAutomaticPiP:(NSNotification *)notification;
- (void)synchronizeNowPlayingAtTime:(NSTimeInterval)playbackTime
                           duration:(NSTimeInterval)duration
                       playbackRate:(double)playbackRate
                             uptime:(NSTimeInterval)uptime;
- (void)scheduleControllerLeaseRelease;
- (void)endActivityForLifecycleReason:(NSString *)reason;
@end

@implementation CIBackgroundPlaybackMonitor

+ (instancetype)sharedMonitor {
    static CIBackgroundPlaybackMonitor *monitor;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ monitor = [CIBackgroundPlaybackMonitor new]; });
    return monitor;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastVideoID = @"";
        _durationPolicyVideoID = @"";
        _applicationIsBackgrounded =
            UIApplication.sharedApplication.applicationState == UIApplicationStateBackground;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(applicationWillResignActive:)
                      name:UIApplicationWillResignActiveNotification object:nil];
        [center addObserver:self selector:@selector(applicationDidEnterBackground:)
                      name:UIApplicationDidEnterBackgroundNotification object:nil];
        [center addObserver:self selector:@selector(applicationDidBecomeActive:)
                      name:UIApplicationDidBecomeActiveNotification object:nil];
        [center addObserver:self selector:@selector(applicationWillTerminate:)
                      name:UIApplicationWillTerminateNotification object:nil];
        [center addObserver:self selector:@selector(sceneDidDisconnect:)
                      name:UISceneDidDisconnectNotification object:nil];
        [center addObserver:self
                   selector:@selector(youPiPSuppressedAutomaticPiP:)
                       name:CIYouPiPAutomaticPiPSuppressedNotification
                     object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self stopTimerWithReason:nil];
}

- (BOOL)isSamplingPlaybackInBackground {
    return self.timer != nil;
}

- (BOOL)playbackAdvancedWithinInterval:(NSTimeInterval)interval {
    if (!isfinite(interval) || interval <= 0 ||
        self.lastPlaybackAdvanceUptime <= 0) return NO;
    NSTimeInterval elapsed =
        NSProcessInfo.processInfo.systemUptime -
        self.lastPlaybackAdvanceUptime;
    return elapsed >= 0 && elapsed <= interval;
}

- (void)attachPlayerController:(YTPlayerViewController *)controller {
    if (!controller) return;
    if (!NSThread.isMainThread) {
        __weak YTPlayerViewController *weakController = controller;
        dispatch_async(dispatch_get_main_queue(), ^{
            YTPlayerViewController *strongController = weakController;
            if (strongController) [self attachPlayerController:strongController];
        });
        return;
    }

    BOOL changedController = self.playerController != controller;
    self.playerController = controller;
    if (self.applicationIsBackgrounded || self.backgroundControllerLease) {
        self.backgroundControllerLease = controller;
        self.controllerLeaseGeneration++;
    }
    if (changedController ||
        ![self.lastVideoID isEqualToString:controller.currentVideoID ?: @""]) {
        [self resetClockState];
    }
    [self startTimerIfNeeded];
}

- (void)detachPlayerController:(YTPlayerViewController *)controller {
    if (!controller) return;
    if (!NSThread.isMainThread) {
        __weak YTPlayerViewController *weakController = controller;
        dispatch_async(dispatch_get_main_queue(), ^{
            YTPlayerViewController *strongController = weakController;
            if (strongController) [self detachPlayerController:strongController];
        });
        return;
    }
    if (self.playerController != controller &&
        self.backgroundControllerLease != controller) return;
    if (self.pictureInPicturePreparedController == controller) {
        self.pictureInPicturePreparedController = nil;
    }
    self.playerController = nil;
    self.backgroundControllerLease = nil;
    self.controllerLeaseGeneration++;
    [self resetClockState];
    [self stopTimerWithReason:@"playback stopped"];
    [CIContinuedProcessingController.sharedController
        endWithReason:@"the active YouTube player stopped"
              success:YES];
}

- (void)prepareForPictureInPictureWithPlayerController:
    (YTPlayerViewController *)controller {
    if (!controller) return;
    if (!NSThread.isMainThread) {
        YTPlayerViewController *retainedController = controller;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self prepareForPictureInPictureWithPlayerController:
                retainedController];
        });
        return;
    }

    [self attachPlayerController:controller];
    self.pictureInPicturePreparedController = controller;
    self.backgroundControllerLease = controller;
    self.controllerLeaseGeneration++;
    NSTimeInterval uptime = NSProcessInfo.processInfo.systemUptime;
    BOOL shouldLog = self.lastPiPPreparationUptime == 0 ||
        uptime - self.lastPiPPreparationUptime >= 1.0;
    self.lastPiPPreparationUptime = uptime;

    CICaptionCoordinator *coordinator =
        CICaptionCoordinator.sharedCoordinator;
    [coordinator prepareForExternalPlayback];
    NSTimeInterval playbackTime = controller.currentVideoMediaTime;
    if (isfinite(playbackTime) && playbackTime >= 0) {
        [coordinator updatePlaybackTime:playbackTime];
    }
    [self startTimerIfNeeded];

    if (shouldLog) {
        [CILogStore.sharedStore recordLevel:CILogLevelInfo
            category:@"Background"
            message:@"Pinned the active YouTube player for Picture in Picture caption timing."];
    }
}

- (void)finishPictureInPicture {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishPictureInPicture];
        });
        return;
    }

    // Only release the controller that this PiP lifecycle pinned. A native
    // time callback may already have rebound the monitor to a newer healthy
    // controller while AVKit was stopping.
    YTPlayerViewController *preparedController =
        self.pictureInPicturePreparedController;
    BOOL releasedPreparedLease =
        preparedController &&
        self.backgroundControllerLease == preparedController;
    if (releasedPreparedLease) {
        self.backgroundControllerLease = nil;
        self.controllerLeaseGeneration++;
        [self resetClockState];
    }
    self.pictureInPicturePreparedController = nil;
    [self startTimerIfNeeded];
    [CILogStore.sharedStore recordLevel:CILogLevelDebug
        category:@"Background"
        format:@"%@ the Picture in Picture player lease after AVKit teardown.",
               releasedPreparedLease ? @"Released" :
                   @"Preserved a newer controller instead of releasing"];
}

- (void)applicationWillResignActive:(__unused NSNotification *)notification {
    // Acquire the lease before YouTube swaps its inline player graph for PiP.
    // The ordinary weak reference can otherwise disappear during that gap.
    self.backgroundControllerLease = self.playerController;
    self.controllerLeaseGeneration++;
    [CICaptionCoordinator.sharedCoordinator prepareForExternalPlayback];
}

- (void)youPiPSuppressedAutomaticPiP:
    (__unused NSNotification *)notification {
    self.didSuppressAutomaticPiPForBackgroundTransition = YES;
    [CICaptionCoordinator.sharedCoordinator prepareForExternalPlayback];
    [CILogStore.sharedStore recordLevel:CILogLevelInfo
        category:@"HomeMode"
        message:@"Suppressed automatic Picture in Picture because Caption Island return-home mode is selected."];
}

- (void)applicationDidEnterBackground:(__unused NSNotification *)notification {
    self.applicationIsBackgrounded = YES;
    if (!self.backgroundControllerLease) {
        self.backgroundControllerLease = self.playerController;
        self.controllerLeaseGeneration++;
    }
    self.didLogNativeBackgroundClock = NO;
    self.hasNativePlaybackTime = NO;
    [self resetClockState];
    [self startTimerIfNeeded];
    [CICaptionCoordinator.sharedCoordinator
        refreshPresentationForReason:@"YouTube entered the background"];
    NSDictionary<NSString *, id> *nowPlayingInfo =
        MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    if (nowPlayingInfo.count > 0) {
        [CILogStore.sharedStore recordLevel:CILogLevelInfo
            category:@"Activity"
            message:@"Caption Island and YouTube Now Playing are both active. Submitted a fresh maximum-relevance caption revision; iOS still owns final Dynamic Island presentation arbitration."];
    } else {
        [CILogStore.sharedStore recordLevel:CILogLevelDebug
            category:@"Activity"
            message:@"Submitted a fresh caption revision for the background transition; no YouTube Now Playing metadata was published at that moment."];
    }
    if (CIContinuedProcessingController.sharedController.taskActive) {
        [CILogStore.sharedStore recordLevel:CILogLevelInfo
            category:@"ContinuedTask"
            message:@"Entered the background with an iOS 26 continued caption task pending or active."];
    } else if (CIPreferenceBool(
                   CIContinuedBackgroundProcessingEnabledKey,
                   NO) &&
               CIContinuedBackgroundProcessingSupported()) {
        [CILogStore.sharedStore recordLevel:CILogLevelWarning
            category:@"ContinuedTask"
            message:@"Entered the background without an active iOS 26 continued caption task; check earlier ContinuedTask errors in the log."];
    }
    if (self.didSuppressAutomaticPiPForBackgroundTransition) {
        [CILogStore.sharedStore recordLevel:CILogLevelInfo
            category:@"HomeMode"
            message:@"Caption Island background mode started; YouTube background audio must remain active for caption timing."];
    } else if (CICurrentReturnHomeMode() ==
                   CIReturnHomeModeCaptionIsland) {
        [CILogStore.sharedStore recordLevel:CILogLevelDebug
            category:@"HomeMode"
            message:@"Caption Island mode entered the background without suppressing PiP, which indicates a manual PiP transition or an unsupported YouPiP hook."];
    } else {
        [CILogStore.sharedStore recordLevel:CILogLevelDebug
            category:@"HomeMode"
            message:@"YouPiP return-home mode entered the background."];
    }
}

- (void)applicationDidBecomeActive:(__unused NSNotification *)notification {
    self.applicationIsBackgrounded = NO;
    self.didSuppressAutomaticPiPForBackgroundTransition = NO;
    [self stopTimerWithReason:@"foreground callbacks resumed"];
    [self scheduleControllerLeaseRelease];
}

- (void)applicationWillTerminate:(__unused NSNotification *)notification {
    [self endActivityForLifecycleReason:@"YouTube is terminating"];
}

- (void)sceneDidDisconnect:(NSNotification *)notification {
    UIScene *disconnectedScene =
        [notification.object isKindOfClass:UIScene.class]
            ? notification.object : nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene != disconnectedScene &&
            scene.activationState != UISceneActivationStateUnattached) {
            return;
        }
    }
    [self endActivityForLifecycleReason:
        @"YouTube's last scene was closed from the app switcher"];
}

- (void)endActivityForLifecycleReason:(NSString *)reason {
    [CILogStore.sharedStore recordLevel:CILogLevelInfo
        category:@"Activity"
        format:@"%@; requesting immediate Live Activity dismissal.", reason];
    [self stopTimerWithReason:nil];
    self.playerController = nil;
    self.backgroundControllerLease = nil;
    self.pictureInPicturePreparedController = nil;
    self.controllerLeaseGeneration++;
    [CIContinuedProcessingController.sharedController
        endWithReason:reason
              success:YES];
    [CIActivityPresenter.sharedPresenter endForProcessTermination];
}

- (void)scheduleControllerLeaseRelease {
    // PiP restoration can briefly use the previous player graph after the app
    // becomes active. Release on a short delay, but only if it is still safe.
    NSUInteger generation = self.controllerLeaseGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.applicationIsBackgrounded ||
            UIApplication.sharedApplication.applicationState !=
                UIApplicationStateActive) return;
        if (strongSelf.controllerLeaseGeneration != generation) {
            [strongSelf scheduleControllerLeaseRelease];
            return;
        }
        strongSelf.backgroundControllerLease = nil;
        [CILogStore.sharedStore recordLevel:CILogLevelDebug
            category:@"Background"
            message:@"Released the background player controller lease."];
    });
}

- (void)resetClockState {
    self.hasPlaybackTime = NO;
    self.lastPlaybackTime = 0;
    self.hasSuppressionState = NO;
    YTPlayerViewController *controller =
        self.backgroundControllerLease ?: self.playerController;
    self.lastVideoID = controller.currentVideoID ?: @"";
    self.didLogClockProgress = NO;
    self.hasNativePlaybackTime = NO;
    self.lastNativePlaybackTime = 0;
    self.lastNativePlaybackUptime = 0;
    self.lastHeartbeatUptime = 0;
    self.lastTimerCallbackUptime = 0;
    self.lastNowPlayingSynchronizationUptime = 0;
    self.lastNowPlayingAttemptUptime = 0;
    self.lastPlaybackProgressUptime = 0;
    self.lastPlaybackAdvanceUptime = 0;
    self.hasPublishedNowPlayingRate = NO;
    self.lastPublishedNowPlayingRate = 0;
}

- (void)observeNativePlaybackTime:(NSTimeInterval)playbackTime
                 playerController:(YTPlayerViewController *)controller {
    if (!controller || !isfinite(playbackTime) ||
        playbackTime < 0) return;

    [CIContinuedProcessingController.sharedController
        updatePlaybackTime:playbackTime
                  duration:controller.currentVideoTotalMediaTime
                   playing:YES];
    if (!self.applicationIsBackgrounded) return;

    NSTimeInterval uptime = NSProcessInfo.processInfo.systemUptime;
    double estimatedRate = 1.0;
    BOOL hadNativePlaybackTime = self.hasNativePlaybackTime;
    NSTimeInterval mediaDelta = hadNativePlaybackTime
        ? playbackTime - self.lastNativePlaybackTime : 0;
    BOOL nativeTimeChanged = !hadNativePlaybackTime ||
        fabs(mediaDelta) >= CIBackgroundMinimumTimeChange;
    if (self.hasNativePlaybackTime) {
        NSTimeInterval elapsed = uptime - self.lastNativePlaybackUptime;
        if (elapsed > 0 && mediaDelta > CIBackgroundMinimumTimeChange) {
            estimatedRate = mediaDelta / elapsed;
        }
    }
    if (!isfinite(estimatedRate) || estimatedRate < 0.25 ||
        estimatedRate > 4.0) {
        estimatedRate = 1.0;
    }
    self.hasNativePlaybackTime = YES;
    self.lastNativePlaybackTime = playbackTime;
    self.lastNativePlaybackUptime = uptime;
    if (!nativeTimeChanged) return;
    self.lastPlaybackProgressUptime = uptime;
    if (hadNativePlaybackTime &&
        mediaDelta > CIBackgroundMinimumTimeChange) {
        self.lastPlaybackAdvanceUptime = uptime;
    }

    [self synchronizeNowPlayingAtTime:playbackTime
                            duration:controller.currentVideoTotalMediaTime
                        playbackRate:estimatedRate
                              uptime:uptime];
    if (!self.didLogNativeBackgroundClock) {
        self.didLogNativeBackgroundClock = YES;
        [CILogStore.sharedStore recordLevel:CILogLevelInfo
            category:@"Background"
            message:@"YouTube native playback callbacks remain active in Picture in Picture or the background."];
    }
}

- (void)startTimerIfNeeded {
    YTPlayerViewController *controller =
        self.backgroundControllerLease ?: self.playerController;
    if (self.timer || !self.applicationIsBackgrounded ||
        !controller || !CIPreferenceBool(CIEnabledKey, YES)) return;

    if (![controller respondsToSelector:@selector(currentVideoMediaTime)]) {
        if (!self.didWarnAboutMissingClock) {
            self.didWarnAboutMissingClock = YES;
            [CILogStore.sharedStore recordLevel:CILogLevelWarning
                category:@"Background"
                message:@"YouTube does not expose a background playback clock; Lock Screen lyric updates are unavailable."];
        }
        return;
    }

    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!timer) return;
    uint64_t interval = (uint64_t)(CIBackgroundClockInterval * NSEC_PER_SEC);
    uint64_t leeway = (uint64_t)(CIBackgroundClockLeeway * NSEC_PER_SEC);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              interval, leeway);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf samplePlaybackClock];
    });
    self.timer = timer;
    dispatch_resume(timer);

    if (!self.didLogAvailability) {
        self.didLogAvailability = YES;
        [CILogStore.sharedStore recordLevel:CILogLevelInfo
            category:@"Background"
            message:@"Lock Screen lyric synchronization is ready while YouTube background audio keeps the app running."];
    } else {
        [CILogStore.sharedStore recordLevel:CILogLevelDebug
            category:@"Background"
            message:@"Background playback clock started."];
    }
}

- (void)stopTimerWithReason:(nullable NSString *)reason {
    dispatch_source_t timer = self.timer;
    if (!timer) return;
    dispatch_source_cancel(timer);
    self.timer = nil;
    if (reason.length > 0) {
        [CILogStore.sharedStore recordLevel:CILogLevelInfo
            category:@"Background"
            format:@"Background playback clock stopped: %@.", reason];
    }
}

- (void)samplePlaybackClock {
    if (!self.applicationIsBackgrounded || !CIPreferenceBool(CIEnabledKey, YES)) {
        [self stopTimerWithReason:@"feature disabled or app returned to foreground"];
        return;
    }

    YTPlayerViewController *controller =
        self.backgroundControllerLease ?: self.playerController;
    if (!controller) {
        [self stopTimerWithReason:@"player released"];
        return;
    }

    NSString *videoID = controller.currentVideoID ?: @"";
    if (videoID.length == 0) return;
    BOOL suppressed = CIPlayerControllerIsAdvertising(controller);
    if (!self.hasSuppressionState || self.lastSuppressed != suppressed) {
        self.hasSuppressionState = YES;
        self.lastSuppressed = suppressed;
        [CICaptionCoordinator.sharedCoordinator setPlaybackSuppressed:suppressed];
        [CIContinuedProcessingController.sharedController
            setPlaybackSuppressed:suppressed];
    }
    if (suppressed) return;

    if (self.lastVideoID.length == 0) {
        [self resetClockState];
        self.lastVideoID = videoID;
    }
    if (![videoID isEqualToString:self.lastVideoID]) {
        // Some YouTube versions omit didActivateVideo while autoplay advances
        // with the screen locked. Recover the new context from the live player
        // instead of freezing the previous video's timeline.
        CIVideoContext *context =
            [CIYouTubeInspector contextFromPlaybackData:nil playerController:controller];
        if (![context.videoID isEqualToString:videoID]) return;
        [self resetClockState];
        [CIContinuedProcessingController.sharedController
            beginForVideoID:context.videoID
                      title:context.title ?: @""
                   duration:context.duration
                     shorts:context.isShorts];
        [CICaptionCoordinator.sharedCoordinator activateContext:context];
        if (context.duration > 0) {
            self.durationPolicyVideoID = videoID;
        }
        [CILogStore.sharedStore recordLevel:CILogLevelInfo
            category:@"Background"
            format:@"Detected background transition to video %@.", videoID];
    }

    NSTimeInterval duration =
        controller.currentVideoTotalMediaTime;
    if (isfinite(duration) && duration > 0 &&
        ![self.durationPolicyVideoID isEqualToString:videoID]) {
        // The duration often arrives after background autoplay has already
        // changed the video ID. Re-submit the context exactly once when that
        // late metadata becomes usable so the configured limit still applies.
        CIVideoContext *durationContext =
            [CIYouTubeInspector
                contextFromPlaybackData:nil
                       playerController:controller];
        if ([durationContext.videoID isEqualToString:videoID] &&
            durationContext.duration > 0) {
            self.durationPolicyVideoID = videoID;
            [CIContinuedProcessingController.sharedController
                beginForVideoID:durationContext.videoID
                          title:durationContext.title ?: @""
                       duration:durationContext.duration
                         shorts:durationContext.isShorts];
            [CICaptionCoordinator.sharedCoordinator
                activateContext:durationContext];
            [CILogStore.sharedStore recordLevel:CILogLevelDebug
                category:@"Background"
                format:@"Reevaluated video %@ after its %.1fs duration became available in the background.",
                       videoID, durationContext.duration];
        }
    }

    NSTimeInterval playbackTime = controller.currentVideoMediaTime;
    if (!isfinite(playbackTime) || playbackTime < 0) return;
    NSTimeInterval uptime = NSProcessInfo.processInfo.systemUptime;
    NSTimeInterval callbackGap = self.lastTimerCallbackUptime > 0
        ? uptime - self.lastTimerCallbackUptime : 0;
    self.lastTimerCallbackUptime = uptime;
    if (self.lastHeartbeatUptime == 0 ||
        uptime - self.lastHeartbeatUptime >= CIBackgroundHeartbeatInterval) {
        self.lastHeartbeatUptime = uptime;
        [CILogStore.sharedStore recordLevel:CILogLevelInfo
            category:@"Background"
            format:@"Background clock heartbeat at %.1fs (callback gap %.1fs).",
                   playbackTime, callbackGap];
    }

    BOOL clockAdvanced = self.hasPlaybackTime &&
        playbackTime > self.lastPlaybackTime + CIBackgroundMinimumTimeChange;
    NSTimeInterval mediaDelta = self.hasPlaybackTime
        ? playbackTime - self.lastPlaybackTime : 0;
    BOOL clockChanged = !self.hasPlaybackTime ||
        fabs(playbackTime - self.lastPlaybackTime) >= CIBackgroundMinimumTimeChange;
    if (!clockChanged) {
        if (self.lastPlaybackProgressUptime > 0 &&
            uptime - self.lastPlaybackProgressUptime >= 3.0) {
            [CIContinuedProcessingController.sharedController
                updatePlaybackTime:playbackTime
                          duration:
                              controller.currentVideoTotalMediaTime
                           playing:NO];
            [self synchronizeNowPlayingAtTime:playbackTime
                                    duration:controller.currentVideoTotalMediaTime
                                playbackRate:0
                                      uptime:uptime];
        }
        return;
    }
    self.hasPlaybackTime = YES;
    self.lastPlaybackTime = playbackTime;
    [CICaptionCoordinator.sharedCoordinator updatePlaybackTime:playbackTime];
    [CIContinuedProcessingController.sharedController
        updatePlaybackTime:playbackTime
                  duration:controller.currentVideoTotalMediaTime
                   playing:YES];
    double estimatedRate = callbackGap > 0 && clockAdvanced
        ? mediaDelta / callbackGap : 1.0;
    if (!isfinite(estimatedRate) || estimatedRate < 0.25 ||
        estimatedRate > 4.0) {
        estimatedRate = 1.0;
    }
    self.lastPlaybackProgressUptime = uptime;
    if (clockAdvanced) {
        self.lastPlaybackAdvanceUptime = uptime;
    }
    [self synchronizeNowPlayingAtTime:playbackTime
                            duration:controller.currentVideoTotalMediaTime
                        playbackRate:estimatedRate
                              uptime:uptime];

    if (clockAdvanced && !self.didLogClockProgress) {
        self.didLogClockProgress = YES;
        [CILogStore.sharedStore recordLevel:CILogLevelInfo
            category:@"Background"
            message:@"YouTube playback clock is advancing in the background."];
    }
}

- (void)synchronizeNowPlayingAtTime:(NSTimeInterval)playbackTime
                           duration:(NSTimeInterval)duration
                       playbackRate:(double)playbackRate
                             uptime:(NSTimeInterval)uptime {
    playbackRate = CIQuantizedPlaybackRate(playbackRate);
    BOOL rateChanged = !self.hasPublishedNowPlayingRate ||
        fabs(playbackRate - self.lastPublishedNowPlayingRate) >= 0.08;
    if (!self.hasPublishedNowPlayingRate &&
        self.lastNowPlayingAttemptUptime > 0 &&
        uptime - self.lastNowPlayingAttemptUptime <
            CINowPlayingRetryInterval) return;
    if (self.hasPublishedNowPlayingRate && !rateChanged &&
        self.lastNowPlayingAttemptUptime > 0 &&
        uptime - self.lastNowPlayingAttemptUptime <
            CINowPlayingRetryInterval) return;
    if (!rateChanged && self.lastNowPlayingSynchronizationUptime > 0 &&
        uptime - self.lastNowPlayingSynchronizationUptime <
            CINowPlayingSynchronizationInterval) return;
    self.lastNowPlayingAttemptUptime = uptime;

    MPNowPlayingInfoCenter *center = MPNowPlayingInfoCenter.defaultCenter;
    NSDictionary<NSString *, id> *existing = center.nowPlayingInfo;
    if (existing.count == 0) {
        if (!self.didWarnAboutMissingNowPlayingInfo) {
            self.didWarnAboutMissingNowPlayingInfo = YES;
            [CILogStore.sharedStore recordLevel:CILogLevelWarning
                category:@"Background"
                message:@"YouTube has not published Now Playing metadata, so the Lock Screen elapsed-time display cannot be synchronized yet."];
        }
        return;
    }

    NSMutableDictionary<NSString *, id> *updated = existing.mutableCopy;
    updated[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(playbackTime);
    updated[MPNowPlayingInfoPropertyPlaybackRate] = @(playbackRate);
    updated[MPNowPlayingInfoPropertyDefaultPlaybackRate] = @1.0;
    if (isfinite(duration) && duration > 0) {
        updated[MPMediaItemPropertyPlaybackDuration] = @(duration);
    }
    center.nowPlayingInfo = updated;
    self.lastNowPlayingSynchronizationUptime = uptime;
    self.hasPublishedNowPlayingRate = YES;
    self.lastPublishedNowPlayingRate = playbackRate;

    if (!self.didLogNowPlayingSynchronization) {
        self.didLogNowPlayingSynchronization = YES;
        [CILogStore.sharedStore recordLevel:CILogLevelInfo
            category:@"Background"
            message:@"Synchronized the Lock Screen Now Playing clock without replacing YouTube's media controls."];
    }
}

@end
