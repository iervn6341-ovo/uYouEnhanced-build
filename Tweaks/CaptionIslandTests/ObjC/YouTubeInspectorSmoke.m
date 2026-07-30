#import <Foundation/Foundation.h>
#import "../../CaptionIsland/CIYouTubeInspector.h"

static void CIAssert(BOOL condition, NSString *message) {
    if (condition) return;
    NSLog(@"YouTube inspector smoke failed: %@", message);
    exit(1);
}

int main(void) {
    @autoreleasepool {
        NSURL *manualURL = [NSURL URLWithString:
            @"https://www.youtube.com/api/timedtext?v=test&lang=zh-TW"];
        NSURL *ASRURL = [NSURL URLWithString:
            @"https://www.youtube.com/api/timedtext?v=test&lang=en&kind=asr"];
        NSDictionary *manualTrack = @{
            @"URL": manualURL,
            @"displayName": @"中文（繁體）",
            @"languageCode": @"zh-TW",
            @"VSSID": @".zh-TW",
        };
        NSDictionary *ASRTrack = @{
            @"URL": ASRURL,
            @"displayName": @"English (auto-generated)",
            @"languageCode": @"en",
            @"VSSID": @"a.en",
        };
        NSDictionary *controller = @{
            @"activeVideo": @{
                @"availableCaptionTracks": @[manualTrack, ASRTrack],
            },
            @"currentVideoID": @"video-id",
            @"currentVideoTotalMediaTime": @210,
        };
        NSDictionary *playbackData = @{
            @"playerResponse": @{
                @"playerData": @{
                    @"videoDetails": @{
                        @"videoId": @"video-id",
                        @"title": @"Artist - Song",
                        @"author": @"Artist",
                        @"lengthSeconds": @210,
                        @"isShorts": @YES,
                    },
                    // Metadata-only protobuf tracks must not shadow the
                    // MLInnerTubeCaptionTrack URLs on activeVideo.
                    @"captions": @{
                        @"playerCaptionsTracklistRenderer": @{
                            @"captionTracksArray": @[
                                @{@"languageCode": @"ja", @"vssId": @".ja"},
                            ],
                        },
                    },
                },
            },
        };

        CIVideoContext *context =
            [CIYouTubeInspector contextFromPlaybackData:playbackData
                                       playerController:controller];
        CIAssert(context != nil, @"valid player data should create a context");
        CIAssert(context.isShorts,
            @"explicit YouTube Shorts metadata should be preserved");
        CIAssert(context.captionTracks.count == 2,
            @"active player URL tracks should take priority over protobuf metadata");
        CIAssert([context.captionTracks.firstObject.baseURL isEqualToString:manualURL.absoluteString],
            @"NSURL caption track properties should become absolute URL strings");

        CICaptionTrack *manual =
            [CIYouTubeInspector manualTrackInContext:context
                                  preferredLanguage:@"zh-Hant"];
        CIAssert(manual != nil && !manual.isAutomatic,
            @"Traditional Chinese source CC should be selected as manual");
        CICaptionTrack *automatic =
            [CIYouTubeInspector automaticTrackInContext:context
                                     preferredLanguage:@"en"];
        CIAssert(automatic != nil && automatic.isAutomatic,
            @"VSSID and kind query should identify YouTube ASR");

        NSURL *requestURL = [CIYouTubeInspector requestURLForTrack:manual];
        CIAssert([requestURL.absoluteString containsString:@"fmt=json3"],
            @"caption requests should explicitly ask for JSON3");
        NSArray<NSURL *> *requestURLs =
            [CIYouTubeInspector requestURLsForTrack:manual];
        CIAssert(requestURLs.count == 3 &&
            [requestURLs.firstObject.absoluteString isEqualToString:manualURL.absoluteString],
            @"caption fallback should try YouTube's unmodified signed URL first");
        CIAssert([requestURLs[1].absoluteString containsString:@"fmt=json3"] &&
            [requestURLs[2].absoluteString containsString:@"fmt=vtt"],
            @"caption fallback should retry JSON3 and WebVTT formats");

        CICaptionTrack *translated = [CICaptionTrack new];
        translated.baseURL =
            @"https://www.youtube.com/api/timedtext?v=test&lang=en&tlang=zh-Hant";
        translated.languageCode = @"zh-Hant";
        context.captionTracks = @[translated];
        CIAssert([CIYouTubeInspector manualTrackInContext:context
                                       preferredLanguage:@"zh-Hant"] == nil,
            @"YouTube auto-translated tracks must never count as manual CC");
        CIAssert([CIYouTubeInspector requestURLForTrack:translated] == nil,
            @"translated timedtext URLs should be rejected before download");
        CIAssert([CIYouTubeInspector requestURLsForTrack:translated].count == 0,
            @"translated timedtext URLs must not enter the format fallback");

        NSMutableDictionary *verticalController = [@{
            @"currentVideoID": @"vertical-video",
            @"currentVideoTotalMediaTime": @45,
            @"isCurrentVideoVertical": @YES,
        } mutableCopy];
        NSDictionary *verticalPlaybackData = @{
            @"playerResponse": @{
                @"playerData": @{
                    @"videoDetails": @{
                        @"videoId": @"vertical-video",
                        @"title": @"Ordinary vertical video",
                        @"lengthSeconds": @45,
                    },
                },
            },
        };
        CIVideoContext *verticalContext =
            [CIYouTubeInspector
                contextFromPlaybackData:verticalPlaybackData
                playerController:verticalController];
        CIAssert(!verticalContext.isShorts,
            @"vertical layout alone must not be treated as Shorts");
        [CIYouTubeInspector
            markPlayerControllerAsShorts:verticalController];
        CIVideoContext *markedShortsContext =
            [CIYouTubeInspector
                contextFromPlaybackData:verticalPlaybackData
                playerController:verticalController];
        CIAssert(markedShortsContext.isShorts,
            @"a Shorts container marker should survive later context refreshes");
        verticalController[@"currentVideoID"] = @"regular-reused-player";
        NSDictionary *reusedPlaybackData = @{
            @"playerResponse": @{
                @"playerData": @{
                    @"videoDetails": @{
                        @"videoId": @"regular-reused-player",
                        @"title": @"Regular watch page",
                        @"lengthSeconds": @180,
                    },
                },
            },
        };
        CIVideoContext *reusedContext =
            [CIYouTubeInspector
                contextFromPlaybackData:reusedPlaybackData
                playerController:verticalController];
        CIAssert(!reusedContext.isShorts,
            @"a reused player must not carry its old Shorts marker to a new video");

        NSLog(@"YouTube inspector smoke passed");
    }
    return 0;
}
