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
- (void)observeNativePlaybackTime:(NSTimeInterval)playbackTime
                 playerController:(YTPlayerViewController *)controller;

@end

NS_ASSUME_NONNULL_END
