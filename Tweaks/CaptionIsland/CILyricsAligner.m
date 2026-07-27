#import "CILyricsAligner.h"
#import "CITextUtilities.h"
#import <math.h>

static double CIRequiredSimilarity(NSString *line) {
    NSUInteger length = CINormalizedText(line).length;
    if (length <= 4) return 0.72;
    if (length <= 8) return 0.56;
    return 0.43;
}

@implementation CILyricsAligner

+ (NSArray<CICaptionCue *> *)alignPlainLyrics:(NSString *)lyrics
                                      toASR:(NSArray<CICaptionCue *> *)ASRCues {
    NSArray<NSString *> *lines = CINonEmptyLines(lyrics);
    if (lines.count == 0 || ASRCues.count == 0) return @[];

    NSMutableArray *starts = [NSMutableArray arrayWithCapacity:lines.count];
    NSMutableArray *ends = [NSMutableArray arrayWithCapacity:lines.count];
    for (NSUInteger index = 0; index < lines.count; index++) {
        [starts addObject:NSNull.null];
        [ends addObject:NSNull.null];
    }

    NSUInteger cursor = 0;
    NSUInteger matched = 0;
    for (NSUInteger lineIndex = 0; lineIndex < lines.count && cursor < ASRCues.count; lineIndex++) {
        NSString *line = lines[lineIndex];
        double bestScore = 0;
        NSUInteger bestStart = NSNotFound;
        NSUInteger bestEnd = NSNotFound;
        NSUInteger searchEnd = MIN(ASRCues.count, cursor + 18);
        for (NSUInteger cueIndex = cursor; cueIndex < searchEnd; cueIndex++) {
            NSMutableString *candidate = [NSMutableString string];
            for (NSUInteger span = 0; span < 3 && cueIndex + span < ASRCues.count; span++) {
                if (candidate.length > 0) [candidate appendString:@" "];
                [candidate appendString:ASRCues[cueIndex + span].text];
                double score = CITextSimilarity(line, candidate);
                if (score > bestScore) {
                    bestScore = score;
                    bestStart = cueIndex;
                    bestEnd = cueIndex + span;
                }
            }
        }
        if (bestStart != NSNotFound && bestScore >= CIRequiredSimilarity(line)) {
            starts[lineIndex] = @(ASRCues[bestStart].startTime);
            ends[lineIndex] = @(ASRCues[bestEnd].endTime);
            cursor = bestEnd + 1;
            matched++;
        }
    }

    NSUInteger minimumMatches = lines.count <= 3 ? 1 : MAX((NSUInteger)2, (NSUInteger)ceil(lines.count * 0.25));
    if (matched < minimumMatches) return @[];

    // Fill gaps between reliable ASR anchors by interpolation. This keeps the
    // official lyric text while using speech recognition only as a clock.
    NSInteger previousAnchor = -1;
    for (NSUInteger index = 0; index <= lines.count; index++) {
        BOOL isAnchor = index < lines.count && starts[index] != NSNull.null;
        if (!isAnchor && index < lines.count) continue;
        NSInteger nextAnchor = index < lines.count ? (NSInteger)index : -1;
        NSUInteger gapStart = (NSUInteger)(previousAnchor + 1);
        NSUInteger gapCount = (nextAnchor >= 0 ? (NSUInteger)nextAnchor : lines.count) - gapStart;
        if (gapCount > 0) {
            NSTimeInterval left = previousAnchor >= 0 ? [ends[(NSUInteger)previousAnchor] doubleValue] : 0;
            NSTimeInterval right;
            if (nextAnchor >= 0) {
                right = [starts[(NSUInteger)nextAnchor] doubleValue];
            } else {
                CICaptionCue *lastASR = ASRCues.lastObject;
                right = MAX(left + gapCount * 2.0, lastASR.endTime);
            }
            if (right <= left) right = left + gapCount * 1.5;
            double slot = (right - left) / (double)gapCount;
            for (NSUInteger gap = 0; gap < gapCount; gap++) {
                NSUInteger lineIndex = gapStart + gap;
                starts[lineIndex] = @(left + slot * gap);
                ends[lineIndex] = @(left + slot * (gap + 1));
            }
        }
        if (nextAnchor >= 0) previousAnchor = nextAnchor;
    }

    NSMutableArray<NSNumber *> *monotonicStarts = [NSMutableArray arrayWithCapacity:lines.count];
    NSTimeInterval previousStart = -0.05;
    for (NSUInteger index = 0; index < lines.count; index++) {
        NSTimeInterval start = MAX([starts[index] doubleValue], previousStart + 0.05);
        [monotonicStarts addObject:@(start)];
        previousStart = start;
    }

    NSMutableArray<CICaptionCue *> *result = [NSMutableArray arrayWithCapacity:lines.count];
    for (NSUInteger index = 0; index < lines.count; index++) {
        NSTimeInterval start = monotonicStarts[index].doubleValue;
        NSTimeInterval end = [ends[index] doubleValue];
        if (index + 1 < lines.count) end = MIN(end, monotonicStarts[index + 1].doubleValue);
        if (end <= start) end = start + 1.5;
        [result addObject:[[CICaptionCue alloc] initWithStartTime:start endTime:end text:lines[index]]];
    }
    return result;
}

+ (NSArray<CICaptionCue *> *)estimatedCuesForPlainLyrics:(NSString *)lyrics
                                                duration:(NSTimeInterval)duration {
    NSArray<NSString *> *lines = CINonEmptyLines(lyrics);
    if (lines.count == 0 || duration <= 0) return @[];
    // Leave a small intro/outro margin, but never create a high-frequency timer.
    NSTimeInterval intro = MIN(8.0, duration * 0.04);
    NSTimeInterval outro = MIN(5.0, duration * 0.025);
    NSTimeInterval usable = MAX(0, duration - intro - outro);
    double slot = usable / (double)lines.count;
    if (slot < 0.25) return @[];
    NSMutableArray<CICaptionCue *> *result = [NSMutableArray arrayWithCapacity:lines.count];
    for (NSUInteger index = 0; index < lines.count; index++) {
        NSTimeInterval start = intro + slot * index;
        NSTimeInterval end = MIN(duration, intro + slot * (index + 1));
        [result addObject:[[CICaptionCue alloc] initWithStartTime:start endTime:end text:lines[index]]];
    }
    return result;
}

@end
