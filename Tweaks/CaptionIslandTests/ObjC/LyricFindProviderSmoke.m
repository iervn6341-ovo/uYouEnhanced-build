#import <Foundation/Foundation.h>
#import <math.h>
#import "../../CaptionIsland/CILyricFindProvider.h"

@interface CILyricFindProvider (SmokeTesting)
- (NSData *)requestBodyForTitle:(NSString *)title
                         artist:(NSString *)artist
                  displayAPIKey:(NSString *)displayAPIKey
                         LRCKey:(NSString *)LRCKey
                      territory:(NSString *)territory;
- (CILyricsResult *)lyricsResultFromData:(NSData *)data
                                duration:(NSTimeInterval)duration
                                   error:(NSError **)error;
@end

static NSData *CIJSONData(NSDictionary *object) {
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
}

static void CIAssert(BOOL condition, NSString *message) {
    if (condition) return;
    NSLog(@"LyricFind provider smoke failed: %@", message);
    exit(1);
}

int main(void) {
    @autoreleasepool {
        CILyricFindProvider *provider = [CILyricFindProvider new];
        NSData *requestBody = [provider requestBodyForTitle:@"A: Track"
                                                    artist:@"An, Artist"
                                             displayAPIKey:@"DISPLAY"
                                                    LRCKey:@"LRC"
                                                 territory:@"TW"];
        NSString *form = [[NSString alloc] initWithData:requestBody encoding:NSUTF8StringEncoding];
        CIAssert([form containsString:@"apikey=DISPLAY"], @"DISPLAY key should be sent in the POST body");
        CIAssert([form containsString:@"lrckey=LRC"], @"LRC key should be sent only for synchronized lookup");
        CIAssert([form containsString:@"format=lrc"], @"LRC request should still allow static fallback");
        CIAssert([form containsString:@"territory=TW"], @"licensed territory should be included");
        CIAssert([form containsString:@"trackid="], @"artist and track should form a composite identifier");

        NSDictionary *success = @{
            @"response": @{@"code": @101, @"description": @"AVAILABLE"},
            @"track": @{
                @"viewable": @YES,
                @"lyrics": @"First line\nSecond line",
                @"lrc": @[
                    @{@"milliseconds": @"500", @"duration": @"1000", @"line": @"First line"},
                    @{@"milliseconds": @"2000", @"duration": @"2000", @"line": @"Second line"}
                ],
                @"copyright": @"Lyrics © Example Publisher",
                @"writer": @"Example Writer"
            }
        };
        NSError *error = nil;
        CILyricsResult *result = [provider lyricsResultFromData:CIJSONData(success)
                                                      duration:3.0
                                                         error:&error];
        CIAssert(result != nil && error == nil, @"valid 101 response should parse");
        CIAssert(result.syncedCues.count == 2, @"two LRC lines should become two cues");
        CIAssert(fabs(result.syncedCues[0].startTime - 0.5) < 0.001, @"milliseconds should convert to seconds");
        CIAssert(fabs(result.syncedCues[1].endTime - 3.0) < 0.001, @"cue should be bounded by video duration");
        CIAssert([result.plainLyrics containsString:@"Second line"], @"static lyrics should remain available");
        CIAssert([result.writerCredit isEqualToString:@"Example Writer"], @"writer credit should be retained");

        NSDictionary *blocked = @{
            @"response": @{@"code": @206, @"description": @"PUBLISHER BLOCK"}
        };
        error = nil;
        result = [provider lyricsResultFromData:CIJSONData(blocked) duration:100 error:&error];
        CIAssert(result == nil && error.code == 206, @"publisher block must never display");

        NSDictionary *missingCredits = @{
            @"response": @{@"code": @111, @"description": @"AVAILABLE"},
            @"track": @{@"viewable": @YES, @"lyrics": @"Text without credits"}
        };
        error = nil;
        result = [provider lyricsResultFromData:CIJSONData(missingCredits) duration:100 error:&error];
        CIAssert(result == nil, @"lyrics without required rights notices must not display");

        NSLog(@"LyricFind provider smoke passed");
    }
    return 0;
}
