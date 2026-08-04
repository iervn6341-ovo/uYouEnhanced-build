#pragma once

#import <Foundation/Foundation.h>

@class YTPlayerViewController;

NS_ASSUME_NONNULL_BEGIN

/// Supplies a low-frequency playback clock while YouTube is executing in the
/// background (for example, while background audio is playing on the Lock
/// Screen). Foreground playback continues to use YouTube's native callbacks.
@interface CIBackgroundPlaybackMonitor : NSObject

+ (instancetype)sharedMonitor;

@property (nonatomic, readonly, getter=isSamplingPlaybackInBackground)
    BOOL samplingPlaybackInBackground;

- (void)attachPlayerController:(YTPlayerViewController *)controller;
- (void)detachPlayerController:(YTPlayerViewController *)controller;
- (void)prepareForPictureInPictureWithPlayerController:
    (YTPlayerViewController *)controller;
- (void)finishPictureInPicture;
- (void)observeNativePlaybackTime:(NSTimeInterval)playbackTime
                 playerController:(YTPlayerViewController *)controller;
- (void)observePlaybackRate:(double)playbackRate
               playbackTime:(NSTimeInterval)playbackTime
            playerController:(YTPlayerViewController *)controller;
- (BOOL)playbackAdvancedWithinInterval:(NSTimeInterval)interval;

/// Caches the current caption in every app state and mirrors it into YouTube's
/// existing Now Playing metadata only while the app is backgrounded and the
/// experiment is enabled. Calls are marshalled to the main thread internally.
- (void)updateNowPlayingCaptionLine:(NSString *)line
                           nextLine:(NSString *)nextLine
                            videoID:(NSString *)videoID
                         videoTitle:(NSString *)videoTitle;

/// Re-evaluates the preference immediately. Disabling the experiment restores
/// only the metadata fields that Caption Island still owns.
- (void)reloadNowPlayingLyricsPreference;

/// Clears cached caption text and restores YouTube's original visible metadata.
- (void)clearNowPlayingCaptionWithReason:(NSString *)reason;

@end

NS_ASSUME_NONNULL_END
