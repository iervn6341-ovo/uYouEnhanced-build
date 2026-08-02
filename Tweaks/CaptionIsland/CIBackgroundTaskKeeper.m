#import "CIBackgroundTaskKeeper.h"
#import "CIConstants.h"
#import "CILogStore.h"
#import "CIProcessDiagnostics.h"
#import <UIKit/UIKit.h>

@interface CIBackgroundTaskKeeper ()
@property (nonatomic) UIBackgroundTaskIdentifier taskIdentifier;
@property (nonatomic) BOOL observing;
@property (nonatomic) NSUInteger renewalCount;
@property (nonatomic) NSTimeInterval acquiredUptime;
- (void)applicationDidEnterBackground:(NSNotification *)notification;
- (void)applicationDidBecomeActive:(NSNotification *)notification;
- (void)acquireTaskForReason:(NSString *)reason;
- (void)releaseTaskForReason:(NSString *)reason;
@end

@implementation CIBackgroundTaskKeeper

+ (instancetype)sharedKeeper {
    static CIBackgroundTaskKeeper *keeper;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ keeper = [CIBackgroundTaskKeeper new]; });
    return keeper;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _taskIdentifier = UIBackgroundTaskInvalid;
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)activate {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self activate]; });
        return;
    }
    if (self.observing) return;
    self.observing = YES;
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
    // Cover the case where the tweak finishes loading while YouTube is already
    // backgrounded and playing.
    if (UIApplication.sharedApplication.applicationState ==
            UIApplicationStateBackground) {
        [self acquireTaskForReason:@"the tweak loaded while backgrounded"];
    }
}

- (void)applicationDidEnterBackground:
    (__unused NSNotification *)notification {
    [self acquireTaskForReason:@"YouTube entered the background"];
}

- (void)applicationDidBecomeActive:
    (__unused NSNotification *)notification {
    [self releaseTaskForReason:@"YouTube returned to the foreground"];
}

- (void)acquireTaskForReason:(NSString *)reason {
    if (!NSThread.isMainThread) {
        NSString *copiedReason = [reason copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self acquireTaskForReason:copiedReason];
        });
        return;
    }
    if (!CIPreferenceBool(CIEnabledKey, YES)) return;
    if (self.taskIdentifier != UIBackgroundTaskInvalid) return;

    __weak typeof(self) weakSelf = self;
    UIBackgroundTaskIdentifier identifier = [UIApplication.sharedApplication
        beginBackgroundTaskWithName:@"CaptionIslandCaptionSync"
                  expirationHandler:^{
        // An audio-backgrounded process normally reports an unlimited
        // allowance, so reaching this handler is itself a finding worth
        // recording. Renew immediately to see whether a replacement can be
        // acquired back-to-back.
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [CILogStore.sharedStore
            recordLevel:CILogLevelWarning
               category:@"Eligibility"
                message:@"The caption background task expired; attempting to renew it."];
        [strongSelf releaseTaskForReason:@"the background task expired"];
        if (UIApplication.sharedApplication.applicationState !=
                UIApplicationStateActive) {
            strongSelf.renewalCount++;
            [strongSelf acquireTaskForReason:
                @"renewing after the previous task expired"];
        }
    }];

    if (identifier == UIBackgroundTaskInvalid) {
        [CILogStore.sharedStore
            recordLevel:CILogLevelWarning
               category:@"Eligibility"
                 format:@"iOS refused a caption background task (%@).",
                        reason];
        return;
    }
    self.taskIdentifier = identifier;
    self.acquiredUptime = NSProcessInfo.processInfo.systemUptime;
    [CILogStore.sharedStore
        recordLevel:CILogLevelInfo
           category:@"Eligibility"
             format:@"Holding caption background task %lu (%@, renewal %lu).",
                    (unsigned long)identifier,
                    reason,
                    (unsigned long)self.renewalCount];
    // Sample straight away so the log shows whether this actually added an
    // assertion to the process rather than being invisible to RunningBoard.
    CILogProcessBackgroundEligibility(
        @"Acquired a caption background task"
    );
}

- (void)releaseTaskForReason:(NSString *)reason {
    if (!NSThread.isMainThread) {
        NSString *copiedReason = [reason copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self releaseTaskForReason:copiedReason];
        });
        return;
    }
    UIBackgroundTaskIdentifier identifier = self.taskIdentifier;
    if (identifier == UIBackgroundTaskInvalid) return;
    self.taskIdentifier = UIBackgroundTaskInvalid;
    NSTimeInterval held = self.acquiredUptime > 0
        ? NSProcessInfo.processInfo.systemUptime - self.acquiredUptime
        : 0;
    self.acquiredUptime = 0;
    [UIApplication.sharedApplication endBackgroundTask:identifier];
    [CILogStore.sharedStore
        recordLevel:CILogLevelInfo
           category:@"Eligibility"
             format:@"Released caption background task %lu after %.1fs (%@).",
                    (unsigned long)identifier, held, reason];
    if ([reason isEqualToString:@"YouTube returned to the foreground"]) {
        self.renewalCount = 0;
    }
}

@end
