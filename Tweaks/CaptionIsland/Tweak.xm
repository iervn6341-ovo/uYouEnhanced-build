#import <Foundation/Foundation.h>
#import <AVKit/AVKit.h>
#import <YouTubeHeader/GOOHUDManagerInternal.h>
#import <YouTubeHeader/MLPIPController.h>
#import <YouTubeHeader/YTHUDMessage.h>
#import <YouTubeHeader/YTPlayerOverlayManager.h>
#import <YouTubeHeader/YTPlayerPIPController.h>
#import <YouTubeHeader/YTPlayerViewController.h>
#import <YouTubeHeader/YTShortsPlayerViewController.h>
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
- (void)didStopPictureInPicture;
@end

@interface YTPlayerViewController (CaptionIslandRemotePlayback)
- (void)play;
- (void)pause;
- (void)varispeedSwitchController:(id)controller
                    didSelectRate:(float)rate;
@end

static const void *CISuppressedStateKey = &CISuppressedStateKey;
static const void *CIActivePlayerKey = &CIActivePlayerKey;
static const void *CIRetiredPlayerKey = &CIRetiredPlayerKey;
static const void *CIShortsPlayerKey = &CIShortsPlayerKey;
static const void *CIPendingShortsPlayerKey =
    &CIPendingShortsPlayerKey;
static const void *CIDurationRefreshVideoKey =
    &CIDurationRefreshVideoKey;
static __weak YTPlayerViewController *CIActivePlayerController;
static __weak AVPictureInPictureController *CIPiPSystemController;
static __weak YTPlayerPIPController *CIPiPRecoveryController;
static NSMapTable<
    YTPlayerPIPController *,
    YTSingleVideoController *
> *CIPiPActiveVideoByController;
static NSHashTable<YTPlayerPIPController *> *
    CIPiPDeferredPauseControllers;
static NSHashTable<YTPlayerPIPController *> *
    CIPiPLifecycleControllers;
static IMP CIPiPOriginalPauseRequestedImplementation;
static NSUInteger CIPlaybackLifecycleGeneration;
static NSUInteger CIPictureInPicturePreparationGeneration;
static NSUInteger CIPiPAudioLifecycleGeneration;
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
static NSUInteger CIPiPLatePauseSuppressionGeneration;
static NSTimeInterval CIPiPLatePauseSuppressionUntil;
static NSString *CIPiPLatePauseSuppressionVideoID;
static NSUInteger CIPiPLatePauseSuppressionCount;
static BOOL CIRemotePlaybackPlaying = YES;
static double CIRemotePlaybackRate = 1.0;

static const NSTimeInterval CIPiPRecentPlaybackInterval = 1.8;
static const NSTimeInterval CIPiPStopToWillStopMaxInterval = 0.65;
static const NSTimeInterval CIPiPWillStopToDidStopMaxInterval = 2.0;
static const NSTimeInterval CIPiPPauseClassificationDelay = 0.80;
static const NSTimeInterval CIPiPLatePauseSuppressionInterval = 1.2;
static const NSTimeInterval CIPiPReadOnlyVerificationDelay = 1.0;

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

static void CISynchronizeRemotePlayback(
    YTPlayerViewController *controller,
    BOOL playing,
    double rate,
    BOOL force
) {
    if (!controller || controller != CIActivePlayerController ||
        CIPlayerControllerIsAdvertising(controller)) return;
    NSTimeInterval position =
        controller.currentVideoMediaTime;
    if (!isfinite(position) || position < 0) return;
    CIRemotePlaybackPlaying = playing;
    if (isfinite(rate) && rate >= 0.25 && rate <= 4.0) {
        CIRemotePlaybackRate = rate;
    }
    [CICaptionCoordinator.sharedCoordinator
        synchronizePlaybackAtPosition:position
                              playing:playing
                                 rate:CIRemotePlaybackRate
                                force:force];
}

static void CIMarkShortsPlayer(
    YTPlayerViewController *controller
);

static BOOL CIPlayerControllerIsShorts(
    YTPlayerViewController *controller
) {
    if (!controller) return NO;
    id marker =
        objc_getAssociatedObject(controller, CIShortsPlayerKey);
    NSString *videoID = CIPlayerVideoID(controller);
    if ([marker isKindOfClass:NSString.class] &&
        videoID.length > 0 &&
        [marker isEqualToString:videoID]) {
        return YES;
    }
    if ([objc_getAssociatedObject(
            controller,
            CIPendingShortsPlayerKey
        ) boolValue] &&
        videoID.length > 0) {
        CIMarkShortsPlayer(controller);
        return YES;
    }
    UIViewController *ancestor = controller;
    for (NSUInteger depth = 0; ancestor && depth < 10; depth++) {
        NSString *className =
            NSStringFromClass(ancestor.class).lowercaseString;
        if ([className containsString:@"shorts"] ||
            [className containsString:@"reelplayer"]) {
            CIMarkShortsPlayer(controller);
            return YES;
        }
        ancestor = ancestor.parentViewController;
    }
    return NO;
}

static void CIMarkShortsPlayer(
    YTPlayerViewController *controller
) {
    if (!controller) return;
    NSString *videoID = CIPlayerVideoID(controller);
    if (videoID.length == 0) {
        objc_setAssociatedObject(
            controller,
            CIPendingShortsPlayerKey,
            @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
        return;
    }
    objc_setAssociatedObject(
        controller,
        CIPendingShortsPlayerKey,
        nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );
    [CIYouTubeInspector markPlayerControllerAsShorts:controller];
    objc_setAssociatedObject(
        controller,
        CIShortsPlayerKey,
        videoID,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );
}

static CIVideoContext *CIContextForPlayer(
    id playbackData,
    YTPlayerViewController *controller
) {
    CIVideoContext *context =
        [CIYouTubeInspector contextFromPlaybackData:playbackData
                                   playerController:controller];
    if (context) {
        if (context.isShorts) {
            CIMarkShortsPlayer(controller);
        } else {
            context.shorts =
                CIPlayerControllerIsShorts(controller);
        }
    }
    return context;
}

static void CIReevaluateShortsPlayer(
    YTPlayerViewController *controller
) {
    if (!controller || controller != CIActivePlayerController ||
        CIPlayerControllerIsAdvertising(controller)) return;
    CIVideoContext *context =
        [CIYouTubeInspector contextFromPlaybackData:nil
                                   playerController:controller];
    if (!context.videoID.length ||
        ![context.videoID isEqualToString:
            CIPlayerVideoID(controller)]) return;
    context.shorts = YES;
    [CICaptionCoordinator.sharedCoordinator
        activateContext:context];
}

static YTPlayerViewController *CIPlayerFromShortsContainer(
    UIViewController *container
) {
    if (!container) return nil;
    id candidate;
    @try {
        candidate = [container valueForKey:@"player"];
    } @catch (__unused NSException *exception) {
        candidate = nil;
    }
    Class playerClass =
        NSClassFromString(@"YTPlayerViewController");
    if (playerClass &&
        [candidate isKindOfClass:playerClass]) {
        return candidate;
    }
    for (UIViewController *child in
         container.childViewControllers) {
        if (playerClass &&
            [child isKindOfClass:playerClass]) {
            return (YTPlayerViewController *)child;
        }
        YTPlayerViewController *nested =
            CIPlayerFromShortsContainer(child);
        if (nested) return nested;
    }
    return nil;
}

static void CIRefreshDurationPolicyIfNeeded(
    YTPlayerViewController *controller
) {
    if (!controller || CIPlayerControllerIsAdvertising(controller)) {
        return;
    }
    NSString *videoID = CIPlayerVideoID(controller);
    NSTimeInterval duration =
        controller.currentVideoTotalMediaTime;
    if (videoID.length == 0 || !isfinite(duration) ||
        duration <= 0) return;
    NSString *lastRefreshedVideoID =
        objc_getAssociatedObject(
            controller,
            CIDurationRefreshVideoKey
        );
    if ([lastRefreshedVideoID isEqualToString:videoID]) return;
    objc_setAssociatedObject(
        controller,
        CIDurationRefreshVideoKey,
        videoID,
        OBJC_ASSOCIATION_COPY_NONATOMIC
    );
    CIVideoContext *context =
        CIContextForPlayer(nil, controller);
    if (context.duration > 0 &&
        [context.videoID isEqualToString:videoID]) {
        [CICaptionCoordinator.sharedCoordinator
            activateContext:context];
    }
}

static void CIClearPiPStopCandidate(void) {
    @synchronized (CIPiPDeferredPauseControllers) {
        [CIPiPDeferredPauseControllers removeAllObjects];
    }
    CIPiPStopCandidate = NO;
    CIPiPStopCandidateGeneration = 0;
    CIPiPStopCandidateUptime = 0;
    CIPiPStopCandidateConfirmedByWillStop = NO;
    CIPiPStopCandidateVideoID = nil;
}

static void CIClearLatePiPPauseSuppression(void) {
    CIPiPLatePauseSuppressionGeneration = 0;
    CIPiPLatePauseSuppressionUntil = 0;
    CIPiPLatePauseSuppressionVideoID = nil;
    CIPiPLatePauseSuppressionCount = 0;
}

static void CIDeferPiPPauseRequest(
    YTPlayerPIPController *controller
) {
    if (!controller) return;
    @synchronized (CIPiPDeferredPauseControllers) {
        [CIPiPDeferredPauseControllers addObject:controller];
    }
}

static NSUInteger CIDeliverDeferredPiPPauseRequests(void) {
    NSArray<YTPlayerPIPController *> *controllers;
    @synchronized (CIPiPDeferredPauseControllers) {
        controllers =
            CIPiPDeferredPauseControllers.allObjects ?: @[];
        [CIPiPDeferredPauseControllers removeAllObjects];
    }
    if (!CIPiPOriginalPauseRequestedImplementation) return 0;
    void (*invokeOriginal)(id, SEL) =
        (void (*)(id, SEL))
            CIPiPOriginalPauseRequestedImplementation;
    for (YTPlayerPIPController *controller in controllers) {
        invokeOriginal(
            controller,
            @selector(pictureInPicturePlaybackPauseRequested)
        );
    }
    return controllers.count;
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
    CIPiPSystemController = pictureInPictureController;
    CIPiPRecoveryController = nil;
    CIPiPConsumedDidStopGeneration = 0;
    CIPiPWillStopUptime = 0;
    CIPiPRestoreRequested = NO;
    NSArray<YTPlayerPIPController *> *activeControllers;
    @synchronized (CIPiPActiveVideoByController) {
        activeControllers =
            CIPiPActiveVideoByController.keyEnumerator.allObjects
                ?: @[];
    }
    @synchronized (CIPiPLifecycleControllers) {
        [CIPiPLifecycleControllers removeAllObjects];
        for (YTPlayerPIPController *activeController
                in activeControllers) {
            [CIPiPLifecycleControllers
                addObject:activeController];
        }
    }
    CIClearLatePiPPauseSuppression();
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
    CISynchronizeRemotePlayback(
        CIActivePlayerController,
        YES,
        CIRemotePlaybackRate,
        YES
    );
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
                NSUInteger deliveredPauseCount =
                    CIDeliverDeferredPiPPauseRequests();
                CIClearPiPStopCandidate();
                CISynchronizeRemotePlayback(
                    CIActivePlayerController,
                    NO,
                    CIRemotePlaybackRate,
                    YES
                );
                [CILogStore.sharedStore recordLevel:CILogLevelDebug
                    category:@"Background"
                    format:@"PiP remained active after the pause request; delivered %lu deferred ordinary-pause callback(s).",
                           (unsigned long)deliveredPauseCount];
            }
        }
    );
}

static void CIObservePiPPlaybackStop(MLPIPController *controller) {
    YTPlayerViewController *playerController = CIActivePlayerController;
    if (CIPiPStopCandidate &&
        CIPiPStopCandidateGeneration ==
            CIPiPAudioLifecycleGeneration) {
        CIPiPPlaybackPauseStateKnown = YES;
        CIPiPPlaybackPaused = YES;
        [CILogStore.sharedStore recordLevel:CILogLevelDebug
            category:@"Background"
            message:@"Ignored a duplicate PiP stop callback while pause classification was already pending."];
        return;
    }
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
    CIPictureInPicturePreparationGeneration++;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    CIPiPWillStopUptime = now;
    NSTimeInterval stopToWillStop = CIPiPStopCandidateUptime > 0
        ? now - CIPiPStopCandidateUptime : -1.0;
    CIUpdatePiPStopPairing();
    if (CIPiPStopCandidateConfirmedByWillStop &&
        !CIPiPRestoreRequested) {
        CIPiPLatePauseSuppressionGeneration =
            CIPiPAudioLifecycleGeneration;
        CIPiPLatePauseSuppressionUntil =
            now + CIPiPLatePauseSuppressionInterval;
        CIPiPLatePauseSuppressionVideoID =
            [CIPiPStopCandidateVideoID copy];
        CIPiPLatePauseSuppressionCount = 0;
    }
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
        CIRefreshDurationPolicyIfNeeded(controller);
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
    CIVideoContext *updated = CIContextForPlayer(nil, controller);
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
        CIVideoContext *updated =
            CIContextForPlayer(nil, strongController);
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
    CIVideoContext *context =
        CIContextForPlayer(playbackData, controller);
    if (!context) {
        [CIBackgroundPlaybackMonitor.sharedMonitor detachPlayerController:controller];
        [coordinator stop];
        return;
    }
    [coordinator activateContext:context];
    if (context.duration > 0) {
        objc_setAssociatedObject(
            controller,
            CIDurationRefreshVideoKey,
            context.videoID,
            OBJC_ASSOCIATION_COPY_NONATOMIC
        );
    }

    // Caption tracks can arrive shortly after the player response. Use three
    // bounded snapshots; there is no foreground polling loop.
    CIScheduleCaptionRefresh(controller, context.videoID, 0);
}

static void CIActivatePlayback(YTPlayerViewController *controller, id playbackData) {
    CIPlaybackLifecycleGeneration++;
    CIRemotePlaybackPlaying = YES;
    objc_setAssociatedObject(
        controller,
        CIDurationRefreshVideoKey,
        nil,
        OBJC_ASSOCIATION_COPY_NONATOMIC
    );
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

%group CaptionIslandShortsPlayerSetterHooks

%hook YTShortsPlayerViewController

- (void)setPlayer:(YTPlayerViewController *)player {
    YTPlayerViewController *previousPlayer =
        CIPlayerFromShortsContainer(self);
    %orig;
    if (previousPlayer && previousPlayer != player) {
        objc_setAssociatedObject(
            previousPlayer,
            CIPendingShortsPlayerKey,
            nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }
    CIMarkShortsPlayer(player);
    CIReevaluateShortsPlayer(player);
}

%end

%end

%group CaptionIslandShortsLifecycleHooks

%hook YTShortsPlayerViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    YTPlayerViewController *player =
        CIPlayerFromShortsContainer(self);
    CIMarkShortsPlayer(player);
    CIReevaluateShortsPlayer(player);
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
    CIClearLatePiPPauseSuppression();
    NSUInteger deliveredPauseCount =
        CIDeliverDeferredPiPPauseRequests();
    if (deliveredPauseCount > 0) {
        CISynchronizeRemotePlayback(
            CIActivePlayerController,
            NO,
            CIRemotePlaybackRate,
            YES
        );
    }
    CIClearPiPStopCandidate();
    [CILogStore.sharedStore recordLevel:CILogLevelDebug
        category:@"Background"
        format:@"PiP is returning to YouTube; preserved %lu deferred pause callback(s) before restoring the interface.",
               (unsigned long)deliveredPauseCount];
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
            @synchronized (CIPiPLifecycleControllers) {
                [CIPiPLifecycleControllers addObject:self];
            }
        } else {
            [CIPiPActiveVideoByController removeObjectForKey:self];
        }
    }
    %orig;
}

- (void)pictureInPicturePlaybackPauseRequested {
    NSString *controllerVideoID =
        CIYTPiPControllerVideoID(self);
    NSTimeInterval uptime =
        NSProcessInfo.processInfo.systemUptime;
    BOOL controllerBelongsToLifecycle;
    @synchronized (CIPiPLifecycleControllers) {
        controllerBelongsToLifecycle =
            [CIPiPLifecycleControllers containsObject:self];
    }
    BOOL shouldSuppressLateDismissalPause =
        CIPiPLatePauseSuppressionGeneration ==
            CIPiPAudioLifecycleGeneration &&
        uptime <= CIPiPLatePauseSuppressionUntil &&
        (controllerBelongsToLifecycle ||
         self == CIPiPRecoveryController ||
         (controllerVideoID.length > 0 &&
          (CIPiPLatePauseSuppressionVideoID.length == 0 ||
           [controllerVideoID isEqualToString:
              CIPiPLatePauseSuppressionVideoID])));
    if (shouldSuppressLateDismissalPause) {
        CIPiPLatePauseSuppressionCount++;
        [CILogStore.sharedStore recordLevel:CILogLevelDebug
            category:@"Background"
            format:@"Discarded a late PiP teardown pause for video %@ without touching the stopped renderer graph.",
                   controllerVideoID];
        return;
    }
    YTPlayerPIPController *selectedController =
        CIPiPRecoveryController;
    BOOL shouldDefer =
        CIPiPStopCandidate &&
        CIYTPiPControllerMatchesCandidate(self);
    BOOL shouldSelect =
        shouldDefer &&
        (!selectedController ||
         (!CIYTPiPControllerOwnsActiveVideo(selectedController) &&
          CIYTPiPControllerOwnsActiveVideo(self)));
    if (shouldSelect) {
        CIPiPRecoveryController = self;
        [CILogStore.sharedStore recordLevel:CILogLevelDebug
            category:@"Background"
            format:@"Selected the PiP observer for video %@ as the background-audio recovery controller.",
                   controllerVideoID];
    }
    if (shouldDefer) {
        CIDeferPiPPauseRequest(self);
        [CILogStore.sharedStore recordLevel:CILogLevelDebug
            category:@"Background"
            format:@"Deferred PiP pause for video %@ until the close-versus-pause lifecycle is known.",
                   controllerVideoID];
        return;
    }
    %orig;
}

- (void)didStopPictureInPicture {
    YTPlayerPIPController *selectedController =
        CIPiPRecoveryController;
    BOOL controllerMatches =
        CIYTPiPControllerMatchesCandidate(self);
    BOOL controllerBelongsToLifecycle;
    @synchronized (CIPiPLifecycleControllers) {
        controllerBelongsToLifecycle =
            [CIPiPLifecycleControllers containsObject:self];
    }
    BOOL shouldConsumeLifecycle =
        (selectedController == self) ||
        (!selectedController &&
         (controllerMatches || controllerBelongsToLifecycle));
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
    NSUInteger deferredPauseCountBeforeStop;
    @synchronized (CIPiPDeferredPauseControllers) {
        deferredPauseCountBeforeStop =
            CIPiPDeferredPauseControllers.allObjects.count;
    }
    NSString *expectedVideoID =
        CIPiPStopCandidateVideoID.length > 0
            ? [CIPiPStopCandidateVideoID copy]
            : [CIYTPiPControllerVideoID(self) copy];
    BOOL shouldSuppressLatePause =
        !restoreWasRequested &&
        (candidateIsCurrent ||
         deferredPauseCountBeforeStop > 0);
    if (shouldSuppressLatePause) {
        CIPiPLatePauseSuppressionGeneration =
            CIPiPAudioLifecycleGeneration;
        CIPiPLatePauseSuppressionUntil =
            NSProcessInfo.processInfo.systemUptime +
            CIPiPLatePauseSuppressionInterval;
        CIPiPLatePauseSuppressionVideoID =
            expectedVideoID;
    }
    CIPictureInPicturePreparationGeneration++;
    NSUInteger lifecycleGeneration =
        CIPiPAudioLifecycleGeneration;
    NSUInteger playbackGeneration =
        CIPlaybackLifecycleGeneration;
    __weak YTPlayerViewController *verificationController =
        CIActivePlayerController;
    NSTimeInterval positionBeforeVerification =
        verificationController.currentVideoMediaTime;
    __block UIBackgroundTaskIdentifier
        verificationBackgroundTask =
            UIBackgroundTaskInvalid;
    void (^finishVerificationBackgroundTask)(void) = ^{
        if (verificationBackgroundTask ==
            UIBackgroundTaskInvalid) return;
        UIBackgroundTaskIdentifier task =
            verificationBackgroundTask;
        verificationBackgroundTask =
            UIBackgroundTaskInvalid;
        [UIApplication.sharedApplication
            endBackgroundTask:task];
    };
    if (!restoreWasRequested &&
        applicationRemainsBackgrounded) {
        verificationBackgroundTask =
            [UIApplication.sharedApplication
                beginBackgroundTaskWithName:
                    @"CaptionIsland.PiPClockVerification"
                expirationHandler:^{
                    [CILogStore.sharedStore
                        recordLevel:CILogLevelWarning
                        category:@"Background"
                        message:@"PiP clock verification background time expired before the relay correction finished."];
                    finishVerificationBackgroundTask();
                }];
    }

    // Keep the candidate alive across YouTube's didStop implementation:
    // some versions emit their playback-pause callback from inside teardown.
    %orig;

    NSUInteger deferredPauseCount;
    @synchronized (CIPiPDeferredPauseControllers) {
        deferredPauseCount =
            CIPiPDeferredPauseControllers.allObjects.count;
    }
    NSUInteger suppressedPauseCount =
        deferredPauseCount +
        CIPiPLatePauseSuppressionCount;
    BOOL suppressedPlayingDismissalPause =
        !restoreWasRequested &&
        suppressedPauseCount > 0 &&
        (candidateIsCurrent || applicationRemainsBackgrounded);
    NSString *classification = restoreWasRequested
        ? @"restore"
        : (suppressedPlayingDismissalPause
            ? @"non-restore dismissal with pause suppression"
            : @"non-restore dismissal without a deferred pause");
    [CILogStore.sharedStore recordLevel:CILogLevelDebug
        category:@"Background"
        format:@"PiP did stop: %@ (candidate %d, confirmed %d, suppressed pauses %lu, candidate age %.2fs, will-stop age %.2fs, app state %ld).",
               classification, CIPiPStopCandidate,
               CIPiPStopCandidateConfirmedByWillStop,
               (unsigned long)suppressedPauseCount,
               candidateAge, willStopAge,
               (long)UIApplication.sharedApplication.applicationState];

    CIClearPiPStopCandidate();
    CIPiPSystemController = nil;
    CIPiPWillStopUptime = 0;
    CIPiPRestoreRequested = NO;
    CIPiPPlaybackPauseStateKnown = NO;
    CIPiPPlaybackPaused = NO;

    if (!restoreWasRequested) {
        [CIBackgroundPlaybackMonitor.sharedMonitor
            finishPictureInPicture];
    }
    if (suppressedPlayingDismissalPause) {
        if (expectedVideoID.length > 0 &&
            isfinite(positionBeforeVerification) &&
            positionBeforeVerification >= 0) {
            [CICaptionCoordinator.sharedCoordinator
                synchronizePlaybackAtPosition:
                    positionBeforeVerification
                                      playing:YES
                                         rate:
                                             CIRemotePlaybackRate
                                        force:YES];
        }
        [CICaptionCoordinator.sharedCoordinator
            prepareForExternalPlayback];
        [CILogStore.sharedStore recordLevel:CILogLevelInfo
            category:@"Background"
            format:@"Suppressed %lu PiP teardown pause callback(s) for video %@; no command was sent to the torn-down player graph.",
                   (unsigned long)suppressedPauseCount,
                   expectedVideoID];
        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(
                    CIPiPReadOnlyVerificationDelay *
                    NSEC_PER_SEC
                )
            ),
            dispatch_get_main_queue(),
            ^{
                if (lifecycleGeneration !=
                        CIPiPAudioLifecycleGeneration ||
                    playbackGeneration !=
                        CIPlaybackLifecycleGeneration ||
                    UIApplication.sharedApplication.applicationState !=
                        UIApplicationStateBackground ||
                    expectedVideoID.length == 0) {
                    finishVerificationBackgroundTask();
                    return;
                }
                YTPlayerViewController *controller =
                    verificationController;
                NSString *currentVideoID =
                    CIPlayerVideoID(controller);
                NSTimeInterval positionAfterVerification =
                    controller.currentVideoMediaTime;
                BOOL sameVideo =
                    controller &&
                    [currentVideoID isEqualToString:
                        expectedVideoID];
                BOOL clockAdvanced =
                    sameVideo &&
                    isfinite(positionBeforeVerification) &&
                    isfinite(positionAfterVerification) &&
                    positionAfterVerification >
                        positionBeforeVerification + 0.04;
                NSTimeInterval verifiedPosition =
                    sameVideo &&
                    isfinite(positionAfterVerification) &&
                    positionAfterVerification >= 0
                        ? positionAfterVerification
                        : positionBeforeVerification;
                if (!isfinite(verifiedPosition) ||
                    verifiedPosition < 0) {
                    [CILogStore.sharedStore
                        recordLevel:CILogLevelWarning
                        category:@"Background"
                        format:@"PiP clock verification for video %@ had no valid playback position; the existing remote schedule was left unchanged.",
                               expectedVideoID];
                    finishVerificationBackgroundTask();
                    return;
                }
                [CICaptionCoordinator.sharedCoordinator
                    synchronizeRemotePlaybackCriticalAtPosition:
                        verifiedPosition
                                                    playing:
                                                        clockAdvanced
                                                       rate:
                                                           CIRemotePlaybackRate
                                            expectedVideoID:
                                                expectedVideoID
                                                 completion:
                    ^(BOOL attempted) {
                        CILogLevel level =
                            attempted
                                ? (clockAdvanced
                                    ? CILogLevelInfo
                                    : CILogLevelWarning)
                                : CILogLevelWarning;
                        [CILogStore.sharedStore
                            recordLevel:level
                            category:@"Background"
                            format:attempted
                                ? (clockAdvanced
                                    ? @"Verified playback clock continuity for video %@ after PiP dismissal (%.1fs → %.1fs); the playing relay snapshot was flushed."
                                    : @"PiP teardown pause was suppressed for video %@, but the playback clock did not advance (%.1fs → %.1fs). A paused relay snapshot was flushed; no player restart was attempted.")
                                : @"PiP clock state for video %@ was resolved (%.1fs → %.1fs), but no token-enabled relay snapshot was available to flush.",
                                   expectedVideoID,
                                   positionBeforeVerification,
                                   positionAfterVerification];
                        finishVerificationBackgroundTask();
                    }];
            }
        );
    } else if (!restoreWasRequested &&
               applicationRemainsBackgrounded) {
        finishVerificationBackgroundTask();
        [CILogStore.sharedStore recordLevel:CILogLevelDebug
            category:@"Background"
            format:@"PiP stopped in the background without a playing-state pause candidate (candidate age %.2fs); playback was left unchanged.",
                   candidateAge];
    } else {
        finishVerificationBackgroundTask();
    }
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


%group CaptionIslandPlayerPlayHooks

%hook YTPlayerViewController

- (void)play {
    %orig;
    CISynchronizeRemotePlayback(
        self,
        YES,
        CIRemotePlaybackRate,
        YES
    );
}

%end

%end


%group CaptionIslandPlayerPauseHooks

%hook YTPlayerViewController

- (void)pause {
    %orig;
    BOOL PiPIsActive =
        CIPiPSystemController &&
        CIPiPSystemController.pictureInPictureActive;
    if (!PiPIsActive && !CIPiPStopCandidate) {
        CISynchronizeRemotePlayback(
            self,
            NO,
            CIRemotePlaybackRate,
            YES
        );
    }
}

%end

%end


%group CaptionIslandPlayerSeekHooks

%hook YTPlayerViewController

- (void)seekToTime:(CGFloat)time {
    %orig;
    if (![objc_getAssociatedObject(
            self,
            CIActivePlayerKey
        ) boolValue]) return;
    [CICaptionCoordinator.sharedCoordinator
        synchronizePlaybackAtPosition:
            MAX(0, (NSTimeInterval)time)
                              playing:
            CIRemotePlaybackPlaying
                                 rate:
            CIRemotePlaybackRate
                                force:YES];
}

%end

%end


%group CaptionIslandPlayerRateHooks

%hook YTPlayerViewController

- (void)varispeedSwitchController:(id)controller
                    didSelectRate:(float)rate {
    %orig;
    CISynchronizeRemotePlayback(
        self,
        CIRemotePlaybackPlaying,
        rate,
        YES
    );
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
    CIPiPDeferredPauseControllers =
        [NSHashTable weakObjectsHashTable];
    CIPiPLifecycleControllers =
        [NSHashTable weakObjectsHashTable];
    %init(CaptionIslandActivationHooks);
    Class shortsPlayerClass =
        NSClassFromString(@"YTShortsPlayerViewController");
    if (shortsPlayerClass &&
        class_getInstanceMethod(
            shortsPlayerClass,
            @selector(setPlayer:)
        )) {
        %init(CaptionIslandShortsPlayerSetterHooks);
    }
    if (shortsPlayerClass &&
        class_getInstanceMethod(
            shortsPlayerClass,
            @selector(viewDidAppear:)
        )) {
        %init(CaptionIslandShortsLifecycleHooks);
    }
    if (class_getInstanceMethod(
            playerClass,
            @selector(play)
        )) {
        %init(CaptionIslandPlayerPlayHooks);
    }
    if (class_getInstanceMethod(
            playerClass,
            @selector(pause)
        )) {
        %init(CaptionIslandPlayerPauseHooks);
    }
    if (class_getInstanceMethod(
            playerClass,
            @selector(seekToTime:)
        )) {
        %init(CaptionIslandPlayerSeekHooks);
    }
    if (class_getInstanceMethod(
            playerClass,
            @selector(
                varispeedSwitchController:
                didSelectRate:
            )
        )) {
        %init(CaptionIslandPlayerRateHooks);
    }
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
        );
    if (hasMLPiPAudioLifecycle && hasMLPiPRestore &&
        hasYTPiPAudioRecovery) {
        CIPiPOriginalPauseRequestedImplementation =
            class_getMethodImplementation(
                YTPiPClass,
                @selector(
                    pictureInPicturePlaybackPauseRequested
                )
            );
        %init(CaptionIslandYTPiPAudioRecoveryHooks);
    }
    if (hasMLPiPAudioLifecycle && hasMLPiPRestore &&
        hasYTPiPAudioRecovery) {
        [CILogStore.sharedStore recordLevel:CILogLevelDebug
            category:@"Background"
            message:@"PiP dismissal protection is ready with deferred pause classification and stale-renderer lease release."];
    } else {
        [CILogStore.sharedStore recordLevel:CILogLevelWarning
            category:@"Background"
            format:@"PiP background-audio recovery is unavailable for this YouTube version (ML lifecycle %d, restore detection %d, YouTube pause observer %d).",
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
