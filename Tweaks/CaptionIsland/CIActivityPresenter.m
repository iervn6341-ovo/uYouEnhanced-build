#import "CIActivityPresenter.h"
#import "CIContinuedProcessingController.h"
#import "CILogStore.h"
#import "CIConstants.h"
#import <objc/message.h>

static NSNotificationName const CIActivityBridgeLogNotification =
    @"CIActivityBridgeLogNotification";

static NSString *CIActivitySourceLabel(
    CICaptionSource source
) {
    BOOL LRCLIBSource =
        source == CICaptionSourceLRCLIBSynced ||
        source == CICaptionSourceLRCLIBAligned ||
        source == CICaptionSourceLRCLIBEstimated;
    return (LRCLIBSource ||
        CIPreferenceBool(CIShowSourceBadgeKey, YES))
        ? CICaptionSourceLabel(source) : @"";
}

@interface CIActivityPresenter ()
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSString *title;
@property (atomic) BOOL didLogSuppressedBackgroundUpdate;
- (BOOL)canSubmitLocalActivityUpdate;
- (void)continuedProcessingRuntimeDidChange:(NSNotification *)notification;
@end

@implementation CIActivityPresenter

+ (instancetype)sharedPresenter {
    static CIActivityPresenter *presenter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ presenter = [CIActivityPresenter new]; });
    return presenter;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _videoID = @"";
        _title = @"";
        [NSNotificationCenter.defaultCenter addObserver:self
            selector:@selector(activityBridgeDidLog:)
            name:CIActivityBridgeLogNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self
            selector:@selector(continuedProcessingRuntimeDidChange:)
            name:CIContinuedProcessingRuntimeDidChangeNotification
            object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)canSubmitLocalActivityUpdate {
    CIContinuedProcessingController *controller =
        CIContinuedProcessingController.sharedController;
    if (controller.localActivityUpdatesPermitted) {
        self.didLogSuppressedBackgroundUpdate = NO;
        return YES;
    }
    if (!self.didLogSuppressedBackgroundUpdate) {
        self.didLogSuppressedBackgroundUpdate = YES;
        [CILogStore.sharedStore
            recordLevel:CILogLevelWarning
               category:@"Activity"
                message:controller.taskPending
                    ? @"Deferred local Live Activity updates while the submitted iOS 26 continued caption request awaits its launch handler; updates resume only after the system grants runtime."
                    : @"Deferred local Live Activity updates because the background process has only media-playback eligibility; this avoids repeated liveactivitiesd rejections."];
    }
    return NO;
}

- (void)continuedProcessingRuntimeDidChange:
    (__unused NSNotification *)notification {
    CIContinuedProcessingController *controller =
        CIContinuedProcessingController.sharedController;
    if (!controller.taskActive ||
        !controller.localActivityUpdatesPermitted ||
        self.videoID.length == 0) return;
    self.didLogSuppressedBackgroundUpdate = NO;
    [self refreshPresentationForReason:
        @"continued processing runtime granted"];
}

- (Class)bridgeClass {
    return NSClassFromString(@"CIActivityBridge");
}

- (void)beginVideoID:(NSString *)videoID title:(NSString *)title {
    if (!CIPreferenceBool(CIEnabledKey, YES) || videoID.length == 0) return;
    self.videoID = videoID;
    self.title = title.length > 0 ? title : @"YouTube";
    if (![self canSubmitLocalActivityUpdate]) return;
    Class bridge = [self bridgeClass];
    SEL selector = NSSelectorFromString(@"startWithVideoID:title:");
    if (![bridge respondsToSelector:selector]) {
        [CILogStore.sharedStore recordLevel:CILogLevelError category:@"Activity"
            message:@"ActivityKit bridge is missing from CaptionIsland.dylib"];
        return;
    }
    ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(
        bridge, selector, self.videoID, self.title);
}

- (void)ensureVideoID:(NSString *)videoID title:(NSString *)title {
    if (!CIPreferenceBool(CIEnabledKey, YES) || videoID.length == 0) return;
    self.videoID = videoID;
    self.title = title.length > 0 ? title : @"YouTube";
    if (![self canSubmitLocalActivityUpdate]) return;
    Class bridge = [self bridgeClass];
    SEL selector = NSSelectorFromString(@"ensureWithVideoID:title:");
    if (![bridge respondsToSelector:selector]) {
        [self beginVideoID:self.videoID title:self.title];
        return;
    }
    ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(
        bridge, selector, self.videoID, self.title);
}

- (void)refreshPresentationForReason:(NSString *)reason {
    if (!CIPreferenceBool(CIEnabledKey, YES) ||
        self.videoID.length == 0) return;
    if (![self canSubmitLocalActivityUpdate]) return;
    Class bridge = [self bridgeClass];
    SEL selector =
        NSSelectorFromString(@"refreshForPresentationWithReason:");
    if (![bridge respondsToSelector:selector]) return;
    ((void (*)(id, SEL, NSString *))objc_msgSend)(
        bridge,
        selector,
        reason.length > 0 ? reason : @"presentation transition"
    );
}

- (void)presentText:(NSString *)text
             source:(CICaptionSource)source
           cueStart:(NSTimeInterval)cueStart
             cueEnd:(NSTimeInterval)cueEnd
           position:(NSTimeInterval)position {
    [self presentText:text
               source:source
             cueStart:cueStart
               cueEnd:cueEnd
             position:position
             nextText:@""
         nextCueStart:0
           nextCueEnd:0];
}

- (void)presentText:(NSString *)text
             source:(CICaptionSource)source
           cueStart:(NSTimeInterval)cueStart
             cueEnd:(NSTimeInterval)cueEnd
           position:(NSTimeInterval)position
           nextText:(NSString *)nextText
       nextCueStart:(NSTimeInterval)nextCueStart
         nextCueEnd:(NSTimeInterval)nextCueEnd {
    if (!CIPreferenceBool(CIEnabledKey, YES) || text.length == 0) {
        [self hide];
        return;
    }
    [CIContinuedProcessingController.sharedController
        updateCaptionLine:text
                 nextLine:nextText ?: @""];
    if (![self canSubmitLocalActivityUpdate]) return;
    Class bridge = [self bridgeClass];
    SEL selector = NSSelectorFromString(
        @"updateWithText:source:cueStart:cueEnd:position:playing:nextText:nextCueStart:nextCueEnd:");
    if (![bridge respondsToSelector:selector]) return;
    NSString *sourceLabel =
        CIActivitySourceLabel(source);
    ((void (*)(id, SEL, NSString *, NSString *, double, double, double, BOOL,
               NSString *, double, double))objc_msgSend)(
        bridge, selector, text, sourceLabel, cueStart, cueEnd, position, YES,
        nextText ?: @"", nextCueStart, nextCueEnd);
}

- (void)hide {
    [CIContinuedProcessingController.sharedController
        updateCaptionLine:@"♪"
                 nextLine:@""];
    if (![self canSubmitLocalActivityUpdate]) return;
    Class bridge = [self bridgeClass];
    SEL selector = NSSelectorFromString(@"showGapWithTitle:");
    if (self.videoID.length == 0 || ![bridge respondsToSelector:selector]) return;
    ((void (*)(id, SEL, NSString *))objc_msgSend)(bridge, selector, self.title ?: @"YouTube");
}

- (void)end {
    Class bridge = [self bridgeClass];
    SEL selector = NSSelectorFromString(@"endImmediately:");
    if ([bridge respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(bridge, selector, YES);
    }
    self.videoID = @"";
    self.title = @"";
    self.didLogSuppressedBackgroundUpdate = NO;
}

- (void)endForProcessTermination {
    Class bridge = [self bridgeClass];
    SEL selector = NSSelectorFromString(@"endAllImmediatelyForTermination");
    if ([bridge respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(bridge, selector);
    } else {
        [self end];
    }
    self.videoID = @"";
    self.title = @"";
    self.didLogSuppressedBackgroundUpdate = NO;
}

- (void)activityBridgeDidLog:(NSNotification *)notification {
    NSDictionary *info = notification.userInfo;
    NSString *message = [info[@"message"] isKindOfClass:NSString.class]
        ? info[@"message"] : @"Unknown ActivityKit event";
    NSString *level = [info[@"level"] isKindOfClass:NSString.class]
        ? info[@"level"] : @"info";
    CILogLevel logLevel = CILogLevelInfo;
    if ([level isEqualToString:@"error"]) logLevel = CILogLevelError;
    else if ([level isEqualToString:@"warning"]) logLevel = CILogLevelWarning;
    else if ([level isEqualToString:@"debug"]) logLevel = CILogLevelDebug;
    [CILogStore.sharedStore recordLevel:logLevel category:@"Activity" message:message];
}

@end
