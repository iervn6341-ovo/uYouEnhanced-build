#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Experimental: keeps a `com.apple.mediaexperience:MediaPlayback`-only process
/// eligible for local Live Activity writes by periodically asking mediaremoted
/// to deliver a redundant Play command.
///
/// Log analysis established that `liveactivitiesd` refuses caption updates only
/// while the process holds nothing but the media-playback assertion, and that
/// working the lock-screen transport controls fixes it by adding
/// `com.apple.mediaremote:Command`. This class tries to reproduce that
/// assertion without the user touching anything.
///
/// This is deliberately opt-in and defaults to off. It uses a private
/// MediaRemote entry point and sends a real transport command, so the blast
/// radius is playback itself: the command is only ever Play, only sent while
/// playback is already running, and never while the app is foregrounded. It is
/// a probe for a specific hypothesis, not a supported mechanism.
@interface CIMediaRemoteNudge : NSObject

+ (instancetype)sharedNudge;

/// Begins observing app lifecycle. Safe to call repeatedly.
- (void)activate;

/// Tracks whether playback is currently running, so a Play command is only
/// ever sent when it would be redundant rather than resuming paused audio.
- (void)setPlaybackPlaying:(BOOL)playing;

@end

NS_ASSUME_NONNULL_END
