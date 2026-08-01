#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns YES only when the public iOS 26 continued-processing classes and
/// selectors needed by Caption Island are available at runtime.
FOUNDATION_EXPORT BOOL CIContinuedBackgroundProcessingSupported(void);

/// Posted on the main thread whenever iOS grants or revokes the actual
/// continued-processing runtime. A submitted request that has not invoked its
/// launch handler does not count as granted.
FOUNDATION_EXPORT NSNotificationName const
    CIContinuedProcessingRuntimeDidChangeNotification;

/// Owns one finite, user-visible background caption task generation for each
/// foreground/background playback cycle. A generation is authorized only
/// after its matching launch handler runs; retaining an older task object is
/// never treated as a valid runtime lease. The implementation intentionally
/// resolves iOS 26 symbols at runtime so the tweak can keep its iOS 17.5
/// deployment target and SDK compatibility.
@interface CIContinuedProcessingController : NSObject

+ (instancetype)sharedController;

/// YES only after BGTaskScheduler has invoked the launch handler for the
/// current generation. This state alone does not authorize an older background
/// cycle.
@property (nonatomic, readonly, getter=isTaskActive) BOOL taskActive;

/// YES after immediate submission succeeds but before its launch handler has
/// supplied the runtime lease.
@property (nonatomic, readonly, getter=isTaskPending) BOOL taskPending;

/// Returns NO only for the iOS 26 experimental path when the app is in the
/// background without a granted continued-processing runtime lease.
@property (nonatomic, readonly) BOOL localActivityUpdatesPermitted;

/// Marks the transition before the presenter publishes its first background
/// revision. The UIApplication notification path also calls this idempotently.
- (void)prepareForApplicationBackground;

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
