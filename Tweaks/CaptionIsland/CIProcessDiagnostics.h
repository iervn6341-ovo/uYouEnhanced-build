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

/// Installs a process-local experiment that can retain the LaunchPrefetch
/// assertion created by Apple's app-launch measurement library. Installation
/// is inert unless `CILaunchPrefetchRetentionProbeEnabledKey` is enabled.
/// Call this as early as possible during tweak initialization so the probe is
/// present before the launch-measurement client invalidates its assertion.
FOUNDATION_EXPORT void CIInstallLaunchPrefetchRetentionProbe(void);

/// Re-reads the experiment preference. Turning the experiment off immediately
/// invalidates every assertion the probe retained through the original RBS
/// implementation.
FOUNDATION_EXPORT void CIReloadLaunchPrefetchRetentionProbe(void);

/// Releases retained assertions for a terminal process lifecycle event.
FOUNDATION_EXPORT void CIReleaseRetainedLaunchPrefetchAssertions(
    NSString *reason
);

NS_ASSUME_NONNULL_END
