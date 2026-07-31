#import <Foundation/Foundation.h>
#import <math.h>
#import "../../CaptionIsland/CIVideoOverrides.h"

static void CIAssert(BOOL condition, NSString *message) {
    if (condition) return;
    NSLog(@"Video overrides smoke failed: %@", message);
    exit(1);
}

int main(void) {
    @autoreleasepool {
        NSString *videoID = [NSString stringWithFormat:
            @"caption-island-smoke-%@", NSUUID.UUID.UUIDString];
        CIClearVideoOverride(videoID);

        CIAssert(CIVideoOverrideForVideoID(videoID) == nil,
            @"a cleared video should not have an override");

        CISaveVideoOverride(
            videoID,
            @"Never Looking Back",
            @"Uma Musume",
            1.75,
            @"Never Looking Back [Official]"
        );
        CIVideoOverride *stored = CIVideoOverrideForVideoID(videoID);
        CIAssert(stored != nil, @"a saved override should be readable");
        CIAssert([stored.searchTitle isEqualToString:@"Never Looking Back"],
            @"the LRCLIB search title should round-trip");
        CIAssert([stored.searchArtist isEqualToString:@"Uma Musume"],
            @"the LRCLIB search artist should round-trip");
        CIAssert([stored.originalTitle
            isEqualToString:@"Never Looking Back [Official]"],
            @"the original YouTube title should round-trip");
        CIAssert(fabs(stored.captionAdvanceSeconds - 1.75) < 0.001,
            @"the caption advance should round-trip");
        CIAssert(stored.updatedAt > 0,
            @"a saved override should record its update time");

        CISaveVideoCaptionLanguagePriorities(
            videoID,
            @[@"ja", @"en", @"zh-Hant"],
            @"Never Looking Back [Official]"
        );
        stored = CIVideoOverrideForVideoID(videoID);
        CIAssert([stored.captionLanguagePriorities
            isEqualToArray:@[@"ja", @"en", @"zh-Hant"]],
            @"a per-video language priority should round-trip");

        CISaveVideoOverride(
            videoID,
            @"Never Looking Back",
            @"Uma Musume",
            500,
            @"Never Looking Back [Official]"
        );
        stored = CIVideoOverrideForVideoID(videoID);
        CIAssert(
            fabs(stored.captionAdvanceSeconds - 30.0) < 0.001,
            @"positive caption advance should clamp to 30 seconds"
        );
        CIAssert([stored.captionLanguagePriorities
            isEqualToArray:@[@"ja", @"en", @"zh-Hant"]],
            @"saving lyric metadata must preserve caption-language priorities");

        CISaveVideoOverride(
            videoID,
            @"Never Looking Back",
            @"Uma Musume",
            -500,
            @"Never Looking Back [Official]"
        );
        stored = CIVideoOverrideForVideoID(videoID);
        CIAssert(
            fabs(stored.captionAdvanceSeconds + 30.0) < 0.001,
            @"negative caption advance should clamp to -30 seconds"
        );

        CISaveVideoCaptionLanguagePriorities(
            videoID,
            @[],
            @"Never Looking Back [Official]"
        );
        stored = CIVideoOverrideForVideoID(videoID);
        CIAssert(stored != nil &&
            stored.captionLanguagePriorities.count == 0 &&
            [stored.searchTitle isEqualToString:@"Never Looking Back"],
            @"returning to global languages must preserve lyric overrides");

        CIClearVideoOverride(videoID);
        CIAssert(CIVideoOverrideForVideoID(videoID) == nil,
            @"clearing an override should remove it");
        NSLog(@"Video overrides smoke passed");
    }
    return 0;
}
