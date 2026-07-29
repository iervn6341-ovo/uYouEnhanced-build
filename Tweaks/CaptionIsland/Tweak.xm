#import <Foundation/Foundation.h>
#import <AVKit/AVKit.h>
#import <YouTubeHeader/GOOHUDManagerInternal.h>
#import <YouTubeHeader/MLPIPController.h>
#import <YouTubeHeader/YTHUDMessage.h>
#import <YouTubeHeader/YTPlayerOverlayManager.h>
#import <YouTubeHeader/YTPlayerPIPController.h>
#import <YouTubeHeader/YTPlayerViewController.h>
#import <YouTubeHeader/YTSingleVideoTime.h>
#import <objc/runtime.h>
#import <math.h>
#import "CIBackgroundPlaybackMonitor.h"
#import "CICaptionCoordinator.h"
#import "CIConstants.h"
#import "CILogStore.h"
#import "CIPlaybackState.h"
#import "CIToastPresenter.h"
#import "CIYouTubeInspector.h"

@interface MLPIPController (CaptionIslandPiPState)
- (BOOL)pictureInPictureControllerIsPlaybackPaused:
    (AVPictureInPictureController *)controller;
@end

@interface YTPlayerPIPController (CaptionIslandPiPRecovery)
- (void)pictureInPicturePlaybackPauseRequested;
- (void)pictureInPicturePlaybackResumeRequested;
- (void)didStopPictureInPicture;
@end

static const void *CISuppressedStateKey = &CISuppressedStateKey;
static const void *CIActivePlayerKey = &CIActivePlayerKey;
static const void *CIRetiredPlayerKey = &CIRetiredPlayerKey;
static __weak YTPlayerViewController *CIActivePlayerController;
static __weak AVPictureInPictureController *CIPiPSystemController;
static __weak YTPlayerPIPController *CIPiPRecoveryController;
static NSMapTable<
    YTPlayerPIPController *,
    YTSingleVideoController *
> *CIPiPActiveVideoByController;
static NSUInteger CIPlaybackLifecycleGeneration;
static NSUInteger CIPictureInPicturePreparationGeneration;
static NSUInteger CIPiPAudioLifecycleGeneration;
static NSUInteger CIPiPAudioRecoveryToken;
static NSUInteger CIPiPStopCandidateGeneration;
static NSUInteger CIPiPConsumedDidStopGeneration;
static NSTimeInterval CIPiPStopCandidateUptime;
static BOOL CIPiPPlaybackPauseStateKnown;
static BOOL CIPiPPlaybackPaused;
static BOOL CIPiPRestoreRequested;
static BOOL CIPiPStopCandidate;
static BOOL CIPiPStopCandidateConfirmedByWillStop;
static NSTimeInterval CIPiPWillStopUptime;
static NSString *CIPiPStopCandidateVideoID;

static const NSTimeInterval CIPiPRecentPlaybackInterval = 1.8;
static const NSTimeInterval CIPiPStopToWillStopMaxInterval = 0.65;
static const NSTimeInterval CIPiPWillStopToDidStopMaxInterval = 2.0;
static const NSTimeInterval CIPiPPauseClassificationDelay = 0.80;
static const NSTimeInterval CIPiPAudioRecoveryDelay = 0.20;
static const NSTimeInterval CIPiPRecoveryVerificationDelay = 0.85;

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

static NSString *CIPlayerVideoID(YTPlayerViewController *controller) {
    if (!controller) return @"";
    NSString *videoID = controller.currentVideoID;
    if (videoID.length == 0) videoID = controller.contentVideoID;
    return videoID ?: @"";
}

static void CIClearPiPStopCandidate(void) {
    CIPiPStopCandidate = NO;
    CIPiPStopCandidateGeneration = 0;
    CIPiPStopCandidateUptime = 0;
    CIPiPStopCandidateConfirmedByWillStop = NO;
    CIPiPStopCandidateVideoID = nil;
}

static BOOL CIPiPControllerIsActive(MLPIPController *controller) {
    if ([controller respondsToSelector:@selector(pictureInPictureActive)]) {
        return [controller pictureInPictureActive];
    }
    return NO;
}

static BOOL CIPlayerCanContinueInBackground(
    YTPlayerViewController *controller,
    NSString *expectedVideoID
) {
    if (!controller || !CIPreferenceBool(CIEnabledKey, YES) ||
        CIPlayerControllerIsAdvertising(controller)) return NO;
    NSString *videoID = CIPlayerVideoID(controller);
    if (videoID.length == 0 ||
        (expectedVideoID.length > 0 &&
         ![videoID isEqualToString:expectedVideoID])) return NO;

    NSTimeInterval position = controller.currentVideoMediaTime;
    NSTimeInterval duration = controller.currentVideoTotalMediaTime;
    if (isfinite(position) && isfinite(duration) && duration > 0 &&
        position >= 0 && position + 1.0 >= duration) return NO;
    return YES;
}

static void CIBeginPiPAudioLifecycle(
    MLPIPController *controller,
    AVPictureInPictureController *pictureInPictureController
) {
    CIPiPAudioLifecycleGeneration++;
    CIPiPAudioRecoveryToken++;
    CIPiPSystemController = pictureInPictureController;
    CIPiPRecoveryController = nil;
    CIPiPConsumedDidStopGeneration = 0;
    CIPiPWillStopUptime = 0;
    CIPiPRestoreRequested = NO;
    CIClearPiPStopCandidate();
    CIPiPPlaybackPauseStateKnown =
        [controller respondsToSelector:
            @selector(pictureInPictureControllerIsPlaybackPaused:)];
    CIPiPPlaybackPaused = CIPiPPlaybackPauseStateKnown
        ? [controller
            pictureInPictureControllerIsPlaybackPaused:
                pictureInPictureController]
        : NO;
}

static void CIObservePiPPlaybackStart(void) {
    CIPiPPlaybackPauseStateKnown = YES;
    CIPiPPlaybackPaused = NO;
    CIClearPiPStopCandidate();
}

static void CIUpdatePiPStopPairing(void) {
    if (!CIPiPStopCandidate || CIPiPStopCandidateUptime <= 0 ||
        CIPiPWillStopUptime <= 0) {
        CIPiPStopCandidateConfirmedByWillStop = NO;
        return;
    }
    NSTimeInterval callbackGap =
        fabs(CIPiPStopCandidateUptime - CIPiPWillStopUptime);
    CIPiPStopCandidateConfirmedByWillStop =
        CIPiPStopCandidateGeneration == CIPiPAudioLifecycleGeneration &&
        callbackGap <= CIPiPStopToWillStopMaxInterval;
}

static void CISchedulePiPPauseClassification(
    MLPIPController *controller,
    NSUInteger generation,
    NSTimeInterval candidateUptime
) {
    __weak MLPIPController *weakController = controller;
    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(CIPiPPauseClassificationDelay * NSEC_PER_SEC)
        ),
        dispatch_get_main_queue(),
        ^{
            if (!CIPiPStopCandidate ||
                CIPiPStopCandidateGeneration != generation ||
                CIPiPStopCandidateUptime != candidateUptime ||
                CIPiPStopCandidateConfirmedByWillStop) return;
            MLPIPController *strongController = weakController;
            BOOL piPRemainsActive =
                strongController &&
                CIPiPControllerIsActive(strongController);
            if (piPRemainsActive) {
                CIClearPiPStopCandidate();
                [CILogStore.sharedStore recordLevel:CILogLevelDebug
                    category:@"Background"
                    message:@"PiP remained active after the pause request; classified it as an ordinary PiP pause and left playback paused."];
            }
        }
    );
}

static void CIObservePiPPlaybackStop(MLPIPController *controller) {
    YTPlayerViewController *playerController = CIActivePlayerController;
    BOOL systemPauseStateKnown =
        [controller respondsToSelector:
            @selector(pictureInPictureControllerIsPlaybackPaused:)] &&
        CIPiPSystemController != nil;
    BOOL systemReportedPaused = systemPauseStateKnown
        ? [controller
            pictureInPictureControllerIsPlaybackPaused:
                CIPiPSystemController]
        : NO;
    BOOL playbackRecentlyAdvanced =
        [CIBackgroundPlaybackMonitor.sharedMonitor
            playbackAdvancedWithinInterval:CIPiPRecentPlaybackInterval];
    BOOL playbackWasAlreadyPaused = systemPauseStateKnown
        ? systemReportedPaused
        : (CIPiPPlaybackPauseStateKnown
            ? CIPiPPlaybackPaused : !playbackRecentlyAdvanced);
    BOOL hasPlayingEvidence = systemPauseStateKnown
        ? !systemReportedPaused : playbackRecentlyAdvanced;
    BOOL shouldArm =
        CIPiPControllerIsActive(controller) &&
        !CIPiPRestoreRequested &&
        !playbackWasAlreadyPaused &&
        hasPlayingEvidence &&
        CIPlayerCanContinueInBackground(playerController, nil);

    CIPiPPlaybackPauseStateKnown = YES;
    CIPiPPlaybackPaused = YES;
    CIClearPiPStopCandidate();
    if (!shouldArm) return;

    CIPiPStopCandidate = YES;
    CIPiPStopCandidateGeneration = CIPiPAudioLifecycleGeneration;
    CIPiPStopCandidateUptime = NSProcessInfo.processInfo.systemUptime;
    CIPiPStopCandidateVideoID = [CIPlayerVideoID(playerController) copy];
    CIUpdatePiPStopPairing();
    CISchedulePiPPauseClassification(
        controller,
        CIPiPStopCandidateGeneration,
        CIPiPStopCandidateUptime
    );
    [CILogStore.sharedStore recordLevel:CILogLevelDebug
        category:@"Background"
        format:@"Observed a PiP pause request while video %@ was playing; waiting to distinguish pause from PiP dismissal.",
               CIPiPStopCandidateVideoID];
}

static void CIObservePiPWillStop(void) {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    CIPiPWillStopUptime = now;
    NSTimeInterval stopToWillStop = CIPiPStopCandidateUptime > 0
        ? now - CIPiPStopCandidateUptime : -1.0;
    CIUpdatePiPStopPairing();
    [CILogStore.sharedStore recordLevel:CILogLevelDebug
        category:@"Background"
        format:@"PiP will stop: matched playing pause candidate %d (pause-to-stop gap %.2fs, restore %d).",
               CIPiPStopCandidateConfirmedByWillStop,
               stopToWillStop, CIPiPRestoreRequested];
}

static NSString *CIYTPiPControllerVideoID(
    YTPlayerPIPController *controller
) {
    YTSingleVideoController *activeVideo = nil;
    @synchronized (CIPiPActiveVideoByController) {
        activeVideo =
            [CIPiPActiveVideoByController objectForKey:controller];
    }
    return activeVideo.singleVideo.videoId ?: @"";
}

static BOOL CIYTPiPControllerMatchesCandidate(
    YTPlayerPIPController *controller
) {
    NSString *controllerVideoID = CIYTPiPControllerVideoID(controller);
    return controllerVideoID.length > 0 &&
        (CIPiPStopCandidateVideoID.length == 0 ||
         [controllerVideoID isEqualToString:CIPiPStopCandidateVideoID]);
}

static BOOL CIYTPiPControllerOwnsActiveVideo(
    YTPlayerPIPController *controller
) {
    YTSingleVideoController *activeVideo =
        CIActivePlayerController.activeVideo;
    YTSingleVideoController *controllerVideo = nil;
    @synchronized (CIPiPActiveVideoByController) {
        controllerVideo =
            [CIPiPActiveVideoByController objectForKey:controller];
    }
    return activeVideo && controllerVideo == activeVideo;
}

static void CIPrepareForPictureInPicture(NSString *source,
                                         NSUInteger generation,
                                         BOOL shouldLog) {
    if (generation != CIPictureInPicturePreparationGeneration) return;
    YTPlayerViewController *controller = CIActivePlayerController;
    if (!controller || CIPlayerVideoID(controller).length == 0) {
        if (shouldLog) {
            [CILogStore.sharedStore recordLevel:CILogLevelWarning
                category:@"Background"
                format:@"Picture in Picture started through %@, but no active YouTube player was available yet.",
                       source];
        }
        return;
    }
    [CIBackgroundPlaybackMonitor.sharedMonitor
        prepareForPictureInPictureWithPlayerController:controller];
    if (shouldLog) {
        [CILogStore.sharedStore recordLevel:CILogLevelInfo
            category:@"Background"
            format:@"Detected Picture in Picture through %@ for video %@.",
                   source, CIPlayerVideoID(controller)];
    }
}

static void CISchedulePictureInPicturePreparation(NSString *source) {
    NSUInteger generation = ++CIPictureInPicturePreparationGeneration;
    NSTimeInterval delays[] = {0, 0.35, 1.0};
    for (NSUInteger index = 0; index < 3; index++) {
        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(delays[index] * NSEC_PER_SEC)
            ),
            dispatch_get_main_queue(),
            ^{
                CIPrepareForPictureInPicture(
                    source ?: @"unknown source",
                    generation,
                    index == 0
                );
            }
        );
    }
}

static BOOL CIRebindPlayerForTimeCallback(YTPlayerViewController *controller) {
    if ([objc_getAssociatedObject(controller, CIRetiredPlayerKey) boolValue]) {
        return NO;
    }
    YTPlayerViewController *activeController = CIActivePlayerController;
    if (!activeController) {
        if (![objc_getAssociatedObject(controller, CIActivePlayerKey) boolValue]) {
            return NO;
        }
        CIActivePlayerController = controller;
        [CIBackgroundPlaybackMonitor.sharedMonitor attachPlayerController:controller];
        return YES;
    }
    if (activeController == controller) return YES;
    if (UIApplication.sharedApplication.applicationState ==
            UIApplicationStateActive &&
        ![CIBackgroundPlaybackMonitor.sharedMonitor
            isSamplingPlaybackInBackground]) return NO;

    NSString *activeVideoID = CIPlayerVideoID(activeController);
    NSString *callbackVideoID = CIPlayerVideoID(controller);
    if (activeVideoID.length == 0 ||
        ![activeVideoID isEqualToString:callbackVideoID]) return NO;

    objc_setAssociatedObject(activeController, CIActivePlayerKey, nil,
                            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(activeController, CIRetiredPlayerKey, @YES,
                            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controller, CIActivePlayerKey, @YES,
                            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controller, CIRetiredPlayerKey, nil,
                            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CIActivePlayerController = controller;
    CIPlaybackLifecycleGeneration++;
    [CIBackgroundPlaybackMonitor.sharedMonitor attachPlayerController:controller];
    [CICaptionCoordinator.sharedCoordinator prepareForExternalPlayback];
    [CILogStore.sharedStore recordLevel:CILogLevelInfo
        category:@"Background"
        format:@"Rebound caption timing to the Picture in Picture player for video %@.",
               callbackVideoID];
    return YES;
}

static void CIHandlePlaybackTimeValue(YTPlayerViewController *controller,
                                      NSTimeInterval playbackTime) {
    if (!controller || !CIRebindPlayerForTimeCallback(controller)) return;
    CICaptionCoordinator *coordinator = CICaptionCoordinator.sharedCoordinator;
    CIUpdateSuppression(controller);
    if (!CIPlayerControllerIsAdvertising(controller)) {
        [CIBackgroundPlaybackMonitor.sharedMonitor
            observeNativePlaybackTime:playbackTime
                     playerController:controller];
        [coordinator updatePlaybackTime:playbackTime];
    }
}

static void CIHandlePlaybackTime(YTPlayerViewController *controller,
                                 YTSingleVideoTime *videoTime) {
    if (!videoTime) return;
    NSTimeInterval playbackTime = videoTime.time;
    if (!NSThread.isMainThread) {
        YTPlayerViewController *retainedController = controller;
        dispatch_async(dispatch_get_main_queue(), ^{
            CIHandlePlaybackTimeValue(retainedController, playbackTime);
        });
        return;
    }
    CIHandlePlaybackTimeValue(controller, playbackTime);
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
        objc_setAssociatedObject(CIActivePlayerController, CIRetiredPlayerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CIActivePlayerController = controller;
    [CIBackgroundPlaybackMonitor.sharedMonitor attachPlayerController:controller];
    objc_setAssociatedObject(controller, CIActivePlayerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controller, CIRetiredPlayerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    objc_setAssociatedObject(controller, CIRetiredPlayerKey, nil,
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
        [CICaptionCoordinator.sharedCoordinator prepareForExternalPlayback];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if ([objc_getAssociatedObject(self, CIRetiredPlayerKey) boolValue]) {
        YTPlayerViewController *activeController = CIActivePlayerController;
        NSString *videoID = CIPlayerVideoID(self);
        NSString *activeVideoID = CIPlayerVideoID(activeController);
        if (videoID.length > 0 &&
            (!activeController || [videoID isEqualToString:activeVideoID])) {
            if (activeController && activeController != self) {
                objc_setAssociatedObject(activeController, CIActivePlayerKey,
                                         nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(activeController, CIRetiredPlayerKey,
                                         @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            objc_setAssociatedObject(self, CIRetiredPlayerKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, CIActivePlayerKey, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CIActivePlayerController = self;
            CIPlaybackLifecycleGeneration++;
            [CIBackgroundPlaybackMonitor.sharedMonitor
                attachPlayerController:self];
            [CILogStore.sharedStore recordLevel:CILogLevelInfo
                category:@"Background"
                format:@"Restored caption timing to the foreground player for video %@.",
                       videoID];
        }
    }
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

%group CaptionIslandAVKitPiPHooks

%hook AVPictureInPictureController

- (void)startPictureInPicture {
    %orig;
    CISchedulePictureInPicturePreparation(@"AVPictureInPictureController");
}

%end

%end

%group CaptionIslandMLActivatePiPHooks

%hook MLPIPController

- (void)activatePiPController {
    %orig;
    CISchedulePictureInPicturePreparation(@"MLPIPController");
}

%end

%end

%group CaptionIslandMLStartPiPHooks

%hook MLPIPController

- (BOOL)startPictureInPicture {
    BOOL started = %orig;
    if (started) {
        CISchedulePictureInPicturePreparation(@"MLPIPController legacy start");
    }
    return started;
}

%end

%end

%group CaptionIslandMLPiPAudioLifecycleHooks

%hook MLPIPController

- (void)pictureInPictureControllerDidStartPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
    CIBeginPiPAudioLifecycle(self, pictureInPictureController);
    %orig;
}

- (void)pictureInPictureController:
            (AVPictureInPictureController *)pictureInPictureController
    setPlaying:(BOOL)playing {
    CIPiPSystemController =
        pictureInPictureController ?: CIPiPSystemController;
    if (playing) {
        CIObservePiPPlaybackStart();
    } else {
        CIObservePiPPlaybackStop(self);
    }
    %orig;
}

- (void)pictureInPictureControllerWillStopPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
    CIObservePiPWillStop();
    %orig;
}

%end

%end

%group CaptionIslandMLPiPRestoreHooks

%hook MLPIPController

- (void)pictureInPictureController:
            (AVPictureInPictureController *)pictureInPictureController
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:
            (void (^)(BOOL restored))completionHandler {
    CIPiPRestoreRequested = YES;
    CIPiPAudioRecoveryToken++;
    CIClearPiPStopCandidate();
    [CILogStore.sharedStore recordLevel:CILogLevelDebug
        category:@"Background"
        message:@"PiP is returning to YouTube; background-audio recovery is not needed."];
    %orig;
}

%end

%end

%group CaptionIslandYTPiPAudioRecoveryHooks

%hook YTPlayerPIPController

- (void)setActiveSingleVideo:
    (YTSingleVideoController *)activeSingleVideo {
    @synchronized (CIPiPActiveVideoByController) {
        if (activeSingleVideo) {
            [CIPiPActiveVideoByController
                setObject:activeSingleVideo
                   forKey:self];
        } else {
            [CIPiPActiveVideoByController removeObjectForKey:self];
        }
    }
    %orig;
}

- (void)pictureInPicturePlaybackPauseRequested {
    YTPlayerPIPController *selectedController =
        CIPiPRecoveryController;
    BOOL shouldSelect =
        CIPiPStopCandidate &&
        CIYTPiPControllerMatchesCandidate(self) &&
        (!selectedController ||
         (!CIYTPiPControllerOwnsActiveVideo(selectedController) &&
          CIYTPiPControllerOwnsActiveVideo(self)));
    if (shouldSelect) {
        CIPiPRecoveryController = self;
        [CILogStore.sharedStore recordLevel:CILogLevelDebug
            category:@"Background"
            format:@"Selected the PiP observer for video %@ as the background-audio recovery controller.",
                   CIYTPiPControllerVideoID(self)];
    }
    %orig;
}

- (void)didStopPictureInPicture {
    YTPlayerPIPController *selectedController =
        CIPiPRecoveryController;
    BOOL controllerMatches =
        CIYTPiPControllerMatchesCandidate(self);
    BOOL shouldConsumeLifecycle =
        (selectedController == self) ||
        (!selectedController && controllerMatches);
    if (!shouldConsumeLifecycle ||
        CIPiPConsumedDidStopGeneration ==
            CIPiPAudioLifecycleGeneration) {
        [CILogStore.sharedStore recordLevel:CILogLevelDebug
            category:@"Background"
            format:@"Ignored a secondary PiP didStop observer (video %@, selected %d, generation already consumed %d).",
                   CIYTPiPControllerVideoID(self),
                   selectedController == self,
                   CIPiPConsumedDidStopGeneration ==
                       CIPiPAudioLifecycleGeneration];
        %orig;
        return;
    }
    CIPiPRecoveryController = self;
    CIPiPConsumedDidStopGeneration =
        CIPiPAudioLifecycleGeneration;

    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSTimeInterval candidateAge = CIPiPStopCandidateUptime > 0
        ? now - CIPiPStopCandidateUptime : -1.0;
    NSTimeInterval willStopAge = CIPiPWillStopUptime > 0
        ? now - CIPiPWillStopUptime : -1.0;
    BOOL restoreWasRequested = CIPiPRestoreRequested;
    BOOL candidateIsCurrent =
        CIPiPStopCandidate &&
        CIPiPStopCandidateConfirmedByWillStop &&
        CIPiPStopCandidateGeneration == CIPiPAudioLifecycleGeneration &&
        CIPiPStopCandidateUptime > 0 &&
        willStopAge >= 0 &&
        willStopAge <= CIPiPWillStopToDidStopMaxInterval;
    BOOL applicationRemainsBackgrounded =
        UIApplication.sharedApplication.applicationState ==
        UIApplicationStateBackground;
    BOOL shouldRecover =
        candidateIsCurrent &&
        !restoreWasRequested &&
        applicationRemainsBackgrounded;
    NSString *expectedVideoID = [CIPiPStopCandidateVideoID copy];
    NSUInteger piPGeneration = CIPiPAudioLifecycleGeneration;
    NSUInteger recoveryToken = ++CIPiPAudioRecoveryToken;
    NSString *classification = restoreWasRequested
        ? @"restore"
        : (shouldRecover
            ? @"non-restore dismissal with recovery"
            : @"non-restore dismissal without recovery");
    [CILogStore.sharedStore recordLevel:CILogLevelDebug
        category:@"Background"
        format:@"PiP did stop: %@ (candidate %d, confirmed %d, candidate age %.2fs, will-stop age %.2fs, app state %ld).",
               classification, CIPiPStopCandidate,
               CIPiPStopCandidateConfirmedByWillStop,
               candidateAge, willStopAge,
               (long)UIApplication.sharedApplication.applicationState];

    CIClearPiPStopCandidate();
    CIPiPSystemController = nil;
    CIPiPWillStopUptime = 0;
    CIPiPRestoreRequested = NO;
    CIPiPPlaybackPauseStateKnown = NO;
    CIPiPPlaybackPaused = NO;
    %orig;

    if (!shouldRecover) {
        if (!restoreWasRequested && applicationRemainsBackgrounded) {
            [CILogStore.sharedStore recordLevel:CILogLevelDebug
                category:@"Background"
                format:@"PiP stopped in the background without a current playing-state candidate (candidate age %.2fs); audio was left unchanged.",
                       candidateAge];
        }
        return;
    }
    YTPlayerPIPController *retainedController = self;
    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(CIPiPAudioRecoveryDelay * NSEC_PER_SEC)
        ),
        dispatch_get_main_queue(),
        ^{
            BOOL tokenIsCurrent =
                recoveryToken == CIPiPAudioRecoveryToken;
            BOOL piPGenerationIsCurrent =
                piPGeneration == CIPiPAudioLifecycleGeneration;
            BOOL applicationStillBackgrounded =
                UIApplication.sharedApplication.applicationState ==
                UIApplicationStateBackground;
            if (!tokenIsCurrent || !piPGenerationIsCurrent ||
                !applicationStillBackgrounded) {
                [CILogStore.sharedStore recordLevel:CILogLevelDebug
                    category:@"Background"
                    format:@"Canceled PiP background-audio recovery because state changed (token %d, PiP generation %d, background %d).",
                           tokenIsCurrent, piPGenerationIsCurrent,
                           applicationStillBackgrounded];
                return;
            }

            YTPlayerViewController *playerController =
                CIActivePlayerController;
            if (!CIPlayerCanContinueInBackground(
                    playerController, expectedVideoID)) {
                [CILogStore.sharedStore recordLevel:CILogLevelDebug
                    category:@"Background"
                    format:@"Canceled PiP background-audio recovery because video %@ is no longer eligible.",
                           expectedVideoID];
                return;
            }
            if (![retainedController respondsToSelector:
                    @selector(pictureInPicturePlaybackResumeRequested)]) {
                [CILogStore.sharedStore recordLevel:CILogLevelWarning
                    category:@"Background"
                    message:@"YouTube does not expose the PiP playback-resume callback; background audio could not be restored after dismissing PiP."];
                return;
            }

            NSTimeInterval positionBeforeRecovery =
                playerController.currentVideoMediaTime;
            [retainedController pictureInPicturePlaybackResumeRequested];
            [CIBackgroundPlaybackMonitor.sharedMonitor
                attachPlayerController:playerController];
            [CICaptionCoordinator.sharedCoordinator
                prepareForExternalPlayback];
            NSTimeInterval playbackTime =
                playerController.currentVideoMediaTime;
            if (isfinite(playbackTime) && playbackTime >= 0) {
                [CICaptionCoordinator.sharedCoordinator
                    updatePlaybackTime:playbackTime];
            }
            [CILogStore.sharedStore recordLevel:CILogLevelInfo
                category:@"Background"
                format:@"Requested background-audio continuation for video %@ after non-restore PiP dismissal.",
                       expectedVideoID];
            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    (int64_t)(
                        CIPiPRecoveryVerificationDelay * NSEC_PER_SEC
                    )
                ),
                dispatch_get_main_queue(),
                ^{
                    if (recoveryToken != CIPiPAudioRecoveryToken ||
                        piPGeneration != CIPiPAudioLifecycleGeneration ||
                        UIApplication.sharedApplication.applicationState !=
                            UIApplicationStateBackground) return;
                    YTPlayerViewController *verificationController =
                        CIActivePlayerController;
                    if (!CIPlayerCanContinueInBackground(
                            verificationController, expectedVideoID)) return;
                    NSTimeInterval positionAfterRecovery =
                        verificationController.currentVideoMediaTime;
                    BOOL playbackAdvanced =
                        isfinite(positionBeforeRecovery) &&
                        isfinite(positionAfterRecovery) &&
                        positionAfterRecovery >
                            positionBeforeRecovery + 0.04;
                    if (playbackAdvanced) {
                        [CILogStore.sharedStore
                            recordLevel:CILogLevelInfo
                            category:@"Background"
                            format:@"Verified background playback for video %@ after PiP dismissal (%.1fs → %.1fs); Control Center should remain active.",
                                   expectedVideoID,
                                   positionBeforeRecovery,
                                   positionAfterRecovery];
                    } else {
                        [CILogStore.sharedStore
                            recordLevel:CILogLevelWarning
                            category:@"Background"
                            format:@"YouTube accepted the PiP resume request for video %@, but its playback clock did not advance (%.1fs → %.1fs).",
                                   expectedVideoID,
                                   positionBeforeRecovery,
                                   positionAfterRecovery];
                    }
                }
            );
        }
    );
}

%end

%end

%group CaptionIslandYTModernPiPHooks

%hook YTPlayerPIPController

- (void)maybeEnablePictureInPicture {
    %orig;
    CISchedulePictureInPicturePreparation(@"YTPlayerPIPController");
}

%end

%end

%group CaptionIslandYTLegacyPiPHooks

%hook YTPlayerPIPController

- (void)maybeInvokePictureInPicture {
    %orig;
    CISchedulePictureInPicturePreparation(@"YTPlayerPIPController legacy start");
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
    CIPiPActiveVideoByController =
        [NSMapTable weakToWeakObjectsMapTable];
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
    Class AVPiPClass = NSClassFromString(@"AVPictureInPictureController");
    if (AVPiPClass &&
        class_getInstanceMethod(AVPiPClass, @selector(startPictureInPicture))) {
        %init(CaptionIslandAVKitPiPHooks);
    }
    Class MLPiPClass = NSClassFromString(@"MLPIPController");
    if (MLPiPClass &&
        class_getInstanceMethod(MLPiPClass, @selector(activatePiPController))) {
        %init(CaptionIslandMLActivatePiPHooks);
    }
    if (MLPiPClass &&
        class_getInstanceMethod(MLPiPClass, @selector(startPictureInPicture))) {
        %init(CaptionIslandMLStartPiPHooks);
    }
    SEL didStartPiP =
        @selector(pictureInPictureControllerDidStartPictureInPicture:);
    SEL setPiPPlaying =
        @selector(pictureInPictureController:setPlaying:);
    SEL willStopPiP =
        @selector(pictureInPictureControllerWillStopPictureInPicture:);
    SEL piPActiveState =
        @selector(pictureInPictureActive);
    SEL piPPauseState =
        @selector(pictureInPictureControllerIsPlaybackPaused:);
    SEL restorePiP =
        @selector(pictureInPictureController:
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:);
    BOOL hasMLPiPAudioLifecycle =
        MLPiPClass &&
        class_getInstanceMethod(MLPiPClass, didStartPiP) &&
        class_getInstanceMethod(MLPiPClass, setPiPPlaying) &&
        class_getInstanceMethod(MLPiPClass, willStopPiP) &&
        class_getInstanceMethod(MLPiPClass, piPActiveState) &&
        class_getInstanceMethod(MLPiPClass, piPPauseState);
    BOOL hasMLPiPRestore =
        MLPiPClass &&
        class_getInstanceMethod(MLPiPClass, restorePiP);
    if (hasMLPiPAudioLifecycle) {
        %init(CaptionIslandMLPiPAudioLifecycleHooks);
    }
    if (hasMLPiPRestore) {
        %init(CaptionIslandMLPiPRestoreHooks);
    }
    Class YTPiPClass = NSClassFromString(@"YTPlayerPIPController");
    Class singleVideoControllerClass =
        NSClassFromString(@"YTSingleVideoController");
    Class singleVideoClass = NSClassFromString(@"YTSingleVideo");
    BOOL hasPiPVideoIdentity =
        singleVideoControllerClass &&
        class_getInstanceMethod(
            singleVideoControllerClass,
            @selector(singleVideo)
        ) &&
        singleVideoClass &&
        class_getInstanceMethod(singleVideoClass, @selector(videoId));
    BOOL hasYTPiPAudioRecovery =
        YTPiPClass &&
        hasPiPVideoIdentity &&
        class_getInstanceMethod(
            YTPiPClass,
            @selector(setActiveSingleVideo:)
        ) &&
        class_getInstanceMethod(
            YTPiPClass,
            @selector(pictureInPicturePlaybackPauseRequested)
        ) &&
        class_getInstanceMethod(
            YTPiPClass,
            @selector(didStopPictureInPicture)
        ) &&
        class_getInstanceMethod(
            YTPiPClass,
            @selector(pictureInPicturePlaybackResumeRequested)
        );
    if (hasMLPiPAudioLifecycle && hasMLPiPRestore &&
        hasYTPiPAudioRecovery) {
        %init(CaptionIslandYTPiPAudioRecoveryHooks);
    }
    if (hasMLPiPAudioLifecycle && hasMLPiPRestore &&
        hasYTPiPAudioRecovery) {
        [CILogStore.sharedStore recordLevel:CILogLevelDebug
            category:@"Background"
            message:@"PiP background-audio recovery is ready with non-restore dismissal detection."];
    } else {
        [CILogStore.sharedStore recordLevel:CILogLevelWarning
            category:@"Background"
            format:@"PiP background-audio recovery is unavailable for this YouTube version (ML lifecycle %d, restore detection %d, YouTube recovery callback %d).",
                   hasMLPiPAudioLifecycle, hasMLPiPRestore,
                   hasYTPiPAudioRecovery];
    }
    if (YTPiPClass &&
        class_getInstanceMethod(
            YTPiPClass,
            @selector(maybeEnablePictureInPicture)
        )) {
        %init(CaptionIslandYTModernPiPHooks);
    }
    if (YTPiPClass &&
        class_getInstanceMethod(
            YTPiPClass,
            @selector(maybeInvokePictureInPicture)
        )) {
        %init(CaptionIslandYTLegacyPiPHooks);
    }
}
