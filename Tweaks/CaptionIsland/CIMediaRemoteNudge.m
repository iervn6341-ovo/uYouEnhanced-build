#import "CIMediaRemoteNudge.h"
#import "CIConstants.h"
#import "CILogStore.h"
#import "CIProcessDiagnostics.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>

// MRMediaRemoteSendCommand lives in the private MediaRemote framework. Resolve
// it at runtime so a missing or renamed symbol degrades to "feature disabled"
// instead of failing to load the tweak.
typedef BOOL (*CIMRSendCommand)(int command, id _Nullable userInfo);

// kMRPlay. Chosen because YouTube already registers a Play handler, and
// delivering Play to a player that is *already playing* is a no-op for
// playback while still causing mediaremoted to take its Command assertion.
static const int CIMediaRemotePlayCommand = 0;

// The Command assertion was observed surviving a few seconds past the last
// command, so nudge a little faster than that to hold it continuously.
static const NSTimeInterval CIMediaRemoteNudgeInterval = 4.0;

@interface CIMediaRemoteNudge ()
@property (nonatomic, strong, nullable) NSTimer *timer;
@property (nonatomic) BOOL observing;
@property (nonatomic) BOOL playing;
@property (nonatomic) NSUInteger sentCount;
@property (nonatomic) BOOL didLogUnavailable;
- (void)applicationDidEnterBackground:(NSNotification *)notification;
- (void)applicationDidBecomeActive:(NSNotification *)notification;
- (void)refreshTimer;
- (void)fire:(nullable NSTimer *)timer;
@end

@implementation CIMediaRemoteNudge

+ (instancetype)sharedNudge {
    static CIMediaRemoteNudge *nudge;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ nudge = [CIMediaRemoteNudge new]; });
    return nudge;
}

- (void)dealloc {
    [_timer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

static CIMRSendCommand CIResolveSendCommand(void) {
    static dispatch_once_t onceToken;
    static CIMRSendCommand function;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework"
            "/MediaRemote",
            RTLD_LAZY
        );
        if (!handle) return;
        function = (CIMRSendCommand)dlsym(handle, "MRMediaRemoteSendCommand");
    });
    return function;
}

- (void)activate {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self activate]; });
        return;
    }
    if (self.observing) return;
    self.observing = YES;
    _playing = YES;
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(applicationDidEnterBackground:)
               name:UIApplicationDidEnterBackgroundNotification
             object:nil];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(applicationDidBecomeActive:)
               name:UIApplicationDidBecomeActiveNotification
             object:nil];
}

- (void)setPlaybackPlaying:(BOOL)playing {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setPlaybackPlaying:playing];
        });
        return;
    }
    if (self.playing == playing) return;
    self.playing = playing;
    [self refreshTimer];
}

- (void)applicationDidEnterBackground:
    (__unused NSNotification *)notification {
    [self refreshTimer];
}

- (void)applicationDidBecomeActive:
    (__unused NSNotification *)notification {
    self.sentCount = 0;
    [self refreshTimer];
}

- (void)refreshTimer {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshTimer]; });
        return;
    }
    BOOL shouldRun =
        CIPreferenceBool(CIEnabledKey, YES) &&
        CIPreferenceBool(CIRemoteCommandNudgeEnabledKey, NO) &&
        self.playing &&
        UIApplication.sharedApplication.applicationState !=
            UIApplicationStateActive;
    if (!shouldRun) {
        if (self.timer) {
            [self.timer invalidate];
            self.timer = nil;
            [CILogStore.sharedStore
                recordLevel:CILogLevelDebug
                   category:@"Eligibility"
                     format:@"Stopped the media-remote nudge after %lu command(s).",
                            (unsigned long)self.sentCount];
        }
        return;
    }
    if (self.timer) return;
    if (!CIResolveSendCommand()) {
        if (!self.didLogUnavailable) {
            self.didLogUnavailable = YES;
            [CILogStore.sharedStore
                recordLevel:CILogLevelWarning
                   category:@"Eligibility"
                    message:@"MRMediaRemoteSendCommand was unavailable; the media-remote nudge cannot run."];
        }
        return;
    }
    self.timer = [NSTimer scheduledTimerWithTimeInterval:
                      CIMediaRemoteNudgeInterval
                                                  target:self
                                                selector:@selector(fire:)
                                                userInfo:nil
                                                 repeats:YES];
    self.timer.tolerance = 0.5;
    [CILogStore.sharedStore
        recordLevel:CILogLevelInfo
           category:@"Eligibility"
            message:@"Started the media-remote nudge; sending a redundant Play command while backgrounded."];
    [self fire:nil];
}

- (void)fire:(__unused NSTimer *)timer {
    // Re-check every precondition on each tick. A stale "playing" flag is the
    // one way this could do real damage — resuming audio the user had paused —
    // so bail out rather than risk it.
    if (!self.playing ||
        UIApplication.sharedApplication.applicationState ==
            UIApplicationStateActive ||
        !CIPreferenceBool(CIRemoteCommandNudgeEnabledKey, NO)) {
        [self refreshTimer];
        return;
    }
    CIMRSendCommand sendCommand = CIResolveSendCommand();
    if (!sendCommand) {
        [self refreshTimer];
        return;
    }

    BOOL accepted = NO;
    @try {
        accepted = sendCommand(CIMediaRemotePlayCommand, nil);
    } @catch (NSException *exception) {
        [CILogStore.sharedStore
            recordLevel:CILogLevelError
               category:@"Eligibility"
                 format:@"MediaRemote rejected the nudge command: %@",
                        exception.reason ?: exception.name];
        [self.timer invalidate];
        self.timer = nil;
        return;
    }
    self.sentCount++;
    [CILogStore.sharedStore
        recordLevel:CILogLevelDebug
           category:@"Eligibility"
             format:@"Sent media-remote nudge #%lu (accepted=%d).",
                    (unsigned long)self.sentCount, accepted];
    // Sample immediately: the whole point is to learn whether this produced a
    // mediaremote:Command assertion.
    CILogProcessBackgroundEligibility(@"After a media-remote nudge");
}

@end
