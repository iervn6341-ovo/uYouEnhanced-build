#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *CICleanCaptionText(NSString * _Nullable text);
FOUNDATION_EXPORT NSString *CINormalizedText(NSString * _Nullable text);
FOUNDATION_EXPORT NSArray<NSString *> *CINonEmptyLines(NSString * _Nullable text);
FOUNDATION_EXPORT double CITextSimilarity(NSString *lhs, NSString *rhs);
FOUNDATION_EXPORT NSString *CISongTitleFromVideoTitle(NSString * _Nullable videoTitle);
FOUNDATION_EXPORT void CISplitSongMetadata(NSString * _Nullable videoTitle,
                                          NSString * _Nullable videoAuthor,
                                          NSString * _Nullable __autoreleasing * _Nullable songTitle,
                                          NSString * _Nullable __autoreleasing * _Nullable artist);

/// One plausible reading of an upload title, expressed as an LRCLIB query.
@interface CISongQuery : NSObject
/// The track name to search for. Never empty.
@property (nonatomic, copy, readonly) NSString *title;
/// The artist to carry into candidate ranking, or an empty string when this
/// reading has no side worth using as a signal.
@property (nonatomic, copy, readonly) NSString *artist;
/// Which rule produced this reading. Diagnostics only; never user-facing.
@property (nonatomic, copy, readonly) NSString *origin;

+ (instancetype)queryWithTitle:(NSString *)title
                        artist:(NSString *)artist
                        origin:(NSString *)origin;
@end

/// The most readings of one upload title that are ever offered to LRCLIB.
///
/// Each reading past the first costs a rate-limited request, so the ceiling
/// bounds how long a lookup can take before the YouTube caption fallback runs.
FOUNDATION_EXPORT const NSUInteger CISongQueryMaximumCandidates;

/// Every plausible reading of an upload title, most likely first.
///
/// An upload title has no grammar, so a single parse has to guess which run of
/// characters is the song. This returns the guesses instead, letting the lookup
/// search them and use the track length to decide which guess was right. The
/// first element always equals what CISplitSongMetadata committed to, so any
/// title that already resolves correctly still resolves on the first request.
FOUNDATION_EXPORT NSArray<CISongQuery *> *CISongQueryCandidates(
    NSString * _Nullable videoTitle,
    NSString * _Nullable videoAuthor
);

NS_ASSUME_NONNULL_END
