#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Records why the system currently believes this process is allowed to keep
/// running in the background.
///
/// `liveactivitiesd` refuses local Live Activity writes with "Process is only
/// playing background media", so the useful signal is which background
/// endowments the process holds *besides* media playback. This snapshot pairs
/// the public background-time allowance with RunningBoard's own view of the
/// process so a working background cycle can be diffed against a refused one.
///
/// Safe to call from any thread; the work hops to the main thread because
/// `UIApplication` state must be read there.
FOUNDATION_EXPORT void CILogProcessBackgroundEligibility(NSString *reason);

NS_ASSUME_NONNULL_END
