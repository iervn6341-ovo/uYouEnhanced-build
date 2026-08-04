#import <Foundation/Foundation.h>
#import <math.h>
#import "../../CaptionIsland/CILRCLIBProvider.h"
#import "../../CaptionIsland/CITextUtilities.h"

@interface CILRCLIBProvider (SmokeTesting)
- (CILRCLIBResult *)lyricsResultFromSearchData:(NSData *)data
                                          title:(NSString *)title
                                         artist:(NSString *)artist
                                  videoDuration:(NSTimeInterval)videoDuration
                                          error:(NSError **)error;
- (CILRCLIBResult *)bestResultFromSearchData:(NSData *)data
                                       title:(NSString *)title
                                      artist:(NSString *)artist
                               videoDuration:(NSTimeInterval)videoDuration
                                       error:(NSError **)error;
- (CILRCLIBResult *)lyricsResultFromExactData:(NSData *)data
                                         title:(NSString *)title
                                        artist:(NSString *)artist
                                 videoDuration:(NSTimeInterval)videoDuration
                                         error:(NSError **)error;
- (NSURL *)searchURLForTitle:(NSString *)title artist:(NSString *)artist broad:(BOOL)broad;
- (NSURL *)getURLForTitle:(NSString *)title
                   artist:(NSString *)artist
                 duration:(NSTimeInterval)duration;
- (BOOL)responseLooksLikeBlockPage:(NSURLResponse *)response
                              data:(NSData *)data;
- (NSString *)cacheKeyForTitle:(NSString *)title
                        artist:(NSString *)artist
                      duration:(NSTimeInterval)duration
                         exact:(BOOL)exact
              endpointIdentity:(NSString *)endpointIdentity;
- (void)storeResult:(CILRCLIBResult *)result
        forCacheKey:(NSString *)key;
- (void)storeNegativeResultForCacheKey:(NSString *)key;
- (CILRCLIBResult *)cachedResultForKey:(NSString *)key
                          negativeHit:(BOOL *)negativeHit;
- (NSTimeInterval)recordCooldownForEndpoint:(NSString *)endpoint
                                     status:(NSInteger)status
                                   response:(NSHTTPURLResponse *)response;
- (NSTimeInterval)cooldownRemainingForEndpoint:(NSString *)endpoint;
- (void)clearCooldownForEndpoint:(NSString *)endpoint;
@end

static NSData *CIJSONData(id object) {
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
}

static void CIAssert(BOOL condition, NSString *message) {
    if (condition) return;
    NSLog(@"LRCLIB provider smoke failed: %@", message);
    exit(1);
}

static void CIAssertSongMetadata(NSString *videoTitle,
                                 NSString *expectedTitle,
                                 NSString *expectedArtist,
                                 NSString *message) {
    NSString *title;
    NSString *artist;
    CISplitSongMetadata(videoTitle, @"Fallback Uploader", &title, &artist);
    CIAssert([title isEqualToString:expectedTitle] &&
             [artist isEqualToString:expectedArtist] &&
             [CISongTitleFromVideoTitle(videoTitle)
                 isEqualToString:expectedTitle],
             message);
}

static NSDictionary *CIRecord(NSInteger recordID,
                              NSString *track,
                              NSString *artist,
                              double duration,
                              NSString *plain,
                              id synced) {
    return @{
        @"id": @(recordID),
        @"trackName": track,
        @"artistName": artist,
        @"albumName": @"Album",
        @"duration": @(duration),
        @"instrumental": @NO,
        @"plainLyrics": plain ?: NSNull.null,
        @"syncedLyrics": synced ?: NSNull.null,
    };
}

int main(void) {
    @autoreleasepool {
        [NSUserDefaults.standardUserDefaults
            removeObjectForKey:CILRCLIBBaseURLKey];
        CIAssert([CILRCLIBBaseURL()
            isEqualToString:@"https://lrclib.net"],
            @"the default base URL should remain the official LRCLIB service");
        NSError *URLValidationError = nil;
        NSString *customBase = CINormalizedLRCLIBBaseURL(
            @"http://127.0.0.1:3300/lyrics/",
            &URLValidationError
        );
        CIAssert([customBase
            isEqualToString:@"http://127.0.0.1:3300/lyrics"] &&
            URLValidationError == nil,
            @"HTTP mirror URLs and base paths should normalize safely");
        CIAssert(CINormalizedLRCLIBBaseURL(
            @"ftp://example.com", NULL) == nil,
            @"non-HTTP schemes should be rejected");
        [NSUserDefaults.standardUserDefaults
            setObject:customBase forKey:CILRCLIBBaseURLKey];
        CIAssert([CILRCLIBSearchEndpointURL().absoluteString
            isEqualToString:
                @"http://127.0.0.1:3300/lyrics/api/search"],
            @"a mirror base path should receive the LRCLIB search endpoint");
        CIAssert([CILRCLIBGetEndpointURL().absoluteString
            isEqualToString:
                @"http://127.0.0.1:3300/lyrics/api/get"],
            @"a mirror base path should receive the LRCLIB exact endpoint");
        CILRCLIBProvider *provider = [CILRCLIBProvider new];
        NSError *error = nil;
        NSString *splitTitle;
        NSString *splitArtist;
        CISplitSongMetadata(@"Example Artist – Example Song [Official Video]",
            @"ExampleArtistVEVO", &splitTitle, &splitArtist);
        CIAssert([splitTitle isEqualToString:@"Example Song"],
            @"common YouTube decorations should be removed before lookup");
        CIAssert([splitArtist isEqualToString:@"Example Artist"],
            @"Unicode title separators should provide the canonical artist");
        CIAssert([CISongTitleFromVideoTitle(
            @"【ウマ娘】Precious Star Dreamer | Full Ver.【パート分け/歌詞】")
            isEqualToString:@"Precious Star Dreamer"],
            @"series labels and known version/lyric suffixes should be removed");
        CIAssert([CISongTitleFromVideoTitle(@"Precious Star Dreamer【歌詞・パート分け】")
            isEqualToString:@"Precious Star Dreamer"],
            @"a trailing Japanese lyric marker should be removed");
        CIAssert([CISongTitleFromVideoTitle(@"Precious Star Dreamer | Official Audio")
            isEqualToString:@"Precious Star Dreamer"],
            @"a known pipe-delimited upload marker should be removed");
        CIAssert([CISongTitleFromVideoTitle(@"Song | Another Song")
            isEqualToString:@"Song | Another Song"],
            @"an unknown pipe suffix should remain part of the title");
        CIAssert([CISongTitleFromVideoTitle(
            @"[HD] Precious [Romaji] Star Dreamer ［歌詞］")
            isEqualToString:@"Precious Star Dreamer"],
            @"all ASCII and full-width square-bracket blocks should be removed");
        CIAssert([CISongTitleFromVideoTitle(@"【アイドル】")
            isEqualToString:@"【アイドル】"],
            @"a bracketed title with no remaining text must not become empty");
        CIAssert([CISongTitleFromVideoTitle(@"Artist - Song")
            isEqualToString:@"Artist - Song"],
            @"title-only lookup must not reinterpret an ordinary artist-title string");
        CIAssertSongMetadata(
            @"AiNA THE END / On The Way [Official Music Video](TV Anime『DANDADAN』Season 2 Opening)",
            @"On The Way", @"AiNA THE END",
            @"artist/title slash uploads should exclude trailing anime context");
        CIAssertSongMetadata(
            @"AiNA THE END/On The Way [Official Music Video]",
            @"On The Way", @"AiNA THE END",
            @"artist/title slash uploads should not require surrounding spaces");
        CIAssertSongMetadata(
            @"YOASOBI「UNDEAD」 Official Music Video／『〈物語〉シリーズ オフ&モンスターシーズン』主題歌",
            @"UNDEAD", @"YOASOBI",
            @"a quoted song before Music Video should outrank a later series name");
        CIAssertSongMetadata(
            @"SawanoHiroyuki[nZk]:Jean-Ken Johnny & TAKUMA『PROVANT』 Music Video",
            @"PROVANT", @"SawanoHiroyuki[nZk]:Jean-Ken Johnny & TAKUMA",
            @"artist identity brackets must survive quoted-title parsing");
        // A dash is only split by CISplitSongMetadata; CISongTitleFromVideoTitle
        // deliberately leaves "Artist - Song" intact, so these two cannot use
        // CIAssertSongMetadata.
        CISplitSongMetadata(
            @"Rokudenashi - The Shape of Rain【Official Music Video】",
            @"Fallback Uploader", &splitTitle, &splitArtist);
        CIAssert([splitTitle isEqualToString:@"The Shape of Rain"] &&
            [splitArtist isEqualToString:@"Rokudenashi"],
            @"a dash upload should drop its video block and keep the artist");
        CISplitSongMetadata(
            @"Street Fighter 6 Ingrid's Theme - Cosmic Scale Pretty",
            @"Fallback Uploader", &splitTitle, &splitArtist);
        CIAssert([splitTitle isEqualToString:@"Cosmic Scale Pretty"] &&
            [splitArtist isEqualToString:@"Street Fighter 6 Ingrid's Theme"],
            @"a game and scene prefix parses as the artist side, so the scorer must tolerate it");
        // Documents a reading the parser gets wrong and cannot fix locally:
        // nothing in "風になる / Nachoneko" marks which side is the song. The
        // lookup compensates by searching the other side when this one finds
        // nothing, so the expectation here is the wrong-but-deliberate reading.
        CIAssertSongMetadata(
            @"風になる / Nachoneko",
            @"Nachoneko", @"風になる",
            @"a title-first slash upload is parsed artist-first and relies on the reversed retry");
        CIAssertSongMetadata(
            @"風になる / Nachoneko【ライブ映像】",
            @"Nachoneko", @"風になる",
            @"a Japanese live-footage block is upload metadata and must not stay in the track name");
        CIAssertSongMetadata(
            @"Tetoris / Kasane Teto SV",
            @"Tetoris", @"",
            @"a vocal-synth suffix should reverse the slash direction without becoming a hard artist filter");
        CIAssertSongMetadata(
            @"TVアニメ「男女の友情は成立する？（いや、しないっ‼）」ノンクレジットOP | HoneyWorks feat.ハコニワリリィ「質問、恋って何でしょうか?」",
            @"質問、恋って何でしょうか?", @"HoneyWorks feat.ハコニワリリィ",
            @"TV Anime work names must not displace the quoted song title");
        CIAssertSongMetadata(
            @"TVアニメ「作品名」OPテーマ「Example Song」",
            @"Example Song", @"",
            @"anime context before a song quote must not become a hard artist filter");
        CIAssertSongMetadata(
            @"Never Looking Back", @"Never Looking Back", @"",
            @"an arbitrary uploader channel must not be treated as the song artist");
        CISplitSongMetadata(@"Never Looking Back", @"Example Artist - Topic",
            &splitTitle, &splitArtist);
        CIAssert([splitTitle isEqualToString:@"Never Looking Back"] &&
            [splitArtist isEqualToString:@"Example Artist"],
            @"a YouTube Topic channel may provide a reliable artist");
        CIAssert([CISongTitleFromVideoTitle(
            @"【赛马娘】GIRLS' LEGEND U 18 音频优化+米浴纯享版")
            isEqualToString:@"GIRLS' LEGEND U"],
            @"franchise and re-upload notes should be removed from a song title");
        NSURLComponents *broadComponents = [NSURLComponents componentsWithURL:
            [provider searchURLForTitle:@"Example Song" artist:@"Example Artist" broad:YES]
            resolvingAgainstBaseURL:NO];
        NSString *broadQuery = broadComponents.queryItems.firstObject.value;
        CIAssert([broadQuery containsString:@"Example Artist"] &&
            [broadQuery containsString:@"Example Song"],
            @"broad lookup should constrain the query with both artist and title");
        NSURLComponents *titleOnlyComponents = [NSURLComponents componentsWithURL:
            [provider searchURLForTitle:@"Precious Star Dreamer" artist:@"" broad:NO]
            resolvingAgainstBaseURL:NO];
        NSMutableDictionary<NSString *, NSString *> *titleOnlyItems = [NSMutableDictionary dictionary];
        for (NSURLQueryItem *item in titleOnlyComponents.queryItems) {
            titleOnlyItems[item.name] = item.value;
        }
        CIAssert([titleOnlyItems[@"track_name"] isEqualToString:@"Precious Star Dreamer"] &&
            titleOnlyItems[@"artist_name"] == nil,
            @"title-only lookup must not send a YouTube channel as artist_name");
        NSURLComponents *titleOnlyKeywordComponents = [NSURLComponents componentsWithURL:
            [provider searchURLForTitle:@"Precious Star Dreamer" artist:@"" broad:YES]
            resolvingAgainstBaseURL:NO];
        CIAssert(titleOnlyKeywordComponents.queryItems.count == 1 &&
            [titleOnlyKeywordComponents.queryItems.firstObject.name isEqualToString:@"q"] &&
            [titleOnlyKeywordComponents.queryItems.firstObject.value
                isEqualToString:@"Precious Star Dreamer"],
            @"title-only keyword lookup should match LRCLIB's web search mode");
        CIAssert([titleOnlyKeywordComponents.host
            isEqualToString:@"127.0.0.1"] &&
            [titleOnlyKeywordComponents.path
                isEqualToString:@"/lyrics/api/search"],
            @"lookups should use the configured LRCLIB base URL");
        NSURLComponents *exactComponents = [NSURLComponents componentsWithURL:
            [provider getURLForTitle:@"Never Looking Back"
                artist:@"Example Artist" duration:251.6]
            resolvingAgainstBaseURL:NO];
        NSMutableDictionary<NSString *, NSString *> *exactItems =
            [NSMutableDictionary dictionary];
        for (NSURLQueryItem *item in exactComponents.queryItems) {
            exactItems[item.name] = item.value;
        }
        CIAssert([exactComponents.path isEqualToString:@"/lyrics/api/get"] &&
            [exactItems[@"track_name"] isEqualToString:@"Never Looking Back"] &&
            [exactItems[@"artist_name"] isEqualToString:@"Example Artist"] &&
            [exactItems[@"duration"] isEqualToString:@"252"],
            @"a reliable artist should use one duration-aware exact lookup");

        NSHTTPURLResponse *blockedResponse = [[NSHTTPURLResponse alloc]
            initWithURL:[NSURL URLWithString:@"https://lrclib.net/api/search"]
            statusCode:200 HTTPVersion:@"HTTP/1.1"
            headerFields:@{@"Content-Type": @"text/html"}];
        NSData *blockedBody = [@"Sorry, you have been blocked"
            dataUsingEncoding:NSUTF8StringEncoding];
        CIAssert([provider responseLooksLikeBlockPage:blockedResponse
            data:blockedBody],
            @"an HTML block page should be recognized even if an edge returns HTTP 200");
        NSString *cooldownEndpoint =
            @"https://caption-island-smoke.invalid";
        NSHTTPURLResponse *rateLimitResponse = [[NSHTTPURLResponse alloc]
            initWithURL:[NSURL URLWithString:cooldownEndpoint]
            statusCode:429 HTTPVersion:@"HTTP/1.1"
            headerFields:@{@"Retry-After": @"120"}];
        NSTimeInterval recordedCooldown = [provider
            recordCooldownForEndpoint:cooldownEndpoint
            status:429 response:rateLimitResponse];
        CILRCLIBProvider *cooldownProvider =
            [CILRCLIBProvider new];
        CIAssert(recordedCooldown >= 120 &&
            [cooldownProvider cooldownRemainingForEndpoint:
                cooldownEndpoint] > 0,
            @"rate-limit cooldowns should survive a provider restart");
        [provider clearCooldownForEndpoint:cooldownEndpoint];

        error = nil;
        NSArray *titleOnlyCandidates = @[
            CIRecord(8, @"Precious Star Dreamer", @"Unrelated Artist", 267.0,
                @"Distant plain\nSecond line", nil),
            CIRecord(9, @"Precious Star Dreamer", @"Correct Database Artist", 252.2,
                @"Closest synced\nSecond line",
                @"[00:01.00]Closest synced\n[03:20.00]Second line"),
        ];
        CILRCLIBResult *titleOnlyResult = [provider lyricsResultFromSearchData:
            CIJSONData(titleOnlyCandidates) title:@"Precious Star Dreamer" artist:@""
            videoDuration:252.0 error:&error];
        CIAssert(titleOnlyResult.recordID == 9 && error == nil,
            @"an empty artist should rank title matches by the closest duration");

        error = nil;
        CILRCLIBResult *exactResult = [provider lyricsResultFromExactData:
            CIJSONData(CIRecord(90, @"Never Looking Back", @"Example Artist",
                252.0, @"Exact first\nExact second",
                @"[00:01.00]Exact first\n[03:20.00]Exact second"))
            title:@"Never Looking Back" artist:@"Example Artist"
            videoDuration:252.0 error:&error];
        CIAssert(exactResult.recordID == 90 &&
            exactResult.syncedCues.count == 2 && error == nil,
            @"the metadata endpoint object should use the same safety checks as search results");
        [CILRCLIBProvider clearPersistentCache];
        NSString *persistentKey = [provider
            cacheKeyForTitle:@"Never Looking Back"
            artist:@"Example Artist" duration:252.0 exact:YES
            endpointIdentity:CILRCLIBBaseURL()];
        [provider storeResult:exactResult forCacheKey:persistentKey];
        CILRCLIBProvider *reloadedProvider =
            [CILRCLIBProvider new];
        BOOL negativeHit = NO;
        CILRCLIBResult *persistentResult =
            [reloadedProvider cachedResultForKey:persistentKey
                negativeHit:&negativeHit];
        CIAssert(persistentResult.recordID == 90 &&
            persistentResult.fromPersistentCache &&
            persistentResult.syncedCues.count == 2 &&
            !negativeHit,
            @"a successful lookup should survive a provider restart without another request");
        NSString *negativeKey = [provider
            cacheKeyForTitle:@"Missing Song"
            artist:@"" duration:180.0 exact:NO
            endpointIdentity:CILRCLIBBaseURL()];
        [provider storeNegativeResultForCacheKey:negativeKey];
        CILRCLIBProvider *negativeProvider =
            [CILRCLIBProvider new];
        negativeHit = NO;
        CIAssert([negativeProvider cachedResultForKey:negativeKey
            negativeHit:&negativeHit] == nil && negativeHit,
            @"a recent no-result lookup should suppress repeated network searches");
        [CILRCLIBProvider clearPersistentCache];

        error = nil;
        NSArray *artistConstrainedCandidates = @[
            CIRecord(91, @"Never Looking Back", @"Unrelated Singer", 248.0,
                @"Wrong but closer\nSecond line", nil),
            CIRecord(92, @"Never Looking Back", @"Uma Musume Pretty Derby", 252.0,
                @"Correct artist\nSecond line", nil),
        ];
        CILRCLIBResult *artistConstrainedResult =
            [provider lyricsResultFromSearchData:
                CIJSONData(artistConstrainedCandidates)
                title:@"Never Looking Back"
                artist:@"Uma Musume Pretty Derby"
                videoDuration:248.0
                error:&error];
        CIAssert(artistConstrainedResult.recordID == 92 && error == nil,
            @"a correct artist must beat a wrong artist even when its duration is less exact");

        // With no usable artist the duration decides, because a popular song
        // has many performers in LRCLIB and abstaining on all of them would
        // mean never showing lyrics for the songs most likely to be watched.
        error = nil;
        CILRCLIBResult *durationDecides =
            [provider lyricsResultFromSearchData:
                CIJSONData(artistConstrainedCandidates)
                title:@"Never Looking Back"
                artist:@""
                videoDuration:248.0
                error:&error];
        CIAssert(durationDecides.recordID == 91 && error == nil,
            @"title-only lookup should take the clearly closer duration rather than abstain");

        // Abstention is now reserved for a real tie: same title, different
        // performers, identical durations, neither carrying a timeline.
        NSArray *tiedCandidates = @[
            CIRecord(97, @"Never Looking Back", @"Kobayashi Rin", 250.0,
                @"Version one\nSecond line", nil),
            CIRecord(98, @"Never Looking Back", @"Wilkinson Trio", 250.0,
                @"Version two\nSecond line", nil),
        ];
        error = nil;
        CILRCLIBResult *trueTie = [provider lyricsResultFromSearchData:
            CIJSONData(tiedCandidates) title:@"Never Looking Back"
            artist:@"" videoDuration:250.0 error:&error];
        CIAssert(trueTie == nil && error.code == 404,
            @"two indistinguishable performances at the same duration should still abstain");

        // A timeline is the feature's whole point, so it breaks a duration tie
        // instead of being treated as a coin flip.
        error = nil;
        CILRCLIBResult *syncedBreaksTie = [provider lyricsResultFromSearchData:
            CIJSONData(@[
                tiedCandidates[0],
                CIRecord(99, @"Never Looking Back", @"Wilkinson Trio", 250.0,
                    @"Version two\nSecond line",
                    @"[00:01.00]Version two\n[04:00.00]Second line"),
            ])
            title:@"Never Looking Back" artist:@"" videoDuration:250.0
            error:&error];
        CIAssert(syncedBreaksTie.recordID == 99 && error == nil,
            @"a synced timeline should resolve a duration tie between performers");

        // Upload titles built around a separator frequently put something other
        // than a performer on the left: a game and scene name, a franchise, a
        // program. The strict pass cannot match such a value against any
        // database credit, so the permissive pass has to decide on title and
        // duration alone or these uploads never resolve.
        error = nil;
        NSArray *bogusArtistCandidates = @[
            CIRecord(50, @"Cosmic Scale Pretty", @"Ingrid", 214.0,
                @"Correct track\nSecond line",
                @"[00:01.00]Correct track\n[03:30.00]Second line"),
        ];
        CILRCLIBResult *bogusArtistResult = [provider bestResultFromSearchData:
            CIJSONData(bogusArtistCandidates) title:@"Cosmic Scale Pretty"
            artist:@"Street Fighter 6 Ingrid's Theme" videoDuration:214.0
            error:&error];
        CIAssert(bogusArtistResult.recordID == 50 &&
            bogusArtistResult.syncedCues.count == 2 && error == nil,
            @"a scene or franchise label must not suppress a title and duration match");

        // A short title normally requires artist agreement, which an uploader
        // channel can never provide. This is where the permissive pass is
        // load-bearing: the strict pass rejects the record outright.
        NSArray *shortTitleCandidates = @[
            CIRecord(51, @"愛唄", @"GReeeeN", 297.0,
                @"First line\nSecond line", nil),
        ];
        error = nil;
        CIAssert([provider lyricsResultFromSearchData:
            CIJSONData(shortTitleCandidates) title:@"愛唄"
            artist:@"Uploader Channel" videoDuration:297.0
            error:&error] == nil,
            @"the strict pass should still require artist agreement for a short title");
        error = nil;
        CILRCLIBResult *shortTitleResult = [provider bestResultFromSearchData:
            CIJSONData(shortTitleCandidates)
            title:@"愛唄" artist:@"Uploader Channel" videoDuration:297.0
            error:&error];
        CIAssert(shortTitleResult.recordID == 51 && error == nil,
            @"a short title with an unusable artist guess should fall back to duration");

        error = nil;
        CILRCLIBResult *corroboratedStillWins = [provider bestResultFromSearchData:
            CIJSONData(artistConstrainedCandidates)
            title:@"Never Looking Back"
            artist:@"Uma Musume Pretty Derby"
            videoDuration:248.0
            error:&error];
        CIAssert(corroboratedStillWins.recordID == 92 && error == nil,
            @"a corroborated artist must still beat a wrong artist with a closer duration");

        error = nil;
        CILRCLIBResult *stillAbstains = [provider bestResultFromSearchData:
            CIJSONData(tiedCandidates)
            title:@"Never Looking Back"
            artist:@"Unrelated Uploader"
            videoDuration:250.0
            error:&error];
        CIAssert(stillAbstains == nil && error.code == 404,
            @"widening the search must not start guessing between indistinguishable performances");

        error = nil;
        NSArray *TVAndFullCandidates = @[
            CIRecord(93, @"Anime Song", @"Example Artist", 89.5,
                @"TV size\nSecond line", nil),
            CIRecord(94, @"Anime Song", @"Example Artist", 251.0,
                @"Full size\nSecond line", nil),
        ];
        CILRCLIBResult *TVSizeResult = [provider lyricsResultFromSearchData:
            CIJSONData(TVAndFullCandidates) title:@"Anime Song"
            artist:@"Example Artist" videoDuration:90.0 error:&error];
        CIAssert(TVSizeResult.recordID == 93 && error == nil,
            @"a 90-second video must prefer the TV-size record over the full version");

        error = nil;
        CILRCLIBResult *fullSizeResult = [provider lyricsResultFromSearchData:
            CIJSONData(TVAndFullCandidates) title:@"Anime Song"
            artist:@"Example Artist" videoDuration:251.0 error:&error];
        CIAssert(fullSizeResult.recordID == 94 && error == nil,
            @"a full-length video must prefer the full-size record over the TV version");

        error = nil;
        CILRCLIBResult *unsafeFullForTV = [provider lyricsResultFromSearchData:
            CIJSONData(@[TVAndFullCandidates[1]]) title:@"Anime Song"
            artist:@"Example Artist" videoDuration:90.0 error:&error];
        CIAssert(unsafeFullForTV == nil && error.code == 404,
            @"a full-size-only result must be rejected for a TV-size video");

        error = nil;
        CILRCLIBResult *mediumEditForTV =
            [provider lyricsResultFromSearchData:
                CIJSONData(@[
                    CIRecord(95, @"Anime Song", @"Example Artist", 120.0,
                        @"Longer edit\nSecond line", nil),
                ])
                title:@"Anime Song"
                artist:@"Example Artist"
                videoDuration:90.0
                error:&error];
        CIAssert(mediumEditForTV == nil && error.code == 404,
            @"a 120-second database edit must not be accepted for a 90-second video");

        error = nil;
        CILRCLIBResult *videoWithLongIntro =
            [provider lyricsResultFromSearchData:
                CIJSONData(@[
                    CIRecord(96, @"Anime Song", @"Example Artist", 204.0,
                        @"Song after intro\nSecond line", nil),
                ])
                title:@"Anime Song"
                artist:@"Example Artist"
                videoDuration:240.0
                error:&error];
        CIAssert(videoWithLongIntro.recordID == 96 && error == nil,
            @"a video may remain longer than its song because of a story intro or outro");

        error = nil;
        NSArray *nearbyVersions = @[
            CIRecord(10, @"Example Song", @"Example Artist", 210.0,
                @"Plain first\nPlain second", nil),
            CIRecord(11, @"Example Song", @"Example Artist", 212.5,
                @"Synced first\nSynced second",
                @"[00:01.00]Synced first\n[03:00.00]Synced second"),
            CIRecord(12, @"Example Song (Live)", @"Example Artist", 211.0,
                @"Wrong version", @"[00:01.00]Wrong version"),
        ];
        CILRCLIBResult *result = [provider lyricsResultFromSearchData:
            CIJSONData(nearbyVersions) title:@"Example Song" artist:@"Example Artist"
            videoDuration:211.0 error:&error];
        CIAssert(result != nil && error == nil, @"valid search response should parse");
        CIAssert(result.recordID == 11, @"nearby synced version should beat a marginally closer plain version");
        CIAssert(result.syncedCues.count == 2, @"syncedLyrics should become timed cues");
        CIAssert(fabs(result.syncedCues[0].startTime - 1.0) < 0.001,
            @"LRC timestamps should remain tied to playback media time");

        error = nil;
        NSArray *distantSynced = @[
            CIRecord(20, @"Example Song", @"Example Artist", 211.0,
                @"Closest plain\nSecond line", nil),
            CIRecord(21, @"Example Song", @"Example Artist", 230.0,
                @"Distant synced", @"[00:01.00]Distant synced"),
        ];
        result = [provider lyricsResultFromSearchData:CIJSONData(distantSynced)
            title:@"Example Song" artist:@"Example Artist" videoDuration:211.0 error:&error];
        CIAssert(result.recordID == 20, @"synced preference must not select a clearly different duration");
        CIAssert(result.syncedCues.count == 0 &&
            [result.plainLyrics containsString:@"Closest plain"],
            @"closest plain lyrics should remain the fallback");

        error = nil;
        NSArray *singleCue = @[
            CIRecord(22, @"Example Song", @"Example Artist", 211.0,
                @"First\nSecond\nThird\nFourth",
                @"[00:01.00]Only one timestamp"),
        ];
        result = [provider lyricsResultFromSearchData:CIJSONData(singleCue)
            title:@"Example Song" artist:@"Example Artist" videoDuration:211.0 error:&error];
        CIAssert(result.recordID == 22 && result.syncedCues.count == 0 &&
            [result.plainLyrics containsString:@"Fourth"],
            @"an incomplete one-cue timeline should fall back to its plain lyrics");

        error = nil;
        NSArray *onlyDistantTimeline = @[
            CIRecord(23, @"Example Song", @"Example Artist", 240.0,
                @"First\nSecond",
                @"[00:01.00]First\n[00:04.00]Second"),
        ];
        result = [provider lyricsResultFromSearchData:CIJSONData(onlyDistantTimeline)
            title:@"Example Song" artist:@"Example Artist" videoDuration:211.0 error:&error];
        CIAssert(result.recordID == 23 && result.syncedCues.count == 0,
            @"a uniquely matched but distant timeline should use plain lyrics instead");

        error = nil;
        NSArray *distantTimelineWithoutPlain = @[
            CIRecord(24, @"Example Song", @"Example Artist", 240.0,
                nil, @"[00:01.00]First\n[00:04.00]Second"),
        ];
        result = [provider lyricsResultFromSearchData:CIJSONData(distantTimelineWithoutPlain)
            title:@"Example Song" artist:@"Example Artist" videoDuration:211.0 error:&error];
        CIAssert(result == nil && error.code == 404,
            @"an unsafe synced timeline without plain lyrics must be rejected");

        error = nil;
        NSArray *wrongArtist = @[
            CIRecord(25, @"Hello", @"Adele", 295.0,
                @"Hello from the other side", nil),
        ];
        result = [provider lyricsResultFromSearchData:CIJSONData(wrongArtist)
            title:@"Hello" artist:@"Random Uploader" videoDuration:295.0 error:&error];
        CIAssert(result == nil && error.code == 404,
            @"an exact short title must not bypass a mismatched artist");

        error = nil;
        NSArray *malformedTimeline = @[
            CIRecord(26, @"Example Song", @"Example Artist", 211.0,
                @"Plain survives\nSecond line", @"not an lrc timeline"),
        ];
        result = [provider lyricsResultFromSearchData:CIJSONData(malformedTimeline)
            title:@"Example Song" artist:@"Example Artist" videoDuration:211.0 error:&error];
        CIAssert(result.recordID == 26 && result.syncedCues.count == 0 &&
            [result.plainLyrics containsString:@"Plain survives"],
            @"malformed synced lyrics should fall back to valid plain lyrics");

        error = nil;
        NSArray *croppedTimeline = @[
            CIRecord(27, @"Example Song", @"Example Artist", 211.0,
                @"First\nSecond",
                @"[00:01.00]First\n[03:40.00]Outside the video"),
        ];
        result = [provider lyricsResultFromSearchData:CIJSONData(croppedTimeline)
            title:@"Example Song" artist:@"Example Artist" videoDuration:211.0 error:&error];
        CIAssert(result.recordID == 27 && result.syncedCues.count == 0,
            @"synced safety checks should run after cues outside the video are removed");

        error = nil;
        NSArray *missingTrackDuration = @[
            CIRecord(28, @"Example Song", @"Example Artist", 0,
                @"First\nSecond",
                @"[00:01.00]First\n[01:00.00]Second"),
        ];
        result = [provider lyricsResultFromSearchData:CIJSONData(missingTrackDuration)
            title:@"Example Song" artist:@"Example Artist" videoDuration:211.0 error:&error];
        CIAssert(result.recordID == 28 && result.syncedCues.count == 0,
            @"unknown LRCLIB duration should not install an unverified synced timeline");

        error = nil;
        NSArray *tinyTimeline = @[
            CIRecord(29, @"Example Song", @"Example Artist", 211.0,
                @"First\nSecond",
                @"[00:01.00]First\n[00:04.00]Second"),
        ];
        result = [provider lyricsResultFromSearchData:CIJSONData(tinyTimeline)
            title:@"Example Song" artist:@"Example Artist" videoDuration:211.0 error:&error];
        CIAssert(result.recordID == 29 && result.syncedCues.count == 0,
            @"two tiny cues should not represent a full-length song timeline");

        error = nil;
        NSArray *gapTimeline = @[
            CIRecord(30, @"Short Song", @"Example Artist", 10.0,
                @"First\nSecond",
                @"[00:01.00]First\n[00:03.00]\n[00:05.00]Second"),
        ];
        result = [provider lyricsResultFromSearchData:CIJSONData(gapTimeline)
            title:@"Short Song" artist:@"Example Artist" videoDuration:10.0 error:&error];
        CIAssert(result.syncedCues.count == 2 &&
            fabs(result.syncedCues[0].endTime - 3.0) < 0.001,
            @"an empty LRC timestamp should end the prior line and create a display gap");

        error = nil;
        NSArray *placeholderOnly = @[
            CIRecord(31, @"Example Song", @"Example Artist", 211.0,
                @"*******\n*******", nil),
        ];
        result = [provider lyricsResultFromSearchData:CIJSONData(placeholderOnly)
            title:@"Example Song" artist:@"Example Artist" videoDuration:211.0 error:&error];
        CIAssert(result == nil && error.code == 404,
            @"placeholder-only plain lyrics should not become a candidate");

        error = nil;
        NSArray *unusable = @[
            @{
                @"id": @40,
                @"trackName": @"Different Track",
                @"artistName": @"Someone Else",
                @"duration": @211,
                @"instrumental": @NO,
                @"plainLyrics": @"Wrong",
                @"syncedLyrics": NSNull.null,
            },
            @{
                @"id": @41,
                @"trackName": @"Example Song",
                @"artistName": @"Example Artist",
                @"duration": @211,
                @"instrumental": @YES,
                @"plainLyrics": NSNull.null,
                @"syncedLyrics": NSNull.null,
            },
        ];
        result = [provider lyricsResultFromSearchData:CIJSONData(unusable)
            title:@"Example Song" artist:@"Example Artist" videoDuration:211.0 error:&error];
        CIAssert(result == nil && error.code == 404,
            @"instrumental and low-confidence candidates should be rejected");

        error = nil;
        NSData *malformedRoot = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
        result = [provider lyricsResultFromSearchData:malformedRoot
            title:@"Example Song" artist:@"Example Artist" videoDuration:211.0 error:&error];
        CIAssert(result == nil && error != nil, @"non-array search roots should fail safely");

        [NSUserDefaults.standardUserDefaults
            removeObjectForKey:CILRCLIBBaseURLKey];
        NSLog(@"LRCLIB provider smoke passed");
    }
    return 0;
}
