#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CIVideoOverride : NSObject
@property (nonatomic, copy, readonly) NSString *searchTitle;
@property (nonatomic, copy, readonly) NSString *searchArtist;
/// Empty means this video inherits the global caption-language priority.
@property (nonatomic, copy, readonly)
    NSArray<NSString *> *captionLanguagePriorities;
/// Positive values display captions earlier; negative values display them later.
@property (nonatomic, readonly) NSTimeInterval captionAdvanceSeconds;
/// YES when the user inspected this video's LRCLIB matches and rejected all of
/// them. Unlike a cached miss this never expires: it records a decision, not the
/// outcome of a lookup, so the lookup is skipped entirely.
@property (nonatomic, readonly) BOOL lyricsSuppressed;
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

FOUNDATION_EXPORT void CISaveVideoCaptionLanguagePriorities(
    NSString * _Nullable videoID,
    NSArray<NSString *> * _Nullable priorities,
    NSString * _Nullable originalTitle
);

/// Records that this video should never be given LRCLIB lyrics, or lifts that.
FOUNDATION_EXPORT void CISaveVideoLyricsSuppressed(
    NSString * _Nullable videoID,
    BOOL suppressed,
    NSString * _Nullable originalTitle
);

FOUNDATION_EXPORT void CIClearVideoOverride(
    NSString * _Nullable videoID
);

FOUNDATION_EXPORT NSUInteger CIVideoOverrideCount(void);

NS_ASSUME_NONNULL_END
