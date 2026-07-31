#import "CILRCLIBProvider.h"
#import "CICaptionParser.h"
#import "CITextUtilities.h"
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
static const NSTimeInterval CILRCLIBPositiveCacheLifetime = 30 * 24 * 60 * 60;
static const NSTimeInterval CILRCLIBNegativeCacheLifetime = 12 * 60 * 60;
static const NSTimeInterval CILRCLIBDefaultRateLimitCooldown = 15 * 60;
static const NSTimeInterval CILRCLIBInitialBlockCooldown = 60 * 60;
static const NSTimeInterval CILRCLIBMaximumBlockCooldown = 24 * 60 * 60;
static const NSUInteger CILRCLIBMaximumCacheEntries = 32;
static const NSUInteger CILRCLIBMaximumCacheBytes = 8 * 1024 * 1024;
static NSString *const CILRCLIBCooldownDefaultsKey =
    @"CaptionIsland.LRCLIBCooldowns";
static NSString *const CILRCLIBCacheKindResult = @"result";
static NSString *const CILRCLIBCacheKindMiss = @"miss";
static NSUInteger CILRCLIBPersistentCacheGeneration = 1;

static NSError *CILRCLIBError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:CILRCLIBErrorDomain code:code userInfo:@{
        NSLocalizedDescriptionKey: description ?: @"LRCLIB request failed."
    }];
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

static NSString *CILRCLIBCachePath(void) {
#if TARGET_OS_OSX
    return [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            @"CaptionIsland-LRCLIBCache-tests.plist"];
#else
    NSString *caches = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (caches.length == 0) return @"";
    NSString *directory =
        [caches stringByAppendingPathComponent:@"CaptionIsland"];
    return [directory stringByAppendingPathComponent:@"LRCLIBCache.plist"];
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
@property (nonatomic, copy) NSArray<CICaptionCue *> *syncedCues;
@property (nonatomic, copy) NSString *plainLyrics;
@end

@implementation CILRCLIBCandidate
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

@implementation CILRCLIBProvider

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
    [self.persistentCacheEntries
        addEntriesFromDictionary:root[@"entries"]];
}

- (NSData *)persistentCacheDataLocked {
    NSDictionary *root = @{
        @"version": @1,
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
    [data writeToFile:path options:NSDataWritingAtomic error:nil];
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
        if ([entry[@"expiresAt"] doubleValue] <= now) {
            [self.persistentCacheEntries removeObjectForKey:key];
            [self writePersistentCacheLocked];
            return nil;
        }
        if ([entry[@"kind"] isEqual:CILRCLIBCacheKindMiss]) {
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
        NSTimeInterval expires =
            NSDate.date.timeIntervalSince1970 + CILRCLIBPositiveCacheLifetime;
        self.persistentCacheEntries[key] =
            [self cacheEntryForResult:result expires:expires];
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

- (NSURL *)searchURLForTitle:(NSString *)title artist:(NSString *)artist broad:(BOOL)broad {
    NSURLComponents *components = [NSURLComponents
        componentsWithURL:CILRCLIBSearchEndpointURL()
        resolvingAgainstBaseURL:NO];
    if (broad) {
        NSString *query = artist.length > 0
            ? [NSString stringWithFormat:@"%@ %@", artist, title] : title;
        components.queryItems = @[
            [NSURLQueryItem queryItemWithName:@"q" value:query],
        ];
    } else {
        NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray arrayWithObject:
            [NSURLQueryItem queryItemWithName:@"track_name" value:title]];
        if (artist.length > 0) {
            [items addObject:[NSURLQueryItem queryItemWithName:@"artist_name" value:artist]];
        }
        components.queryItems = items;
    }
    return components.URL;
}

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
    if (artist.length > 0 && artistScore < 0.42) return nil;

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
    candidate.syncedCues = syncedCues;
    candidate.plainLyrics = plainLyrics;
    return candidate;
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

    double bestMetadataScore = 0;
    for (CILRCLIBCandidate *candidate in candidates) {
        bestMetadataScore = MAX(bestMetadataScore, candidate.metadataScore);
    }
    double metadataFloor = MAX(0.70, bestMetadataScore - 0.08);
    NSIndexSet *outsideFloor = [candidates indexesOfObjectsPassingTest:
        ^BOOL(CILRCLIBCandidate *candidate, __unused NSUInteger index, __unused BOOL *stop) {
            return candidate.metadataScore + DBL_EPSILON < metadataFloor;
        }];
    [candidates removeObjectsAtIndexes:outsideFloor];

    NSComparator comparator = ^NSComparisonResult(CILRCLIBCandidate *left,
                                                  CILRCLIBCandidate *right) {
        if (videoDuration > 0) {
            if (left.durationDifference < right.durationDifference) return NSOrderedAscending;
            if (left.durationDifference > right.durationDifference) return NSOrderedDescending;
        }
        if (left.metadataScore > right.metadataScore) return NSOrderedAscending;
        if (left.metadataScore < right.metadataScore) return NSOrderedDescending;
        BOOL leftSynced = left.syncedCues.count > 0;
        BOOL rightSynced = right.syncedCues.count > 0;
        if (leftSynced != rightSynced) return leftSynced ? NSOrderedAscending : NSOrderedDescending;
        if (left.recordID < right.recordID) return NSOrderedAscending;
        if (left.recordID > right.recordID) return NSOrderedDescending;
        return NSOrderedSame;
    };
    [candidates sortUsingComparator:comparator];
    CILRCLIBCandidate *closest = candidates.firstObject;

    if (artist.length == 0 && candidates.count > 1) {
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
            if (fabs(closest.metadataScore -
                     other.metadataScore) > 0.03) {
                continue;
            }
            if (videoDuration > 0 &&
                other.durationDifference >
                    closest.durationDifference + 8.0) {
                continue;
            }
            // With no reliable artist, two near-identical titles from
            // different singers at comparable durations are genuinely
            // ambiguous. Prefer a YouTube fallback or a per-video override
            // instead of silently selecting the wrong performance.
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

- (void)performLookupForTitle:(NSString *)title
                       artist:(NSString *)artist
                     duration:(NSTimeInterval)duration
                        exact:(BOOL)exact
                        token:(NSUInteger)token
                     cacheKey:(NSString *)cacheKey
                   completion:(CILRCLIBCompletion)completion {
    if (![self isCurrentToken:token]) return;
    NSURL *URL = exact
        ? [self getURLForTitle:title artist:artist duration:duration]
        : [self searchURLForTitle:title artist:@"" broad:YES];
    if (!URL) {
        [self completeToken:token result:nil
            error:CILRCLIBError(-2, @"Unable to construct the LRCLIB URL.")
            completion:completion];
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
            [self completeToken:token result:nil
                error:CILRCLIBError(cooldownStatus, description)
                completion:completion];
            return;
        }
        if (networkError) {
            if (networkError.code != NSURLErrorCancelled) {
                [self completeToken:token result:nil error:networkError completion:completion];
            }
            return;
        }
        if ((status >= 200 && status < 300) || status == 404) {
            [self clearCooldownForEndpoint:serviceIdentity];
        }
        NSError *responseError = [self responseErrorForResponse:response data:data];
        if (responseError) {
            if (responseError.code == 404) {
                [self storeNegativeResultForCacheKey:cacheKey];
            }
            [self completeToken:token result:nil error:responseError completion:completion];
            return;
        }
        NSError *parseError = nil;
        CILRCLIBResult *result = exact
            ? [self lyricsResultFromExactData:data title:title artist:artist
                videoDuration:duration error:&parseError]
            : [self lyricsResultFromSearchData:data title:title artist:@""
                videoDuration:duration error:&parseError];
        if (result) {
            [self storeResult:result forCacheKey:cacheKey];
        } else if ([parseError.domain isEqualToString:CILRCLIBErrorDomain] &&
                   parseError.code == 404) {
            [self storeNegativeResultForCacheKey:cacheKey];
        }
        [self completeToken:token result:result
            error:parseError ?: (result ? nil :
                CILRCLIBError(-5, @"Unable to parse LRCLIB response."))
            completion:completion];
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
            [self completeToken:token result:nil
                error:CILRCLIBError(429, [NSString stringWithFormat:
                    @"LRCLIB cooldown is active for another %.0f minute(s); using YouTube captions instead.",
                    ceil(remaining / 60.0)])
                completion:completion];
        } else if (taskCreationFailed) {
            [self completeToken:token result:nil
                error:CILRCLIBError(-3, @"Unable to create the LRCLIB request task.")
                completion:completion];
        } else if ([self isCurrentToken:token] && remainingDelay > 0) {
            [self startLookupForTitle:title artist:artist duration:duration
                exact:exact token:token cacheKey:cacheKey
                completion:completion];
        }
        return;
    }
}

- (void)startLookupForTitle:(NSString *)title
                     artist:(NSString *)artist
                   duration:(NSTimeInterval)duration
                      exact:(BOOL)exact
                      token:(NSUInteger)token
                   cacheKey:(NSString *)cacheKey
                 completion:(CILRCLIBCompletion)completion {
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
            [self startLookupForTitle:title artist:artist duration:duration
                exact:exact token:token cacheKey:cacheKey
                completion:completion];
            return;
        }
        [self performLookupForTitle:title artist:artist duration:duration
            exact:exact token:token cacheKey:cacheKey
            completion:completion];
    });
}

- (void)fetchLyricsForTitle:(NSString *)title
                     artist:(NSString *)artist
                   duration:(NSTimeInterval)duration
                 completion:(CILRCLIBCompletion)completion {
    NSString *cleanTitle = CILRCLIBString(CICleanCaptionText(title), 512);
    NSString *cleanArtist = CILRCLIBString(CICleanCaptionText(artist), 512);
    NSUInteger token;
    @synchronized (self) {
        self.requestToken++;
        [self.currentTask cancel];
        self.currentTask = nil;
        token = self.requestToken;
    }
    if (cleanTitle.length == 0) {
        [self completeToken:token result:nil
            error:CILRCLIBError(-1, @"A song title is required.")
            completion:completion];
        return;
    }
    BOOL exact = cleanArtist.length > 0;
    NSString *serviceIdentity = CILRCLIBBaseURL();
    NSString *cacheKey = [self cacheKeyForTitle:cleanTitle
        artist:cleanArtist duration:duration exact:exact
        endpointIdentity:serviceIdentity];
    BOOL negativeHit = NO;
    CILRCLIBResult *cached =
        [self cachedResultForKey:cacheKey negativeHit:&negativeHit];
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
        [self cooldownRemainingForEndpoint:serviceIdentity];
    if (cooldown > 0) {
        [self completeToken:token result:nil
            error:CILRCLIBError(429, [NSString stringWithFormat:
                @"LRCLIB cooldown is active for another %.0f minute(s); the network request was skipped.",
                ceil(cooldown / 60.0)])
            completion:completion];
        return;
    }
    // A trustworthy artist allows LRCLIB's metadata endpoint to perform one
    // duration-aware exact lookup. Without one, perform one keyword search and
    // let the local scorer reject ambiguous singers; never expand a playback
    // lookup into multiple automatic requests.
    [self startLookupForTitle:cleanTitle artist:cleanArtist duration:duration
        exact:exact token:token cacheKey:cacheKey completion:completion];
}

@end
