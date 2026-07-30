#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CIVideoExclusionReason) {
    CIVideoExclusionReasonNone,
    CIVideoExclusionReasonShorts,
    CIVideoExclusionReasonDuration,
};

FOUNDATION_EXPORT CIVideoExclusionReason CIVideoExclusionReasonForPlayback(
    BOOL isShorts,
    BOOL disableForShorts,
    NSTimeInterval duration,
    NSInteger maximumDurationMinutes
);

NS_ASSUME_NONNULL_END
