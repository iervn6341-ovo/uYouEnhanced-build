#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CIVideoOverride : NSObject
@property (nonatomic, copy, readonly) NSString *searchTitle;
@property (nonatomic, copy, readonly) NSString *searchArtist;
/// Positive values display captions earlier; negative values display them later.
@property (nonatomic, readonly) NSTimeInterval captionAdvanceSeconds;
@property (nonatomic, copy, readonly) NSString *originalTitle;
@property (nonatomic, readonly) NSTimeInterval updatedAt;
@end

FOUNDATION_EXPORT CIVideoOverride * _Nullable
CIVideoOverrideForVideoID(NSString * _Nullable videoID);

FOUNDATION_EXPORT void CISaveVideoOverride(
    NSString * _Nullable videoID,
    NSString * _Nullable searchTitle,
    NSString * _Nullable searchArtist,
    NSTimeInterval captionAdvanceSeconds,
    NSString * _Nullable originalTitle
);

FOUNDATION_EXPORT void CIClearVideoOverride(
    NSString * _Nullable videoID
);

FOUNDATION_EXPORT NSUInteger CIVideoOverrideCount(void);

NS_ASSUME_NONNULL_END
