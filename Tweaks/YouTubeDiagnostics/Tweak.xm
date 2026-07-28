#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <YouTubeHeader/GOOHUDManagerInternal.h>
#import <YouTubeHeader/GOOHUDMessage.h>
#import <YouTubeHeader/YTHUDMessage.h>
#import <YouTubeHeader/YTPlayerTapToRetryResponderEvent.h>
#import <YouTubeHeader/YTPlayerViewController.h>
#import <YouTubeHeader/YTSingleVideoController.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import "YTDLogStore.h"
#import "YTDUnifiedLogCollector.h"

static const void *YTDHUDTextKey = &YTDHUDTextKey;

static NSString *YTDValueForKey(id object, NSString *key) {
    if (!object) return @"";
    id value;
    @try { value = [object valueForKey:key]; }
    @catch (__unused NSException *exception) { value = nil; }
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSAttributedString.class]) {
        return [(NSAttributedString *)value string];
    }
    return @"";
}

static NSString *YTDDescriptionForObject(id object) {
    if (!object) return @"No error context";
    NSString *associatedText = objc_getAssociatedObject(object, YTDHUDTextKey);
    if (associatedText.length > 0) return associatedText;
    if ([object isKindOfClass:NSError.class]) {
        NSError *error = object;
        NSMutableString *result = [NSMutableString stringWithFormat:
            @"%@ (%ld): %@", error.domain, (long)error.code,
            error.localizedDescription ?: @"Unknown error"];
        NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
        if (underlying && underlying != error) {
            [result appendFormat:@" · underlying %@ (%ld): %@",
                underlying.domain, (long)underlying.code,
                underlying.localizedDescription ?: @"Unknown error"];
        }
        return result;
    }
    if ([object isKindOfClass:NSString.class]) return object;
    for (NSString *key in @[@"text", @"message", @"title", @"subtitle",
                             @"detailText", @"accessibilityLabel"]) {
        NSString *value = YTDValueForKey(object, key);
        if (value.length > 0) return value;
    }
    return [NSString stringWithFormat:@"%@ · %@",
        NSStringFromClass([object class]), [object description]];
}

static NSString *YTDLoadedThirdPartyModules(void) {
    NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSet];
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *path = _dyld_get_image_name(index);
        if (!path) continue;
        NSString *imagePath = [NSString stringWithUTF8String:path];
        NSString *name = imagePath.lastPathComponent;
        if (![name.pathExtension.lowercaseString isEqualToString:@"dylib"]) continue;
        if ([imagePath hasPrefix:@"/System/"] ||
            [imagePath hasPrefix:@"/usr/lib/"]) continue;
        [names addObject:name];
    }
    return names.count > 0
        ? [names.array componentsJoinedByString:@", "]
        : @"No injected dylibs were enumerated";
}

static BOOL YTDMessageLooksLikeError(NSString *message) {
    NSString *lower = message.lowercaseString;
    for (NSString *needle in @[@"error", @"failed", @"failure", @"retry",
                                @"reset", @"發生錯誤", @"處理錯誤", @"重試",
                                @"リトライ", @"エラー", @"再試行", @"오류"]) {
        if ([lower containsString:needle]) return YES;
    }
    return NO;
}

@interface YTDLifecycleObserver : NSObject
+ (instancetype)sharedObserver;
@end

@implementation YTDLifecycleObserver

+ (instancetype)sharedObserver {
    static YTDLifecycleObserver *observer;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ observer = [YTDLifecycleObserver new]; });
    return observer;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(memoryWarning:)
            name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
        [center addObserver:self selector:@selector(didEnterBackground:)
            name:UIApplicationDidEnterBackgroundNotification object:nil];
        [center addObserver:self selector:@selector(willEnterForeground:)
            name:UIApplicationWillEnterForegroundNotification object:nil];
    }
    return self;
}

- (void)memoryWarning:(__unused NSNotification *)notification {
    [YTDLogStore.sharedStore recordLevel:YTDLogLevelWarning
        category:@"Lifecycle" message:@"YouTube received a memory warning."];
}

- (void)didEnterBackground:(__unused NSNotification *)notification {
    [YTDLogStore.sharedStore recordLevel:YTDLogLevelInfo
        category:@"Lifecycle" message:@"YouTube entered the background."];
}

- (void)willEnterForeground:(__unused NSNotification *)notification {
    [YTDLogStore.sharedStore recordLevel:YTDLogLevelInfo
        category:@"Lifecycle" message:@"YouTube is returning to the foreground."];
}

@end

%group YTDHUDHooks

%hook GOOHUDMessage

+ (instancetype)messageWithText:(NSString *)text {
    id message = %orig;
    if (message && text.length > 0) {
        objc_setAssociatedObject(message, YTDHUDTextKey, text,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return message;
}

%end

%hook GOOHUDManagerInternal

- (void)showMessageMainThread:(YTHUDMessage *)message {
    NSString *text = YTDDescriptionForObject(message);
    [YTDLogStore.sharedStore
        recordLevel:YTDMessageLooksLikeError(text)
            ? YTDLogLevelError : YTDLogLevelInfo
        category:@"YouTube HUD" message:text];
    %orig;
}

%end

%end

%group YTDPlayerErrorHooks

%hook YTSingleVideoController

- (void)playerViewErrorDidOccur:(id)error {
    [YTDLogStore.sharedStore recordLevel:YTDLogLevelError
        category:@"Player"
        message:[NSString stringWithFormat:@"playerViewErrorDidOccur: %@",
            YTDDescriptionForObject(error)]];
    %orig;
}

%end

%end

%group YTDReloadHooks

%hook YTPlayerViewController

- (void)singleVideoController:(id)controller
    requiresReloadWithContext:(id)context {
    [YTDLogStore.sharedStore recordLevel:YTDLogLevelWarning
        category:@"Player"
        message:[NSString stringWithFormat:
            @"Player requested a reload. video=%@ controller=%@ context=%@",
            self.currentVideoID ?: @"unknown",
            NSStringFromClass([controller class]),
            YTDDescriptionForObject(context)]];
    %orig;
}

%end

%end

%group YTDRetryHooks

%hook YTPlayerTapToRetryResponderEvent

+ (instancetype)eventWithFirstResponder:(id)firstResponder {
    [YTDLogStore.sharedStore recordLevel:YTDLogLevelWarning
        category:@"Player"
        message:[NSString stringWithFormat:
            @"YouTube created a tap-to-retry event. responder=%@",
            NSStringFromClass([firstResponder class])]];
    return %orig;
}

%end

%end

%ctor {
    (void)YTDLifecycleObserver.sharedObserver;
    (void)YTDUnifiedLogCollector.sharedCollector;
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:
        @"CFBundleShortVersionString"] ?: @"unknown";
    NSString *build = [NSBundle.mainBundle objectForInfoDictionaryKey:
        @"CFBundleVersion"] ?: @"unknown";
    [YTDLogStore.sharedStore recordLevel:YTDLogLevelInfo
        category:@"Session"
        message:[NSString stringWithFormat:
            @"YouTube diagnostics started. app=%@ (%@), iOS=%@",
            version, build, UIDevice.currentDevice.systemVersion]];
    [YTDLogStore.sharedStore recordLevel:YTDLogLevelInfo
        category:@"Loaded Modules" message:YTDLoadedThirdPartyModules()];

    Class HUDMessage = NSClassFromString(@"GOOHUDMessage");
    Class HUDManager = NSClassFromString(@"GOOHUDManagerInternal");
    if (HUDMessage && HUDManager &&
        class_getClassMethod(HUDMessage, @selector(messageWithText:)) &&
        class_getInstanceMethod(HUDManager, @selector(showMessageMainThread:))) {
        %init(YTDHUDHooks);
    }
    Class singleVideoController = NSClassFromString(@"YTSingleVideoController");
    if (singleVideoController &&
        class_getInstanceMethod(singleVideoController,
                                @selector(playerViewErrorDidOccur:))) {
        %init(YTDPlayerErrorHooks);
    }
    Class playerController = NSClassFromString(@"YTPlayerViewController");
    if (playerController &&
        class_getInstanceMethod(playerController,
            @selector(singleVideoController:requiresReloadWithContext:))) {
        %init(YTDReloadHooks);
    }
    Class retryEvent = NSClassFromString(@"YTPlayerTapToRetryResponderEvent");
    if (retryEvent &&
        class_getClassMethod(retryEvent, @selector(eventWithFirstResponder:))) {
        %init(YTDRetryHooks);
    }
}
