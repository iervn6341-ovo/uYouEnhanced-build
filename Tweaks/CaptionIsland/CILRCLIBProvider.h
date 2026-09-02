#import <Foundation/Foundation.h>
#import "CIModels.h"
#import "CITextUtilities.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const CILRCLIBBaseURLKey;
FOUNDATION_EXPORT NSString *CILRCLIBDefaultBaseURL(void);
FOUNDATION_EXPORT NSString *CILRCLIBBaseURL(void);
FOUNDATION_EXPORT NSString * _Nullable CINormalizedLRCLIBBaseURL(
    NSString * _Nullable value,
    NSError * _Nullable * _Nullable error
);
FOUNDATION_EXPORT NSURL *CILRCLIBSearchEndpointURL(void);
FOUNDATION_EXPORT NSURL *CILRCLIBGetEndpointURL(void);

@interface CILRCLIBResult : NSObject
@property (nonatomic) NSInteger recordID;
@property (nonatomic, copy) NSString *trackName;
@property (nonatomic, copy) NSString *artistName;
@property (nonatomic, copy) NSString *albumName;
@property (nonatomic) NSTimeInterval trackDuration;
@property (nonatomic) NSTimeInterval durationDifference;
@property (nonatomic, copy) NSArray<CICaptionCue *> *syncedCues;
@property (nonatomic, copy) NSString *plainLyrics;
@property (nonatomic) BOOL fromPersistentCache;
@end

typedef void (^CILRCLIBCompletion)(CILRCLIBResult * _Nullable result,
                                   NSError * _Nullable error);

/// A snapshot of what the on-disk LRCLIB cache currently holds.
@interface CILRCLIBCacheSummary : NSObject
/// Unexpired entries that carry usable lyrics.
@property (nonatomic) NSUInteger lyricCount;
/// Unexpired "this track has no lyrics" entries, which suppress repeat lookups.
@property (nonatomic) NSUInteger missCount;
/// Size of the cache file on disk.
@property (nonatomic) unsigned long long byteCount;
@end

/// One cached song, as shown in the saved-lyrics browser.
@interface CILRCLIBCacheEntry : NSObject
/// Opaque cache identity, used to delete this specific entry.
@property (nonatomic, copy) NSString *cacheKey;
@property (nonatomic, copy) NSString *trackName;
@property (nonatomic, copy) NSString *artistName;
@property (nonatomic, copy) NSString *albumName;
@property (nonatomic) NSTimeInterval trackDuration;
@property (nonatomic) NSUInteger lineCount;
@property (nonatomic) BOOL hasSyncedTimeline;
/// Seconds since 1970 when this entry was saved.
@property (nonatomic) NSTimeInterval storedAt;
/// The lyrics as displayable text, timestamped when a timeline exists.
@property (nonatomic, copy) NSString *lyricsText;
/// Lowercased track, artist and album, joined for substring searching.
@property (nonatomic, copy) NSString *searchIndex;
@end

@interface CILRCLIBProvider : NSObject
+ (void)clearPersistentCache;

/// Every cached song, ordered by track name. Misses are excluded: they hold no
/// lyrics to inspect and are only an internal optimisation.
+ (NSArray<CILRCLIBCacheEntry *> *)cachedLyricEntries;

/// Deletes the given entries and returns how many were actually removed.
+ (NSUInteger)removeCachedEntriesWithKeys:(NSArray<NSString *> *)keys;

/// Counts what is currently cached, ignoring entries that have already expired.
+ (CILRCLIBCacheSummary *)cacheSummary;

/// Writes the cached lyrics to a shareable file and returns its location, or nil
/// with `error` set. Misses and expired entries are left out: they are
/// short-lived and worthless to carry to another device.
+ (nullable NSURL *)exportCacheWithError:(NSError * _Nullable * _Nullable)error;

/// Merges an exported file into the cache and returns how many entries were
/// added. The file is untrusted input, so every entry is re-validated and
/// anything malformed is skipped rather than failing the whole import.
+ (NSUInteger)importCacheFromURL:(NSURL *)URL
                           error:(NSError * _Nullable * _Nullable)error;

/// Looks up one committed reading of a title. Use this only when the query is
/// known rather than guessed — a user-supplied override, or a test.
- (void)fetchLyricsForTitle:(NSString *)title
                     artist:(NSString *)artist
                   duration:(NSTimeInterval)duration
                 completion:(CILRCLIBCompletion)completion;

/// Looks up several readings of one upload title and returns the best match.
///
/// Readings are searched in order and each one is rate limited like any other
/// request, so this cannot fan out into a burst. The search stops early as soon
/// as a reading produces a synced timeline whose length all but matches the
/// video, which is the common case and costs a single request; otherwise every
/// reading is tried and the match closest to the video length wins.
/// Every reading uses LRCLIB's `q=` search across track, artist and album fields;
/// inferred artist metadata remains a local ranking signal rather than an API
/// filter. If `q=` returns no rows, that same reading is retried once with
/// `track_name=` before the lookup advances.
- (void)fetchLyricsForCandidates:(NSArray<CISongQuery *> *)candidates
                        duration:(NSTimeInterval)duration
                      completion:(CILRCLIBCompletion)completion;

/// Searches every reading and returns everything LRCLIB holds, for the user to
/// choose from by hand.
///
/// This differs from the automatic lookup in three deliberate ways, all of them
/// because a person is about to read the list rather than a scorer:
///
/// * **No early exit.** Every reading is searched even after a good match, so the
///   list is complete. That costs one rate-limited request per reading, which is
///   acceptable for an action the user explicitly asked for and would not be for
///   playback.
/// * **Displayed artist is searchable.** A selected `title — artist` reading is
///   sent to `q=` as `title artist`; the display dash never enters the query.
/// * **Permissive filtering.** The title-similarity and duration gates that the
///   automatic path uses are dropped. Those gates are exactly what rejected
///   everything when the automatic lookup came back empty, so applying them here
///   would show an empty list precisely when the feature is needed.
/// * **Nothing is cached.** A browse must not teach the automatic path anything;
///   only an explicit `pinResult:` does that.
///
/// Results are de-duplicated by record id across readings and ordered by how
/// close their length is to the video.
- (void)fetchAllMatchesForCandidates:(NSArray<CISongQuery *> *)candidates
                            duration:(NSTimeInterval)duration
                          completion:
    (void (^)(NSArray<CILRCLIBResult *> *matches,
              NSError * _Nullable error))completion;

/// Makes `result` the answer the automatic lookup will give for this video.
///
/// Written under the same cache key `fetchLyricsForCandidates:` derives from the
/// first reading, so the ordinary playback path finds it as a cache hit and needs
/// no separate "user picked this" branch. Lyric cache entries never expire, so the
/// choice survives until the user clears the cache or picks again.
- (void)pinResult:(CILRCLIBResult *)result
    forCandidates:(NSArray<CISongQuery *> *)candidates
         duration:(NSTimeInterval)duration;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
