#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

#import "../YTVideoOverlay/Header.h"
#import "../YTVideoOverlay/Init.x"
#import "../YouTubeHeader/YTColor.h"
#import "../YouTubeHeader/YTMainAppVideoPlayerOverlayViewController.h"
#import "../YouTubeHeader/YTMainAppVideoPlayerOverlayView.h"
#import "../YouTubeHeader/YTMainAppControlsOverlayView.h"
#import "../YouTubeHeader/YTPlayerViewController.h"
#import "../YouTubeHeader/QTMIcon.h"

#define TweakKey @"YouLoop"
#define IS_ENABLED(k) [[NSUserDefaults standardUserDefaults] boolForKey:k]

@interface YTMainAppVideoPlayerOverlayViewController (YouLoop)
@property (nonatomic, assign) YTPlayerViewController *parentViewController; // for accessing YTPlayerViewController
@end

@interface YTMainAppVideoPlayerOverlayView (YouLoop)
@property (nonatomic, weak, readwrite) YTMainAppVideoPlayerOverlayViewController *delegate;
@end

@interface YTPlayerViewController (YouLoop)
- (void)didPressYouLoop;
- (void)play;
@property (nonatomic, assign) BOOL youLoopRestartPending;
@end

@interface YTMainAppControlsOverlayView (YouLoop)
@property (nonatomic, assign) YTPlayerViewController *playerViewController; // for accessing YTPlayerViewController
- (void)didPressYouLoop:(id)arg; // for custom button press
@end

// For accessing YTPlayerViewController
@interface YTInlinePlayerBarController : NSObject
@end

@interface YTInlinePlayerBarContainerView (YouLoop)
@property (nonatomic, strong) YTInlinePlayerBarController *delegate; // for accessing YTPlayerViewController
- (void)didPressYouLoop:(id)arg; // for custom button press
@end

@interface YTColor (YouLoop)
+ (UIColor *)lightRed; // for tinting the loop button when enabled
@end

// For displaying snackbars - @theRealfoxster
@interface YTHUDMessage : NSObject
+ (id)messageWithText:(id)text;
- (void)setAction:(id)action;
@end
@interface GOOHUDManagerInternal : NSObject
- (void)showMessageMainThread:(id)message;
+ (id)sharedInstance;
@end

// Retrieves the bundle for the tweak
NSBundle *YouLoopBundle() {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *tweakBundlePath = [[NSBundle mainBundle] pathForResource:TweakKey ofType:@"bundle"];
        if (tweakBundlePath)
            bundle = [NSBundle bundleWithPath:tweakBundlePath];
        else
            bundle = [NSBundle bundleWithPath:[NSString stringWithFormat:ROOT_PATH_NS(@"/Library/Application Support/%@.bundle"), TweakKey]];
    });
    return bundle;
}
static NSBundle *tweakBundle = nil; // not sure why I need to store tweakBundle

// Get the image for the loop button based on the given state and size
static UIImage *getYouLoopImage(NSString *imageSize) {
    UIColor *tintColor = IS_ENABLED(@"defaultLoop_enabled") ? [%c(YTColor) lightRed] : [%c(YTColor) white1];
    NSString *imageName = [NSString stringWithFormat:@"PlayerLoop@%@", imageSize];
    return [%c(QTMIcon) tintImage:[UIImage imageNamed:imageName inBundle:YouLoopBundle() compatibleWithTraitCollection:nil] color:tintColor];
}

%group Main
%hook YTPlayerViewController
%property (nonatomic, assign) BOOL youLoopRestartPending;

// Store the user's preference without using YouTube's autonav loop mode.
// Autonav recreates the playback item at the end of the video, which also
// discards the current buffer.
%new
- (void)didPressYouLoop {
    BOOL isLoopEnabled = !IS_ENABLED(@"defaultLoop_enabled");
    [[NSUserDefaults standardUserDefaults] setBool:isLoopEnabled forKey:@"defaultLoop_enabled"];
    [[%c(GOOHUDManagerInternal) sharedInstance] showMessageMainThread:[%c(YTHUDMessage) messageWithText:LOC(isLoopEnabled ? @"Loop enabled" : @"Loop disabled")]];
}

// Rewind the active playback item instead of asking autonav to reload the
// current video. Dispatching to the next main-queue turn lets YouTube finish
// its end-of-playback notification before we seek and resume.
- (void)playbackController:(id)playbackController didFinishPlaybackAndWillInternallyTransitionToNextPlayback:(BOOL)willTransition {
    if (!IS_ENABLED(@"defaultLoop_enabled") || self.isPlayingAd) {
        %orig;
        return;
    }

    if (self.youLoopRestartPending) {
        %orig(playbackController, NO);
        return;
    }

    // Preserve YouTube's normal completion callbacks (and hooks from other
    // tweaks), but report that no next-item transition should be presented.
    %orig(playbackController, NO);

    self.youLoopRestartPending = YES;
    NSString *finishedVideoID = [self.currentVideoID copy];
    __weak YTPlayerViewController *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        YTPlayerViewController *strongSelf = weakSelf;
        if (!strongSelf)
            return;

        BOOL isSameVideo = finishedVideoID.length == 0 || [strongSelf.currentVideoID isEqualToString:finishedVideoID];
        if (IS_ENABLED(@"defaultLoop_enabled") && !strongSelf.isPlayingAd && isSameVideo) {
            [strongSelf seekToTime:0];
            [strongSelf play];
        }
        strongSelf.youLoopRestartPending = NO;
    });
}
%end
%end

/**
  * Adds a button to the top area in the video player overlay
  */
%group Top
%hook YTMainAppControlsOverlayView

- (UIImage *)buttonImage:(NSString *)tweakId {
    return [tweakId isEqualToString:TweakKey] ? getYouLoopImage(@"3") : %orig;
}

// Custom method to handle the button press
%new(v@:@)
- (void)didPressYouLoop:(id)arg {
    // Call our custom method in the YTPlayerViewController class
    YTMainAppVideoPlayerOverlayView *mainOverlayView = (YTMainAppVideoPlayerOverlayView *)self.superview;
    YTMainAppVideoPlayerOverlayViewController *mainOverlayController = (YTMainAppVideoPlayerOverlayViewController *)mainOverlayView.delegate;
    YTPlayerViewController *playerViewController = mainOverlayController.parentViewController;
    if (playerViewController) {
        [playerViewController didPressYouLoop];
    }
    // Update button color
    [self.overlayButtons[TweakKey] setImage:getYouLoopImage(@"3") forState:0];
}

%end
%end

/**
  * Adds a button to the bottom area next to the fullscreen button
  */
%group Bottom
%hook YTInlinePlayerBarContainerView

- (UIImage *)buttonImage:(NSString *)tweakId {
    return [tweakId isEqualToString:TweakKey] ? getYouLoopImage(@"3") : %orig;
}

// Custom method to handle the button press
%new(v@:@)
- (void)didPressYouLoop:(id)arg {
    // Navigate to the YTPlayerViewController class from here
    YTInlinePlayerBarController *delegate = self.delegate; // for @property
    YTMainAppVideoPlayerOverlayViewController *_delegate = [delegate valueForKey:@"_delegate"]; // for ivars
    YTPlayerViewController *parentViewController = _delegate.parentViewController;
    // Call our custom method in the YTPlayerViewController class
    if (parentViewController) {
        [parentViewController didPressYouLoop];
    }
    // Update button color
    [self.overlayButtons[TweakKey] setImage:getYouLoopImage(@"3") forState:0];
}

%end
%end

%ctor {
    tweakBundle = YouLoopBundle(); // not sure why I need to store tweakBundle
    // Setup as defined in the example from YTVideoOverlay
    initYTVideoOverlay(TweakKey, @{
        AccessibilityLabelKey: @"Toggle Loop",
        SelectorKey: @"didPressYouLoop:"
    });
    %init(Main);
    %init(Top);
    %init(Bottom);
}
