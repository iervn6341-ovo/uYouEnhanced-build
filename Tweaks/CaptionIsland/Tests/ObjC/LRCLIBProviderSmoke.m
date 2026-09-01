#import <Foundation/Foundation.h>
#import <math.h>
#import "../../CILRCLIBProvider.h"
#import "../../CITextUtilities.h"
#import "../../CIConstants.h"

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
- (NSURL *)searchURLForTitle:(NSString *)title artist:(NSString *)artist;
- (NSURL *)trackNameSearchURLForTitle:(NSString *)title;
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

// Keeps the browse-path regression test offline while still exercising the real
// NSURLSession request. The response deliberately stores the Japanese name only
// in albumName, matching the LRCLIB records that exposed the q=/track_name= bug.
static NSURL *CIStubLastRequestURL;
static NSData *CIStubResponseData;
static NSData *CIStubTrackNameResponseData;
static NSMutableArray<NSURL *> *CIStubRequestURLs;

@interface CILRCLIBStubURLProtocol : NSURLProtocol
@end

@implementation CILRCLIBStubURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return [request.URL.host isEqualToString:@"127.0.0.1"];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSData *data;
    @synchronized (CILRCLIBStubURLProtocol.class) {
        CIStubLastRequestURL = self.request.URL;
        if (!CIStubRequestURLs) CIStubRequestURLs = [NSMutableArray array];
        [CIStubRequestURLs addObject:self.request.URL];
        NSURLComponents *components = [NSURLComponents
            componentsWithURL:self.request.URL resolvingAgainstBaseURL:NO];
        BOOL usesTrackName = NO;
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name isEqualToString:@"track_name"]) {
                usesTrackName = YES;
                break;
            }
        }
        data = usesTrackName && CIStubTrackNameResponseData
            ? CIStubTrackNameResponseData : CIStubResponseData;
        data = data ?: [@"[]" dataUsingEncoding:NSUTF8StringEncoding];
    }
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
        initWithURL:self.request.URL
        statusCode:200
        HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Content-Type": @"application/json"}];
    [self.client URLProtocol:self didReceiveResponse:response
        cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {}

@end

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
        // A pipe is a separator now rather than a keyword-stripped suffix, so the
        // committed title keeps both halves and the reading list splits them.
        CIAssert([CISongTitleFromVideoTitle(
            @"【ウマ娘】Precious Star Dreamer | Full Ver.【パート分け/歌詞】")
            isEqualToString:@"Precious Star Dreamer | Full Ver."],
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
        // The Chinese re-upload notes are no longer a built-in keyword rule: they
        // are a channel habit, so they belong in the user's editable list. The
        // committed title keeps them, and "+" being a separator means the reading
        // list still offers the halves.
        CIAssert([CISongTitleFromVideoTitle(
            @"【赛马娘】GIRLS' LEGEND U 18 音频优化+米浴纯享版")
            isEqualToString:@"GIRLS' LEGEND U 18 音频优化+米浴纯享版"],
            @"a franchise label is structural and removed; a bare re-upload note is not");
        CISetDiscardedTitleKeywords(@[@"音频优化+米浴纯享版"]);
        CIAssert([CISongTitleFromVideoTitle(
            @"【赛马娘】GIRLS' LEGEND U 18 音频优化+米浴纯享版")
            isEqualToString:@"GIRLS' LEGEND U 18"],
            @"a user-supplied keyword should strip the suffix it names");
        CIAssert([CISongTitleFromVideoTitle(@"音频优化+米浴纯享版")
            isEqualToString:@"音频优化+米浴纯享版"],
            @"a keyword must never delete an entire title");
        CISetDiscardedTitleKeywords(nil);
        // The same re-upload notes wrapped in a bracket. Only the bare form was
        // recognized before, so a parenthesized one reached LRCLIB as part of the
        // track name and the lookup missed.
        // Bracketed, so no keyword is needed at all: every bracket pair except
        // 「」/『』 is discarded structurally.
        CIAssert([CISongTitleFromVideoTitle(
            @"【赛马娘】ユメヲカケル！  (米浴纯享版)")
            isEqualToString:@"ユメヲカケル！"],
            @"a bracketed note is discarded without any keyword involved");
        CIAssert([CISongTitleFromVideoTitle(
            @"【赛马娘】ユメヲカケル！（音频优化）")
            isEqualToString:@"ユメヲカケル！"],
            @"full-width brackets are discarded the same way");
        // A tilde is not a bracket and never decoration; subtitles use it.
        CIAssert([CISongTitleFromVideoTitle(@"歌名〜サブタイトル〜")
            isEqualToString:@"歌名〜サブタイトル〜"],
            @"tildes must be preserved");

        // 《》 is deliberately not an extraction source: the work it names is as
        // often the anime, film or album as the song. Pinned so reinstating it
        // has to be a deliberate change rather than a side effect.
        // 《》 is a title source alongside 「」 and 『』, not decoration.
        CIAssert([CISongTitleFromVideoTitle(@"竖屏｜《トレセン音頭》花钻Ver")
            isEqualToString:@"トレセン音頭"],
            @"a 《》 block names the track and leads the readings");
        // When the bracket names the work rather than the song, the separator
        // readings still reach the real track name, so a first guess is safe.
        CIAssert(CISongQueryCandidates(
            @"《鬼滅之刃》主題曲 紅蓮華 / LiSA", @"").count >= 3,
            @"an anime-naming bracket must not be the only reading offered");

        // A `【】` block remains decoration for the committed parse, but when one
        // block contains two localized names the Han and Latin halves become
        // second-tier readings. No artist or song-specific wording is involved.
        NSArray<CISongQuery *> *bilingualReadings = CISongQueryCandidates(
            @"MC HotDog 熱狗 feat.張震嶽 A-Yue&關穎 Terri Kwan【嗨嗨人生 High High Life】Official Music Video",
            @"");
        CIAssert(bilingualReadings.count >= 3 &&
            [bilingualReadings[1].title isEqualToString:@"嗨嗨人生"] &&
            [bilingualReadings[2].title isEqualToString:@"High High Life"] &&
            [bilingualReadings[1].origin isEqualToString:@"bilingual-bracket"] &&
            [bilingualReadings[2].origin isEqualToString:@"bilingual-bracket"],
            @"a bilingual square bracket should offer separate Han and Latin title readings immediately after the committed parse");
        NSArray<CISongQuery *> *reversedBilingualReadings =
            CISongQueryCandidates(@"Artist【High High Life 嗨嗨人生】Official Video", @"");
        NSMutableSet<NSString *> *reversedBilingualTitles = [NSMutableSet set];
        for (CISongQuery *reading in reversedBilingualReadings) {
            [reversedBilingualTitles addObject:reading.title];
        }
        CIAssert([reversedBilingualTitles containsObject:@"High High Life"] &&
            [reversedBilingualTitles containsObject:@"嗨嗨人生"],
            @"the localized-title split should also support Latin-first brackets");
        NSArray<CISongQuery *> *singleScriptReadings =
            CISongQueryCandidates(@"Artist【Official Music Video】【歌詞】", @"");
        for (CISongQuery *reading in singleScriptReadings) {
            CIAssert(![reading.title isEqualToString:@"Official Music Video"] &&
                ![reading.title isEqualToString:@"歌詞"],
                @"single-script square-bracket decoration must not become a title reading");
        }
        NSArray<CISongQuery *> *alternatingScriptReadings =
            CISongQueryCandidates(@"Artist【嗨嗨 High 人生 Life】Official Video", @"");
        for (CISongQuery *reading in alternatingScriptReadings) {
            CIAssert(![reading.title isEqualToString:@"嗨嗨"] &&
                ![reading.title isEqualToString:@"High 人生 Life"],
                @"a square bracket that alternates scripts more than once must not be split speculatively");
        }

        // Several readings of one title, most likely first. Nothing here reaches
        // the network: the assertions pin which queries would be issued.
        NSArray<CISongQuery *> *readings = CISongQueryCandidates(
            @"封茗囧菌x雙笙 - 世末歌者「那怕只 一瞬的 奇蹟。」 [ High Quality Lyrics ][ Chinese Style ] tk推薦 益笙菌",
            @"");
        NSMutableArray<NSString *> *readingTitles = [NSMutableArray array];
        for (CISongQuery *reading in readings) {
            [readingTitles addObject:reading.title];
        }
        CIAssert([readingTitles containsObject:@"那怕只 一瞬的 奇蹟。"],
            @"the quoted run is the strongest signal and must be offered");
        CIAssert([readingTitles containsObject:@"世末歌者"],
            @"the run before a quote on a separator side is where the song name sits");
        CIAssert([readingTitles containsObject:@"封茗囧菌x雙笙"],
            @"both separator sides must be offered, since neither is knowably the song");
        CIAssert([readingTitles.lastObject isEqualToString:
            @"封茗囧菌x雙笙 - 世末歌者「那怕只 一瞬的 奇蹟。」 [ High Quality Lyrics ][ Chinese Style ] tk推薦 益笙菌"],
            @"the untouched title must remain as the last resort, so stripping is never fatal");
        CIAssert(CISongQueryCandidates(@"Re-Bell", @"").count == 1,
            @"an unspaced ASCII hyphen inside a word must not be split");
        CIAssert(CISongQueryCandidates(@"", @"").count == 0,
            @"an empty title cannot produce a searchable reading");
        CIAssert(CISongQueryCandidates(
            @"A - B 「C」 『D』 「E」 - F", @"").count <=
                CISongQueryMaximumCandidates,
            @"the reading count must stay bounded so one lookup cannot burst");
        NSURLComponents *keywordComponents = [NSURLComponents componentsWithURL:
            [provider searchURLForTitle:@"Example Song" artist:@"Example Artist"]
            resolvingAgainstBaseURL:NO];
        NSString *keywordQuery = keywordComponents.queryItems.firstObject.value;
        CIAssert([keywordQuery containsString:@"Example Artist"] &&
            [keywordQuery containsString:@"Example Song"],
            @"keyword lookup should include both artist and title when both are supplied");
        NSURLComponents *titleOnlyKeywordComponents = [NSURLComponents componentsWithURL:
            [provider searchURLForTitle:@"Precious Star Dreamer" artist:@""]
            resolvingAgainstBaseURL:NO];
        CIAssert(titleOnlyKeywordComponents.queryItems.count == 1 &&
            [titleOnlyKeywordComponents.queryItems.firstObject.name isEqualToString:@"q"] &&
            [titleOnlyKeywordComponents.queryItems.firstObject.value
                isEqualToString:@"Precious Star Dreamer"],
            @"title-only keyword lookup should match LRCLIB's web search mode");
        NSURLComponents *localizedAlbumKeywordComponents =
            [NSURLComponents componentsWithURL:
                [provider searchURLForTitle:@"「今はいいんだよ」"
                    artist:@""]
                resolvingAgainstBaseURL:NO];
        CIAssert(localizedAlbumKeywordComponents.queryItems.count == 1 &&
            [localizedAlbumKeywordComponents.queryItems.firstObject.name
                isEqualToString:@"q"] &&
            [localizedAlbumKeywordComponents.queryItems.firstObject.value
                isEqualToString:@"「今はいいんだよ」"],
            @"manual browsing must preserve a localized title and search all LRCLIB fields");
        CIAssert([titleOnlyKeywordComponents.host
            isEqualToString:@"127.0.0.1"] &&
            [titleOnlyKeywordComponents.path
                isEqualToString:@"/lyrics/api/search"],
            @"lookups should use the configured LRCLIB base URL");

        NSDictionary *localizedAlbumRecord = @{
            @"id": @19094338,
            @"trackName": @"It's Okay Now (feat. KAFU)",
            @"artistName": @"MIMI, KAFU",
            @"albumName": @"今はいいんだよ。 (feat. 可不)",
            @"duration": @147,
            @"instrumental": @NO,
            @"plainLyrics": @"First line\nSecond line",
            @"syncedLyrics": @"[00:01.00]First line\n[00:05.00]Second line",
        };
        @synchronized (CILRCLIBStubURLProtocol.class) {
            CIStubLastRequestURL = nil;
            CIStubResponseData = CIJSONData(@[localizedAlbumRecord]);
            CIStubTrackNameResponseData = nil;
            CIStubRequestURLs = [NSMutableArray array];
        }
        NSURLSessionConfiguration *stubConfiguration =
            NSURLSessionConfiguration.ephemeralSessionConfiguration;
        stubConfiguration.protocolClasses = @[CILRCLIBStubURLProtocol.class];
        CILRCLIBProvider *browsePathProvider = [CILRCLIBProvider new];
        [browsePathProvider setValue:
            [NSURLSession sessionWithConfiguration:stubConfiguration]
                           forKey:@"session"];
        dispatch_semaphore_t browseFinished = dispatch_semaphore_create(0);
        __block NSArray<CILRCLIBResult *> *localizedMatches = nil;
        __block NSError *localizedBrowseError = nil;
        [browsePathProvider fetchAllMatchesForCandidates:@[
            [CISongQuery queryWithTitle:@"「今はいいんだよ」"
                                artist:@"" origin:@"manual"]
        ] duration:147 completion:
            ^(NSArray<CILRCLIBResult *> *matches, NSError *browseError) {
                localizedMatches = matches;
                localizedBrowseError = browseError;
                dispatch_semaphore_signal(browseFinished);
            }];
        long browseWait = dispatch_semaphore_wait(browseFinished,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
        NSURL *browseRequestURL;
        @synchronized (CILRCLIBStubURLProtocol.class) {
            browseRequestURL = CIStubLastRequestURL;
        }
        NSURLComponents *browseRequestComponents =
            [NSURLComponents componentsWithURL:browseRequestURL
                resolvingAgainstBaseURL:NO];
        NSMutableDictionary<NSString *, NSString *> *browseRequestItems =
            [NSMutableDictionary dictionary];
        for (NSURLQueryItem *item in browseRequestComponents.queryItems) {
            browseRequestItems[item.name] = item.value;
        }
        CIAssert(browseWait == 0 && localizedBrowseError == nil &&
            localizedMatches.count == 1 &&
            localizedMatches.firstObject.recordID == 19094338,
            @"manual browsing should retain an LRCLIB row whose localized title exists only in albumName");
        CIAssert([browseRequestItems[@"q"] isEqualToString:@"「今はいいんだよ」"] &&
            browseRequestItems[@"track_name"] == nil,
            @"the real manual browse path must send q= rather than track_name=");

        // Automatic playback must use the same q= request mode. Its stricter
        // local scoring remains responsible for rejecting unrelated matches.
        NSDictionary *automaticRecord = @{
            @"id": @19094339,
            @"trackName": @"「今はいいんだよ」",
            @"artistName": @"MIMI, KAFU",
            @"albumName": @"Single",
            @"duration": @147,
            @"instrumental": @NO,
            @"plainLyrics": @"First line\nSecond line",
            @"syncedLyrics": @"[00:01.00]First line\n[00:05.00]Second line",
        };
        [CILRCLIBProvider clearPersistentCache];
        @synchronized (CILRCLIBStubURLProtocol.class) {
            CIStubLastRequestURL = nil;
            CIStubResponseData = CIJSONData(@[automaticRecord]);
            CIStubTrackNameResponseData = nil;
            CIStubRequestURLs = [NSMutableArray array];
        }
        CILRCLIBProvider *automaticPathProvider = [CILRCLIBProvider new];
        [automaticPathProvider setValue:
            [NSURLSession sessionWithConfiguration:stubConfiguration]
                              forKey:@"session"];
        dispatch_semaphore_t automaticFinished = dispatch_semaphore_create(0);
        __block CILRCLIBResult *automaticResult = nil;
        __block NSError *automaticError = nil;
        [automaticPathProvider fetchLyricsForCandidates:@[
            [CISongQuery queryWithTitle:@"「今はいいんだよ」"
                                artist:@"" origin:@"automatic-test"]
        ] duration:147 completion:
            ^(CILRCLIBResult *result, NSError *lookupError) {
                automaticResult = result;
                automaticError = lookupError;
                dispatch_semaphore_signal(automaticFinished);
            }];
        long automaticWait = dispatch_semaphore_wait(automaticFinished,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
        NSURL *automaticRequestURL;
        NSUInteger automaticRequestCount;
        @synchronized (CILRCLIBStubURLProtocol.class) {
            automaticRequestURL = CIStubLastRequestURL;
            automaticRequestCount = CIStubRequestURLs.count;
        }
        NSURLComponents *automaticRequestComponents =
            [NSURLComponents componentsWithURL:automaticRequestURL
                resolvingAgainstBaseURL:NO];
        NSMutableDictionary<NSString *, NSString *> *automaticRequestItems =
            [NSMutableDictionary dictionary];
        for (NSURLQueryItem *item in automaticRequestComponents.queryItems) {
            automaticRequestItems[item.name] = item.value;
        }
        CIAssert(automaticWait == 0 && automaticError == nil &&
            automaticResult.recordID == 19094339,
            @"automatic lookup should still score and return a matching q= result");
        CIAssert([automaticRequestItems[@"q"]
                isEqualToString:@"「今はいいんだよ」"] &&
            automaticRequestItems[@"track_name"] == nil &&
            automaticRequestCount == 1,
            @"a non-empty automatic q= response must not trigger track_name=");
        [CILRCLIBProvider clearPersistentCache];

        NSDictionary *fallbackRecord = @{
            @"id": @19094340,
            @"trackName": @"Structured Fallback Song",
            @"artistName": @"Example Artist",
            @"albumName": @"Example Album",
            @"duration": @147,
            @"instrumental": @NO,
            @"plainLyrics": @"First line\nSecond line",
            @"syncedLyrics": @"[00:01.00]First line\n[00:05.00]Second line",
        };
        @synchronized (CILRCLIBStubURLProtocol.class) {
            CIStubLastRequestURL = nil;
            CIStubResponseData = CIJSONData(@[]);
            CIStubTrackNameResponseData = CIJSONData(@[fallbackRecord]);
            CIStubRequestURLs = [NSMutableArray array];
        }
        CILRCLIBProvider *fallbackPathProvider = [CILRCLIBProvider new];
        [fallbackPathProvider setValue:
            [NSURLSession sessionWithConfiguration:stubConfiguration]
                            forKey:@"session"];
        dispatch_semaphore_t fallbackFinished = dispatch_semaphore_create(0);
        __block CILRCLIBResult *fallbackResult = nil;
        __block NSError *fallbackError = nil;
        [fallbackPathProvider fetchLyricsForCandidates:@[
            [CISongQuery queryWithTitle:@"Structured Fallback Song"
                                artist:@"" origin:@"fallback-test"]
        ] duration:147 completion:
            ^(CILRCLIBResult *result, NSError *lookupError) {
                fallbackResult = result;
                fallbackError = lookupError;
                dispatch_semaphore_signal(fallbackFinished);
            }];
        long fallbackWait = dispatch_semaphore_wait(fallbackFinished,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)));
        NSArray<NSURL *> *fallbackRequestURLs;
        @synchronized (CILRCLIBStubURLProtocol.class) {
            fallbackRequestURLs = CIStubRequestURLs.copy;
        }
        NSURLComponents *firstFallbackRequest = fallbackRequestURLs.count > 0
            ? [NSURLComponents componentsWithURL:fallbackRequestURLs[0]
                resolvingAgainstBaseURL:NO] : nil;
        NSURLComponents *secondFallbackRequest = fallbackRequestURLs.count > 1
            ? [NSURLComponents componentsWithURL:fallbackRequestURLs[1]
                resolvingAgainstBaseURL:NO] : nil;
        CIAssert(fallbackWait == 0 && fallbackError == nil &&
            fallbackResult.recordID == 19094340,
            @"an empty q= response should still return a valid track_name= fallback result");
        CIAssert(fallbackRequestURLs.count == 2 &&
            [firstFallbackRequest.queryItems.firstObject.name
                isEqualToString:@"q"] &&
            [secondFallbackRequest.queryItems.firstObject.name
                isEqualToString:@"track_name"] &&
            [firstFallbackRequest.queryItems.firstObject.value
                isEqualToString:@"Structured Fallback Song"] &&
            [secondFallbackRequest.queryItems.firstObject.value
                isEqualToString:@"Structured Fallback Song"],
            @"an empty q= response must retry the same title with track_name= exactly once");
        [CILRCLIBProvider clearPersistentCache];
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

        // Several performers holding one title is not ambiguity: covers carry
        // the same words, so a known video length must still produce lyrics
        // even when the durations are identical.
        NSArray *tiedCandidates = @[
            CIRecord(97, @"Never Looking Back", @"Kobayashi Rin", 250.0,
                @"Version one\nSecond line", nil),
            CIRecord(98, @"Never Looking Back", @"Wilkinson Trio", 250.0,
                @"Version two\nSecond line", nil),
        ];
        error = nil;
        CILRCLIBResult *sameDurationDifferentSingers =
            [provider lyricsResultFromSearchData:
                CIJSONData(tiedCandidates) title:@"Never Looking Back"
                artist:@"" videoDuration:250.0 error:&error];
        CIAssert(sameDurationDifferentSingers != nil && error == nil,
            @"a known video length must resolve same-title records rather than abstain");

        // A timeline is the feature's whole point, so it decides among records
        // the duration cannot separate.
        error = nil;
        CILRCLIBResult *syncedWinsAtSameDuration =
            [provider lyricsResultFromSearchData:
                CIJSONData(@[
                    tiedCandidates[0],
                    CIRecord(99, @"Never Looking Back", @"Wilkinson Trio", 250.0,
                        @"Version two\nSecond line",
                        @"[00:01.00]Version two\n[04:00.00]Second line"),
                ])
                title:@"Never Looking Back" artist:@"" videoDuration:250.0
                error:&error];
        CIAssert(syncedWinsAtSameDuration.recordID == 99 && error == nil,
            @"a synced timeline should win when the duration cannot separate two records");

        // Without a video length there is nothing to judge by, and a
        // same-title-different-song mismatch would go undetected.
        error = nil;
        CILRCLIBResult *noDurationAbstains =
            [provider lyricsResultFromSearchData:
                CIJSONData(tiedCandidates) title:@"Never Looking Back"
                artist:@"" videoDuration:0 error:&error];
        CIAssert(noDurationAbstains == nil && error.code == 404,
            @"with no video length, same-title records by different artists should abstain");

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

        // Widening the search must not invent a duration to judge by: with no
        // video length the permissive pass has to abstain just as the strict
        // pass does.
        error = nil;
        CILRCLIBResult *stillAbstains = [provider bestResultFromSearchData:
            CIJSONData(tiedCandidates)
            title:@"Never Looking Back"
            artist:@"Unrelated Uploader"
            videoDuration:0
            error:&error];
        CIAssert(stillAbstains == nil && error.code == 404,
            @"widening the search must still abstain when nothing can separate two records");

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
