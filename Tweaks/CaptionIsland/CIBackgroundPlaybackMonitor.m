#import "CIBackgroundPlaybackMonitor.h"
#import "CICaptionCoordinator.h"
#import "CIConstants.h"
#import "CILogStore.h"
#import "CIPlaybackState.h"
#import <UIKit/UIKit.h>
#import <YouTubeHeader/YTPlayerViewController.h>
#import <math.h>

static const NSTimeInterval CIBackgroundClockInterval = 0.75;
static const NSTimeInterval CIBackgroundClockLeeway = 0.15;
static const NSTimeInterval CIBackgroundMinimumTimeChange = 0.04;

@interface CIBackgroundPlaybackMonitor ()
@property (nonatomic, weak, nullable) YTPlayerViewController *playerController;
@property (atomic, strong, nullable) dispatch_source_t timer;
@property (nonatomic) BOOL applicationIsBackgrounded;
@property (nonatomic) BOOL hasSuppressionState;
@property (nonatomic) BOOL lastSuppressed;
@property (nonatomic) BOOL hasPlaybackTime;
@property (nonatomic) NSTimeInterval lastPlaybackTime;
@property (nonatomic, copy) NSString *lastVideoID;
@property (nonatomic) BOOL didLogAvailability;
@property (nonatomic) BOOL didLogClockProgress;
@property (nonatomic) BOOL didWarnAboutMissingClock;
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
        _applicationIsBackgrounded =
            UIApplication.sharedApplication.applicationState == UIApplicationStateBackground;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(applicationDidEnterBackground:)
                      name:UIApplicationDidEnterBackgroundNotification object:nil];
        [center addObserver:self selector:@selector(applicationWillEnterForeground:)
                      name:UIApplicationWillEnterForegroundNotification object:nil];
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
    if (self.playerController != controller) return;
    self.playerController = nil;
    [self resetClockState];
    [self stopTimerWithReason:@"playback stopped"];
}

- (void)applicationDidEnterBackground:(__unused NSNotification *)notification {
    self.applicationIsBackgrounded = YES;
    [self resetClockState];
    [self startTimerIfNeeded];
}

- (void)applicationWillEnterForeground:(__unused NSNotification *)notification {
    self.applicationIsBackgrounded = NO;
    [self stopTimerWithReason:@"foreground callbacks resumed"];
}

- (void)resetClockState {
    self.hasPlaybackTime = NO;
    self.lastPlaybackTime = 0;
    self.hasSuppressionState = NO;
    self.lastVideoID = self.playerController.currentVideoID ?: @"";
    self.didLogClockProgress = NO;
}

- (void)startTimerIfNeeded {
    if (self.timer || !self.applicationIsBackgrounded ||
        !self.playerController || !CIPreferenceBool(CIEnabledKey, YES)) return;

    if (![self.playerController respondsToSelector:@selector(currentVideoMediaTime)]) {
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
        [CILogStore.sharedStore recordLevel:CILogLevelDebug
            category:@"Background"
            format:@"Background playback clock stopped: %@.", reason];
    }
}

- (void)samplePlaybackClock {
    if (!self.applicationIsBackgrounded || !CIPreferenceBool(CIEnabledKey, YES)) {
        [self stopTimerWithReason:@"feature disabled or app returned to foreground"];
        return;
    }

    YTPlayerViewController *controller = self.playerController;
    if (!controller) {
        [self stopTimerWithReason:@"player released"];
        return;
    }

    NSString *videoID = controller.currentVideoID ?: @"";
    if (videoID.length == 0) return;
    if (self.lastVideoID.length == 0) {
        [self resetClockState];
        self.lastVideoID = videoID;
    }
    // Wait for didActivateVideo before moving the clock to a new item. This
    // prevents a brief autoplay transition from rendering the previous
    // video's lyrics against the next video's timestamp.
    if (![videoID isEqualToString:self.lastVideoID]) return;

    BOOL suppressed = CIPlayerControllerIsAdvertising(controller);
    if (!self.hasSuppressionState || self.lastSuppressed != suppressed) {
        self.hasSuppressionState = YES;
        self.lastSuppressed = suppressed;
        [CICaptionCoordinator.sharedCoordinator setPlaybackSuppressed:suppressed];
    }
    if (suppressed) return;

    NSTimeInterval playbackTime = controller.currentVideoMediaTime;
    if (!isfinite(playbackTime) || playbackTime < 0) return;
    if (self.hasPlaybackTime &&
        fabs(playbackTime - self.lastPlaybackTime) < CIBackgroundMinimumTimeChange) return;

    BOOL clockAdvanced = self.hasPlaybackTime &&
        playbackTime > self.lastPlaybackTime + CIBackgroundMinimumTimeChange;
    self.hasPlaybackTime = YES;
    self.lastPlaybackTime = playbackTime;
    [CICaptionCoordinator.sharedCoordinator updatePlaybackTime:playbackTime];

    if (clockAdvanced && !self.didLogClockProgress) {
        self.didLogClockProgress = YES;
        [CILogStore.sharedStore recordLevel:CILogLevelDebug
            category:@"Background"
            message:@"YouTube playback clock is advancing in the background."];
    }
}

@end
