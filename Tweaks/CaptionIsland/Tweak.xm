#import <Foundation/Foundation.h>
#import <YouTubeHeader/GOOHUDManagerInternal.h>
#import <YouTubeHeader/YTHUDMessage.h>
#import <YouTubeHeader/YTPlayerOverlayManager.h>
#import <YouTubeHeader/YTPlayerViewController.h>
#import <YouTubeHeader/YTSingleVideoTime.h>
#import <objc/runtime.h>
#import "CIBackgroundPlaybackMonitor.h"
#import "CICaptionCoordinator.h"
#import "CIConstants.h"
#import "CIToastPresenter.h"
#import "CIYouTubeInspector.h"

static const void *CISuppressedStateKey = &CISuppressedStateKey;
static const void *CIActivePlayerKey = &CIActivePlayerKey;
static __weak YTPlayerViewController *CIActivePlayerController;

void CIShowToast(NSString *text) {
    if (text.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        Class messageClass = NSClassFromString(@"YTHUDMessage");
        Class managerClass = NSClassFromString(@"GOOHUDManagerInternal");
        if (![messageClass respondsToSelector:@selector(messageWithText:)] ||
            ![managerClass respondsToSelector:@selector(sharedInstance)]) return;
        id manager = [managerClass sharedInstance];
        if (![manager respondsToSelector:@selector(showMessageMainThread:)]) return;
        id message = [messageClass messageWithText:text];
        if (message) [manager showMessageMainThread:message];
    });
}

static void CIUpdateSuppression(YTPlayerViewController *controller) {
    NSNumber *previous = objc_getAssociatedObject(controller, CISuppressedStateKey);
    BOOL suppressed = controller.isPlayingAd;
    if (!previous || previous.boolValue != suppressed) {
        objc_setAssociatedObject(controller, CISuppressedStateKey, @(suppressed), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [CICaptionCoordinator.sharedCoordinator setPlaybackSuppressed:suppressed];
    }
}

static void CIHandlePlaybackTime(YTPlayerViewController *controller, YTSingleVideoTime *videoTime) {
    if (!videoTime || (CIActivePlayerController && CIActivePlayerController != controller)) return;
    if (CIBackgroundPlaybackMonitor.sharedMonitor.isSamplingPlaybackInBackground) return;
    CICaptionCoordinator *coordinator = CICaptionCoordinator.sharedCoordinator;
    CIUpdateSuppression(controller);
    if (!controller.isPlayingAd) [coordinator updatePlaybackTime:videoTime.time];
}

static void CIRefreshCaptionContext(YTPlayerOverlayManager *overlayManager) {
    if (!NSThread.isMainThread) {
        __weak YTPlayerOverlayManager *weakManager = overlayManager;
        dispatch_async(dispatch_get_main_queue(), ^{
            CIRefreshCaptionContext(weakManager);
        });
        return;
    }
    YTPlayerViewController *controller = CIActivePlayerController;
    if (!controller) return;
    if (controller.overlayManager && controller.overlayManager != overlayManager) return;
    CIVideoContext *updated =
        [CIYouTubeInspector contextFromPlaybackData:nil playerController:controller];
    if (updated.videoID.length > 0 &&
        [updated.videoID isEqualToString:controller.currentVideoID]) {
        [CICaptionCoordinator.sharedCoordinator activateContext:updated];
    }
}

static void CIScheduleCaptionRefresh(YTPlayerViewController *controller,
                                     NSString *videoID,
                                     NSUInteger attempt) {
    if (attempt >= 3) return;
    NSTimeInterval delays[] = {0.6, 1.5, 3.0};
    __weak YTPlayerViewController *weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[attempt] * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YTPlayerViewController *strongController = weakController;
        if (!strongController || ![[strongController currentVideoID] isEqualToString:videoID]) return;
        CIVideoContext *updated = [CIYouTubeInspector contextFromPlaybackData:nil playerController:strongController];
        if ([updated.videoID isEqualToString:videoID]) {
            [CICaptionCoordinator.sharedCoordinator activateContext:updated];
        }
        CIScheduleCaptionRefresh(strongController, videoID, attempt + 1);
    });
}

static void CIActivatePlayback(YTPlayerViewController *controller, id playbackData) {
    CICaptionCoordinator *coordinator = CICaptionCoordinator.sharedCoordinator;
    if (CIActivePlayerController && CIActivePlayerController != controller) {
        objc_setAssociatedObject(CIActivePlayerController, CIActivePlayerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CIActivePlayerController = controller;
    [CIBackgroundPlaybackMonitor.sharedMonitor attachPlayerController:controller];
    objc_setAssociatedObject(controller, CIActivePlayerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CIUpdateSuppression(controller);
    if (controller.isPlayingAd) return;
    [coordinator playerViewDidAppear];
    CIVideoContext *context = [CIYouTubeInspector contextFromPlaybackData:playbackData
                                                        playerController:controller];
    if (!context) { [coordinator stop]; return; }
    [coordinator activateContext:context];

    // Caption tracks can arrive shortly after the player response. Use three
    // bounded snapshots; there is no polling loop or permanent timer.
    CIScheduleCaptionRefresh(controller, context.videoID, 0);
}

static void CIStopPlayback(YTPlayerViewController *controller) {
    if (CIActivePlayerController != controller &&
        ![objc_getAssociatedObject(controller, CIActivePlayerKey) boolValue]) return;
    objc_setAssociatedObject(controller, CIActivePlayerKey, nil,
                            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (CIActivePlayerController == controller) CIActivePlayerController = nil;
    [CIBackgroundPlaybackMonitor.sharedMonitor detachPlayerController:controller];
    [CICaptionCoordinator.sharedCoordinator stop];
}

%group CaptionIslandActivationHooks

%hook YTPlayerViewController

- (void)playbackController:(id)playbackController
          didActivateVideo:(id)video
          withPlaybackData:(id)playbackData {
    %orig;
    CIActivatePlayback(self, playbackData);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if ([objc_getAssociatedObject(self, CIActivePlayerKey) boolValue]) {
        [CICaptionCoordinator.sharedCoordinator playerViewDidDisappear];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if ([objc_getAssociatedObject(self, CIActivePlayerKey) boolValue]) {
        [CICaptionCoordinator.sharedCoordinator playerViewDidAppear];
    }
}

- (void)dealloc {
    if ([objc_getAssociatedObject(self, CIActivePlayerKey) boolValue]) {
        CIStopPlayback(self);
    }
    %orig;
}

%end


%end


%group CaptionIslandPlaybackFinishHooks

%hook YTPlayerViewController

- (void)playbackController:(id)playbackController
    didFinishPlaybackAndWillInternallyTransitionToNextPlayback:(BOOL)willTransition {
    %orig;
    // Keep the shared Live Activity alive while YouTube advances its queue in
    // the background. A true stop ends it immediately.
    if (!willTransition) CIStopPlayback(self);
}

%end

%end


%group CaptionIslandCaptionTrackHooks

%hook YTPlayerOverlayManager

- (void)singleVideo:(id)singleVideo availableCaptionTracksDidChange:(id)tracks {
    %orig;
    CIRefreshCaptionContext(self);
}

%end

%end


%group CaptionIslandModernTimeHooks

%hook YTPlayerViewController

- (void)potentiallyMutatedSingleVideo:(id)singleVideo
            currentVideoTimeDidChange:(YTSingleVideoTime *)videoTime {
    %orig;
    CIHandlePlaybackTime(self, videoTime);
}

%end


%end


%group CaptionIslandLegacyTimeHooks

%hook YTPlayerViewController

- (void)singleVideo:(id)singleVideo currentVideoTimeDidChange:(YTSingleVideoTime *)videoTime {
    %orig;
    CIHandlePlaybackTime(self, videoTime);
}

%end

%end

%ctor {
    Class playerClass = NSClassFromString(@"YTPlayerViewController");
    if (!playerClass) return;
    (void)CIBackgroundPlaybackMonitor.sharedMonitor;
    %init(CaptionIslandActivationHooks);
    SEL modern = @selector(potentiallyMutatedSingleVideo:currentVideoTimeDidChange:);
    if (class_getInstanceMethod(playerClass, modern)) {
        %init(CaptionIslandModernTimeHooks);
    }
    SEL legacy = @selector(singleVideo:currentVideoTimeDidChange:);
    if (class_getInstanceMethod(playerClass, legacy)) {
        %init(CaptionIslandLegacyTimeHooks);
    }
    SEL finish =
        @selector(playbackController:didFinishPlaybackAndWillInternallyTransitionToNextPlayback:);
    if (class_getInstanceMethod(playerClass, finish)) {
        %init(CaptionIslandPlaybackFinishHooks);
    }
    Class overlayManagerClass = NSClassFromString(@"YTPlayerOverlayManager");
    SEL captionTracksChanged =
        @selector(singleVideo:availableCaptionTracksDidChange:);
    if (overlayManagerClass &&
        class_getInstanceMethod(overlayManagerClass, captionTracksChanged)) {
        %init(CaptionIslandCaptionTrackHooks);
    }
}
