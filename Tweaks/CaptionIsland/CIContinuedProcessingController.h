#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns YES only when the public iOS 26 continued-processing classes and
/// selectors needed by Caption Island are available at runtime.
FOUNDATION_EXPORT BOOL CIContinuedBackgroundProcessingSupported(void);

/// Owns one finite, user-visible background caption task for the active video.
/// The implementation intentionally resolves iOS 26 symbols at runtime so the
/// tweak can keep its iOS 17.5 deployment target and SDK compatibility.
@interface CIContinuedProcessingController : NSObject

+ (instancetype)sharedController;

@property (nonatomic, readonly, getter=isTaskActive) BOOL taskActive;

- (void)beginForVideoID:(NSString *)videoID
                  title:(NSString *)title
               duration:(NSTimeInterval)duration
                 shorts:(BOOL)isShorts;
- (void)updatePlaybackTime:(NSTimeInterval)playbackTime
                  duration:(NSTimeInterval)duration
                   playing:(BOOL)playing;
- (void)updateCaptionLine:(NSString *)line
                 nextLine:(NSString *)nextLine;
- (void)setPlaybackSuppressed:(BOOL)suppressed;
- (void)finishVideoWillTransition:(BOOL)willTransition;
- (void)endWithReason:(NSString *)reason success:(BOOL)success;

@end

NS_ASSUME_NONNULL_END
