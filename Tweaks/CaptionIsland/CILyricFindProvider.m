#import "CILyricFindProvider.h"
#import "CITextUtilities.h"
#import <math.h>

static NSString *const CIProviderErrorDomain = @"CaptionIsland.LyricFind";
static NSString *const CILyricFindEndpoint = @"https://api.lyricfind.com/lyric.do";
static const NSUInteger CIMaxLyricResponseBytes = 2 * 1024 * 1024;
static const NSUInteger CIMaxLyricLines = 5000;

static NSError *CIValidateProviderResponse(NSURLResponse *response, NSData *data) {
    if ([response isKindOfClass:NSHTTPURLResponse.class]) {
        NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
        if (status < 200 || status >= 300) {
            return [NSError errorWithDomain:CIProviderErrorDomain code:status userInfo:@{
                NSLocalizedDescriptionKey: @"The lyrics provider returned an HTTP error."
            }];
        }
    }
    if (data.length == 0 || data.length > CIMaxLyricResponseBytes) {
        return [NSError errorWithDomain:CIProviderErrorDomain code:-4 userInfo:@{
            NSLocalizedDescriptionKey: data.length == 0
                ? @"LyricFind returned an empty response."
                : @"The LyricFind response was unexpectedly large."
        }];
    }
    return nil;
}

static double CIDoubleValue(id value) {
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : NAN;
}

static NSString *CIRequiredString(id value) {
    if (![value isKindOfClass:NSString.class]) return @"";
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *CISafeIdentifierValue(NSString *value) {
    NSString *clean = CICleanCaptionText(value);
    clean = [clean stringByReplacingOccurrencesOfString:@":" withString:@";"];
    clean = [clean stringByReplacingOccurrencesOfString:@"," withString:@";"];
    return clean.length > 0 ? clean : @"Unknown";
}

static NSError *CIProviderError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:CIProviderErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description ?: @"LyricFind request failed."}];
}

@interface CILyricFindProvider ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *currentTask;
@end

@implementation CILyricsResult

- (instancetype)init {
    self = [super init];
    if (self) {
        _syncedCues = @[];
        _plainLyrics = @"";
        _copyrightNotice = @"";
        _writerCredit = @"";
    }
    return self;
}

@end

@implementation CILyricFindProvider

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
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

- (void)cancel {
    [self.currentTask cancel];
    self.currentTask = nil;
}

- (void)dealloc {
    [self.session invalidateAndCancel];
}

- (NSData *)requestBodyForTitle:(NSString *)title
                         artist:(NSString *)artist
                  displayAPIKey:(NSString *)displayAPIKey
                         LRCKey:(NSString *)LRCKey
                      territory:(NSString *)territory {
    NSString *trackID = [NSString stringWithFormat:@"artistname:%@,trackname:%@",
        CISafeIdentifierValue(artist), CISafeIdentifierValue(title)];
    NSMutableArray<NSURLQueryItem *> *items = [@[
        [NSURLQueryItem queryItemWithName:@"apikey" value:displayAPIKey],
        [NSURLQueryItem queryItemWithName:@"territory" value:territory],
        [NSURLQueryItem queryItemWithName:@"reqtype" value:@"default"],
        [NSURLQueryItem queryItemWithName:@"trackid" value:trackID],
        [NSURLQueryItem queryItemWithName:@"output" value:@"json"]
    ] mutableCopy];
    if (LRCKey.length > 0) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"lrckey" value:LRCKey]];
        // "lrc" returns line-synced data when available and otherwise returns
        // the licensed static lyric in the same request.
        [items addObject:[NSURLQueryItem queryItemWithName:@"format" value:@"lrc"]];
    }
    NSURLComponents *form = [NSURLComponents new];
    form.queryItems = items;
    return [form.percentEncodedQuery dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSArray<CICaptionCue *> *)cuesFromLRCObjects:(NSArray *)objects
                                       duration:(NSTimeInterval)videoDuration {
    if (![objects isKindOfClass:NSArray.class] || objects.count == 0) return @[];
    NSMutableArray<CICaptionCue *> *cues = [NSMutableArray arrayWithCapacity:MIN(objects.count, CIMaxLyricLines)];
    for (id object in objects) {
        if (cues.count >= CIMaxLyricLines) break;
        if (![object isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *lineObject = object;
        NSString *text = CICleanCaptionText(lineObject[@"line"]);
        double startMilliseconds = CIDoubleValue(lineObject[@"milliseconds"]);
        double durationMilliseconds = CIDoubleValue(lineObject[@"duration"]);
        if (text.length == 0 || !isfinite(startMilliseconds) || startMilliseconds < 0) continue;
        NSTimeInterval start = startMilliseconds / 1000.0;
        if (videoDuration > 0 && start >= videoDuration) continue;
        NSTimeInterval end = isfinite(durationMilliseconds) && durationMilliseconds > 0
            ? start + durationMilliseconds / 1000.0 : start + 4.0;
        if (videoDuration > 0) end = MIN(end, videoDuration);
        if (end - start < 0.05) continue;
        [cues addObject:[[CICaptionCue alloc] initWithStartTime:start endTime:end text:text]];
    }
    [cues sortUsingComparator:^NSComparisonResult(CICaptionCue *lhs, CICaptionCue *rhs) {
        if (lhs.startTime < rhs.startTime) return NSOrderedAscending;
        if (lhs.startTime > rhs.startTime) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return cues.copy;
}

- (CILyricsResult *)lyricsResultFromData:(NSData *)data
                                duration:(NSTimeInterval)duration
                                   error:(NSError **)error {
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![object isKindOfClass:NSDictionary.class]) {
        if (error && !*error) *error = CIProviderError(-5, @"LyricFind returned malformed JSON.");
        return nil;
    }
    NSDictionary *root = object;
    NSDictionary *response = [root[@"response"] isKindOfClass:NSDictionary.class] ? root[@"response"] : nil;
    NSInteger code = [response[@"code"] respondsToSelector:@selector(integerValue)]
        ? [response[@"code"] integerValue] : 0;
    if (code != 101 && code != 111) {
        NSString *message = CIRequiredString(response[@"message"]);
        if (message.length == 0) message = CIRequiredString(response[@"description"]);
        if (error) *error = CIProviderError(code ?: -6,
            message.length > 0 ? message : @"LyricFind did not return a displayable lyric.");
        return nil;
    }

    NSDictionary *track = [root[@"track"] isKindOfClass:NSDictionary.class] ? root[@"track"] : nil;
    if (!track || ([track[@"viewable"] respondsToSelector:@selector(boolValue)] && ![track[@"viewable"] boolValue])) {
        if (error) *error = CIProviderError(206, @"LyricFind marked this lyric as unavailable.");
        return nil;
    }
    NSString *copyrightNotice = CIRequiredString(track[@"copyright"]);
    NSString *writerCredit = CIRequiredString(track[@"writer"]);
    if (copyrightNotice.length == 0 || writerCredit.length == 0) {
        if (error) *error = CIProviderError(-7, @"LyricFind omitted required copyright or writer credits.");
        return nil;
    }

    CILyricsResult *result = [CILyricsResult new];
    result.syncedCues = [self cuesFromLRCObjects:track[@"lrc"] duration:duration];
    result.plainLyrics = CIRequiredString(track[@"lyrics"]);
    result.copyrightNotice = copyrightNotice;
    result.writerCredit = writerCredit;
    if (result.syncedCues.count == 0 && CINonEmptyLines(result.plainLyrics).count == 0) {
        if (error) *error = CIProviderError(404, @"LyricFind returned no usable lyric text.");
        return nil;
    }
    return result;
}

- (void)fetchLyricsForTitle:(NSString *)title
                     artist:(NSString *)artist
                   duration:(NSTimeInterval)duration
              displayAPIKey:(NSString *)displayAPIKey
                     LRCKey:(NSString *)LRCKey
                  territory:(NSString *)territory
                 completion:(CILyricsCompletion)completion {
    [self cancel];
    NSString *normalizedTerritory = territory.uppercaseString;
    NSCharacterSet *nonLetters = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZ"].invertedSet;
    BOOL validTerritory = normalizedTerritory.length == 2 &&
        [normalizedTerritory rangeOfCharacterFromSet:nonLetters].location == NSNotFound;
    if (title.length == 0 || displayAPIKey.length == 0 || !validTerritory) {
        completion(nil, CIProviderError(-1, @"Missing title, DISPLAY key, or two-letter territory."));
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:CILyricFindEndpoint]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:6.0];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [self requestBodyForTitle:title artist:artist displayAPIKey:displayAPIKey
                                          LRCKey:LRCKey territory:normalizedTerritory];
    [request setValue:@"application/x-www-form-urlencoded; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"no-store, no-cache" forHTTPHeaderField:@"Cache-Control"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Pragma"];

    __weak typeof(self) weakSelf = self;
    self.currentTask = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
        if (networkError) { completion(nil, networkError); return; }
        NSError *responseError = CIValidateProviderResponse(response, data);
        if (responseError) { completion(nil, responseError); return; }
        NSError *parseError = nil;
        CILyricsResult *result = [weakSelf lyricsResultFromData:data duration:duration error:&parseError];
        completion(result, parseError);
    }];
    [self.currentTask resume];
}

@end
