#import "CICaptionTiming.h"
#import <math.h>

NSTimeInterval CIAdjustedCaptionLookupTime(
    NSTimeInterval playbackTime,
    NSTimeInterval advance
) {
    if (!isfinite(playbackTime)) return 0;
    if (!isfinite(advance)) advance = 0;
    // A negative result is intentional: it keeps a cue that begins at media
    // time zero hidden until a negative advance (delay) has elapsed.
    return playbackTime + advance;
}

NSTimeInterval CIAdjustedCaptionBoundary(
    NSTimeInterval mediaBoundary,
    NSTimeInterval advance
) {
    if (!isfinite(mediaBoundary)) return 0;
    if (!isfinite(advance)) advance = 0;
    return MAX(0, mediaBoundary - advance);
}
