#import "CILRCLIBProvider.h"
#import "CICaptionParser.h"
#import "CITextUtilities.h"
#import <float.h>
#import <math.h>

static NSString *const CILRCLIBErrorDomain = @"CaptionIsland.LRCLIB";
static NSString *const CILRCLIBSearchEndpoint = @"https://lrclib.net/api/search";
static NSString *const CILRCLIBUserAgent =
    @"CaptionIsland/1.0 (+https://github.com/iervn6341-ovo/uYouEnhanced-build)";
static const NSUInteger CILRCLIBMaximumResponseBytes = 2 * 1024 * 1024;
static const NSUInteger CILRCLIBMaximumLyricsCharacters = 512 * 1024;
static const NSUInteger CILRCLIBMaximumCandidates = 20;
static const NSUInteger CILRCLIBMaximumSyncedCues = 5000;
static const NSUInteger CILRCLIBMaximumPlainLines = 1000;
static const NSUInteger CILRCLIBMaximumLyricLineCharacters = 2048;
static const NSTimeInterval CILRCLIBMinimumRequestInterval = 0.35;
static const NSTimeInterval CILRCLIBMinimumCompletionInterval = 0.20;

static NSError *CILRCLIBError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:CILRCLIBErrorDomain code:code userInfo:@{
        NSLocalizedDescriptionKey: description ?: @"LRCLIB request failed."
    }];
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
@property (nonatomic) NSTimeInterval blockedUntilUptime;
@property (nonatomic) NSTimeInterval lastRequestStartUptime;
@property (nonatomic) NSTimeInterval lastRequestCompletionUptime;
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

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *configuration =
            NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = 6.0;
        configuration.timeoutIntervalForResource = 8.0;
        configuration.HTTPMaximumConnectionsPerHost = 1;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.URLCache = nil;
        configuration.HTTPCookieStorage = nil;
        configuration.HTTPShouldSetCookies = NO;
        _session = [NSURLSession sessionWithConfiguration:configuration];
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
    NSURLComponents *components = [NSURLComponents componentsWithString:CILRCLIBSearchEndpoint];
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

- (NSMutableURLRequest *)requestForURL:(NSURL *)URL {
    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:URL
           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
       timeoutInterval:6.0];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:CILRCLIBUserAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:CILRCLIBUserAgent forHTTPHeaderField:@"Lrclib-Client"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    return request;
}

- (NSError *)responseErrorForResponse:(NSURLResponse *)response data:(NSData *)data {
    if ([response isKindOfClass:NSHTTPURLResponse.class]) {
        NSHTTPURLResponse *HTTPResponse = (NSHTTPURLResponse *)response;
        if (HTTPResponse.statusCode < 200 || HTTPResponse.statusCode >= 300) {
            NSString *description = HTTPResponse.statusCode == 429
                ? @"LRCLIB rate limit reached; Retry-After will be honored."
                : @"LRCLIB returned an HTTP error.";
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
        double maximumDifference = MAX(45.0, videoDuration * 0.25);
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

- (CILRCLIBResult *)lyricsResultFromSearchData:(NSData *)data
                                          title:(NSString *)title
                                         artist:(NSString *)artist
                                  videoDuration:(NSTimeInterval)videoDuration
                                          error:(NSError **)error {
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![root isKindOfClass:NSArray.class]) {
        if (error && !*error) *error = CILRCLIBError(-5, @"LRCLIB returned malformed JSON.");
        return nil;
    }
    CILRCLIBCandidate *candidate = [self bestCandidateFromObjects:root title:title
        artist:artist videoDuration:videoDuration];
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

- (void)performSearchForTitle:(NSString *)title
                       artist:(NSString *)artist
                     duration:(NSTimeInterval)duration
                        broad:(BOOL)broad
                        token:(NSUInteger)token
                   completion:(CILRCLIBCompletion)completion {
    if (![self isCurrentToken:token]) return;
    NSURL *URL = [self searchURLForTitle:title artist:artist broad:broad];
    if (!URL) {
        [self completeToken:token result:nil
            error:CILRCLIBError(-2, @"Unable to construct the LRCLIB URL.")
            completion:completion];
        return;
    }

    __weak typeof(self) weakSelf = self;
    void (^responseHandler)(NSData *, NSURLResponse *, NSError *) =
    ^(NSData *data, NSURLResponse *response, NSError *networkError) {
        typeof(self) self = weakSelf;
        if (!self) return;
        NSHTTPURLResponse *HTTPResponse =
            [response isKindOfClass:NSHTTPURLResponse.class]
                ? (NSHTTPURLResponse *)response : nil;
        NSURLSessionDataTask *taskToCancelForRateLimit = nil;
        @synchronized (self) {
            NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
            self.lastRequestCompletionUptime =
                MAX(self.lastRequestCompletionUptime, now);
            if (HTTPResponse.statusCode == 429) {
                NSString *value = [HTTPResponse valueForHTTPHeaderField:@"Retry-After"];
                NSTimeInterval seconds = [value respondsToSelector:@selector(doubleValue)]
                    ? [value doubleValue] : 60.0;
                if (!isfinite(seconds) || seconds <= 0) seconds = 60.0;
                self.blockedUntilUptime =
                    MAX(self.blockedUntilUptime, now + seconds);
                if (token != self.requestToken) {
                    taskToCancelForRateLimit = self.currentTask;
                }
            }
        }
        [taskToCancelForRateLimit cancel];
        BOOL shouldHandle;
        @synchronized (self) {
            shouldHandle = token == self.requestToken;
            if (shouldHandle) self.currentTask = nil;
        }
        if (!shouldHandle) return;
        if (networkError) {
            if (networkError.code == NSURLErrorCancelled) {
                BOOL blocked;
                @synchronized (self) {
                    blocked = NSProcessInfo.processInfo.systemUptime <
                        self.blockedUntilUptime;
                }
                if (blocked) {
                    [self completeToken:token result:nil
                        error:CILRCLIBError(429,
                            @"LRCLIB Retry-After period is still active.")
                        completion:completion];
                }
            } else {
                [self completeToken:token result:nil error:networkError completion:completion];
            }
            return;
        }
        NSError *responseError = [self responseErrorForResponse:response data:data];
        if (responseError) {
            [self completeToken:token result:nil error:responseError completion:completion];
            return;
        }
        NSError *parseError = nil;
        CILRCLIBResult *result = [self lyricsResultFromSearchData:data title:title
            artist:artist videoDuration:duration error:&parseError];
        if (result || broad) {
            [self completeToken:token result:result error:parseError completion:completion];
            return;
        }
        BOOL shouldTryBroad = [parseError.domain isEqualToString:CILRCLIBErrorDomain] &&
            parseError.code == 404;
        if (!shouldTryBroad) {
            [self completeToken:token result:nil
                error:parseError ?: CILRCLIBError(-5, @"Unable to parse LRCLIB response.")
                completion:completion];
            return;
        }
        [self startSearchForTitle:title artist:artist duration:duration broad:YES
            token:token completion:completion];
    };
    BOOL shouldStart = NO;
    BOOL rateLimited = NO;
    BOOL taskCreationFailed = NO;
    NSTimeInterval remainingDelay = 0;
    @synchronized (self) {
        if (token == self.requestToken) {
            NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
            rateLimited = now < self.blockedUntilUptime;
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
            [self completeToken:token result:nil
                error:CILRCLIBError(429, @"LRCLIB Retry-After period is still active.")
                completion:completion];
        } else if (taskCreationFailed) {
            [self completeToken:token result:nil
                error:CILRCLIBError(-3, @"Unable to create the LRCLIB request task.")
                completion:completion];
        } else if ([self isCurrentToken:token] && remainingDelay > 0) {
            [self startSearchForTitle:title artist:artist duration:duration
                broad:broad token:token completion:completion];
        }
        return;
    }
}

- (void)startSearchForTitle:(NSString *)title
                     artist:(NSString *)artist
                   duration:(NSTimeInterval)duration
                      broad:(BOOL)broad
                      token:(NSUInteger)token
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
            [self startSearchForTitle:title artist:artist duration:duration
                broad:broad token:token completion:completion];
            return;
        }
        [self performSearchForTitle:title artist:artist duration:duration
            broad:broad token:token completion:completion];
    });
}

- (void)fetchLyricsForTitle:(NSString *)title
                     artist:(NSString *)artist
                   duration:(NSTimeInterval)duration
                 completion:(CILRCLIBCompletion)completion {
    NSString *cleanTitle = CILRCLIBString(CICleanCaptionText(title), 512);
    NSString *cleanArtist = CILRCLIBString(CICleanCaptionText(artist), 512);
    BOOL blocked;
    NSUInteger token;
    @synchronized (self) {
        self.requestToken++;
        [self.currentTask cancel];
        self.currentTask = nil;
        token = self.requestToken;
        blocked = NSProcessInfo.processInfo.systemUptime < self.blockedUntilUptime;
    }
    if (cleanTitle.length == 0) {
        [self completeToken:token result:nil
            error:CILRCLIBError(-1, @"A song title is required.")
            completion:completion];
        return;
    }
    if (blocked) {
        [self completeToken:token result:nil
            error:CILRCLIBError(429, @"LRCLIB Retry-After period is still active.")
            completion:completion];
        return;
    }
    // With no trustworthy artist metadata, mirror LRCLIB's keyword search.
    // This is the same query mode used by its web search and exposes records
    // that a track_name-only response may omit from its 20-result limit.
    BOOL titleOnlySearch = cleanArtist.length == 0;
    [self startSearchForTitle:cleanTitle artist:cleanArtist duration:duration
        broad:titleOnlySearch
        token:token completion:completion];
}

@end
