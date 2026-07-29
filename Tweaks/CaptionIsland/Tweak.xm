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
#import "CIPlaybackState.h"
#import "CIToastPresenter.h"
#import "CIYouTubeInspector.h"

static const void *CISuppressedStateKey = &CISuppressedStateKey;
static const void *CIActivePlayerKey = &CIActivePlayerKey;
static __weak YTPlayerViewController *CIActivePlayerController;
static NSUInteger CIPlaybackLifecycleGeneration;

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
    BOOL suppressed = CIPlayerControllerIsAdvertising(controller);
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
    if (!CIPlayerControllerIsAdvertising(controller)) {
        [coordinator updatePlaybackTime:videoTime.time];
    }
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
    CIUpdateSuppression(controller);
    if (CIPlayerControllerIsAdvertising(controller)) return;
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
        CIUpdateSuppression(strongController);
        if (CIPlayerControllerIsAdvertising(strongController)) return;
        CIVideoContext *updated = [CIYouTubeInspector contextFromPlaybackData:nil playerController:strongController];
        if ([updated.videoID isEqualToString:videoID]) {
            [CICaptionCoordinator.sharedCoordinator activateContext:updated];
        }
        CIScheduleCaptionRefresh(strongController, videoID, attempt + 1);
    });
}

static void CIResolveActivatedPlayback(YTPlayerViewController *controller,
                                       id playbackData,
                                       NSString *activationVideoID) {
    if (!controller || CIActivePlayerController != controller ||
        ![objc_getAssociatedObject(controller, CIActivePlayerKey) boolValue]) return;
    NSString *currentVideoID = controller.currentVideoID ?: @"";
    if (activationVideoID.length > 0 &&
        ![currentVideoID isEqualToString:activationVideoID]) return;

    CICaptionCoordinator *coordinator = CICaptionCoordinator.sharedCoordinator;
    CIUpdateSuppression(controller);
    if (CIPlayerControllerIsAdvertising(controller)) {
        CILog(@"Skipping caption lookup while YouTube is playing an ad.");
        return;
    }
    [coordinator playerViewDidAppear];
    CIVideoContext *context = [CIYouTubeInspector contextFromPlaybackData:playbackData
                                                        playerController:controller];
    if (!context) {
        [CIBackgroundPlaybackMonitor.sharedMonitor detachPlayerController:controller];
        [coordinator stop];
        return;
    }
    [coordinator activateContext:context];

    // Caption tracks can arrive shortly after the player response. Use three
    // bounded snapshots; there is no foreground polling loop.
    CIScheduleCaptionRefresh(controller, context.videoID, 0);
}

static void CIActivatePlayback(YTPlayerViewController *controller, id playbackData) {
    CIPlaybackLifecycleGeneration++;
    if (CIActivePlayerController && CIActivePlayerController != controller) {
        objc_setAssociatedObject(CIActivePlayerController, CIActivePlayerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CIActivePlayerController = controller;
    [CIBackgroundPlaybackMonitor.sharedMonitor attachPlayerController:controller];
    objc_setAssociatedObject(controller, CIActivePlayerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CIUpdateSuppression(controller);
    if (CIPlayerControllerIsAdvertising(controller)) {
        CILog(@"Skipping caption lookup while YouTube is playing an ad.");
        return;
    }

    // YouTube can invoke didActivateVideo a fraction of a second before its
    // ad state settles. Debounce the expensive lookup, then check isPlayingAd
    // again so short pre-rolls never become LRCLIB searches.
    NSString *activationVideoID = controller.currentVideoID ?: @"";
    __weak YTPlayerViewController *weakController = controller;
    id retainedPlaybackData = playbackData;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CIResolveActivatedPlayback(weakController, retainedPlaybackData,
                                   activationVideoID);
    });
}

static void CIStopPlayback(YTPlayerViewController *controller) {
    if (CIActivePlayerController != controller &&
        ![objc_getAssociatedObject(controller, CIActivePlayerKey) boolValue]) return;
    objc_setAssociatedObject(controller, CIActivePlayerKey, nil,
                            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (CIActivePlayerController == controller) CIActivePlayerController = nil;
    CIPlaybackLifecycleGeneration++;
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
    // Ending a Live Activity prevents a background autoplay item from starting
    // a replacement, because ActivityKit only allows ordinary starts while the
    // host is foregrounded. Keep this activity reusable across the queue.
    NSUInteger finishGeneration = ++CIPlaybackLifecycleGeneration;
    [CICaptionCoordinator.sharedCoordinator playbackDidFinish];
    if (willTransition) return;

    // A genuinely finished session is cleaned up after a grace period. Any
    // replay/new activation invalidates this block, while controller teardown
    // still ends the activity immediately.
    NSString *finishedVideoID = self.currentVideoID ?: @"";
    __weak YTPlayerViewController *weakController = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(90 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YTPlayerViewController *controller = weakController;
        if (!controller ||
            finishGeneration != CIPlaybackLifecycleGeneration ||
            ![objc_getAssociatedObject(controller, CIActivePlayerKey) boolValue] ||
            ![controller.currentVideoID isEqualToString:finishedVideoID]) return;
        NSTimeInterval position = controller.currentVideoMediaTime;
        NSTimeInterval duration = controller.currentVideoTotalMediaTime;
        if (duration > 0 && position >= 0 && position + 2.0 < duration) return;
        CIStopPlayback(controller);
    });
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
