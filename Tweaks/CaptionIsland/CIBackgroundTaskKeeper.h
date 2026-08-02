#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Holds a plain `UIApplication` background task for as long as YouTube is
/// backgrounded, purely to add a second RunningBoard assertion to the process.
///
/// `liveactivitiesd` refuses local Live Activity writes only while the process
/// is holding *nothing but* `com.apple.mediaexperience:MediaPlayback`. Log
/// evidence shows captions flow normally whenever any second assertion happens
/// to be present — the launch-time `pagein-prefetching:LaunchPrefetch` grant,
/// or `mediaremote:Command` while the user works the lock-screen controls.
///
/// Whether a `beginBackgroundTask` assertion also satisfies that test is
/// unverified: YouTube's own background tasks did not appear in the sampled
/// assertion lists. This class exists to answer that question with the
/// eligibility diagnostic rather than by assumption, so it logs every
/// acquisition, renewal and expiry.
@interface CIBackgroundTaskKeeper : NSObject

+ (instancetype)sharedKeeper;

/// Starts observing app lifecycle notifications. Safe to call more than once.
- (void)activate;

@end

NS_ASSUME_NONNULL_END
