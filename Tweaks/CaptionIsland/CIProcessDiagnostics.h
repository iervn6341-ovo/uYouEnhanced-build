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

/// Retains the LaunchPrefetch assertion created by Apple's app-launch
/// measurement library, so it survives the app's first return to the foreground.
///
/// This is core behaviour with no preference behind it: `liveactivitiesd` refuses
/// every local Live Activity write once that assertion is gone, which means
/// background captions would otherwise die for the rest of the app session the
/// first time the user reopens YouTube. Call this as early as possible during
/// tweak initialization so the hooks exist before the launch-measurement client
/// invalidates its assertion.
FOUNDATION_EXPORT void CIInstallLaunchPrefetchRetentionProbe(void);

/// Re-arms retention. Idempotent, reads no preference, and can only ensure the
/// interception points are live — it never tears them down.
FOUNDATION_EXPORT void CIReloadLaunchPrefetchRetentionProbe(void);

/// Releases retained assertions for a terminal process lifecycle event.
FOUNDATION_EXPORT void CIReleaseRetainedLaunchPrefetchAssertions(
    NSString *reason
);

NS_ASSUME_NONNULL_END
