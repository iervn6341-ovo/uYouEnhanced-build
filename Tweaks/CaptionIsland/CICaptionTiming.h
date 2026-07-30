#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Positive advance values make a caption appear earlier.
FOUNDATION_EXPORT NSTimeInterval CIAdjustedCaptionLookupTime(
    NSTimeInterval playbackTime,
    NSTimeInterval advance
);

FOUNDATION_EXPORT NSTimeInterval CIAdjustedCaptionBoundary(
    NSTimeInterval mediaBoundary,
    NSTimeInterval advance
);

NS_ASSUME_NONNULL_END
