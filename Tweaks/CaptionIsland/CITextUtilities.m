#import "CITextUtilities.h"

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

static NSString *CIRemoveVideoDecorations(NSString *value) {
    if (value.length == 0) return @"";
    // Only discard bracketed text when it is recognizably upload metadata.
    // Artist identities such as SawanoHiroyuki[nZk] must remain searchable.
    NSArray<NSString *> *patterns = @[
        // A leading lenticular block is normally a franchise/category tag.
        // CISongTitleFromVideoTitle restores the original if it was the whole
        // title, so a real title such as 【アイドル】 is still preserved.
        @"^\\s*【[^】\\r\\n]*】\\s*",
        // Known decoration blocks can occur anywhere in an upload title.
        @"(?i)[\\[［【][^\\]］】\\r\\n]*(?:official|music\\s*video|lyric\\s*video|mv|pv|lyrics?|audio|visualizer|hd|4k|full\\s*(?:ver(?:sion)?\\.?|song)|歌詞|歌词|パート分け|字幕|高音質|フル|完整版|動態歌詞|动态歌词|中文歌詞|中文歌词|中日字幕|romaji)[^\\]］】\\r\\n]*[\\]］】]",
        // Remove a trailing bracket only when it contains a known video,
        // version, lyric, subtitle, or transliteration marker.
        @"(?i)\\s*[\\[(（【][^\\])）】\\r\\n]*(?:official|music\\s*video|lyric\\s*video|mv|pv|lyrics?|audio|visualizer|hd|4k|full\\s*(?:ver(?:sion)?\\.?|song)|歌詞|歌词|パート分け|字幕|高音質|フル|完整版|動態歌詞|动态歌词|中文歌詞|中文歌词|中日字幕|romaji)[^\\])）】\\r\\n]*[\\])）】]\\s*$",
        // Anime/program context following a clean song title is upload
        // metadata, not part of the LRCLIB track name.
        @"(?i)\\s*\\((?:tv\\s*)?(?:anime|アニメ)[^\\r\\n)]*(?:opening|ending|\\bop\\b|\\bed\\b|主題歌)[^\\r\\n)]*\\)\\s*$",
        // A pipe normally separates the actual title from upload metadata.
        // Unknown pipe suffixes are retained instead of being guessed away.
        @"(?i)\\s*[|｜]\\s*(?:full\\s*(?:ver(?:sion)?\\.?|song)|official(?:\\s*(?:music\\s*)?video)?|music\\s*video|lyric\\s*video|mv|pv|lyrics?|audio|visualizer|hd|4k|歌詞|歌词|パート分け|字幕|高音質|フル|完整版|動態歌詞|动态歌词|中文歌詞|中文歌词|中日字幕|romaji)(?:\\b|[\\s.：:【\\[(（/]).*$",
        // The same metadata is sometimes introduced with a dash.
        @"(?i)\\s*[-–—]\\s*(?:full\\s*(?:ver(?:sion)?\\.?|song)|official(?:\\s*(?:music\\s*)?video)?|music\\s*video|lyric\\s*video|mv|pv|lyrics?|audio|visualizer|hd|4k|歌詞|歌词|パート分け|字幕|高音質|フル|完整版|動態歌詞|动态歌词|中文歌詞|中文歌词|中日字幕|romaji)(?:\\b|[\\s.：:【\\[(（/]).*$",
        // Common re-upload notes, optionally preceded by a take/track number.
        @"(?i)\\s+(?:\\d+\\s*)?(?:音[频頻](?:优化|優化)|纯享版|純享版).*$"
    ];
    NSString *result = value;
    for (NSString *pattern in patterns) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        result = [regex stringByReplacingMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:@""];
        result = CICleanCaptionText(result);
    }
    NSCharacterSet *edgeSeparators = [NSCharacterSet characterSetWithCharactersInString:@" \t-|｜–—:："];
    result = [result stringByTrimmingCharactersInSet:edgeSeparators];
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
             @"主題歌|テーマ)"
        )) {
        return @"";
    }
    return candidate;
}

static BOOL CIExtractQuotedSongMetadata(NSString *value,
                                        NSString **songTitle,
                                        NSString **artist) {
    if (value.length == 0) return NO;
    NSRegularExpression *quotes = [NSRegularExpression
        regularExpressionWithPattern:@"「([^」\\r\\n]+)」|『([^』\\r\\n]+)』"
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
        if (titleRange.location == NSNotFound || titleRange.length == 0) continue;

        NSString *prefix = [value substringToIndex:match.range.location];
        if (CIQuoteHasMediaContext(prefix)) continue;
        NSString *title = CICleanCaptionText([value substringWithRange:titleRange]);
        if (title.length == 0) continue;
        NSString *suffix =
            CICleanCaptionText([value substringFromIndex:NSMaxRange(match.range)]);
        NSString *candidateArtist =
            CIArtistCandidateFromQuotePrefix(prefix);

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
