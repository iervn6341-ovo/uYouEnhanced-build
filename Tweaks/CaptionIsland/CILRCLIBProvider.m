#import "CILRCLIBProvider.h"
#import "CICaptionParser.h"
#import "CITextUtilities.h"
#import "CILogStore.h"
#import <float.h>
#import <math.h>
#import <TargetConditionals.h>

static NSString *const CILRCLIBErrorDomain = @"CaptionIsland.LRCLIB";
NSString *const CILRCLIBBaseURLKey = @"CaptionIsland.LRCLIBBaseURL";
static NSString *const CILRCLIBDefaultBaseURLValue =
    @"https://lrclib.net";
static NSString *const CILRCLIBUserAgent =
    @"CaptionIsland/1.0 (+https://github.com/iervn6341-ovo/uYouEnhanced-build)";
static const NSUInteger CILRCLIBMaximumResponseBytes = 2 * 1024 * 1024;
static const NSUInteger CILRCLIBMaximumLyricsCharacters = 512 * 1024;
static const NSUInteger CILRCLIBMaximumCandidates = 50;
static const NSUInteger CILRCLIBMaximumSyncedCues = 5000;
static const NSUInteger CILRCLIBMaximumPlainLines = 1000;
static const NSUInteger CILRCLIBMaximumLyricLineCharacters = 2048;
static const NSTimeInterval CILRCLIBMinimumRequestInterval = 2.0;
static const NSTimeInterval CILRCLIBMinimumCompletionInterval = 1.0;
// Lyrics never expire: an entry is removed only when the user deletes it, or
// when the cache exceeds its size limits and the least recently stored entries
// are evicted. Stored as expiresAt = 0, and any positive-kind entry written by
// an older build is also treated as permanent.
static const NSTimeInterval CILRCLIBNeverExpires = 0;
// Misses deliberately keep a short life. A track absent from LRCLIB today may be
// contributed tomorrow, so a permanent "no lyrics" verdict would lock the song
// out for good; twelve hours is enough to stop repeat lookups during playback.
static const NSTimeInterval CILRCLIBNegativeCacheLifetime = 12 * 60 * 60;
static const NSTimeInterval CILRCLIBDefaultRateLimitCooldown = 15 * 60;
static const NSTimeInterval CILRCLIBInitialBlockCooldown = 60 * 60;
static const NSTimeInterval CILRCLIBMaximumBlockCooldown = 24 * 60 * 60;
// Raised from 32 once the cache became exportable: 32 songs is too small to be
// worth migrating. The 8 MB file cap below remains the real guard, and a cached
// entry is only a few KB.
// Nothing expires any more, so this and the byte ceiling are the only limits.
// Eviction is least-recently-stored, not time based, and only happens once a
// limit is exceeded — the export file is the way to keep more than this.
static const NSUInteger CILRCLIBMaximumCacheEntries = 2000;
static const NSUInteger CILRCLIBMaximumCacheBytes = 8 * 1024 * 1024;
static NSString *const CILRCLIBCooldownDefaultsKey =
    @"CaptionIsland.LRCLIBCooldowns";
static NSString *const CILRCLIBCacheKindResult = @"result";
static NSString *const CILRCLIBCacheKindMiss = @"miss";
static NSString *const CILRCLIBExportFileName =
    @"CaptionIsland-Lyrics.plist";
static NSUInteger CILRCLIBPersistentCacheGeneration = 1;
// Bump whenever a change to query construction or candidate scoring could turn
// a previously cached miss into a hit. Cached negatives live for 12 hours and
// short-circuit the network entirely, so without this a search-behaviour fix
// stays invisible until every stale entry ages out.
//   2: search by track_name only; artist demoted to a ranking signal.
static const NSUInteger CILRCLIBCacheSchemaVersion = 2;
// Cached misses are only valid for the query behaviour that produced them, but
// cached hits stay valid forever. Bumping this generation therefore discards
// every stored miss while keeping successful lookups — and, unlike a schema
// bump, leaves user-exported .plist files importable.
//   2: every automatic lookup searches by track_name; /api/get is no longer
//      used with an artist guessed from the upload title; a title built around
//      a separator retries the reversed reading of its two sides.
//   3: a lookup searches several readings of one title — both sides of a dash,
//      and anything inside 「」 or 『』 — and the video length picks the
//      winner, so titles that used to miss outright can now resolve.
//   4: a bilingual 【Han Latin】 title block yields one reading for each
//      localized name instead of disappearing with the upload decorations.
//   5: every /api/search request uses q= so localized names stored only in an
//      artist or album field remain discoverable during automatic lookup too.
//   6: an empty q= response retries the same reading with track_name= before
//      moving to a reversed or lower-priority title candidate.
//   7: `work metadata『Song』version｜Artist` uses the trailing artist, and
//      adjacent-script caption labels no longer consume bilingual readings.
static const NSUInteger CILRCLIBCacheQueryGeneration = 7;
// Duration gap below which two candidates count as the same edition, so a
// synced timeline wins over plain lyrics that are only marginally closer.
static const NSTimeInterval CILRCLIBDurationTieTolerance = 2.5;
// A normalized title this short is usually an everyday word — "hello", "love",
// "stay" — and carries too little identifying information to justify attaching
// lyrics on its own, so some artist agreement is still required there. Longer
// titles are distinctive enough to stand alone, which matters because an artist
// inferred from an upload title is frequently wrong.
static const NSUInteger CILRCLIBAmbiguousTitleLength = 5;
static const double CILRCLIBMinimumArtistScoreForShortTitle = 0.42;

// A separator-built upload title gives no reliable clue which side is the song.
// "AiNA THE END / On The Way" is artist-first, "風になる / Nachoneko" is
// title-first, and "Street Fighter 6 Ingrid's Theme - Cosmic Scale Pretty" has
// no artist at all. CISplitSongMetadata has to commit to one reading, so when
// that reading finds nothing the other side is worth one more search — bounded
// to plausible track names so an obvious channel string is not retried.
static BOOL CILRCLIBReversedQueryIsWorthwhile(NSString *title,
                                              NSString *artist) {
    if (artist.length == 0 || artist.length > 80) return NO;
    NSString *normalizedArtist = CINormalizedText(artist);
    if (normalizedArtist.length == 0) return NO;
    return ![normalizedArtist isEqualToString:CINormalizedText(title)];
}

static NSError *CILRCLIBError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:CILRCLIBErrorDomain code:code userInfo:@{
        NSLocalizedDescriptionKey: description ?: @"LRCLIB request failed."
    }];
}

// Only misses expire. Entries written by an older build carry a real expiry
// date, and are promoted to permanent here rather than by rewriting the file, so
// nothing the user already has is ever lost to the change.
static BOOL CILRCLIBCacheEntryHasExpired(NSDictionary *entry,
                                         NSTimeInterval now) {
    if (![entry isKindOfClass:NSDictionary.class]) return YES;
    if (![entry[@"kind"] isEqual:CILRCLIBCacheKindMiss]) return NO;
    return [entry[@"expiresAt"] doubleValue] <= now;
}

NSString *CILRCLIBDefaultBaseURL(void) {
    return CILRCLIBDefaultBaseURLValue;
}

NSString * _Nullable CINormalizedLRCLIBBaseURL(
    NSString * _Nullable value,
    NSError * _Nullable * _Nullable error
) {
    NSString *trimmed = [[value ?: @""
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet]
        copy];
    if (trimmed.length == 0) {
        if (error) {
            *error = CILRCLIBError(
                -20,
                @"Enter an LRCLIB base URL."
            );
        }
        return nil;
    }
    NSURLComponents *components =
        [NSURLComponents componentsWithString:trimmed];
    NSString *scheme = components.scheme.lowercaseString;
    BOOL validScheme =
        [scheme isEqualToString:@"https"] ||
        [scheme isEqualToString:@"http"];
    if (!components || !validScheme ||
        components.host.length == 0 ||
        components.user.length > 0 ||
        components.password.length > 0 ||
        components.query.length > 0 ||
        components.fragment.length > 0) {
        if (error) {
            *error = CILRCLIBError(
                -21,
                @"Use an absolute HTTP or HTTPS URL without credentials, query, or fragment."
            );
        }
        return nil;
    }
    components.scheme = scheme;
    NSString *path = components.percentEncodedPath ?: @"";
    while (path.length > 0 && [path hasSuffix:@"/"]) {
        path = [path substringToIndex:path.length - 1];
    }
    components.percentEncodedPath = path;
    NSURL *URL = components.URL;
    if (!URL.absoluteString.length) {
        if (error) {
            *error = CILRCLIBError(
                -22,
                @"Unable to parse the LRCLIB base URL."
            );
        }
        return nil;
    }
    return URL.absoluteString;
}

NSString *CILRCLIBBaseURL(void) {
    NSString *stored = [NSUserDefaults.standardUserDefaults
        stringForKey:CILRCLIBBaseURLKey];
    NSString *normalized =
        CINormalizedLRCLIBBaseURL(stored, NULL);
    return normalized.length > 0
        ? normalized
        : CILRCLIBDefaultBaseURLValue;
}

NSURL *CILRCLIBSearchEndpointURL(void) {
    NSURL *baseURL = [NSURL URLWithString:CILRCLIBBaseURL()];
    NSString *path = baseURL.path.lowercaseString ?: @"";
    if ([path hasSuffix:@"/api/search"]) return baseURL;
    if ([path hasSuffix:@"/api/get"]) {
        return [[baseURL URLByDeletingLastPathComponent]
            URLByAppendingPathComponent:@"search"
                            isDirectory:NO];
    }
    if ([path hasSuffix:@"/api"]) {
        return [baseURL URLByAppendingPathComponent:@"search"
                                       isDirectory:NO];
    }
    return [[baseURL URLByAppendingPathComponent:@"api"
                                     isDirectory:YES]
        URLByAppendingPathComponent:@"search"
                        isDirectory:NO];
}

NSURL *CILRCLIBGetEndpointURL(void) {
    NSURL *baseURL = [NSURL URLWithString:CILRCLIBBaseURL()];
    NSString *path = baseURL.path.lowercaseString ?: @"";
    if ([path hasSuffix:@"/api/get"]) return baseURL;
    if ([path hasSuffix:@"/api/search"]) {
        return [[baseURL URLByDeletingLastPathComponent]
            URLByAppendingPathComponent:@"get"
                            isDirectory:NO];
    }
    if ([path hasSuffix:@"/api"]) {
        return [baseURL URLByAppendingPathComponent:@"get"
                                       isDirectory:NO];
    }
    return [[baseURL URLByAppendingPathComponent:@"api"
                                     isDirectory:YES]
        URLByAppendingPathComponent:@"get"
                        isDirectory:NO];
}

#if !TARGET_OS_OSX
// Where the cache used to live. Library/Caches is reclaimable storage: iOS may
// delete it whenever the device is short on space, which is incompatible with
// lyrics that are meant to be kept until the user removes them.
static NSString *CILRCLIBLegacyCachePath(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (caches.length == 0) return @"";
    return [[caches stringByAppendingPathComponent:@"CaptionIsland"]
        stringByAppendingPathComponent:@"LRCLIBCache.plist"];
}
#endif

static NSString *CILRCLIBCachePath(void) {
#if TARGET_OS_OSX
    return [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            @"CaptionIsland-LRCLIBCache-tests.plist"];
#else
    NSString *support = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (support.length == 0) return @"";
    NSString *directory =
        [support stringByAppendingPathComponent:@"CaptionIsland"];
    return [directory stringByAppendingPathComponent:@"LRCLIBCache.plist"];
#endif
}

// Moves a cache written by an earlier build into the durable location. Runs at
// most once: the legacy file is removed on success, and a failure just means the
// next lookup refetches.
static void CILRCLIBMigrateLegacyCacheIfNeeded(void) {
#if !TARGET_OS_OSX
    NSString *destination = CILRCLIBCachePath();
    NSString *legacy = CILRCLIBLegacyCachePath();
    if (destination.length == 0 || legacy.length == 0) return;
    NSFileManager *manager = NSFileManager.defaultManager;
    if (![manager fileExistsAtPath:legacy]) return;
    if ([manager fileExistsAtPath:destination]) {
        [manager removeItemAtPath:legacy error:nil];
        return;
    }
    [manager createDirectoryAtPath:[destination stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES attributes:nil error:nil];
    if ([manager moveItemAtPath:legacy toPath:destination error:nil]) return;
    [manager removeItemAtPath:legacy error:nil];
#endif
}

static NSString *CILRCLIBString(id value, NSUInteger maximumLength) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *result = [value stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (maximumLength > 0 && result.length > maximumLength) {
        result = [result substringToIndex:maximumLength];
    }
    return result;
}

static double CILRCLIBDouble(id value) {
    if (![value respondsToSelector:@selector(doubleValue)]) return NAN;
    double number = [value doubleValue];
    return isfinite(number) ? number : NAN;
}

static double CILRCLIBFieldSimilarity(NSString *query, NSString *candidate) {
    NSString *left = CINormalizedText(query);
    NSString *right = CINormalizedText(candidate);
    if (left.length == 0 || right.length == 0) return 0;
    if ([left isEqualToString:right]) return 1;
    if ([left containsString:right] || [right containsString:left]) {
        double lengthRatio = (double)MIN(left.length, right.length) /
            (double)MAX(left.length, right.length);
        if (MIN(left.length, right.length) < 4 && lengthRatio < 0.80) {
            return CITextSimilarity(left, right);
        }
        return 0.68 + 0.30 * lengthRatio;
    }
    return CITextSimilarity(left, right);
}

static BOOL CILRCLIBHasVersionMismatch(NSString *query, NSString *candidate) {
    static NSArray<NSRegularExpression *> *patterns;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *qualifiers = @[
            @"live", @"acoustic", @"remix(?:ed)?", @"instrumental", @"karaoke",
            @"cover", @"demo", @"unplugged", @"nightcore", @"sped\\s+up", @"slowed"
        ];
        NSMutableArray *compiled = [NSMutableArray arrayWithCapacity:qualifiers.count];
        for (NSString *qualifier in qualifiers) {
            NSString *pattern = [NSString stringWithFormat:
                @"(?i)(?:^|[^a-z0-9])(?:%@)(?:[^a-z0-9]|$)", qualifier];
            NSRegularExpression *expression =
                [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
            if (expression) [compiled addObject:expression];
        }
        patterns = compiled.copy;
    });
    for (NSRegularExpression *pattern in patterns) {
        BOOL queryContains = [pattern firstMatchInString:query options:0
            range:NSMakeRange(0, query.length)] != nil;
        BOOL candidateContains = [pattern firstMatchInString:candidate options:0
            range:NSMakeRange(0, candidate.length)] != nil;
        if (queryContains != candidateContains) return YES;
    }
    return NO;
}

static NSString *CILRCLIBLyricsString(id value) {
    if (![value isKindOfClass:NSString.class] ||
        [(NSString *)value length] > CILRCLIBMaximumLyricsCharacters) return @"";
    return [(NSString *)value stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSUInteger CILRCLIBPlainLineCount(NSString *lyrics) {
    if (lyrics.length == 0) return 0;
    __block NSUInteger count = 0;
    [lyrics enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *clean = CICleanCaptionText(line);
        if (clean.length > CILRCLIBMaximumLyricLineCharacters) {
            count = CILRCLIBMaximumPlainLines + 1;
            *stop = YES;
            return;
        }
        if (clean.length > 0 && ![clean hasPrefix:@"*******"]) count++;
        if (count > CILRCLIBMaximumPlainLines) *stop = YES;
    }];
    return count;
}

static NSArray<CICaptionCue *> *CILRCLIBUsableCues(NSString *syncedLyrics,
                                                   NSUInteger plainLineCount,
                                                   NSTimeInterval videoDuration,
                                                   NSTimeInterval trackDuration) {
    NSArray<CICaptionCue *> *parsed = [CICaptionParser parseLRCString:syncedLyrics];
    if (parsed.count < 2 || parsed.count > CILRCLIBMaximumSyncedCues) return @[];
    NSTimeInterval referenceDuration = videoDuration > 0 ? videoDuration : trackDuration;
    if (videoDuration > 0 && trackDuration <= 0) return @[];
    if (videoDuration > 0 && trackDuration > 0) {
        NSTimeInterval maximumSyncedDifference =
            MIN(12.0, MAX(8.0, videoDuration * 0.05));
        if (fabs(trackDuration - videoDuration) > maximumSyncedDifference) return @[];
    }
    NSTimeInterval limit = videoDuration > 0 ? videoDuration :
        (trackDuration > 0 ? trackDuration : DBL_MAX);
    NSMutableArray<CICaptionCue *> *result = [NSMutableArray arrayWithCapacity:parsed.count];
    for (CICaptionCue *cue in parsed) {
        if (cue.text.length == 0 ||
            cue.text.length > CILRCLIBMaximumLyricLineCharacters ||
            cue.startTime >= limit) continue;
        NSTimeInterval end = MIN(cue.endTime, limit);
        if (end <= cue.startTime) continue;
        [result addObject:[[CICaptionCue alloc] initWithStartTime:cue.startTime
                                                         endTime:end
                                                            text:cue.text]];
    }
    NSUInteger distinctStarts = 0;
    NSTimeInterval previousStart = -DBL_MAX;
    for (CICaptionCue *cue in result) {
        if (distinctStarts == 0 || cue.startTime - previousStart > 0.05) {
            distinctStarts++;
            previousStart = cue.startTime;
        }
    }
    if (distinctStarts < 2) return @[];
    if (referenceDuration >= 60) {
        NSTimeInterval span = result.lastObject.startTime - result.firstObject.startTime;
        NSTimeInterval minimumSpan = MIN(30.0, MAX(10.0, referenceDuration * 0.10));
        if (span < minimumSpan) return @[];
    }
    if (plainLineCount >= 4 &&
        (double)result.count / (double)plainLineCount < 0.40) return @[];
    return result.copy;
}

@interface CILRCLIBCandidate : NSObject
@property (nonatomic) NSInteger recordID;
@property (nonatomic, copy) NSString *trackName;
@property (nonatomic, copy) NSString *artistName;
@property (nonatomic, copy) NSString *albumName;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) NSTimeInterval durationDifference;
@property (nonatomic) double metadataScore;
@property (nonatomic) double titleScore;
@property (nonatomic) double artistScore;
@property (nonatomic, copy) NSArray<CICaptionCue *> *syncedCues;
@property (nonatomic, copy) NSString *plainLyrics;
@end

@implementation CILRCLIBCandidate
@end

// The mutable state of one multi-reading lookup.
//
// It exists because the request chain is asynchronous and self-recursive: every
// rate-limit deferral re-enters the same two methods, so the position in the
// candidate list and the best match found so far cannot live in local variables.
@interface CILRCLIBLookupContext : NSObject
/// Readings to try, most likely first. Never empty.
@property (nonatomic, copy) NSArray<CISongQuery *> *candidates;
/// Which reading is being searched right now.
@property (nonatomic) NSUInteger candidateIndex;
@property (nonatomic) NSTimeInterval duration;
/// Guards against a superseded lookup writing back its result.
@property (nonatomic) NSUInteger token;
/// Where a result or a miss is recorded. Derived from the first reading, so an
/// entry written by an earlier build stays addressable.
@property (nonatomic, copy) NSString *cacheKey;
/// The closest match found so far, kept in case a later reading finds nothing
/// better.
@property (nonatomic, strong, nullable) CILRCLIBResult *bestResult;
/// Which reading produced `bestResult`, for the diagnostic log.
@property (nonatomic, copy, nullable) NSString *bestOrigin;
/// The failure to report if no reading matches at all.
@property (nonatomic, strong, nullable) NSError *lastError;
@property (nonatomic, copy, nullable) CILRCLIBCompletion completion;
/// Set for a manual browse: search every reading, filter permissively, cache
/// nothing, and report the whole list instead of one winner.
@property (nonatomic) BOOL collectsAllMatches;
@property (nonatomic, strong, nullable)
    NSMutableArray<CILRCLIBResult *> *allMatches;
@property (nonatomic, strong, nullable)
    NSMutableSet<NSNumber *> *seenRecordIDs;
@property (nonatomic, copy, nullable)
    void (^listCompletion)(NSArray<CILRCLIBResult *> *, NSError * _Nullable);
/// The reading at `candidateIndex`, or nil once the list is exhausted.
@property (nonatomic, readonly, nullable) CISongQuery *currentCandidate;
@end

@implementation CILRCLIBLookupContext
- (CISongQuery *)currentCandidate {
    return self.candidateIndex < self.candidates.count
        ? self.candidates[self.candidateIndex] : nil;
}
@end

@interface CILRCLIBProvider ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *currentTask;
@property (nonatomic) NSUInteger requestToken;
@property (nonatomic) NSTimeInterval lastRequestStartUptime;
@property (nonatomic) NSTimeInterval lastRequestCompletionUptime;
@property (nonatomic, copy) NSString *configuredEndpointIdentity;
@property (nonatomic) BOOL persistentCacheLoaded;
@property (nonatomic) NSUInteger persistentCacheGeneration;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *
    persistentCacheEntries;
- (nullable CILRCLIBResult *)resultFromCacheEntry:(NSDictionary *)entry;
- (NSDictionary *)cacheEntryForResult:(CILRCLIBResult *)result
                              expires:(NSTimeInterval)expires;
- (void)storeCacheEntry:(NSDictionary *)entry forKey:(NSString *)key;
@end

@implementation CILRCLIBResult

- (instancetype)init {
    self = [super init];
    if (self) {
        _trackName = @"";
        _artistName = @"";
        _albumName = @"";
        _syncedCues = @[];
        _plainLyrics = @"";
    }
    return self;
}

@end

@implementation CILRCLIBCacheSummary
@end

@implementation CILRCLIBCacheEntry

- (instancetype)init {
    self = [super init];
    if (self) {
        _cacheKey = @"";
        _trackName = @"";
        _artistName = @"";
        _albumName = @"";
        _lyricsText = @"";
        _searchIndex = @"";
    }
    return self;
}

@end

@implementation CILRCLIBProvider

/// Reads the cache file straight from disk. Summary, export and import all work
/// on the file rather than any live instance's dictionary, so they agree with
/// each other regardless of which providers happen to exist.
+ (NSDictionary *)entriesFromDiskWithByteCount:(unsigned long long *)byteCount {
    if (byteCount) *byteCount = 0;
    CILRCLIBMigrateLegacyCacheIfNeeded();
    NSString *path = CILRCLIBCachePath();
    if (path.length == 0) return @{};
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:nil];
    if (data.length == 0 || data.length > CILRCLIBMaximumCacheBytes) return @{};
    if (byteCount) *byteCount = data.length;
    id root = [NSPropertyListSerialization propertyListWithData:data
                                                        options:0
                                                         format:NULL
                                                          error:nil];
    if (![root isKindOfClass:NSDictionary.class]) return @{};
    NSUInteger storedVersion =
        [root[@"version"] respondsToSelector:@selector(unsignedIntegerValue)]
            ? [root[@"version"] unsignedIntegerValue] : 0;
    if (storedVersion != CILRCLIBCacheSchemaVersion) return @{};
    id entries = root[@"entries"];
    return [entries isKindOfClass:NSDictionary.class] ? entries : @{};
}

// Renders a cached entry for reading. A timeline is shown with its timestamps
// because that is what distinguishes a synced record from plain text, and seeing
// the timing is the point of inspecting one.
static NSString *CILRCLIBDisplayLyricsForEntry(NSDictionary *entry) {
    NSArray *cues = entry[@"cues"];
    if ([cues isKindOfClass:NSArray.class] && cues.count > 0) {
        NSMutableArray<NSString *> *lines =
            [NSMutableArray arrayWithCapacity:cues.count];
        for (id candidate in cues) {
            if (![candidate isKindOfClass:NSDictionary.class]) continue;
            NSString *text = CILRCLIBString(
                ((NSDictionary *)candidate)[@"text"],
                CILRCLIBMaximumLyricLineCharacters
            );
            if (text.length == 0) continue;
            double start = CILRCLIBDouble(
                ((NSDictionary *)candidate)[@"start"]
            );
            if (!isfinite(start) || start < 0) start = 0;
            [lines addObject:[NSString stringWithFormat:@"[%02d:%05.2f] %@",
                (int)(start / 60.0), fmod(start, 60.0), text]];
        }
        if (lines.count > 0) return [lines componentsJoinedByString:@"\n"];
    }
    return CILRCLIBString(entry[@"plainLyrics"],
                          CILRCLIBMaximumLyricsCharacters);
}

+ (NSArray<CILRCLIBCacheEntry *> *)cachedLyricEntries {
    NSDictionary *entries = [self entriesFromDiskWithByteCount:NULL];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSMutableArray<CILRCLIBCacheEntry *> *result =
        [NSMutableArray arrayWithCapacity:entries.count];
    for (id key in entries) {
        if (![key isKindOfClass:NSString.class]) continue;
        NSDictionary *stored = entries[key];
        if (![stored isKindOfClass:NSDictionary.class] ||
            ![stored[@"kind"] isEqual:CILRCLIBCacheKindResult] ||
            CILRCLIBCacheEntryHasExpired(stored, now)) continue;
        NSString *lyrics = CILRCLIBDisplayLyricsForEntry(stored);
        if (lyrics.length == 0) continue;

        CILRCLIBCacheEntry *item = [CILRCLIBCacheEntry new];
        item.cacheKey = key;
        item.trackName = CILRCLIBString(stored[@"trackName"], 512);
        item.artistName = CILRCLIBString(stored[@"artistName"], 512);
        item.albumName = CILRCLIBString(stored[@"albumName"], 512);
        item.trackDuration = CILRCLIBDouble(stored[@"trackDuration"]);
        item.storedAt = CILRCLIBDouble(stored[@"storedAt"]);
        NSArray *cues = stored[@"cues"];
        item.hasSyncedTimeline =
            [cues isKindOfClass:NSArray.class] && cues.count > 0;
        item.lyricsText = lyrics;
        item.lineCount = CINonEmptyLines(lyrics).count;
        item.searchIndex = [[NSString stringWithFormat:@"%@\n%@\n%@",
            item.trackName, item.artistName, item.albumName] lowercaseString];
        [result addObject:item];
    }
    [result sortUsingComparator:^NSComparisonResult(CILRCLIBCacheEntry *left,
                                                    CILRCLIBCacheEntry *right) {
        NSComparisonResult byTrack = [left.trackName
            compare:right.trackName
            options:NSCaseInsensitiveSearch | NSNumericSearch];
        if (byTrack != NSOrderedSame) return byTrack;
        NSComparisonResult byArtist = [left.artistName
            compare:right.artistName options:NSCaseInsensitiveSearch];
        if (byArtist != NSOrderedSame) return byArtist;
        return [left.cacheKey compare:right.cacheKey];
    }];
    return result;
}

+ (NSUInteger)removeCachedEntriesWithKeys:(NSArray<NSString *> *)keys {
    if (![keys isKindOfClass:NSArray.class] || keys.count == 0) return 0;
    unsigned long long byteCount = 0;
    NSDictionary *entries = [self entriesFromDiskWithByteCount:&byteCount];
    if (entries.count == 0) return 0;
    NSMutableDictionary *remaining = entries.mutableCopy;
    NSUInteger removed = 0;
    for (id key in keys) {
        if (![key isKindOfClass:NSString.class]) continue;
        if (!remaining[key]) continue;
        [remaining removeObjectForKey:key];
        removed++;
    }
    if (removed == 0) return 0;

    NSString *path = CILRCLIBCachePath();
    if (path.length == 0) return 0;
    if (remaining.count == 0) {
        [self clearPersistentCache];
        return removed;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{
            @"version": @(CILRCLIBCacheSchemaVersion),
            @"entries": remaining,
        }
        format:NSPropertyListBinaryFormat_v1_0
        options:0
        error:nil];
    if (data.length == 0 || data.length > CILRCLIBMaximumCacheBytes) return 0;
    if (![data writeToFile:path options:NSDataWritingAtomic error:nil]) return 0;
    // Live providers hold their own copy of the dictionary, so make them reload
    // rather than serve a deleted entry from memory.
    @synchronized (CILRCLIBProvider.class) {
        CILRCLIBPersistentCacheGeneration++;
    }
    return removed;
}

+ (CILRCLIBCacheSummary *)cacheSummary {
    CILRCLIBCacheSummary *summary = [CILRCLIBCacheSummary new];
    unsigned long long byteCount = 0;
    NSDictionary *entries = [self entriesFromDiskWithByteCount:&byteCount];
    summary.byteCount = byteCount;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    for (id key in entries) {
        NSDictionary *entry = entries[key];
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if (CILRCLIBCacheEntryHasExpired(entry, now)) continue;
        if ([entry[@"kind"] isEqual:CILRCLIBCacheKindMiss]) summary.missCount++;
        else if ([entry[@"kind"] isEqual:CILRCLIBCacheKindResult]) {
            summary.lyricCount++;
        }
    }
    return summary;
}

+ (NSURL *)exportCacheWithError:(NSError **)error {
    NSDictionary *entries = [self entriesFromDiskWithByteCount:NULL];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSMutableDictionary *exported = [NSMutableDictionary dictionary];
    for (id key in entries) {
        if (![key isKindOfClass:NSString.class]) continue;
        NSDictionary *entry = entries[key];
        if (![entry isKindOfClass:NSDictionary.class] ||
            ![entry[@"kind"] isEqual:CILRCLIBCacheKindResult] ||
            CILRCLIBCacheEntryHasExpired(entry, now)) continue;
        exported[key] = entry;
    }
    if (exported.count == 0) {
        if (error) {
            *error = CILRCLIBError(-30, @"There are no cached lyrics to export.");
        }
        return nil;
    }

    NSData *data = [NSPropertyListSerialization
        dataWithPropertyList:@{
            @"version": @(CILRCLIBCacheSchemaVersion),
            @"entries": exported,
        }
        format:NSPropertyListBinaryFormat_v1_0
        options:0
        error:nil];
    if (data.length == 0) {
        if (error) {
            *error = CILRCLIBError(-31, @"Unable to encode the cached lyrics.");
        }
        return nil;
    }
    // A stable name inside a unique directory keeps the shared filename
    // meaningful without colliding across repeated exports.
    NSString *directory = [NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil]) {
        if (error) {
            *error = CILRCLIBError(-32, @"Unable to prepare the export file.");
        }
        return nil;
    }
    NSString *path =
        [directory stringByAppendingPathComponent:CILRCLIBExportFileName];
    if (![data writeToFile:path options:NSDataWritingAtomic error:nil]) {
        if (error) {
            *error = CILRCLIBError(-33, @"Unable to write the export file.");
        }
        return nil;
    }
    return [NSURL fileURLWithPath:path];
}

+ (NSUInteger)importCacheFromURL:(NSURL *)URL error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfURL:URL options:0 error:nil];
    if (data.length == 0 || data.length > CILRCLIBMaximumCacheBytes) {
        if (error) {
            *error = CILRCLIBError(-34, data.length == 0
                ? @"The selected file could not be read."
                : @"The selected file is too large to import.");
        }
        return 0;
    }
    id root = [NSPropertyListSerialization propertyListWithData:data
                                                        options:0
                                                         format:NULL
                                                          error:nil];
    NSUInteger version =
        [root isKindOfClass:NSDictionary.class] &&
        [root[@"version"] respondsToSelector:@selector(unsignedIntegerValue)]
            ? [root[@"version"] unsignedIntegerValue] : 0;
    id incoming = [root isKindOfClass:NSDictionary.class]
        ? root[@"entries"] : nil;
    if (![incoming isKindOfClass:NSDictionary.class]) {
        if (error) {
            *error = CILRCLIBError(-35,
                @"The selected file is not a Caption Island lyric export.");
        }
        return 0;
    }
    if (version != CILRCLIBCacheSchemaVersion) {
        if (error) {
            *error = CILRCLIBError(-36,
                @"The export was written by an incompatible version.");
        }
        return 0;
    }

    CILRCLIBProvider *provider = [CILRCLIBProvider new];
    NSUInteger imported = 0;
    for (id key in incoming) {
        if (imported >= CILRCLIBMaximumCacheEntries) break;
        if (![key isKindOfClass:NSString.class] ||
            ((NSString *)key).length == 0) continue;
        NSDictionary *entry = incoming[key];
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        // Round-tripping through resultFromCacheEntry re-applies every length,
        // count and timing rule the network path uses, so a hand-edited or
        // corrupted file cannot inject anything the app would not have accepted
        // from LRCLIB itself.
        CILRCLIBResult *result = [provider resultFromCacheEntry:entry];
        if (!result) continue;
        [provider storeCacheEntry:[provider cacheEntryForResult:result
                                        expires:CILRCLIBNeverExpires]
                          forKey:key];
        imported++;
    }
    if (imported == 0 && error) {
        *error = CILRCLIBError(-37,
            @"The export contained no usable lyrics.");
    }
    return imported;
}

+ (void)clearPersistentCache {
    NSString *path = CILRCLIBCachePath();
    if (path.length > 0) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    @synchronized (CILRCLIBProvider.class) {
        CILRCLIBPersistentCacheGeneration++;
    }
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *configuration =
            NSURLSessionConfiguration.defaultSessionConfiguration;
        configuration.timeoutIntervalForRequest = 6.0;
        configuration.timeoutIntervalForResource = 8.0;
        configuration.HTTPMaximumConnectionsPerHost = 1;
        configuration.requestCachePolicy = NSURLRequestUseProtocolCachePolicy;
        configuration.HTTPCookieStorage = nil;
        configuration.HTTPShouldSetCookies = NO;
        _session = [NSURLSession sessionWithConfiguration:configuration];
        _persistentCacheEntries = [NSMutableDictionary dictionary];
        @synchronized (CILRCLIBProvider.class) {
            _persistentCacheGeneration =
                CILRCLIBPersistentCacheGeneration;
        }
    }
    return self;
}

- (void)dealloc {
    [self.session invalidateAndCancel];
}

- (void)cancel {
    @synchronized (self) {
        self.requestToken++;
        [self.currentTask cancel];
        self.currentTask = nil;
    }
}

- (void)loadPersistentCacheIfNeededLocked {
    NSUInteger currentGeneration;
    @synchronized (CILRCLIBProvider.class) {
        currentGeneration = CILRCLIBPersistentCacheGeneration;
    }
    if (self.persistentCacheGeneration != currentGeneration) {
        self.persistentCacheGeneration = currentGeneration;
        self.persistentCacheLoaded = NO;
        [self.persistentCacheEntries removeAllObjects];
    }
    if (self.persistentCacheLoaded) return;
    self.persistentCacheLoaded = YES;
    CILRCLIBMigrateLegacyCacheIfNeeded();
    NSString *path = CILRCLIBCachePath();
    NSData *data = path.length > 0
        ? [NSData dataWithContentsOfFile:path options:0 error:nil] : nil;
    if (data.length == 0 || data.length > CILRCLIBMaximumCacheBytes) return;
    id root = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListMutableContainersAndLeaves
        format:NULL
        error:nil];
    if (![root isKindOfClass:NSDictionary.class] ||
        ![root[@"entries"] isKindOfClass:NSDictionary.class]) return;
    // The version was previously written but never read back, so entries
    // created under older search semantics were reused indefinitely. Discard
    // the whole file on a mismatch: it is a cache, and refetching is cheap
    // compared with serving a stale "no lyrics" verdict for 12 hours.
    NSUInteger storedVersion =
        [root[@"version"] respondsToSelector:@selector(unsignedIntegerValue)]
            ? [root[@"version"] unsignedIntegerValue] : 0;
    if (storedVersion != CILRCLIBCacheSchemaVersion) {
        // Deliberately silent: this file is linked by an isolated smoke test
        // that does not pull in CILogStore, and keeping the provider free of
        // that dependency is worth more than one diagnostic line. A discarded
        // cache is observable anyway, as the next lookup hits the network.
        NSString *stalePath = CILRCLIBCachePath();
        if (stalePath.length > 0) {
            [[NSFileManager defaultManager] removeItemAtPath:stalePath
                                                       error:nil];
        }
        return;
    }
    [self.persistentCacheEntries
        addEntriesFromDictionary:root[@"entries"]];
}

- (NSData *)persistentCacheDataLocked {
    NSDictionary *root = @{
        @"version": @(CILRCLIBCacheSchemaVersion),
        @"entries": self.persistentCacheEntries ?: @{},
    };
    return [NSPropertyListSerialization dataWithPropertyList:root
        format:NSPropertyListBinaryFormat_v1_0
        options:0
        error:nil];
}

- (void)writePersistentCacheLocked {
    [self loadPersistentCacheIfNeededLocked];
    NSArray<NSString *> *(^oldestKeys)(void) = ^NSArray<NSString *> * {
        return [self.persistentCacheEntries.allKeys
            sortedArrayUsingComparator:^NSComparisonResult(
                NSString *leftKey,
                NSString *rightKey
            ) {
                NSDictionary *left = self.persistentCacheEntries[leftKey];
                NSDictionary *right = self.persistentCacheEntries[rightKey];
                NSTimeInterval leftTime =
                    [left[@"storedAt"] doubleValue];
                NSTimeInterval rightTime =
                    [right[@"storedAt"] doubleValue];
                if (leftTime < rightTime) return NSOrderedAscending;
                if (leftTime > rightTime) return NSOrderedDescending;
                return [leftKey compare:rightKey];
            }];
    };
    while (self.persistentCacheEntries.count >
           CILRCLIBMaximumCacheEntries) {
        NSString *oldest = oldestKeys().firstObject;
        if (oldest.length == 0) break;
        [self.persistentCacheEntries removeObjectForKey:oldest];
    }
    NSData *data = [self persistentCacheDataLocked];
    while (data.length > CILRCLIBMaximumCacheBytes &&
           self.persistentCacheEntries.count > 1) {
        NSString *oldest = oldestKeys().firstObject;
        if (oldest.length == 0) break;
        [self.persistentCacheEntries removeObjectForKey:oldest];
        data = [self persistentCacheDataLocked];
    }
    NSString *path = CILRCLIBCachePath();
    if (path.length == 0 || data.length == 0 ||
        data.length > CILRCLIBMaximumCacheBytes) return;
    NSString *directory = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    if (![data writeToFile:path options:NSDataWritingAtomic error:nil]) return;
    // Tell every other provider instance that its in-memory copy is stale.
    //
    // Without this a write is invisible across instances: the panel's browse
    // provider could pin the user's chosen lyrics and the coordinator's provider
    // would keep serving the copy it loaded at launch. The writer advances its own
    // marker in the same breath so it does not throw away the copy it just wrote.
    @synchronized (CILRCLIBProvider.class) {
        CILRCLIBPersistentCacheGeneration++;
        self.persistentCacheGeneration = CILRCLIBPersistentCacheGeneration;
    }
}

- (NSString *)cacheKeyForTitle:(NSString *)title
                        artist:(NSString *)artist
                      duration:(NSTimeInterval)duration
                         exact:(BOOL)exact
              endpointIdentity:(NSString *)endpointIdentity {
    return [NSString stringWithFormat:@"v1\n%@\n%@\n%@\n%.0f\n%@",
        endpointIdentity ?: @"",
        CINormalizedText(title),
        CINormalizedText(artist),
        MAX(0, isfinite(duration) ? duration : 0),
        exact ? @"get" : @"search"];
}

- (NSDictionary *)cacheEntryForResult:(CILRCLIBResult *)result
                              expires:(NSTimeInterval)expires {
    NSMutableArray<NSDictionary *> *cues =
        [NSMutableArray arrayWithCapacity:result.syncedCues.count];
    for (CICaptionCue *cue in result.syncedCues) {
        if (cue.text.length == 0 ||
            cue.text.length > CILRCLIBMaximumLyricLineCharacters ||
            !isfinite(cue.startTime) || !isfinite(cue.endTime) ||
            cue.endTime <= cue.startTime) continue;
        [cues addObject:@{
            @"start": @(cue.startTime),
            @"end": @(cue.endTime),
            @"text": cue.text,
        }];
    }
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    return @{
        @"kind": CILRCLIBCacheKindResult,
        @"storedAt": @(now),
        @"expiresAt": @(expires),
        @"recordID": @(result.recordID),
        @"trackName": result.trackName ?: @"",
        @"artistName": result.artistName ?: @"",
        @"albumName": result.albumName ?: @"",
        @"trackDuration": @(result.trackDuration),
        @"durationDifference": @(result.durationDifference),
        @"plainLyrics": result.plainLyrics ?: @"",
        @"cues": cues,
    };
}

- (CILRCLIBResult *)resultFromCacheEntry:(NSDictionary *)entry {
    if (![entry isKindOfClass:NSDictionary.class] ||
        ![entry[@"kind"] isEqual:CILRCLIBCacheKindResult]) return nil;
    NSString *trackName = CILRCLIBString(entry[@"trackName"], 512);
    NSString *artistName = CILRCLIBString(entry[@"artistName"], 512);
    NSString *albumName = CILRCLIBString(entry[@"albumName"], 512);
    NSString *plainLyrics = CILRCLIBLyricsString(entry[@"plainLyrics"]);
    NSArray *storedCues = [entry[@"cues"] isKindOfClass:NSArray.class]
        ? entry[@"cues"] : @[];
    NSMutableArray<CICaptionCue *> *cues =
        [NSMutableArray arrayWithCapacity:storedCues.count];
    for (id object in storedCues) {
        if (![object isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *dictionary = object;
        NSString *text = CILRCLIBString(
            dictionary[@"text"], CILRCLIBMaximumLyricLineCharacters);
        double start = CILRCLIBDouble(dictionary[@"start"]);
        double end = CILRCLIBDouble(dictionary[@"end"]);
        if (text.length == 0 || !isfinite(start) || !isfinite(end) ||
            start < 0 || end <= start) continue;
        [cues addObject:[[CICaptionCue alloc]
            initWithStartTime:start endTime:end text:text]];
        if (cues.count >= CILRCLIBMaximumSyncedCues) break;
    }
    if (cues.count == 0 && CILRCLIBPlainLineCount(plainLyrics) == 0) {
        return nil;
    }
    CILRCLIBResult *result = [CILRCLIBResult new];
    result.recordID = [entry[@"recordID"] integerValue];
    result.trackName = trackName;
    result.artistName = artistName;
    result.albumName = albumName;
    result.trackDuration = [entry[@"trackDuration"] doubleValue];
    result.durationDifference = [entry[@"durationDifference"] doubleValue];
    result.syncedCues = cues.copy;
    result.plainLyrics = plainLyrics;
    result.fromPersistentCache = YES;
    return result;
}

- (CILRCLIBResult *)cachedResultForKey:(NSString *)key
                          negativeHit:(BOOL *)negativeHit {
    @synchronized (self) {
        [self loadPersistentCacheIfNeededLocked];
        NSDictionary *entry = self.persistentCacheEntries[key];
        if (![entry isKindOfClass:NSDictionary.class]) return nil;
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        if (CILRCLIBCacheEntryHasExpired(entry, now)) {
            [self.persistentCacheEntries removeObjectForKey:key];
            [self writePersistentCacheLocked];
            return nil;
        }
        if ([entry[@"kind"] isEqual:CILRCLIBCacheKindMiss]) {
            // A miss recorded by older query logic says nothing about what the
            // current logic would find, so drop it and let the lookup run.
            NSUInteger generation =
                [entry[@"queryGeneration"]
                    respondsToSelector:@selector(unsignedIntegerValue)]
                    ? [entry[@"queryGeneration"] unsignedIntegerValue] : 0;
            if (generation != CILRCLIBCacheQueryGeneration) {
                [self.persistentCacheEntries removeObjectForKey:key];
                [self writePersistentCacheLocked];
                return nil;
            }
            if (negativeHit) *negativeHit = YES;
            return nil;
        }
        CILRCLIBResult *result = [self resultFromCacheEntry:entry];
        if (!result) {
            [self.persistentCacheEntries removeObjectForKey:key];
            [self writePersistentCacheLocked];
        }
        return result;
    }
}

- (void)storeResult:(CILRCLIBResult *)result forCacheKey:(NSString *)key {
    if (!result || key.length == 0) return;
    @synchronized (self) {
        [self loadPersistentCacheIfNeededLocked];
        self.persistentCacheEntries[key] =
            [self cacheEntryForResult:result
                              expires:CILRCLIBNeverExpires];
        [self writePersistentCacheLocked];
    }
}

- (void)storeCacheEntry:(NSDictionary *)entry forKey:(NSString *)key {
    if (entry.count == 0 || key.length == 0) return;
    @synchronized (self) {
        [self loadPersistentCacheIfNeededLocked];
        self.persistentCacheEntries[key] = entry;
        [self writePersistentCacheLocked];
    }
}

- (void)storeNegativeResultForCacheKey:(NSString *)key {
    if (key.length == 0) return;
    @synchronized (self) {
        [self loadPersistentCacheIfNeededLocked];
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        self.persistentCacheEntries[key] = @{
            @"kind": CILRCLIBCacheKindMiss,
            @"storedAt": @(now),
            @"expiresAt": @(now + CILRCLIBNegativeCacheLifetime),
            @"queryGeneration": @(CILRCLIBCacheQueryGeneration),
        };
        [self writePersistentCacheLocked];
    }
}

- (NSMutableDictionary *)cooldowns {
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults
        dictionaryForKey:CILRCLIBCooldownDefaultsKey];
    return [stored isKindOfClass:NSDictionary.class]
        ? stored.mutableCopy : [NSMutableDictionary dictionary];
}

- (NSTimeInterval)cooldownRemainingForEndpoint:(NSString *)endpoint {
    if (endpoint.length == 0) return 0;
    NSDictionary *entry = [self cooldowns][endpoint];
    NSTimeInterval remaining =
        [entry[@"until"] doubleValue] - NSDate.date.timeIntervalSince1970;
    return MAX(0, remaining);
}

- (NSTimeInterval)retryAfterSecondsFromResponse:
    (NSHTTPURLResponse *)response {
    NSString *value = [response valueForHTTPHeaderField:@"Retry-After"];
    double seconds = [value respondsToSelector:@selector(doubleValue)]
        ? value.doubleValue : 0;
    return isfinite(seconds) && seconds > 0
        ? seconds : CILRCLIBDefaultRateLimitCooldown;
}

- (NSTimeInterval)recordCooldownForEndpoint:(NSString *)endpoint
                                     status:(NSInteger)status
                                   response:(NSHTTPURLResponse *)response {
    if (endpoint.length == 0) return 0;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSMutableDictionary *all = [self cooldowns];
    NSDictionary *old = all[endpoint];
    NSInteger strikes = [old[@"until"] doubleValue] > now - 24 * 60 * 60
        ? MAX(0, [old[@"strikes"] integerValue]) + 1 : 1;
    NSTimeInterval seconds;
    if (status == 429) {
        NSTimeInterval serverDelay =
            [self retryAfterSecondsFromResponse:response];
        NSTimeInterval protectiveDelay = MIN(
            CILRCLIBMaximumBlockCooldown,
            CILRCLIBDefaultRateLimitCooldown *
                pow(2.0, MIN(5, strikes - 1)));
        seconds = MAX(serverDelay, protectiveDelay);
    } else {
        seconds = MIN(
            CILRCLIBMaximumBlockCooldown,
            CILRCLIBInitialBlockCooldown *
                pow(4.0, MIN(3, strikes - 1)));
    }
    all[endpoint] = @{
        @"until": @(now + seconds),
        @"strikes": @(strikes),
        @"status": @(status),
    };
    [NSUserDefaults.standardUserDefaults
        setObject:all forKey:CILRCLIBCooldownDefaultsKey];
    return seconds;
}

- (void)clearCooldownForEndpoint:(NSString *)endpoint {
    if (endpoint.length == 0) return;
    NSMutableDictionary *all = [self cooldowns];
    if (!all[endpoint]) return;
    [all removeObjectForKey:endpoint];
    [NSUserDefaults.standardUserDefaults
        setObject:all forKey:CILRCLIBCooldownDefaultsKey];
}

- (BOOL)responseLooksLikeBlockPage:(NSURLResponse *)response
                              data:(NSData *)data {
    if ([response isKindOfClass:NSHTTPURLResponse.class] &&
        ((NSHTTPURLResponse *)response).statusCode == 403) return YES;
    if (data.length == 0) return NO;
    NSUInteger length = MIN(data.length, 64 * 1024);
    NSString *body = [[NSString alloc]
        initWithData:[data subdataWithRange:NSMakeRange(0, length)]
        encoding:NSUTF8StringEncoding];
    NSString *lower = body.lowercaseString;
    return [lower containsString:@"you have been blocked"] ||
        [lower containsString:@"sorry, you have been blocked"] ||
        ([lower containsString:@"cloudflare"] &&
         [lower containsString:@"access denied"]);
}

- (BOOL)isCurrentToken:(NSUInteger)token {
    @synchronized (self) {
        return token == self.requestToken;
    }
}

- (void)completeToken:(NSUInteger)token
                result:(CILRCLIBResult *)result
                 error:(NSError *)error
            completion:(CILRCLIBCompletion)completion {
    @synchronized (self) {
        if (token != self.requestToken) return;
        completion(result, error);
    }
}

- (NSURL *)searchURLForTitle:(NSString *)title artist:(NSString *)artist {
    NSURLComponents *components = [NSURLComponents
        componentsWithURL:CILRCLIBSearchEndpointURL()
        resolvingAgainstBaseURL:NO];
    // q= searches LRCLIB's track, artist and album fields. This matters when a
    // localized title is stored only as the album name while trackName is
    // English or romanized. Do not send artist_name as a structured AND filter:
    // an artist inferred from a YouTube upload remains only a ranking signal.
    NSString *query = artist.length > 0
        ? [NSString stringWithFormat:@"%@ %@", artist, title] : title;
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"q" value:query],
    ];
    return components.URL;
}

- (NSURL *)trackNameSearchURLForTitle:(NSString *)title {
    NSURLComponents *components = [NSURLComponents
        componentsWithURL:CILRCLIBSearchEndpointURL()
        resolvingAgainstBaseURL:NO];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"track_name" value:title],
    ];
    return components.URL;
}

// No longer used by any automatic lookup: /api/get matches track, artist and
// duration as one AND, which only works when the artist is LRCLIB's canonical
// credit rather than a guess from an upload title. Kept — with its tests — for
// the one case that could justify it later: a channel whose identity is
// trustworthy by construction, such as Topic or VEVO.
- (NSURL *)getURLForTitle:(NSString *)title
                   artist:(NSString *)artist
                 duration:(NSTimeInterval)duration {
    NSURLComponents *components = [NSURLComponents
        componentsWithURL:CILRCLIBGetEndpointURL()
        resolvingAgainstBaseURL:NO];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray arrayWithObjects:
        [NSURLQueryItem queryItemWithName:@"track_name" value:title],
        [NSURLQueryItem queryItemWithName:@"artist_name" value:artist],
        nil];
    if (duration > 0 && isfinite(duration)) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"duration"
            value:[NSString stringWithFormat:@"%.0f", duration]]];
    }
    components.queryItems = items;
    return components.URL;
}

- (NSMutableURLRequest *)requestForURL:(NSURL *)URL {
    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:URL
           cachePolicy:NSURLRequestUseProtocolCachePolicy
       timeoutInterval:6.0];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:CILRCLIBUserAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:CILRCLIBUserAgent forHTTPHeaderField:@"Lrclib-Client"];
    return request;
}

- (NSError *)responseErrorForResponse:(NSURLResponse *)response data:(NSData *)data {
    if ([response isKindOfClass:NSHTTPURLResponse.class]) {
        NSHTTPURLResponse *HTTPResponse = (NSHTTPURLResponse *)response;
        if (HTTPResponse.statusCode < 200 || HTTPResponse.statusCode >= 300) {
            NSString *description;
            switch (HTTPResponse.statusCode) {
                case 403:
                    description =
                        @"LRCLIB access was blocked; automatic requests are temporarily paused.";
                    break;
                case 404:
                    description = @"LRCLIB returned no exact match.";
                    break;
                case 429:
                    description =
                        @"LRCLIB rate limit reached; Retry-After is being honored.";
                    break;
                default:
                    description = [NSString stringWithFormat:
                        @"LRCLIB returned HTTP %ld.",
                        (long)HTTPResponse.statusCode];
                    break;
            }
            return CILRCLIBError(HTTPResponse.statusCode, description);
        }
    }
    if (data.length == 0 || data.length > CILRCLIBMaximumResponseBytes) {
        return CILRCLIBError(-4, data.length == 0
            ? @"LRCLIB returned an empty response."
            : @"LRCLIB response exceeded the size limit.");
    }
    return nil;
}

- (CILRCLIBCandidate *)candidateFromObject:(id)object
                                      title:(NSString *)title
                                     artist:(NSString *)artist
                              videoDuration:(NSTimeInterval)videoDuration {
    if (![object isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *dictionary = object;
    if ([dictionary[@"instrumental"] respondsToSelector:@selector(boolValue)] &&
        [dictionary[@"instrumental"] boolValue]) return nil;

    NSString *trackName = CILRCLIBString(dictionary[@"trackName"], 512);
    NSString *artistName = CILRCLIBString(dictionary[@"artistName"], 512);
    NSString *albumName = CILRCLIBString(dictionary[@"albumName"], 512);
    if (trackName.length == 0) return nil;

    double titleScore = CILRCLIBFieldSimilarity(title, trackName);
    double artistScore = artist.length > 0
        ? CILRCLIBFieldSimilarity(artist, artistName) : 1.0;
    if (titleScore < 0.68) return nil;
    if (artist.length > 0 &&
        CINormalizedText(title).length <= CILRCLIBAmbiguousTitleLength &&
        artistScore < CILRCLIBMinimumArtistScoreForShortTitle) {
        return nil;
    }
    // The artist is only ever a ranking signal, never a filter. An artist
    // inferred from an upload title is frequently a near-miss of LRCLIB's
    // canonical credit — "ウォルピスカーター MV", "HoneyWorks feat.ハコニワリリィ"
    // or a character/CV name — and discarding candidates on that basis threw
    // away the correct track. A weak artist match simply scores lower, so a
    // genuinely better-matching candidate still wins when one exists.
    double metadataScore = artist.length > 0
        ? titleScore * 0.72 + artistScore * 0.28 : titleScore;
    if (CILRCLIBHasVersionMismatch(title, trackName)) metadataScore -= 0.18;
    if (metadataScore < 0.70) return nil;

    double duration = CILRCLIBDouble(dictionary[@"duration"]);
    double durationDifference = videoDuration > 0 && duration > 0
        ? fabs(duration - videoDuration) : DBL_MAX;
    if (videoDuration > 0 && duration > 0) {
        // A YouTube upload can be longer than the database track because of
        // an intro/outro. The reverse direction is riskier: a database track
        // substantially longer than the video usually means TV-size versus
        // full-size (or another edit), so keep that tolerance tighter.
        double maximumDifference = duration > videoDuration
            ? MAX(18.0, MIN(35.0, videoDuration * 0.15))
            : MAX(35.0, MIN(60.0, videoDuration * 0.20));
        if (durationDifference > maximumDifference) return nil;
    }

    NSString *plainLyrics = CILRCLIBLyricsString(dictionary[@"plainLyrics"]);
    NSUInteger plainLineCount = CILRCLIBPlainLineCount(plainLyrics);
    if (plainLineCount > CILRCLIBMaximumPlainLines) {
        plainLyrics = @"";
        plainLineCount = 0;
    }
    NSString *syncedLyrics = CILRCLIBLyricsString(dictionary[@"syncedLyrics"]);
    NSArray<CICaptionCue *> *syncedCues = syncedLyrics.length > 0
        ? CILRCLIBUsableCues(syncedLyrics, plainLineCount, videoDuration, duration) : @[];
    if (syncedCues.count == 0 && plainLineCount == 0) return nil;

    CILRCLIBCandidate *candidate = [CILRCLIBCandidate new];
    candidate.recordID = [dictionary[@"id"] respondsToSelector:@selector(integerValue)]
        ? [dictionary[@"id"] integerValue] : 0;
    candidate.trackName = trackName;
    candidate.artistName = artistName;
    candidate.albumName = albumName;
    candidate.duration = duration > 0 ? duration : 0;
    candidate.durationDifference = durationDifference;
    candidate.metadataScore = metadataScore;
    candidate.titleScore = titleScore;
    candidate.artistScore = artistScore;
    candidate.syncedCues = syncedCues;
    candidate.plainLyrics = plainLyrics;
    return candidate;
}

// Everything in a payload that carries lyrics at all, for the manual chooser.
//
// The only rejections here are the ones that would make a row useless to a human:
// no track name, marked instrumental, or no lyrics of either kind. Title
// similarity and duration are surfaced as sort order and displayed detail rather
// than used as gates, because the user is looking at this list precisely when the
// automatic gates rejected everything.
- (NSArray<CILRCLIBCandidate *> *)browsableCandidatesFromObjects:(NSArray *)objects
                                                   videoDuration:(NSTimeInterval)videoDuration {
    if (![objects isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<CILRCLIBCandidate *> *candidates = [NSMutableArray array];
    NSUInteger count = MIN(objects.count, CILRCLIBMaximumCandidates);
    for (NSUInteger index = 0; index < count; index++) {
        id object = objects[index];
        if (![object isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *dictionary = object;
        if ([dictionary[@"instrumental"] respondsToSelector:@selector(boolValue)] &&
            [dictionary[@"instrumental"] boolValue]) continue;
        NSString *trackName = CILRCLIBString(dictionary[@"trackName"], 512);
        if (trackName.length == 0) continue;

        double duration = CILRCLIBDouble(dictionary[@"duration"]);
        NSString *plainLyrics = CILRCLIBLyricsString(dictionary[@"plainLyrics"]);
        NSUInteger plainLineCount = CILRCLIBPlainLineCount(plainLyrics);
        if (plainLineCount > CILRCLIBMaximumPlainLines) {
            plainLyrics = @"";
            plainLineCount = 0;
        }
        NSString *syncedLyrics = CILRCLIBLyricsString(dictionary[@"syncedLyrics"]);
        NSArray<CICaptionCue *> *syncedCues = syncedLyrics.length > 0
            ? CILRCLIBUsableCues(syncedLyrics, plainLineCount, videoDuration, duration)
            : @[];
        if (syncedCues.count == 0 && plainLineCount == 0) continue;

        CILRCLIBCandidate *candidate = [CILRCLIBCandidate new];
        candidate.recordID =
            [dictionary[@"id"] respondsToSelector:@selector(integerValue)]
                ? [dictionary[@"id"] integerValue] : 0;
        candidate.trackName = trackName;
        candidate.artistName = CILRCLIBString(dictionary[@"artistName"], 512);
        candidate.albumName = CILRCLIBString(dictionary[@"albumName"], 512);
        candidate.duration = duration > 0 ? duration : 0;
        candidate.durationDifference = videoDuration > 0 && duration > 0
            ? fabs(duration - videoDuration) : DBL_MAX;
        candidate.syncedCues = syncedCues;
        candidate.plainLyrics = plainLyrics;
        [candidates addObject:candidate];
    }
    return candidates;
}

- (CILRCLIBCandidate *)bestCandidateFromObjects:(NSArray *)objects
                                           title:(NSString *)title
                                          artist:(NSString *)artist
                                   videoDuration:(NSTimeInterval)videoDuration {
    if (![objects isKindOfClass:NSArray.class] || objects.count == 0) return nil;
    NSMutableArray<CILRCLIBCandidate *> *candidates = [NSMutableArray array];
    NSUInteger count = MIN(objects.count, CILRCLIBMaximumCandidates);
    for (NSUInteger index = 0; index < count; index++) {
        CILRCLIBCandidate *candidate = [self candidateFromObject:objects[index]
            title:title artist:artist videoDuration:videoDuration];
        if (candidate) [candidates addObject:candidate];
    }
    if (candidates.count == 0) return nil;

    // Prune on the title match alone. Basing this floor on the combined score
    // let a wrong inferred artist drag an otherwise perfect candidate below the
    // cut before the comparator could ever see it — the same failure mode as
    // filtering the query by artist, just one stage later. Artist quality still
    // influences ordering through metadataScore.
    double bestMetadataScore = 0;
    double bestTitleScore = 0;
    double bestArtistScore = 0;
    for (CILRCLIBCandidate *candidate in candidates) {
        bestMetadataScore = MAX(bestMetadataScore, candidate.metadataScore);
        bestTitleScore = MAX(bestTitleScore, candidate.titleScore);
        bestArtistScore = MAX(bestArtistScore, candidate.artistScore);
    }
    // Let the database decide whether the artist is worth filtering on. When
    // some candidate genuinely matches it, the artist is corroborated and
    // pruning on the combined score correctly rejects same-title songs by other
    // performers. When nothing matches, the artist was almost certainly
    // mis-inferred from the upload title — "ウォルピスカーター MV",
    // "HoneyWorks feat.ハコニワリリィ" — and pruning on it would discard the
    // very track being looked for, so fall back to judging the title alone.
    BOOL artistCorroborated =
        artist.length > 0 && bestArtistScore >= 0.70;
    NSIndexSet *outsideFloor;
    if (artistCorroborated) {
        double metadataFloor = MAX(0.70, bestMetadataScore - 0.08);
        outsideFloor = [candidates indexesOfObjectsPassingTest:
            ^BOOL(CILRCLIBCandidate *candidate, __unused NSUInteger index, __unused BOOL *stop) {
                return candidate.metadataScore + DBL_EPSILON < metadataFloor;
            }];
    } else {
        double titleFloor = MAX(0.68, bestTitleScore - 0.08);
        outsideFloor = [candidates indexesOfObjectsPassingTest:
            ^BOOL(CILRCLIBCandidate *candidate, __unused NSUInteger index, __unused BOOL *stop) {
                return candidate.titleScore + DBL_EPSILON < titleFloor;
            }];
    }
    [candidates removeObjectsAtIndexes:outsideFloor];

    NSComparator comparator = ^NSComparisonResult(CILRCLIBCandidate *left,
                                                  CILRCLIBCandidate *right) {
        BOOL leftSynced = left.syncedCues.count > 0;
        BOOL rightSynced = right.syncedCues.count > 0;
        if (videoDuration > 0) {
            // Treat near-identical durations as a tie. LRCLIB often holds
            // several uploads of one song whose lengths differ by well under a
            // second, and only one of them carries a synced timeline: sorting
            // strictly by duration would hand back plain lyrics that happen to
            // be 0.3s closer and throw the synced version away. Beyond this
            // band the duration really does distinguish editions (TV size,
            // full version), so it still decides.
            double difference =
                fabs(left.durationDifference - right.durationDifference);
            if (difference > CILRCLIBDurationTieTolerance) {
                return left.durationDifference < right.durationDifference
                    ? NSOrderedAscending : NSOrderedDescending;
            }
            if (leftSynced != rightSynced) {
                return leftSynced ? NSOrderedAscending : NSOrderedDescending;
            }
        }
        if (left.metadataScore > right.metadataScore) return NSOrderedAscending;
        if (left.metadataScore < right.metadataScore) return NSOrderedDescending;
        if (leftSynced != rightSynced) return leftSynced ? NSOrderedAscending : NSOrderedDescending;
        if (left.recordID < right.recordID) return NSOrderedAscending;
        if (left.recordID > right.recordID) return NSOrderedDescending;
        return NSOrderedSame;
    };
    [candidates sortUsingComparator:comparator];
    CILRCLIBCandidate *closest = candidates.firstObject;

    // Abstain only when there is no duration to judge by.
    //
    // Several performers holding the same title is not itself a reason to give
    // up: covers and re-uploads of one song carry the same words, so picking
    // "the wrong performer" usually still shows the right lyrics. Treating a
    // differing artist as ambiguity meant abstaining on exactly the songs most
    // likely to be watched — "風になる" resolves to a dozen uploads — while
    // protecting against a problem that mostly does not exist.
    //
    // The case that genuinely differs is two *different songs* sharing a title,
    // and those are separated by length, which the comparator already orders on.
    // So whenever the video length is known, let it decide. Without a length
    // there is nothing to choose on, and a same-title-different-song mismatch
    // would go undetected, so keep abstaining there.
    if (!artistCorroborated && videoDuration <= 0 && candidates.count > 1) {
        for (NSUInteger index = 1; index < candidates.count; index++) {
            CILRCLIBCandidate *other = candidates[index];
            if (CILRCLIBFieldSimilarity(
                    closest.trackName,
                    other.trackName
                ) < 0.92) {
                continue;
            }
            NSString *closestArtist =
                CINormalizedText(closest.artistName);
            NSString *otherArtist =
                CINormalizedText(other.artistName);
            if ([closestArtist isEqualToString:otherArtist] ||
                CILRCLIBFieldSimilarity(
                    closest.artistName,
                    other.artistName
                ) >= 0.60) {
                continue;
            }
            // Compare on the title alone, matching the floor used above. An
            // uncorroborated artist was already judged unreliable, so letting
            // its similarity spread two candidates apart here would resurrect
            // the same bad signal the floor just discarded.
            if (fabs(closest.titleScore - other.titleScore) > 0.03) {
                continue;
            }
            // A synced timeline is a meaningful difference in its own right: it
            // is what the feature exists to display, so prefer it rather than
            // treating the pair as a coin flip.
            if ((closest.syncedCues.count > 0) !=
                (other.syncedCues.count > 0)) {
                continue;
            }
            return nil;
        }
    }

    NSArray<CILRCLIBCandidate *> *synced = [candidates filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(CILRCLIBCandidate *candidate,
                                             __unused NSDictionary *bindings) {
            return candidate.syncedCues.count > 0;
        }]];
    synced = [synced sortedArrayUsingComparator:comparator];
    CILRCLIBCandidate *closestSynced = synced.firstObject;
    if (!closestSynced) return closest;
    if (videoDuration <= 0) {
        return closestSynced.metadataScore + 0.05 >= closest.metadataScore
            ? closestSynced : closest;
    }
    double syncedTolerance = MIN(8.0, MAX(3.0, videoDuration * 0.02));
    return closestSynced.durationDifference <= closest.durationDifference + syncedTolerance
        ? closestSynced : closest;
}

- (CILRCLIBResult *)resultFromCandidate:(CILRCLIBCandidate *)candidate
                                  error:(NSError **)error {
    if (!candidate) {
        if (error) *error = CILRCLIBError(404, @"LRCLIB returned no sufficiently close match.");
        return nil;
    }

    CILRCLIBResult *result = [CILRCLIBResult new];
    result.recordID = candidate.recordID;
    result.trackName = candidate.trackName;
    result.artistName = candidate.artistName;
    result.albumName = candidate.albumName;
    result.trackDuration = candidate.duration;
    result.durationDifference = isfinite(candidate.durationDifference) &&
        candidate.durationDifference < DBL_MAX ? candidate.durationDifference : -1;
    result.syncedCues = candidate.syncedCues;
    result.plainLyrics = candidate.plainLyrics;
    return result;
}

- (CILRCLIBResult *)lyricsResultFromSearchData:(NSData *)data
                                          title:(NSString *)title
                                         artist:(NSString *)artist
                                  videoDuration:(NSTimeInterval)videoDuration
                                          error:(NSError **)error {
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![root isKindOfClass:NSArray.class]) {
        if (error && !*error) {
            *error = CILRCLIBError(-5, @"LRCLIB returned malformed search JSON.");
        }
        return nil;
    }
    CILRCLIBCandidate *candidate = [self bestCandidateFromObjects:root
        title:title artist:artist videoDuration:videoDuration];
    return [self resultFromCandidate:candidate error:error];
}

// Two passes over one payload, so widening the search costs no extra request.
//
// The first pass keeps the artist as a ranking signal, which is what correctly
// separates same-title songs by different performers. The second drops it
// entirely, because an artist inferred from an upload title is frequently not a
// performer at all — "Street Fighter 6 Ingrid's Theme", a franchise label, or a
// channel name — and in the first pass such a value can only ever suppress the
// right track. Judging on title plus duration alone is exactly the fallback
// order requested: the ambiguity check still runs in the second pass, so two
// genuinely indistinguishable performances continue to abstain rather than
// guess.
- (CILRCLIBResult *)bestResultFromSearchData:(NSData *)data
                                       title:(NSString *)title
                                      artist:(NSString *)artist
                               videoDuration:(NSTimeInterval)videoDuration
                                       error:(NSError **)error {
    NSError *strictError = nil;
    CILRCLIBResult *strict = [self lyricsResultFromSearchData:data
        title:title artist:artist videoDuration:videoDuration
        error:&strictError];
    if (strict || artist.length == 0) {
        if (error) *error = strictError;
        return strict;
    }
    NSError *permissiveError = nil;
    CILRCLIBResult *permissive = [self lyricsResultFromSearchData:data
        title:title artist:@"" videoDuration:videoDuration
        error:&permissiveError];
    if (error) *error = permissive ? nil : (permissiveError ?: strictError);
    return permissive;
}

// Paired with getURLForTitle:artist:duration: and likewise off the automatic
// path; it stays so that reinstating the exact endpoint does not also mean
// rewriting its safety checks.
- (CILRCLIBResult *)lyricsResultFromExactData:(NSData *)data
                                         title:(NSString *)title
                                        artist:(NSString *)artist
                                 videoDuration:(NSTimeInterval)videoDuration
                                         error:(NSError **)error {
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![root isKindOfClass:NSDictionary.class]) {
        if (error && !*error) {
            *error = CILRCLIBError(-5, @"LRCLIB returned malformed exact-match JSON.");
        }
        return nil;
    }
    CILRCLIBCandidate *candidate = [self bestCandidateFromObjects:@[root]
        title:title artist:artist videoDuration:videoDuration];
    return [self resultFromCandidate:candidate error:error];
}

// A match this good ends the lookup without searching the remaining readings.
//
// The two conditions together are what make it safe: a synced timeline means the
// feature gets what it exists to display, and a length inside the tie tolerance
// means this really is the same edition as the video rather than a TV size or an
// extended cut. Either one alone is not enough — plain lyrics of the right length
// may still be beaten by a synced version under another reading of the title, and
// a synced timeline of the wrong length is exactly the mistake this whole change
// is meant to catch.
- (BOOL)resultIsConclusive:(CILRCLIBResult *)result
                  duration:(NSTimeInterval)duration {
    if (result.syncedCues.count == 0) return NO;
    if (duration <= 0) return YES;
    return result.durationDifference >= 0 &&
        result.durationDifference <= CILRCLIBDurationTieTolerance;
}

// Keeps whichever of two matches is the better answer for this video.
//
// Length decides, because two different songs sharing a title are separated by
// length and nothing else available here separates them. Inside the tie tolerance
// the lengths are saying the same thing, so a synced timeline breaks the tie.
- (void)recordCandidateResult:(CILRCLIBResult *)result
                      context:(CILRCLIBLookupContext *)context
                     reversed:(BOOL)reversed {
    CISongQuery *reading = context.currentCandidate;
    NSString *label = [NSString stringWithFormat:@"%@%@ \"%@\"",
        reading.origin, reversed ? @"/reversed" : @"", reading.title];
    CILRCLIBResult *incumbent = context.bestResult;
    BOOL replaces;
    if (!incumbent) {
        replaces = YES;
    } else if (context.duration <= 0) {
        replaces = incumbent.syncedCues.count == 0 && result.syncedCues.count > 0;
    } else {
        double difference =
            fabs(result.durationDifference - incumbent.durationDifference);
        if (difference > CILRCLIBDurationTieTolerance) {
            replaces = result.durationDifference < incumbent.durationDifference;
        } else {
            replaces = incumbent.syncedCues.count == 0 &&
                result.syncedCues.count > 0;
        }
    }
    if (!replaces) return;
    context.bestResult = result;
    context.bestOrigin = label;
}

// Appends this payload's usable rows to the browse list, ignoring repeats.
//
// One record routinely appears under several readings of the same title, so the
// record id is the identity; without that the list would show the same song three
// times for a title carrying a dash and a quote.
- (void)collectBrowsableMatchesFromData:(NSData *)data
                                context:(CILRCLIBLookupContext *)context {
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:NSArray.class]) return;
    for (CILRCLIBCandidate *candidate in
         [self browsableCandidatesFromObjects:root
                               videoDuration:context.duration]) {
        NSNumber *identity = @(candidate.recordID);
        if (candidate.recordID != 0) {
            if ([context.seenRecordIDs containsObject:identity]) continue;
            [context.seenRecordIDs addObject:identity];
        }
        CILRCLIBResult *result = [self resultFromCandidate:candidate error:nil];
        if (result) [context.allMatches addObject:result];
    }
}

- (void)completeBrowseWithContext:(CILRCLIBLookupContext *)context
                            error:(NSError *)error {
    NSArray<CILRCLIBResult *> *matches = [context.allMatches
        sortedArrayUsingComparator:^NSComparisonResult(CILRCLIBResult *left,
                                                       CILRCLIBResult *right) {
        // Unknown lengths sort last: they are the rows the user can judge least.
        double leftDelta = left.durationDifference < 0
            ? DBL_MAX : left.durationDifference;
        double rightDelta = right.durationDifference < 0
            ? DBL_MAX : right.durationDifference;
        if (leftDelta != rightDelta) {
            return leftDelta < rightDelta
                ? NSOrderedAscending : NSOrderedDescending;
        }
        BOOL leftSynced = left.syncedCues.count > 0;
        BOOL rightSynced = right.syncedCues.count > 0;
        if (leftSynced != rightSynced) {
            return leftSynced ? NSOrderedAscending : NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    void (^completion)(NSArray<CILRCLIBResult *> *, NSError *) =
        context.listCompletion;
    if (!completion) return;
    @synchronized (self) {
        if (context.token != self.requestToken) return;
        completion(matches, matches.count > 0 ? nil : error);
    }
}

// Moves to the next reading, or finishes when the list is spent.
- (void)advanceLookupWithContext:(CILRCLIBLookupContext *)context {
    if (![self isCurrentToken:context.token]) return;
    context.candidateIndex++;
    if (!context.currentCandidate) {
        [self finishLookupWithContext:context];
        return;
    }
    [self startLookupWithContext:context attempt:1];
}

// Ends the lookup with the best match found across every reading.
//
// The result is filed under the first reading's key regardless of which reading
// produced it, so a re-watch is a single cache read. A miss is only recorded once
// every reading has failed, which is what keeps the negative cache from freezing
// one wrong guess in place for twelve hours.
- (void)finishLookupWithContext:(CILRCLIBLookupContext *)context {
    if (context.collectsAllMatches) {
        [self completeBrowseWithContext:context error:nil];
        return;
    }
    CILRCLIBResult *result = context.bestResult;
    if (result) {
        if (context.candidates.count > 1) {
            [CILogStore.sharedStore recordLevel:CILogLevelInfo
                category:@"LRCLIB"
                format:@"Reading %@ won out of %lu: %@ — %@ (%.1fs, delta %.1fs).",
                       context.bestOrigin ?: @"unspecified",
                       (unsigned long)context.candidates.count,
                       result.artistName, result.trackName,
                       result.trackDuration, result.durationDifference];
        }
        [self storeResult:result forCacheKey:context.cacheKey];
        [self completeToken:context.token result:result error:nil
            completion:context.completion];
        return;
    }
    NSError *reason = context.lastError ?:
        CILRCLIBError(404, @"LRCLIB returned no sufficiently close match.");
    if (reason.code == 404 &&
        [reason.domain isEqualToString:CILRCLIBErrorDomain]) {
        [self storeNegativeResultForCacheKey:context.cacheKey];
    }
    [self completeToken:context.token result:nil error:reason
        completion:context.completion];
}

// Ends the lookup on a failure that later readings cannot recover from — a
// network error, a cooldown, a malformed request. Continuing would spend
// rate-limited requests on an endpoint that has already said no. A match already
// banked by an earlier reading is still returned rather than thrown away.
- (void)abortLookupWithContext:(CILRCLIBLookupContext *)context
                         error:(NSError *)error {
    if (context.collectsAllMatches) {
        // Whatever earlier readings already found is still worth showing; the
        // error only stands in when the list is empty.
        [self completeBrowseWithContext:context
                                 error:context.allMatches.count > 0 ? nil : error];
        return;
    }
    if (context.bestResult) {
        [self finishLookupWithContext:context];
        return;
    }
    [self completeToken:context.token result:nil error:error
        completion:context.completion];
}

// Each orientation has two possible requests: q= first, then track_name= only
// when q= explicitly returns no rows. Attempts 1/2 are the reading as written;
// attempts 3/4 are the reversed sides of the first separator-built reading.
// All attempts go through /api/search, never /api/get:
// the metadata endpoint matches track, artist and duration as one AND, so a
// single wrong guess in an artist inferred from an upload title turns the whole
// lookup into a 404. A q= search keeps the artist out of that structured AND
// filter; it remains a ranking signal, which is the only role a guess can safely
// play, while localized album and artist fields remain searchable.
//
// Exhausting an orientation tries the reverse when it is useful, then advances
// to the next reading; see advanceLookupWithContext:.
- (void)performLookupWithContext:(CILRCLIBLookupContext *)context
                         attempt:(NSUInteger)attempt {
    NSUInteger token = context.token;
    if (![self isCurrentToken:token]) return;
    CISongQuery *reading = context.currentCandidate;
    if (!reading) {
        [self finishLookupWithContext:context];
        return;
    }
    NSString *title = reading.title;
    NSString *artist = reading.artist;
    NSTimeInterval duration = context.duration;
    BOOL reversed = attempt >= 3;
    BOOL usesTrackNameFallback = attempt == 2 || attempt == 4;
    NSString *queryTitle = reversed ? artist : title;
    NSString *queryArtist = reversed ? title : artist;
    // Only the committed reading earns a reversed retry. Every later reading is
    // itself an alternative split of the same title, so reversing them too would
    // re-search ground the candidate list already covers, at two seconds a go.
    BOOL canRetryReversed = !reversed && context.candidateIndex == 0 &&
        CILRCLIBReversedQueryIsWorthwhile(title, artist);
    NSURL *URL = usesTrackNameFallback
        ? [self trackNameSearchURLForTitle:queryTitle]
        : [self searchURLForTitle:queryTitle artist:@""];
    if (!URL) {
        [self abortLookupWithContext:context
                              error:CILRCLIBError(-2,
                                  @"Unable to construct the LRCLIB URL.")];
        return;
    }
    NSString *serviceIdentity = CILRCLIBBaseURL();
    @synchronized (self) {
        if (![self.configuredEndpointIdentity
                isEqualToString:serviceIdentity]) {
            self.configuredEndpointIdentity = serviceIdentity;
            self.lastRequestStartUptime = 0;
            self.lastRequestCompletionUptime = 0;
        }
    }

    __weak typeof(self) weakSelf = self;
    void (^responseHandler)(NSData *, NSURLResponse *, NSError *) =
    ^(NSData *data, NSURLResponse *response, NSError *networkError) {
        typeof(self) self = weakSelf;
        if (!self) return;
        NSHTTPURLResponse *HTTPResponse =
            [response isKindOfClass:NSHTTPURLResponse.class]
                ? (NSHTTPURLResponse *)response : nil;
        NSInteger status = HTTPResponse.statusCode;
        BOOL blockedPage =
            [self responseLooksLikeBlockPage:response data:data];
        NSInteger cooldownStatus = status == 429
            ? 429 : (blockedPage ? 403 : 0);
        NSTimeInterval cooldownSeconds = 0;
        if (cooldownStatus > 0) {
            cooldownSeconds = [self recordCooldownForEndpoint:serviceIdentity
                status:cooldownStatus response:HTTPResponse];
        }
        @synchronized (self) {
            NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
            self.lastRequestCompletionUptime =
                MAX(self.lastRequestCompletionUptime, now);
        }
        BOOL shouldHandle;
        @synchronized (self) {
            shouldHandle = token == self.requestToken;
            if (shouldHandle) self.currentTask = nil;
        }
        if (!shouldHandle) return;
        if (cooldownStatus > 0) {
            NSString *description = [NSString stringWithFormat:
                @"LRCLIB HTTP %ld triggered a %.0f-minute cooldown; using YouTube captions instead.",
                (long)cooldownStatus, ceil(cooldownSeconds / 60.0)];
            [self abortLookupWithContext:context
                                  error:CILRCLIBError(cooldownStatus, description)];
            return;
        }
        if (networkError) {
            if (networkError.code != NSURLErrorCancelled) {
                [self abortLookupWithContext:context error:networkError];
            }
            return;
        }
        if ((status >= 200 && status < 300) || status == 404) {
            [self clearCooldownForEndpoint:serviceIdentity];
        }
        // A genuinely empty q= response gets one structured track_name= retry
        // for the same reading. A non-empty response that merely fails local
        // scoring does not: repeating it would spend a request without widening
        // the data. After both modes, try the reversed primary reading, then the
        // next candidate. Only the end of the whole chain records a miss.
        void (^completeExhausted)(NSError *, BOOL) =
        ^(NSError *reason, BOOL responseHadNoRows) {
            if (reason.code == 404 &&
                [reason.domain isEqualToString:CILRCLIBErrorDomain] &&
                !context.lastError) {
                context.lastError = reason;
            }
            if (responseHadNoRows && !usesTrackNameFallback) {
                [self startLookupWithContext:context attempt:attempt + 1];
                return;
            }
            if (canRetryReversed) {
                [self startLookupWithContext:context attempt:3];
                return;
            }
            [self advanceLookupWithContext:context];
        };

        NSError *responseError = [self responseErrorForResponse:response data:data];
        if (responseError) {
            if (responseError.code == 404) {
                completeExhausted(responseError, YES);
            } else {
                [self abortLookupWithContext:context error:responseError];
            }
            return;
        }
        id responseRoot = [NSJSONSerialization JSONObjectWithData:data
            options:0 error:nil];
        BOOL responseHadNoRows =
            [responseRoot isKindOfClass:NSArray.class] &&
            [(NSArray *)responseRoot count] == 0;
        if (responseHadNoRows) {
            completeExhausted(CILRCLIBError(404,
                @"LRCLIB returned no rows for this query."), YES);
            return;
        }
        if (context.collectsAllMatches) {
            [self collectBrowsableMatchesFromData:data context:context];
            [self advanceLookupWithContext:context];
            return;
        }
        NSError *parseError = nil;
        CILRCLIBResult *result = [self bestResultFromSearchData:data
            title:queryTitle artist:queryArtist videoDuration:duration
            error:&parseError];
        if (result) {
            [self recordCandidateResult:result
                                context:context
                               reversed:reversed];
            // A synced timeline whose length all but matches the video is proof
            // enough. Searching the remaining readings could only find something
            // equally good, at two rate-limited seconds each.
            if ([self resultIsConclusive:result duration:duration]) {
                [self finishLookupWithContext:context];
                return;
            }
            completeExhausted(CILRCLIBError(404,
                @"Match kept as a fallback; still checking the other readings of the title."),
                NO);
            return;
        }
        completeExhausted(parseError ?:
            CILRCLIBError(-5, @"Unable to parse LRCLIB response."), NO);
    };
    BOOL shouldStart = NO;
    BOOL rateLimited = NO;
    BOOL taskCreationFailed = NO;
    NSTimeInterval remainingDelay = 0;
    @synchronized (self) {
        if (token == self.requestToken) {
            NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
            rateLimited =
                [self cooldownRemainingForEndpoint:serviceIdentity] > 0;
            remainingDelay = MAX(
                self.lastRequestStartUptime + CILRCLIBMinimumRequestInterval,
                self.lastRequestCompletionUptime + CILRCLIBMinimumCompletionInterval) - now;
            if (!rateLimited && remainingDelay <= 0) {
                NSURLSessionDataTask *task = [self.session
                    dataTaskWithRequest:[self requestForURL:URL]
                    completionHandler:responseHandler];
                if (task) {
                    shouldStart = YES;
                    self.currentTask = task;
                    self.lastRequestStartUptime = now;
                    [task resume];
                } else {
                    taskCreationFailed = YES;
                }
            }
        }
    }
    if (!shouldStart) {
        if (rateLimited) {
            NSTimeInterval remaining =
                [self cooldownRemainingForEndpoint:serviceIdentity];
            [self abortLookupWithContext:context
                error:CILRCLIBError(429, [NSString stringWithFormat:
                    @"LRCLIB cooldown is active for another %.0f minute(s); using YouTube captions instead.",
                    ceil(remaining / 60.0)])];
        } else if (taskCreationFailed) {
            [self abortLookupWithContext:context
                error:CILRCLIBError(-3, @"Unable to create the LRCLIB request task.")];
        } else if ([self isCurrentToken:token] && remainingDelay > 0) {
            [self startLookupWithContext:context attempt:attempt];
        }
        return;
    }
}

- (void)startLookupWithContext:(CILRCLIBLookupContext *)context
                       attempt:(NSUInteger)attempt {
    NSUInteger token = context.token;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSTimeInterval delay;
    @synchronized (self) {
        if (token != self.requestToken) return;
        NSTimeInterval earliest = MAX(
            self.lastRequestStartUptime + CILRCLIBMinimumRequestInterval,
            self.lastRequestCompletionUptime + CILRCLIBMinimumCompletionInterval);
        delay = MAX(0, earliest - now);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTimeInterval remainingDelay;
        BOOL shouldStart;
        @synchronized (self) {
            shouldStart = token == self.requestToken;
            NSTimeInterval currentUptime = NSProcessInfo.processInfo.systemUptime;
            NSTimeInterval earliest = MAX(
                self.lastRequestStartUptime + CILRCLIBMinimumRequestInterval,
                self.lastRequestCompletionUptime + CILRCLIBMinimumCompletionInterval);
            remainingDelay = MAX(0, earliest - currentUptime);
        }
        if (!shouldStart) return;
        if (remainingDelay > 0) {
            [self startLookupWithContext:context attempt:attempt];
            return;
        }
        [self performLookupWithContext:context attempt:attempt];
    });
}

- (void)fetchLyricsForTitle:(NSString *)title
                     artist:(NSString *)artist
                   duration:(NSTimeInterval)duration
                 completion:(CILRCLIBCompletion)completion {
    [self fetchLyricsForCandidates:@[
        [CISongQuery queryWithTitle:title ?: @""
                            artist:artist ?: @""
                            origin:@"committed"],
    ] duration:duration completion:completion];
}

// Cleans a caller's readings and derives the lookup identity they share.
//
// Both entry points must agree on the cache key or a pinned choice would be
// filed where the playback lookup never looks, so the derivation lives here once.
- (nullable CILRCLIBLookupContext *)contextForCandidates:
                                        (NSArray<CISongQuery *> *)candidates
                                              duration:(NSTimeInterval)duration
                                                 token:(NSUInteger)token {
    CISongQuery *primary = candidates.firstObject;
    NSString *cleanTitle =
        CILRCLIBString(CICleanCaptionText(primary.title), 512);
    NSString *cleanArtist =
        CILRCLIBString(CICleanCaptionText(primary.artist), 512);
    if (cleanTitle.length == 0) return nil;
    NSMutableArray<CISongQuery *> *readings =
        [NSMutableArray arrayWithCapacity:candidates.count];
    for (CISongQuery *candidate in candidates) {
        NSString *readingTitle =
            CILRCLIBString(CICleanCaptionText(candidate.title), 512);
        if (readingTitle.length == 0) continue;
        if (readings.count >= CISongQueryMaximumCandidates) break;
        [readings addObject:[CISongQuery queryWithTitle:readingTitle
            artist:CILRCLIBString(CICleanCaptionText(candidate.artist), 512)
            origin:candidate.origin]];
    }
    if (readings.count == 0) return nil;

    CILRCLIBLookupContext *context = [CILRCLIBLookupContext new];
    context.candidates = readings;
    context.candidateIndex = 0;
    context.duration = duration;
    context.token = token;
    context.cacheKey = [self cacheKeyForTitle:cleanTitle
        artist:cleanArtist duration:duration
        exact:cleanArtist.length > 0
        endpointIdentity:CILRCLIBBaseURL()];
    return context;
}

- (void)fetchAllMatchesForCandidates:(NSArray<CISongQuery *> *)candidates
                            duration:(NSTimeInterval)duration
                          completion:
    (void (^)(NSArray<CILRCLIBResult *> *, NSError * _Nullable))completion {
    NSUInteger token;
    @synchronized (self) {
        self.requestToken++;
        [self.currentTask cancel];
        self.currentTask = nil;
        token = self.requestToken;
    }
    CILRCLIBLookupContext *context =
        [self contextForCandidates:candidates duration:duration token:token];
    if (!context) {
        completion(@[], CILRCLIBError(-1, @"A song title is required."));
        return;
    }
    NSTimeInterval cooldown =
        [self cooldownRemainingForEndpoint:CILRCLIBBaseURL()];
    if (cooldown > 0) {
        completion(@[], CILRCLIBError(429, [NSString stringWithFormat:
            @"LRCLIB cooldown is active for another %.0f minute(s).",
            ceil(cooldown / 60.0)]));
        return;
    }
    context.collectsAllMatches = YES;
    context.allMatches = [NSMutableArray array];
    context.seenRecordIDs = [NSMutableSet set];
    context.listCompletion = completion;
    [self startLookupWithContext:context attempt:1];
}

- (void)pinResult:(CILRCLIBResult *)result
    forCandidates:(NSArray<CISongQuery *> *)candidates
         duration:(NSTimeInterval)duration {
    if (!result) return;
    CILRCLIBLookupContext *context =
        [self contextForCandidates:candidates duration:duration token:0];
    if (!context) return;
    [self storeResult:result forCacheKey:context.cacheKey];
    [CILogStore.sharedStore recordLevel:CILogLevelInfo
        category:@"LRCLIB"
        format:@"User pinned record #%ld (%@ — %@) for this video; the automatic lookup will now find it in the cache.",
               (long)result.recordID, result.artistName, result.trackName];
}

- (void)fetchLyricsForCandidates:(NSArray<CISongQuery *> *)candidates
                        duration:(NSTimeInterval)duration
                      completion:(CILRCLIBCompletion)completion {
    NSUInteger token;
    @synchronized (self) {
        self.requestToken++;
        [self.currentTask cancel];
        self.currentTask = nil;
        token = self.requestToken;
    }
    CILRCLIBLookupContext *context =
        [self contextForCandidates:candidates duration:duration token:token];
    if (!context) {
        [self completeToken:token result:nil
            error:CILRCLIBError(-1, @"A song title is required.")
            completion:completion];
        return;
    }
    context.completion = completion;

    BOOL negativeHit = NO;
    CILRCLIBResult *cached =
        [self cachedResultForKey:context.cacheKey negativeHit:&negativeHit];
    if (cached) {
        [self completeToken:token result:cached error:nil
            completion:completion];
        return;
    }
    if (negativeHit) {
        [self completeToken:token result:nil
            error:CILRCLIBError(404,
                @"LRCLIB negative cache hit; the network request was skipped.")
            completion:completion];
        return;
    }
    NSTimeInterval cooldown =
        [self cooldownRemainingForEndpoint:CILRCLIBBaseURL()];
    if (cooldown > 0) {
        [self completeToken:token result:nil
            error:CILRCLIBError(429, [NSString stringWithFormat:
                @"LRCLIB cooldown is active for another %.0f minute(s); the network request was skipped.",
                ceil(cooldown / 60.0)])
            completion:completion];
        return;
    }
    // Readings are searched one at a time and every request goes through the same
    // rate limiter, so a lookup cannot fan out into a burst no matter how many
    // readings a title produces. The common case still costs a single request:
    // the committed reading leads, and a synced match of the right length ends
    // the search immediately.
    [self startLookupWithContext:context attempt:1];
}

@end
