#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CIVideoCaptionSourcePreference) {
    /// Follow the global LRCLIB-first or YouTube-first setting.
    CIVideoCaptionSourcePreferenceInherit = 0,
    /// Try the selected video's manual YouTube caption track before LRCLIB.
    CIVideoCaptionSourcePreferenceManualCC,
    /// Try the selected video's automatic YouTube caption track before LRCLIB.
    CIVideoCaptionSourcePreferenceASR,
};

@interface CIVideoOverride : NSObject
@property (nonatomic, copy, readonly) NSString *searchTitle;
@property (nonatomic, copy, readonly) NSString *searchArtist;
/// Empty means this video inherits the global caption-language priority.
@property (nonatomic, copy, readonly)
    NSArray<NSString *> *captionLanguagePriorities;
/// A selection made in the player panel overrides the global source order for
/// this video. The language list above identifies the requested track language.
@property (nonatomic, readonly)
    CIVideoCaptionSourcePreference captionSourcePreference;
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

/// Saves the exact YouTube caption choice made in the player panel. Passing
/// `Inherit` with an empty language list restores the global source and language
/// order for this video.
FOUNDATION_EXPORT void CISaveVideoCaptionSelection(
    NSString * _Nullable videoID,
    NSArray<NSString *> * _Nullable priorities,
    CIVideoCaptionSourcePreference sourcePreference,
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
