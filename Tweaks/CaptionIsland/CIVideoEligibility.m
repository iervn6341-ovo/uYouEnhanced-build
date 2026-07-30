#import "CIVideoEligibility.h"
#import <math.h>

CIVideoExclusionReason CIVideoExclusionReasonForPlayback(
    BOOL isShorts,
    BOOL disableForShorts,
    NSTimeInterval duration,
    NSInteger maximumDurationMinutes
) {
    if (disableForShorts && isShorts) {
        return CIVideoExclusionReasonShorts;
    }
    if (maximumDurationMinutes <= 0 || !isfinite(duration) || duration <= 0) {
        return CIVideoExclusionReasonNone;
    }
    NSTimeInterval maximumDuration =
        (NSTimeInterval)maximumDurationMinutes * 60.0;
    return duration > maximumDuration
        ? CIVideoExclusionReasonDuration
        : CIVideoExclusionReasonNone;
}
