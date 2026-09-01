#import "CITextUtilities.h"
#import "CIConstants.h"

static NSString *CIDecodeCommonEntities(NSString *text) {
    NSDictionary<NSString *, NSString *> *entities = @{
        @"&amp;": @"&", @"&lt;": @"<", @"&gt;": @">",
        @"&quot;": @"\"", @"&apos;": @"'", @"&#39;": @"'", @"&nbsp;": @" "
    };
    NSMutableString *result = text.mutableCopy;
    [entities enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, __unused BOOL *stop) {
        [result replaceOccurrencesOfString:key withString:value options:0 range:NSMakeRange(0, result.length)];
    }];
    NSRegularExpression *numeric = [NSRegularExpression regularExpressionWithPattern:@"&#(x[0-9a-fA-F]+|[0-9]+);" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [numeric matchesInString:result options:0 range:NSMakeRange(0, result.length)];
    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        NSString *token = [result substringWithRange:[match rangeAtIndex:1]];
        unsigned long long value = 0;
        NSScanner *scanner;
        if ([token.lowercaseString hasPrefix:@"x"]) {
            scanner = [NSScanner scannerWithString:[token substringFromIndex:1]];
            [scanner scanHexLongLong:&value];
        } else {
            value = token.integerValue;
        }
        if (value == 0 || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) continue;
        NSString *replacement;
        if (value <= 0xFFFF) {
            unichar character = (unichar)value;
            replacement = [NSString stringWithCharacters:&character length:1];
        } else {
            uint32_t scalar = (uint32_t)value - 0x10000;
            unichar pair[] = {(unichar)(0xD800 + (scalar >> 10)), (unichar)(0xDC00 + (scalar & 0x3FF))};
            replacement = [NSString stringWithCharacters:pair length:2];
        }
        [result replaceCharactersInRange:match.range withString:replacement];
    }
    return result;
}

NSString *CICleanCaptionText(NSString *text) {
    if (![text isKindOfClass:NSString.class] || text.length == 0) return @"";
    NSString *result = [text stringByReplacingOccurrencesOfString:@"\u200B" withString:@""];
    result = [result stringByReplacingOccurrencesOfString:@"\u200E" withString:@""];
    result = [result stringByReplacingOccurrencesOfString:@"\u200F" withString:@""];
    result = [result stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    NSRegularExpression *tags = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil];
    result = [tags stringByReplacingMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:@""];
    result = CIDecodeCommonEntities(result);
    result = result.precomposedStringWithCanonicalMapping;
    NSRegularExpression *spaces = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    result = [spaces stringByReplacingMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:@" "];
    return [result stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

NSString *CINormalizedText(NSString *text) {
    NSString *clean = CICleanCaptionText(text).lowercaseString;
    NSMutableString *result = [NSMutableString stringWithCapacity:clean.length];
    NSCharacterSet *allowed = [NSCharacterSet alphanumericCharacterSet];
    [clean enumerateSubstringsInRange:NSMakeRange(0, clean.length)
                              options:NSStringEnumerationByComposedCharacterSequences
                           usingBlock:^(NSString *substring, __unused NSRange substringRange,
                                        __unused NSRange enclosingRange, __unused BOOL *stop) {
        if ([substring rangeOfCharacterFromSet:allowed].location != NSNotFound) [result appendString:substring];
    }];
    return result;
}

NSArray<NSString *> *CINonEmptyLines(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return @[];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [text enumerateLinesUsingBlock:^(NSString *line, __unused BOOL *stop) {
        NSString *clean = CICleanCaptionText(line);
        if (clean.length > 0 && ![clean hasPrefix:@"*******"]) [lines addObject:clean];
    }];
    return lines;
}

double CITextSimilarity(NSString *lhs, NSString *rhs) {
    NSString *a = CINormalizedText(lhs);
    NSString *b = CINormalizedText(rhs);
    if (a.length == 0 || b.length == 0) return 0;
    if ([a isEqualToString:b]) return 1;

    NSUInteger n = a.length, m = b.length;
    NSMutableData *rowData = [NSMutableData dataWithLength:(m + 1) * sizeof(NSUInteger)];
    NSMutableData *nextData = [NSMutableData dataWithLength:(m + 1) * sizeof(NSUInteger)];
    NSUInteger *row = rowData.mutableBytes;
    NSUInteger *next = nextData.mutableBytes;
    for (NSUInteger j = 0; j <= m; j++) row[j] = j;
    for (NSUInteger i = 1; i <= n; i++) {
        next[0] = i;
        unichar ca = [a characterAtIndex:i - 1];
        for (NSUInteger j = 1; j <= m; j++) {
            NSUInteger substitution = row[j - 1] + (ca == [b characterAtIndex:j - 1] ? 0 : 1);
            next[j] = MIN(MIN(row[j] + 1, next[j - 1] + 1), substitution);
        }
        NSUInteger *tmp = row; row = next; next = tmp;
    }
    return 1.0 - ((double)row[m] / (double)MAX(n, m));
}

// Bracket pairs whose contents are normally upload decoration rather than part of
// a track name. 「」, 『』 and 《》 are deliberately absent: all three quote a title,
// and are handled as a title source instead. A bilingual `【中文 English】` block
// remains removable here but is separately offered as two lower-priority readings
// by CISongQueryCandidates, so the committed parse does not become less cautious.
//
// This replaced a hand-maintained keyword list ("official", "歌詞", "音频优化", …).
// The list was surgical because a single wrong guess used to be the only guess;
// now that a lookup offers several readings and keeps the untouched title as a
// last resort, removing a bracket that mattered costs one wasted request rather
// than the whole match, and structural rules cover shapes nobody thought to add.
static NSString *const CIDecorationOpenBrackets = @"([{（［｛【〔〈";
static NSString *const CIDecorationCloseBrackets = @")]}）］｝】〕〉";
// The same two sets as regex character-class bodies. "]" and "[" must be escaped
// or the class terminates early and the rest becomes literal text — which is
// exactly how the first version of this silently stripped nothing at all.
static NSString *const CIDecorationOpenClass = @"(\\[{（［｛【〔〈";
static NSString *const CIDecorationCloseClass = @")\\]}）］｝】〕〉";

/// Strips bracketed decoration and any `feat.` credit.
///
/// Unbalanced brackets are left alone: an upload title truncated mid-bracket is
/// far more likely than a title that means to open one, and deleting to the end of
/// the string on a stray "(" would throw away the song name.
static NSString *CIRemoveVideoDecorations(NSString *value) {
    if (value.length == 0) return @"";
    NSString *result = CICleanCaptionText(value);

    NSString *pattern = [NSString stringWithFormat:
        @"[%@][^%@%@]*[%@]",
        CIDecorationOpenClass, CIDecorationOpenClass,
        CIDecorationCloseClass, CIDecorationCloseClass];
    NSRegularExpression *brackets = [NSRegularExpression
        regularExpressionWithPattern:pattern options:0 error:nil];
    // Innermost-first, repeatedly: one pass cannot clear 【[MV]】, and the inner
    // pair has to go before the outer one becomes a balanced match.
    for (NSUInteger pass = 0; pass < 4; pass++) {
        NSString *next = [brackets
            stringByReplacingMatchesInString:result options:0
                                       range:NSMakeRange(0, result.length)
                                withTemplate:@""];
        if ([next isEqualToString:result]) break;
        result = next;
    }

    // The only keyword rule left in code, and it is user-editable.
    //
    // A bare trailing "Official Music Video" carries no bracket, no separator and
    // no other structural marker, so nothing but the words themselves identifies
    // it — and left in place it reliably defeats the title match. Anchored to the
    // end so the words alone can never remove a whole title, and driven by
    // CIDiscardedTitleKeywords() so the user can add the phrases their own
    // uploaders use without a rebuild.
    //
    // feat./ft. is deliberately NOT handled here. Stripping it before the
    // separator split threw away everything after the credit, which for
    // "HoneyWorks feat.ハコニワリリィ - 質問、恋って何でしょうか?" was the song
    // itself. It is offered as an extra reading instead; see CISongQueryCandidates.
    for (NSString *keyword in CIDiscardedTitleKeywords()) {
        NSString *escaped =
            [NSRegularExpression escapedPatternForString:keyword];
        NSRegularExpression *anchored = [NSRegularExpression
            regularExpressionWithPattern:[NSString stringWithFormat:
                @"(?i)\\s*[-–—/|｜+]?\\s*%@\\s*$", escaped]
                                   options:0 error:nil];
        if (!anchored) continue;
        result = [anchored stringByReplacingMatchesInString:result options:0
            range:NSMakeRange(0, result.length) withTemplate:@""];
    }

    result = CICleanCaptionText(result);
    // Orphaned bracket characters left by nesting or by a truncated upload title.
    NSCharacterSet *orphans = [NSCharacterSet characterSetWithCharactersInString:
        [CIDecorationOpenBrackets
            stringByAppendingString:CIDecorationCloseBrackets]];
    result = [[result componentsSeparatedByCharactersInSet:orphans]
        componentsJoinedByString:@" "];
    NSCharacterSet *edgeSeparators = [NSCharacterSet
        characterSetWithCharactersInString:@" \t-|｜–—:：/／、,，"];
    result = [CICleanCaptionText(result)
        stringByTrimmingCharactersInSet:edgeSeparators];
    return CICleanCaptionText(result);
}

static BOOL CITextMatchesPattern(NSString *text, NSString *pattern) {
    if (text.length == 0 || pattern.length == 0) return NO;
    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:pattern
                                                  options:0
                                                    error:nil];
    return [regex firstMatchInString:text
                             options:0
                               range:NSMakeRange(0, text.length)] != nil;
}

static NSString *CILastMetadataSegment(NSString *value) {
    NSString *result = CICleanCaptionText(value);
    NSUInteger location = NSNotFound;
    NSUInteger separatorLength = 0;
    for (NSString *separator in @[@"|", @"｜", @"／"]) {
        NSRange found = [result rangeOfString:separator
                                     options:NSBackwardsSearch];
        if (found.location != NSNotFound &&
            (location == NSNotFound || found.location > location)) {
            location = found.location;
            separatorLength = found.length;
        }
    }
    if (location != NSNotFound) {
        result = [result substringFromIndex:location + separatorLength];
    }
    NSCharacterSet *edges =
        [NSCharacterSet characterSetWithCharactersInString:@" \t-|｜/／–—:："];
    return [CICleanCaptionText(result)
        stringByTrimmingCharactersInSet:edges];
}

static BOOL CIQuoteHasMediaContext(NSString *prefix) {
    NSString *context = CICleanCaptionText(prefix);
    if (context.length > 64) {
        context = [context substringFromIndex:context.length - 64];
    }
    return CITextMatchesPattern(
        context,
        @"(?i)(?:tv\\s*anime|anime|official\\s*(?:music\\s*)?video|"
         @"music\\s*video|アニメ|映画|ドラマ)\\s*[/／:：-]?\\s*$"
    );
}

static NSString *CIArtistCandidateFromQuotePrefix(NSString *prefix) {
    NSString *candidate = CILastMetadataSegment(prefix);
    if (candidate.length == 0 || candidate.length > 160) return @"";
    NSRange quoteRange = [candidate rangeOfCharacterFromSet:
        [NSCharacterSet characterSetWithCharactersInString:@"「」『』"]];
    if (quoteRange.location != NSNotFound) {
        return @"";
    }
    if (CITextMatchesPattern(
            candidate,
            @"(?i)(?:tv\\s*anime|anime|アニメ|映画|ドラマ|"
             @"ノンクレジット|opening|ending|\\bop\\b|\\bed\\b|"
             @"主題歌|テーマ|插曲|劇中歌|insert\\s+song)"
        )) {
        return @"";
    }
    return candidate;
}

// Some uploads put the work and role before a quoted song, then append the real
// performer after a pipe: `作品 插曲『Song』完整版｜Artist`. That explicit
// trailing field is stronger than treating the entire work description as an
// artist. Only pipes qualify here; a slash in ordinary suffix prose is too
// ambiguous to promote into performer metadata.
static NSString *CIArtistCandidateFromQuoteSuffix(NSString *suffix) {
    NSString *clean = CICleanCaptionText(suffix);
    NSUInteger location = NSNotFound;
    for (NSString *separator in @[@"|", @"｜"]) {
        NSRange found = [clean rangeOfString:separator
                                    options:NSBackwardsSearch];
        if (found.location != NSNotFound &&
            (location == NSNotFound || found.location > location)) {
            location = found.location;
        }
    }
    if (location == NSNotFound || location + 1 >= clean.length) return @"";
    NSString *candidate = [clean substringFromIndex:location + 1];
    NSCharacterSet *edges = [NSCharacterSet
        characterSetWithCharactersInString:@" \t-|｜/／–—:：「」『』《》"];
    candidate = [CICleanCaptionText(candidate)
        stringByTrimmingCharactersInSet:edges];
    return CIArtistCandidateFromQuotePrefix(candidate);
}

static BOOL CIExtractQuotedSongMetadata(NSString *value,
                                        NSString **songTitle,
                                        NSString **artist) {
    if (value.length == 0) return NO;
    NSRegularExpression *quotes = [NSRegularExpression
        regularExpressionWithPattern:
            @"「([^」\\r\\n]+)」|『([^』\\r\\n]+)』|《([^》\\r\\n]+)》"
                               options:0
                                 error:nil];
    NSArray<NSTextCheckingResult *> *matches =
        [quotes matchesInString:value
                        options:0
                          range:NSMakeRange(0, value.length)];
    NSString *bestTitle = @"";
    NSString *bestArtist = @"";
    NSInteger bestScore = NSIntegerMin;
    for (NSTextCheckingResult *match in matches) {
        NSRange titleRange = [match rangeAtIndex:1];
        if (titleRange.location == NSNotFound) titleRange = [match rangeAtIndex:2];
        if (titleRange.location == NSNotFound) titleRange = [match rangeAtIndex:3];
        if (titleRange.location == NSNotFound || titleRange.length == 0) continue;

        NSString *prefix = [value substringToIndex:match.range.location];
        if (CIQuoteHasMediaContext(prefix)) continue;
        NSString *title = CICleanCaptionText([value substringWithRange:titleRange]);
        if (title.length == 0) continue;
        NSString *suffix =
            CICleanCaptionText([value substringFromIndex:NSMaxRange(match.range)]);
        NSString *suffixArtist =
            CIArtistCandidateFromQuoteSuffix(suffix);
        NSString *candidateArtist = suffixArtist.length > 0
            ? suffixArtist : CIArtistCandidateFromQuotePrefix(prefix);

        NSInteger score = 1;
        if (candidateArtist.length > 0) score += 1;
        if (suffix.length == 0) score += 2;
        if (CITextMatchesPattern(
                suffix,
                @"(?i)^\\s*(?:official\\s*(?:music\\s*)?video|"
                 @"music\\s*video|lyric\\s*video|mv|pv)(?:\\b|\\s|[/／])"
            )) {
            score += 4;
        }
        if ([prefix rangeOfString:@"|"].location != NSNotFound ||
            [prefix rangeOfString:@"｜"].location != NSNotFound) {
            score += 1;
        }
        if (score > bestScore) {
            bestScore = score;
            bestTitle = title;
            bestArtist = candidateArtist;
        }
    }
    if (bestTitle.length == 0) return NO;
    if (songTitle) *songTitle = bestTitle;
    if (artist) *artist = bestArtist;
    return YES;
}

static BOOL CIRightSideLooksLikeArtist(NSString *value) {
    return CITextMatchesPattern(
        value,
        @"(?i)(?:^|[^a-z0-9])(?:feat\\.?|ft\\.?|cv\\.?|vocals?|"
         @"kasane\\s+teto|hatsune\\s+miku|sv)(?:[^a-z0-9]|$)|"
         @"初音ミク|重音テト|鏡音"
    );
}

static BOOL CIExtractSlashSongMetadata(NSString *value,
                                       NSString **songTitle,
                                       NSString **artist) {
    NSString *searchValue = CIRemoveVideoDecorations(value);
    NSRegularExpression *separator = [NSRegularExpression
        regularExpressionWithPattern:
            @"(?<!:)\\s+[/／]\\s+|(?<![:/\\d])[/／](?![/\\d])"
                               options:0
                                 error:nil];
    NSTextCheckingResult *match =
        [separator firstMatchInString:searchValue
                              options:0
                                range:NSMakeRange(0, searchValue.length)];
    if (!match) return NO;
    NSString *left = CIRemoveVideoDecorations(
        [searchValue substringToIndex:match.range.location]
    );
    NSString *right = CIRemoveVideoDecorations(
        [searchValue substringFromIndex:NSMaxRange(match.range)]
    );
    if (left.length == 0 || right.length == 0) return NO;
    if (CIRightSideLooksLikeArtist(right)) {
        if (songTitle) *songTitle = left;
        // This shape usually identifies a vocalist or voicebank rather than
        // LRCLIB's canonical artist/composer. Use it to determine which side
        // is the title, but do not turn a low-confidence credit into a hard
        // artist filter.
        if (artist) *artist = @"";
    } else {
        if (songTitle) *songTitle = right;
        if (artist) *artist = left;
    }
    return YES;
}

NSString *CISongTitleFromVideoTitle(NSString *videoTitle) {
    NSString *original = CICleanCaptionText(videoTitle ?: @"");
    NSString *structuredTitle = @"";
    if (CIExtractQuotedSongMetadata(original, &structuredTitle, NULL) ||
        CIExtractSlashSongMetadata(original, &structuredTitle, NULL)) {
        NSString *cleanedStructuredTitle =
            CIRemoveVideoDecorations(structuredTitle);
        if (cleanedStructuredTitle.length > 0) return cleanedStructuredTitle;
    }
    NSString *cleaned = CIRemoveVideoDecorations(original);
    // Regex cleanup is heuristic. Never turn a usable YouTube title into an
    // empty LRCLIB query when the entire title was a decorative-looking block.
    return cleaned.length > 0 ? cleaned : original;
}

void CISplitSongMetadata(NSString *videoTitle,
                         NSString *videoAuthor,
                         NSString **songTitle,
                         NSString **artist) {
    NSString *original = CICleanCaptionText(videoTitle ?: @"");
    NSString *title = @"";
    NSString *author = CICleanCaptionText(videoAuthor ?: @"");
    NSRegularExpression *channelSuffix = [NSRegularExpression
        regularExpressionWithPattern:@"(?i)(?:\\s*[-–—]\\s*topic|\\s*vevo|\\s+official(?:\\s+artist)?(?:\\s+channel)?)$"
        options:0 error:nil];
    BOOL hasTrustedArtistChannelSuffix =
        [channelSuffix firstMatchInString:author options:0
            range:NSMakeRange(0, author.length)] != nil;
    author = [channelSuffix stringByReplacingMatchesInString:author options:0
        range:NSMakeRange(0, author.length) withTemplate:@""];
    author = CICleanCaptionText(author);

    NSString *parsedArtist = @"";
    BOOL foundStructuredMetadata =
        CIExtractQuotedSongMetadata(original, &title, &parsedArtist) ||
        CIExtractSlashSongMetadata(original, &title, &parsedArtist);
    if (foundStructuredMetadata) {
        NSString *cleanedTitle = CIRemoveVideoDecorations(title);
        if (cleanedTitle.length > 0) title = cleanedTitle;
        parsedArtist = CICleanCaptionText(parsedArtist);
        if (parsedArtist.length > 0) author = parsedArtist;
        else if (!hasTrustedArtistChannelSuffix) author = @"";
    } else {
        title = CISongTitleFromVideoTitle(original);
        if (!hasTrustedArtistChannelSuffix) author = @"";
    }

    NSRange separator = NSMakeRange(NSNotFound, 0);
    for (NSString *candidate in
         (foundStructuredMetadata ? @[] : @[@" - ", @" – ", @" — ", @"｜"])) {
        NSRange found = [title rangeOfString:candidate];
        if (found.location != NSNotFound &&
            (separator.location == NSNotFound || found.location < separator.location)) {
            separator = found;
        }
    }
    if (separator.location != NSNotFound && separator.location > 0) {
        NSString *left = CICleanCaptionText([title substringToIndex:separator.location]);
        NSString *right = CICleanCaptionText([title substringFromIndex:NSMaxRange(separator)]);
        if (left.length > 0 && right.length > 0) {
            author = left;
            title = right;
        }
    }
    if (songTitle) *songTitle = title;
    if (artist) *artist = author;
}

const NSUInteger CISongQueryMaximumCandidates = 6;

@interface CISongQuery ()
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *origin;
@end

@implementation CISongQuery
+ (instancetype)queryWithTitle:(NSString *)title
                        artist:(NSString *)artist
                        origin:(NSString *)origin {
    CISongQuery *query = [self new];
    query.title = CICleanCaptionText(title ?: @"");
    query.artist = CICleanCaptionText(artist ?: @"");
    query.origin = origin.length > 0 ? origin : @"unspecified";
    return query;
}
@end


// The two sides of the first separator that genuinely divides a title, or an
// empty array when there is none.
//
// Which side is the song is not decidable from the title — "AiNA THE END / On The
// Way" is artist-first and "風になる / Nachoneko" is title-first — so this only
// reports the split and lets the caller offer both readings.
//
// An ASCII hyphen must be surrounded by whitespace, so "Re-Bell", "K-POP" and
// "lo-fi" stay intact. An en or em dash is not used inside words so it counts
// unspaced, but never between digits, keeping "2019—2020" a range. Slashes and
// pipes count either way; a slash between digits is a date, not a separator.
static NSArray<NSString *> *CISeparatedSides(NSString *value,
                                            NSString *separatorPattern) {
    NSString *searchValue = CICleanCaptionText(value);
    if (searchValue.length == 0) return @[];
    NSRegularExpression *separator = [NSRegularExpression
        regularExpressionWithPattern:separatorPattern options:0 error:nil];
    NSTextCheckingResult *match =
        [separator firstMatchInString:searchValue options:0
                               range:NSMakeRange(0, searchValue.length)];
    if (!match) return @[];
    NSString *left = CIRemoveVideoDecorations(
        [searchValue substringToIndex:match.range.location]);
    NSString *right = CIRemoveVideoDecorations(
        [searchValue substringFromIndex:NSMaxRange(match.range)]);
    if (left.length == 0 || right.length == 0) return @[];
    return @[left, right];
}

// Dash, slash and pipe all divide a title the same way, so they share one rule.
static NSString *const CIPrimarySeparatorPattern =
    @"\\s+[-–—+]\\s+|(?<=[^\\s\\d])[–—](?=[^\\s\\d])"
     @"|\\s*[/／](?![/\\d])(?<![:/\\d][/／])\\s*|\\s*[|｜]\\s*"
     @"|(?<=[^\\s\\d])\\+(?=[^\\s\\d])";

// A colon usually introduces a credit or a role rather than dividing title from
// artist ("SawanoHiroyuki[nZk]:mizuki", "OP：曲名"), so its readings rank below
// the primary separators rather than replacing them.
static NSString *const CIColonSeparatorPattern = @"\\s*[:：]\\s*";

// Every 「」, 『』 or 《》 run in the title, in the order they appear.
//
// These three are the strongest brackets treated as a title source. A bilingual
// `【】` block is handled separately below at a lower priority. 《》 is the Chinese
// convention for naming a work, and on a music upload that work is usually the
// song. When it is not — "《鬼滅之刃》主題曲 紅蓮華" names the anime — the separator
// readings still cover the real track name, which is why this can be a first guess
// rather than a decision.
static NSArray<NSString *> *CIQuotedFragments(NSString *value) {
    if (value.length == 0) return @[];
    NSRegularExpression *quotes = [NSRegularExpression
        regularExpressionWithPattern:
            @"「([^」\\r\\n]+)」|『([^』\\r\\n]+)』|《([^》\\r\\n]+)》"
                               options:0 error:nil];
    NSMutableArray<NSString *> *fragments = [NSMutableArray array];
    for (NSTextCheckingResult *match in
         [quotes matchesInString:value options:0
                          range:NSMakeRange(0, value.length)]) {
        NSRange range = [match rangeAtIndex:1];
        if (range.location == NSNotFound) range = [match rangeAtIndex:2];
        if (range.location == NSNotFound) range = [match rangeAtIndex:3];
        if (range.location == NSNotFound || range.length == 0) continue;
        NSString *fragment =
            CICleanCaptionText([value substringWithRange:range]);
        if (fragment.length > 0) [fragments addObject:fragment];
    }
    return fragments;
}

// Chinese-language uploads often put two localized names in one decorative
// square bracket, e.g. `【中文歌名 English Song Name】`. Treating every `【】` block
// as a title would resurrect franchise, lyric and video-format labels, so this
// narrower rule activates only when one balanced block contains both Han and
// Latin text. The two scripts are returned as independent readings because LRCLIB
// may store either localized title, but rarely stores the combined upload form.
//
// Only a single transition is accepted. A block that alternates scripts again is
// prose, credits or mixed metadata rather than the common localized-title shape;
// leaving it to the verbatim fallback is safer than inventing more splits.
static NSArray<NSString *> *CIBilingualSquareBracketFragments(NSString *value) {
    if (value.length == 0) return @[];
    NSRegularExpression *blocks = [NSRegularExpression
        regularExpressionWithPattern:@"【([^】\\r\\n]+)】"
                               options:0 error:nil];
    NSRegularExpression *Han = [NSRegularExpression
        regularExpressionWithPattern:@"\\p{Han}" options:0 error:nil];
    NSRegularExpression *Latin = [NSRegularExpression
        regularExpressionWithPattern:@"[A-Za-z]" options:0 error:nil];
    NSMutableCharacterSet *scriptBoundaries =
        NSCharacterSet.whitespaceAndNewlineCharacterSet.mutableCopy;
    [scriptBoundaries formUnionWithCharacterSet:
        NSCharacterSet.punctuationCharacterSet];
    [scriptBoundaries formUnionWithCharacterSet:
        NSCharacterSet.symbolCharacterSet];
    NSMutableArray<NSString *> *fragments = [NSMutableArray array];
    for (NSTextCheckingResult *match in
         [blocks matchesInString:value options:0
                           range:NSMakeRange(0, value.length)]) {
        if ([match rangeAtIndex:1].location == NSNotFound) continue;
        NSString *content = CICleanCaptionText(
            [value substringWithRange:[match rangeAtIndex:1]]
        );
        NSRange whole = NSMakeRange(0, content.length);
        NSTextCheckingResult *firstHan =
            [Han firstMatchInString:content options:0 range:whole];
        NSTextCheckingResult *firstLatin =
            [Latin firstMatchInString:content options:0 range:whole];
        if (!firstHan || !firstLatin) continue;

        BOOL HanComesFirst = firstHan.range.location < firstLatin.range.location;
        NSUInteger split = HanComesFirst
            ? firstLatin.range.location : firstHan.range.location;
        if (split == 0 || split >= content.length) continue;
        // Two localized names need an actual boundary. Adjacent scripts such as
        // `CC中日字幕` are one upload label, not English and Chinese song names.
        if (![scriptBoundaries characterIsMember:
                [content characterAtIndex:split - 1]]) {
            continue;
        }
        NSString *left = [content substringToIndex:split];
        NSString *right = [content substringFromIndex:split];

        // Trim only upload-style delimiters around the language boundary. Broad
        // punctuation trimming would corrupt legitimate names such as "'Til
        // Morning" or "You?".
        NSCharacterSet *edges = [NSCharacterSet
            characterSetWithCharactersInString:@" \t-|｜/／–—:："];
        left = [CICleanCaptionText(left)
            stringByTrimmingCharactersInSet:edges];
        right = [CICleanCaptionText(right)
            stringByTrimmingCharactersInSet:edges];
        if (left.length == 0 || right.length == 0) continue;

        NSString *HanFragment = HanComesFirst ? left : right;
        NSString *LatinFragment = HanComesFirst ? right : left;
        NSRange HanRange = NSMakeRange(0, HanFragment.length);
        NSRange LatinRange = NSMakeRange(0, LatinFragment.length);
        NSUInteger HanCount = [Han numberOfMatchesInString:HanFragment
            options:0 range:HanRange];
        NSUInteger LatinCount = [Latin numberOfMatchesInString:LatinFragment
            options:0 range:LatinRange];
        // Reject a second script transition and one-character labels. This keeps
        // the rule specific to two complete localized names.
        if (HanCount < 2 || LatinCount < 2 ||
            [Latin firstMatchInString:HanFragment options:0 range:HanRange] ||
            [Han firstMatchInString:LatinFragment options:0 range:LatinRange]) {
            continue;
        }
        [fragments addObject:left];
        [fragments addObject:right];
    }
    return fragments.copy;
}

NSArray<CISongQuery *> *CISongQueryCandidates(NSString *videoTitle,
                                              NSString *videoAuthor) {
    NSString *original = CICleanCaptionText(videoTitle ?: @"");
    NSMutableArray<CISongQuery *> *queries = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    void (^add)(NSString *, NSString *, NSString *) =
    ^(NSString *title, NSString *artist, NSString *origin) {
        if (queries.count >= CISongQueryMaximumCandidates) return;
        NSString *cleanTitle = CICleanCaptionText(title ?: @"");
        // A run this long is a sentence or a channel blurb, not a track name, and
        // searching it only spends a rate-limited request.
        if (cleanTitle.length == 0 || cleanTitle.length > 200) return;
        NSString *identity = CINormalizedText(cleanTitle);
        if (identity.length == 0 || [seen containsObject:identity]) return;
        [seen addObject:identity];
        [queries addObject:[CISongQuery queryWithTitle:cleanTitle
                                               artist:artist
                                               origin:origin]];
    };

    // 1. A quoted run is the strongest signal a title can carry: the uploader
    //    marked the song themselves. The committed parse already prefers it, and
    //    it leads here so a title that resolves today still costs one request.
    NSString *parsedTitle = @"";
    NSString *parsedArtist = @"";
    CISplitSongMetadata(original, videoAuthor, &parsedTitle, &parsedArtist);
    NSArray<NSString *> *quoted = CIQuotedFragments(original);
    if (quoted.count > 0) {
        add(parsedTitle, parsedArtist, @"parsed");
        for (NSString *fragment in quoted) add(fragment, @"", @"quoted");
    } else {
        add(parsedTitle, parsedArtist, @"parsed");
    }

    // 2. Separate localized names inside a bilingual `【中文 English】` block.
    //    This is weaker than an explicit song quote but stronger than guessing
    //    which side of a generic separator is the track name.
    for (NSString *fragment in CIBilingualSquareBracketFragments(original)) {
        add(fragment, @"", @"bilingual-bracket");
    }

    // 3. Both sides of a dash, slash or pipe. The right side leads because
    //    "Artist - Song" is the more common shape, and each side is handed the
    //    other as its artist, which is a real ranking signal when the reading is
    //    the correct one.
    NSArray<NSString *> *sides =
        CISeparatedSides(original, CIPrimarySeparatorPattern);
    if (sides.count == 2) {
        add(sides[1], sides[0], @"separator-right");
        add(sides[0], sides[1], @"separator-left");
        // A side that also carries a quoted run keeps that run, because 「」 is a
        // title source and must not be stripped. But then the side reads
        // "世末歌者「那怕只 一瞬的 奇蹟。」 tk推薦 益笙菌" and matches nothing, so the
        // run before the quote is offered too. That is where the song name sits
        // when an uploader writes "artist - song「tagline」extra notes".
        for (NSString *side in sides) {
            NSRange quote = [side rangeOfCharacterFromSet:
                [NSCharacterSet characterSetWithCharactersInString:@"「『《"]];
            if (quote.location == NSNotFound || quote.location == 0) continue;
            add(CIRemoveVideoDecorations([side substringToIndex:quote.location]),
                @"", @"separator-head");
        }
    }

    // 4. A colon's readings, ranked after the primary separators.
    NSArray<NSString *> *colonSides =
        CISeparatedSides(original, CIColonSeparatorPattern);
    if (colonSides.count == 2) {
        add(colonSides[1], colonSides[0], @"colon-right");
        add(colonSides[0], colonSides[1], @"colon-left");
    }

    // 5. A feat./ft. credit dropped. This is a reading, not a rewrite: stripping
    //    it in the shared cleaner ran before the separator split and threw away
    //    everything after the credit — for
    //    "HoneyWorks feat.ハコニワリリィ - 質問、恋って何でしょうか?" that was the
    //    song. Both separator sides are offered above with the credit intact, and
    //    this adds the shortened form for the case where LRCLIB stores the track
    //    without it.
    NSRegularExpression *feat = [NSRegularExpression
        regularExpressionWithPattern:
            @"(?i)\\s*[-–—/|｜+]?\\s*\\b(?:feat|ft|featuring)\\b\\.?\\s*.*$"
                               options:0 error:nil];
    for (NSString *reading in queries.count > 0
             ? [queries valueForKey:@"title"] : @[]) {
        if (![reading isKindOfClass:NSString.class]) continue;
        NSString *withoutCredit = [feat
            stringByReplacingMatchesInString:reading options:0
                                       range:NSMakeRange(0, reading.length)
                                withTemplate:@""];
        if ([withoutCredit isEqualToString:reading]) continue;
        add(CIRemoveVideoDecorations(withoutCredit), @"", @"no-feat");
    }

    // 6. The title with nothing removed, as a last resort. This is what makes
    //    blanket bracket removal safe: when a bracket held part of the real name
    //    — "(Don't Fear) The Reaper", "Mine (Taylor's Version)" — the untouched
    //    title is still searched, so an over-eager strip costs a request instead
    //    of the match.
    add(original, @"", @"verbatim");

    // Never hand back an empty list: the caller has no other way to search.
    if (queries.count == 0) {
        add(CISongTitleFromVideoTitle(original), @"", @"fallback");
    }
    return queries.copy;
}
