#import "CIActivityPresenter.h"
#import "CILogStore.h"
#import "CIConstants.h"
#import <objc/message.h>
#import <math.h>

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
    }
    return self;
}

- (Class)bridgeClass {
    return NSClassFromString(@"CIActivityBridge");
}

- (void)beginVideoID:(NSString *)videoID title:(NSString *)title {
    if (!CIPreferenceBool(CIEnabledKey, YES) || videoID.length == 0) return;
    self.videoID = videoID;
    self.title = title.length > 0 ? title : @"YouTube";
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
    Class bridge = [self bridgeClass];
    SEL selector = NSSelectorFromString(@"ensureWithVideoID:title:");
    if (![bridge respondsToSelector:selector]) {
        [self beginVideoID:self.videoID title:self.title];
        return;
    }
    ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(
        bridge, selector, self.videoID, self.title);
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

- (void)configureRemoteTimelineWithCues:
            (NSArray<CICaptionCue *> *)cues
                              source:(CICaptionSource)source
                            position:(NSTimeInterval)position
                            duration:(NSTimeInterval)duration {
    if (!CIPreferenceBool(CIPushRelayEnabledKey, NO) ||
        cues.count == 0 || self.videoID.length == 0) return;
    NSMutableArray<NSDictionary *> *payload =
        [NSMutableArray arrayWithCapacity:
            MIN(cues.count, (NSUInteger)512)];
    for (CICaptionCue *cue in cues) {
        if (payload.count >= 512) break;
        if (!isfinite(cue.startTime) ||
            !isfinite(cue.endTime) ||
            cue.endTime <= cue.startTime ||
            cue.text.length == 0) continue;
        [payload addObject:@{
            @"startMS": @((long long)llround(
                MAX(0, cue.startTime) * 1000.0
            )),
            @"endMS": @((long long)llround(
                MAX(cue.startTime + 0.001, cue.endTime) *
                    1000.0
            )),
            @"line": cue.text,
        }];
    }
    if (payload.count == 0) return;
    Class bridge = [self bridgeClass];
    SEL selector = NSSelectorFromString(
        @"configureRemoteTimelineWithCues:source:position:duration:"
    );
    if (![bridge respondsToSelector:selector]) return;
    ((void (*)(id, SEL, NSArray *, NSString *, double, double))
        objc_msgSend)(
            bridge,
            selector,
            payload.copy,
            CIActivitySourceLabel(source),
            position,
            duration
        );
}

- (void)synchronizeRemotePlaybackAtPosition:
            (NSTimeInterval)position
                                    playing:(BOOL)playing
                                       rate:(double)rate
                                      force:(BOOL)force {
    if (!CIPreferenceBool(CIPushRelayEnabledKey, NO) ||
        self.videoID.length == 0 ||
        !isfinite(position) || position < 0) return;
    Class bridge = [self bridgeClass];
    SEL selector = NSSelectorFromString(
        @"syncRemotePlaybackAtPosition:playing:rate:force:"
    );
    if (![bridge respondsToSelector:selector]) return;
    ((void (*)(id, SEL, double, BOOL, double, BOOL))
        objc_msgSend)(
            bridge,
            selector,
            position,
            playing,
            rate,
            force
        );
}

- (void)synchronizeRemotePlaybackCriticalAtPosition:
            (NSTimeInterval)position
                                            playing:(BOOL)playing
                                               rate:(double)rate
                                    expectedVideoID:
                                        (NSString *)expectedVideoID
                                         completion:
                                             (void (^)(BOOL attempted))
                                                 completion {
    if (!CIPreferenceBool(CIPushRelayEnabledKey, NO) ||
        self.videoID.length == 0 ||
        expectedVideoID.length == 0 ||
        ![self.videoID isEqualToString:expectedVideoID] ||
        !isfinite(position) || position < 0) {
        if (completion) {
            dispatch_async(
                dispatch_get_main_queue(),
                ^{ completion(NO); }
            );
        }
        return;
    }
    Class bridge = [self bridgeClass];
    SEL selector = NSSelectorFromString(
        @"syncRemotePlaybackCriticalAtPosition:playing:rate:expectedVideoID:completion:"
    );
    if (![bridge respondsToSelector:selector]) {
        [self synchronizeRemotePlaybackAtPosition:position
                                          playing:playing
                                             rate:rate
                                            force:YES];
        if (completion) {
            dispatch_async(
                dispatch_get_main_queue(),
                ^{ completion(NO); }
            );
        }
        return;
    }
    ((void (*)(id, SEL, double, BOOL, double, NSString *,
               void (^)(BOOL)))
        objc_msgSend)(
            bridge,
            selector,
            position,
            playing,
            rate,
            expectedVideoID,
            completion ?: ^(__unused BOOL attempted) {}
        );
}

- (void)clearRemoteTimelineAtPosition:
            (NSTimeInterval)position
                              duration:(NSTimeInterval)duration {
    if (!CIPreferenceBool(CIPushRelayEnabledKey, NO) ||
        self.videoID.length == 0) return;
    Class bridge = [self bridgeClass];
    SEL selector = NSSelectorFromString(
        @"clearRemoteTimelineAtPosition:duration:"
    );
    if (![bridge respondsToSelector:selector]) return;
    ((void (*)(id, SEL, double, double))objc_msgSend)(
        bridge,
        selector,
        isfinite(position) ? MAX(0, position) : 0,
        isfinite(duration) ? MAX(0, duration) : 0
    );
}

- (void)hide {
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
