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

static BOOL CITrackIsTranslated(CICaptionTrack *track) {
    NSURLComponents *components = [NSURLComponents componentsWithString:track.baseURL];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name.lowercaseString isEqualToString:@"tlang"]) return YES;
    }
    return NO;
}

@implementation CIYouTubeInspector

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

    NSArray *rawTracks = CIFindCaptionTracks(playerData, 0);
    if (rawTracks.count == 0) {
        id activeVideo = CIValue(playerController, @"activeVideo");
        rawTracks = CIValue(activeVideo, @"availableCaptionTracks");
    }
    NSMutableArray<CICaptionTrack *> *tracks = [NSMutableArray arrayWithCapacity:rawTracks.count];
    for (id rawTrack in rawTracks) {
        CICaptionTrack *track = [CICaptionTrack new];
        track.baseURL = CIStringValue(CIValue(rawTrack, @"baseUrl"));
        if (track.baseURL.length == 0) track.baseURL = CIStringValue(CIValue(rawTrack, @"baseURL"));
        if (track.baseURL.length == 0) track.baseURL = CIStringValue(CIValue(rawTrack, @"URL"));
        track.languageCode = CIStringValue(CIValue(rawTrack, @"languageCode"));
        track.kind = CIStringValue(CIValue(rawTrack, @"kind"));
        track.vssID = CIStringValue(CIValue(rawTrack, @"vssId"));
        if (track.vssID.length == 0) track.vssID = CIStringValue(CIValue(rawTrack, @"vssID"));
        if (track.vssID.length == 0) track.vssID = CIStringValue(CIValue(rawTrack, @"VSSID"));
        track.displayName = CIStringValue(CIValue(rawTrack, @"name"));
        if (track.displayName.length == 0) track.displayName = CIStringValue(CIValue(rawTrack, @"displayName"));
        if (track.baseURL.length > 0) [tracks addObject:track];
    }
    context.captionTracks = tracks;
    return context.videoID.length > 0 ? context : nil;
}

+ (CICaptionTrack *)manualTrackInContext:(CIVideoContext *)context
                       preferredLanguage:(NSString *)preferredLanguage {
    CICaptionTrack *best;
    NSInteger bestScore = 0;
    for (CICaptionTrack *track in context.captionTracks) {
        if (track.isAutomatic || CITrackIsTranslated(track)) continue;
        NSInteger score = CILanguageScore(track.languageCode, preferredLanguage);
        if (score > bestScore) { best = track; bestScore = score; }
    }
    return best;
}

+ (CICaptionTrack *)automaticTrackInContext:(CIVideoContext *)context
                          preferredLanguage:(NSString *)preferredLanguage {
    CICaptionTrack *best;
    NSInteger bestScore = NSIntegerMin;
    for (CICaptionTrack *track in context.captionTracks) {
        if (!track.isAutomatic || CITrackIsTranslated(track)) continue;
        NSInteger languageScore = CILanguageScore(track.languageCode, preferredLanguage);
        // A mismatched ASR language is still more useful than no clock at all.
        NSInteger score = languageScore > 0 ? languageScore : 1;
        if (score > bestScore) { best = track; bestScore = score; }
    }
    return best;
}

+ (NSURL *)requestURLForTrack:(CICaptionTrack *)track {
    NSURLComponents *components = [NSURLComponents componentsWithString:track.baseURL];
    if (!components) return nil;
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        NSString *name = item.name.lowercaseString;
        // Raw source tracks do not contain tlang. Reject translated wrappers
        // outright so their language label can never be mistaken for source CC.
        if ([name isEqualToString:@"tlang"]) return nil;
        if ([name isEqualToString:@"fmt"]) continue;
        [items addObject:item];
    }
    [items addObject:[NSURLQueryItem queryItemWithName:@"fmt" value:@"json3"]];
    components.queryItems = items;
    return components.URL;
}

@end
