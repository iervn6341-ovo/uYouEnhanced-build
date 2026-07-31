#import "CIYouTubeInspector.h"
#import "CITextUtilities.h"
#import <objc/message.h>

static id CIValue(id object, NSString *key) {
    if (!object || key.length == 0) return nil;
    @try {
        if ([object isKindOfClass:NSDictionary.class]) return [(NSDictionary *)object objectForKey:key];
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *CIStringValue(id object) {
    if ([object isKindOfClass:NSString.class]) return object;
    if ([object isKindOfClass:NSNumber.class]) return [object stringValue];
    if ([object isKindOfClass:NSURL.class]) return [(NSURL *)object absoluteString] ?: @"";
    SEL formattingSelector = NSSelectorFromString(@"stringWithFormattingRemoved");
    if ([object respondsToSelector:formattingSelector]) {
        NSString *(*send)(id, SEL) = (void *)objc_msgSend;
        id value = send(object, formattingSelector);
        if ([value isKindOfClass:NSString.class]) return value;
    }
    id simpleText = CIValue(object, @"simpleText");
    if ([simpleText isKindOfClass:NSString.class]) return simpleText;
    NSArray *runs = CIValue(object, @"runsArray") ?: CIValue(object, @"runs");
    if ([runs isKindOfClass:NSArray.class]) {
        NSMutableString *result = [NSMutableString string];
        for (id run in runs) {
            id text = CIValue(run, @"text");
            if ([text isKindOfClass:NSString.class]) [result appendString:text];
        }
        return result;
    }
    return @"";
}

static NSArray *CIFindCaptionTracks(id object, NSUInteger depth) {
    if (!object || depth > 7) return nil;
    NSArray *direct = CIValue(object, @"captionTracksArray");
    if (![direct isKindOfClass:NSArray.class]) direct = CIValue(object, @"captionTracks");
    if ([direct isKindOfClass:NSArray.class] && direct.count > 0) return direct;
    NSArray<NSString *> *paths = @[
        @"captions", @"playerCaptions", @"playerCaptionsRenderer",
        @"playerCaptionsTracklistRenderer", @"captionsTracklistRenderer",
        @"captionTracklistRenderer", @"renderer"
    ];
    for (NSString *key in paths) {
        id child = CIValue(object, key);
        if (!child || child == object) continue;
        NSArray *found = CIFindCaptionTracks(child, depth + 1);
        if (found.count > 0) return found;
    }
    return nil;
}

static id CIPlayerDataFromPlaybackData(id playbackData) {
    id response = CIValue(playbackData, @"playerResponse") ?: playbackData;
    return CIValue(response, @"playerData") ?: response;
}

static NSString *CINormalizedLanguage(NSString *language) {
    return [[language ?: @"" stringByReplacingOccurrencesOfString:@"_" withString:@"-"] lowercaseString];
}

static NSInteger CILanguageScore(NSString *candidate, NSString *preferred) {
    NSString *value = CINormalizedLanguage(candidate);
    NSString *target = CINormalizedLanguage(preferred);
    if (value.length == 0 || target.length == 0) return 0;
    if ([value isEqualToString:target]) return 100;
    if ([target isEqualToString:@"zh-hant"]) {
        if ([value isEqualToString:@"zh-tw"] || [value isEqualToString:@"zh-hk"] ||
            [value isEqualToString:@"zh-mo"] || [value hasPrefix:@"zh-hant-"]) return 95;
        return 0; // Never silently substitute Simplified Chinese.
    }
    NSString *targetBase = [target componentsSeparatedByString:@"-"].firstObject;
    NSString *valueBase = [value componentsSeparatedByString:@"-"].firstObject;
    return [targetBase isEqualToString:valueBase] ? 80 : 0;
}

static NSInteger CILanguagePriorityScore(
    NSString *candidate,
    NSArray<NSString *> *priorities
) {
    for (NSUInteger index = 0; index < priorities.count; index++) {
        NSInteger match =
            CILanguageScore(candidate, priorities[index]);
        if (match <= 0) continue;
        return (NSInteger)(priorities.count - index) * 1000 + match;
    }
    // This is a priority list, not an exclusion list. A source-language
    // caption that is not listed is still preferable to having no captions.
    return 1;
}

static BOOL CITrackIsTranslated(CICaptionTrack *track) {
    NSURLComponents *components = [NSURLComponents componentsWithString:track.baseURL];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name.lowercaseString isEqualToString:@"tlang"]) return YES;
    }
    return NO;
}

static NSURL *CITrackURLWithFormat(CICaptionTrack *track, NSString *format) {
    NSURLComponents *components = [NSURLComponents componentsWithString:track.baseURL];
    if (!components) return nil;
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        NSString *name = item.name.lowercaseString;
        // Raw source tracks do not contain tlang. Reject translated wrappers
        // outright so their language label can never be mistaken for source CC.
        if ([name isEqualToString:@"tlang"]) return nil;
        if (format.length > 0 && [name isEqualToString:@"fmt"]) continue;
        [items addObject:item];
    }
    if (format.length == 0) {
        // Avoid reserializing signed query values. Even equivalent percent
        // encoding can invalidate a URL whose exact bytes were signed.
        return [NSURL URLWithString:track.baseURL];
    }
    if (format.length > 0) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"fmt" value:format]];
    }
    components.queryItems = items;
    return components.URL;
}

static NSArray<CICaptionTrack *> *CITracksFromRawTracks(id rawTracks) {
    if (![rawTracks isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<CICaptionTrack *> *tracks =
        [NSMutableArray arrayWithCapacity:[(NSArray *)rawTracks count]];
    for (id rawTrack in (NSArray *)rawTracks) {
        CICaptionTrack *track = [CICaptionTrack new];
        track.baseURL = CIStringValue(CIValue(rawTrack, @"baseUrl"));
        if (track.baseURL.length == 0) {
            track.baseURL = CIStringValue(CIValue(rawTrack, @"baseURL"));
        }
        if (track.baseURL.length == 0) {
            track.baseURL = CIStringValue(CIValue(rawTrack, @"URL"));
        }
        track.languageCode = CIStringValue(CIValue(rawTrack, @"languageCode"));
        track.kind = CIStringValue(CIValue(rawTrack, @"kind"));
        track.vssID = CIStringValue(CIValue(rawTrack, @"vssId"));
        if (track.vssID.length == 0) {
            track.vssID = CIStringValue(CIValue(rawTrack, @"vssID"));
        }
        if (track.vssID.length == 0) {
            track.vssID = CIStringValue(CIValue(rawTrack, @"VSSID"));
        }
        track.displayName = CIStringValue(CIValue(rawTrack, @"name"));
        if (track.displayName.length == 0) {
            track.displayName = CIStringValue(CIValue(rawTrack, @"displayName"));
        }
        if (track.baseURL.length > 0) [tracks addObject:track];
    }
    return tracks.copy;
}

@implementation CIYouTubeInspector

+ (NSMapTable *)shortsPlayerVideoIDs {
    static NSMapTable *videoIDs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        videoIDs = [NSMapTable weakToStrongObjectsMapTable];
    });
    return videoIDs;
}

+ (void)markPlayerControllerAsShorts:(id)playerController {
    if (!playerController) return;
    NSString *videoID =
        CIStringValue(CIValue(playerController, @"currentVideoID"));
    if (videoID.length == 0) return;
    @synchronized (self) {
        [[self shortsPlayerVideoIDs]
            setObject:videoID
            forKey:playerController];
    }
}

+ (CIVideoContext *)contextFromPlaybackData:(id)playbackData playerController:(id)playerController {
    if (!NSThread.isMainThread) return nil;
    if (!playbackData) {
        id activeVideo = CIValue(playerController, @"activeVideo");
        id singleVideo = CIValue(activeVideo, @"singleVideo") ?: CIValue(activeVideo, @"videoData");
        playbackData = CIValue(singleVideo, @"playbackData");
    }
    id playerData = CIPlayerDataFromPlaybackData(playbackData);
    id details = CIValue(playerData, @"videoDetails");
    if (!details) {
        id video = CIValue(playbackData, @"video");
        details = CIValue(video, @"videoDetails");
    }

    CIVideoContext *context = [CIVideoContext new];
    context.videoID = CIStringValue(CIValue(details, @"videoId"));
    if (context.videoID.length == 0) context.videoID = CIStringValue(CIValue(playerController, @"currentVideoID"));
    context.title = CIStringValue(CIValue(details, @"title"));
    context.author = CIStringValue(CIValue(details, @"author"));
    context.duration = [CIValue(details, @"lengthSeconds") doubleValue];
    if (context.duration <= 0) context.duration = [CIValue(playerController, @"currentVideoTotalMediaTime") doubleValue];
    NSArray<NSString *> *shortsKeys =
        @[@"isShorts", @"isShort", @"isShortFormContent", @"isReel"];
    for (NSString *key in shortsKeys) {
        if ([CIValue(details, key) boolValue] ||
            [CIValue(playerData, key) boolValue] ||
            [CIValue(playbackData, key) boolValue]) {
            context.shorts = YES;
            break;
        }
    }
    if (!context.isShorts && playerController) {
        NSString *markedVideoID;
        @synchronized (self) {
            markedVideoID =
                [[self shortsPlayerVideoIDs]
                    objectForKey:playerController];
        }
        context.shorts =
            context.videoID.length > 0 &&
            [markedVideoID isEqualToString:context.videoID];
    }

    // MLInnerTubeCaptionTrack exposes the usable signed URL at runtime.
    // Prefer those objects over protobuf metadata, whose renderer entries can
    // contain language labels without a downloadable URL.
    id activeVideo = CIValue(playerController, @"activeVideo");
    NSArray<CICaptionTrack *> *tracks =
        CITracksFromRawTracks(CIValue(activeVideo, @"availableCaptionTracks"));
    if (tracks.count == 0) {
        id playerItem = CIValue(activeVideo, @"playerItem");
        tracks = CITracksFromRawTracks(CIValue(playerItem, @"availableCaptionTracks"));
    }
    if (tracks.count == 0) {
        tracks = CITracksFromRawTracks(CIFindCaptionTracks(playerData, 0));
    }
    context.captionTracks = tracks;
    return context.videoID.length > 0 ? context : nil;
}

+ (CICaptionTrack *)manualTrackInContext:(CIVideoContext *)context
                       preferredLanguage:(NSString *)preferredLanguage {
    return [self manualTrackInContext:context
                   preferredLanguages:preferredLanguage.length > 0
                       ? @[preferredLanguage] : @[]];
}

+ (CICaptionTrack *)manualTrackInContext:(CIVideoContext *)context
                      preferredLanguages:
                          (NSArray<NSString *> *)preferredLanguages {
    CICaptionTrack *best;
    NSInteger bestScore = NSIntegerMin;
    for (CICaptionTrack *track in context.captionTracks) {
        if (track.isAutomatic || CITrackIsTranslated(track)) continue;
        NSInteger score = CILanguagePriorityScore(
            track.languageCode,
            preferredLanguages
        );
        if (score > bestScore) { best = track; bestScore = score; }
    }
    return best;
}

+ (CICaptionTrack *)automaticTrackInContext:(CIVideoContext *)context
                          preferredLanguage:(NSString *)preferredLanguage {
    return [self automaticTrackInContext:context
                      preferredLanguages:preferredLanguage.length > 0
                          ? @[preferredLanguage] : @[]];
}

+ (CICaptionTrack *)automaticTrackInContext:(CIVideoContext *)context
                         preferredLanguages:
                             (NSArray<NSString *> *)preferredLanguages {
    CICaptionTrack *best;
    NSInteger bestScore = NSIntegerMin;
    for (CICaptionTrack *track in context.captionTracks) {
        if (!track.isAutomatic || CITrackIsTranslated(track)) continue;
        NSInteger score = CILanguagePriorityScore(
            track.languageCode,
            preferredLanguages
        );
        if (score > bestScore) { best = track; bestScore = score; }
    }
    return best;
}

+ (NSURL *)requestURLForTrack:(CICaptionTrack *)track {
    return CITrackURLWithFormat(track, @"json3");
}

+ (NSArray<NSURL *> *)requestURLsForTrack:(CICaptionTrack *)track {
    NSMutableArray<NSURL *> *URLs = [NSMutableArray arrayWithCapacity:3];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithCapacity:3];
    NSURL *originalURL = CITrackURLWithFormat(track, nil);
    NSURLComponents *originalComponents = originalURL
        ? [NSURLComponents componentsWithURL:originalURL resolvingAgainstBaseURL:NO] : nil;
    NSString *originalFormat = @"";
    for (NSURLQueryItem *item in originalComponents.queryItems) {
        if ([item.name.lowercaseString isEqualToString:@"fmt"]) {
            originalFormat = item.value.lowercaseString ?: @"";
            break;
        }
    }
    // Prefer YouTube's signed URL exactly as supplied. Some app/player
    // versions return an empty body after fmt is replaced, even though their
    // original XML/SRV3 endpoint remains valid.
    for (NSString *format in @[@"", @"json3", @"vtt"]) {
        if (format.length > 0 && [format isEqualToString:originalFormat]) continue;
        NSURL *URL = format.length == 0
            ? originalURL : CITrackURLWithFormat(track, format);
        NSString *key = URL.absoluteString ?: @"";
        if (key.length == 0 || [seen containsObject:key]) continue;
        [seen addObject:key];
        [URLs addObject:URL];
    }
    return URLs.copy;
}

@end
