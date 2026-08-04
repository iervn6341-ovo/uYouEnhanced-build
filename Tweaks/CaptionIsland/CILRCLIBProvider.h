#import <Foundation/Foundation.h>
#import "CIModels.h"

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

- (void)fetchLyricsForTitle:(NSString *)title
                     artist:(NSString *)artist
                   duration:(NSTimeInterval)duration
                 completion:(CILRCLIBCompletion)completion;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
