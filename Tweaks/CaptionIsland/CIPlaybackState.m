#import "CIPlaybackState.h"
#import <YouTubeHeader/YTPlayerViewController.h>
#import <YouTubeHeader/YTSingleVideo.h>
#import <YouTubeHeader/YTSingleVideoController.h>

BOOL CIPlayerControllerIsAdvertising(YTPlayerViewController *controller) {
    if (!controller) return NO;
    if (controller.isPlayingAd) return YES;

    YTSingleVideoController *activeVideo = controller.activeVideo;
    YTSingleVideo *singleVideo = activeVideo.singleVideo;
    if (![singleVideo respondsToSelector:@selector(videoType)]) return NO;
    YTSingleVideoType type = singleVideo.videoType;
    return type == YTSingleVideoTypeAdInterrupt ||
        type == YTSingleVideoTypeContentInterstitial;
}
