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
    // Square-bracket blocks are explicitly treated as YouTube decorations.
    // Unknown separators and ordinary parentheses remain part of the title so
    // a real song name is not shortened merely because it is styled.
    NSArray<NSString *> *patterns = @[
        // Remove all ASCII/full-width square-bracket and lenticular-bracket
        // blocks, not just leading ones: [HD], ［字幕］, 【ウマ娘】, etc.
        @"\\[[^\\]\\r\\n]*\\]|［[^］\\r\\n]*］|【[^】\\r\\n]*】",
        // Remove a trailing bracket only when it contains a known video,
        // version, lyric, subtitle, or transliteration marker.
        @"(?i)\\s*[\\[(（【][^\\])）】\\r\\n]*(?:official|music\\s*video|lyric\\s*video|mv|pv|lyrics?|audio|visualizer|hd|4k|full\\s*(?:ver(?:sion)?\\.?|song)|歌詞|歌词|パート分け|字幕|高音質|フル|完整版|動態歌詞|动态歌词|中文歌詞|中文歌词|中日字幕|romaji)[^\\])）】\\r\\n]*[\\])）】]\\s*$",
        // A pipe normally separates the actual title from upload metadata.
        // Unknown pipe suffixes are retained instead of being guessed away.
        @"(?i)\\s*[|｜]\\s*(?:full\\s*(?:ver(?:sion)?\\.?|song)|official(?:\\s*(?:music\\s*)?video)?|music\\s*video|lyric\\s*video|mv|pv|lyrics?|audio|visualizer|hd|4k|歌詞|歌词|パート分け|字幕|高音質|フル|完整版|動態歌詞|动态歌词|中文歌詞|中文歌词|中日字幕|romaji)(?:\\b|[\\s.：:【\\[(（/]).*$",
        // The same metadata is sometimes introduced with a dash.
        @"(?i)\\s*[-–—]\\s*(?:full\\s*(?:ver(?:sion)?\\.?|song)|official(?:\\s*(?:music\\s*)?video)?|music\\s*video|lyric\\s*video|mv|pv|lyrics?|audio|visualizer|hd|4k|歌詞|歌词|パート分け|字幕|高音質|フル|完整版|動態歌詞|动态歌词|中文歌詞|中文歌词|中日字幕|romaji)(?:\\b|[\\s.：:【\\[(（/]).*$"
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

NSString *CISongTitleFromVideoTitle(NSString *videoTitle) {
    NSString *original = CICleanCaptionText(videoTitle ?: @"");
    NSString *cleaned = CIRemoveVideoDecorations(original);
    // Regex cleanup is heuristic. Never turn a usable YouTube title into an
    // empty LRCLIB query when the entire title was a decorative-looking block.
    return cleaned.length > 0 ? cleaned : original;
}

void CISplitSongMetadata(NSString *videoTitle,
                         NSString *videoAuthor,
                         NSString **songTitle,
                         NSString **artist) {
    NSString *title = CISongTitleFromVideoTitle(videoTitle);
    NSString *author = CICleanCaptionText(videoAuthor ?: @"");
    NSRegularExpression *channelSuffix = [NSRegularExpression
        regularExpressionWithPattern:@"(?i)(?:\\s*[-–—]\\s*topic|\\s*vevo|\\s+official(?:\\s+artist)?(?:\\s+channel)?)$"
        options:0 error:nil];
    author = [channelSuffix stringByReplacingMatchesInString:author options:0
        range:NSMakeRange(0, author.length) withTemplate:@""];
    author = CICleanCaptionText(author);

    NSRange separator = NSMakeRange(NSNotFound, 0);
    for (NSString *candidate in @[@" - ", @" – ", @" — ", @"｜"]) {
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
