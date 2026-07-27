#import "CICaptionParser.h"
#import "CITextUtilities.h"
#import <math.h>

static NSTimeInterval CIParseClock(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return -1;
    NSString *clean = [[value stringByReplacingOccurrencesOfString:@"," withString:@"."]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *parts = [clean componentsSeparatedByString:@":"];
    if (parts.count < 2 || parts.count > 3) return -1;
    double seconds = parts.lastObject.doubleValue;
    double minutes = parts[parts.count - 2].doubleValue;
    double hours = parts.count == 3 ? parts.firstObject.doubleValue : 0;
    return MAX(0, hours * 3600.0 + minutes * 60.0 + seconds);
}

static NSTimeInterval CIParseLRCTimestamp(NSString *value) {
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@":"];
    if (parts.count == 2) return parts[0].doubleValue * 60.0 + parts[1].doubleValue;
    if (parts.count != 3) return -1;
    NSString *last = parts[2];
    // Some legacy LRC files use [mm:ss:cc]. Treat a leading 00 as that
    // centisecond/millisecond form; otherwise accept [h:mm:ss.xxx].
    if ([parts[0] integerValue] == 0 && [last rangeOfString:@"."].location == NSNotFound) {
        double divisor = pow(10.0, MIN((NSUInteger)3, last.length));
        return parts[1].doubleValue + last.doubleValue / divisor;
    }
    return parts[0].doubleValue * 3600.0 + parts[1].doubleValue * 60.0 + last.doubleValue;
}

static NSArray<CICaptionCue *> *CIFinalizeCues(NSArray<CICaptionCue *> *input) {
    NSArray<CICaptionCue *> *sorted = [input sortedArrayUsingComparator:^NSComparisonResult(CICaptionCue *a, CICaptionCue *b) {
        if (a.startTime < b.startTime) return NSOrderedAscending;
        if (a.startTime > b.startTime) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSMutableArray<CICaptionCue *> *result = [NSMutableArray arrayWithCapacity:sorted.count];
    for (NSUInteger index = 0; index < sorted.count; index++) {
        CICaptionCue *cue = sorted[index];
        NSString *text = CICleanCaptionText(cue.text);
        if (text.length == 0) continue;
        NSTimeInterval end = cue.endTime;
        BOOL placeholderDuration = end <= cue.startTime + 0.051;
        if (index + 1 < sorted.count) {
            NSTimeInterval nextStart = sorted[index + 1].startTime;
            if (placeholderDuration || end > nextStart + 0.25) end = nextStart;
        } else if (placeholderDuration) {
            end = cue.startTime + 4.0;
        }
        if (end <= cue.startTime) end = cue.startTime + 2.5;
        [result addObject:[[CICaptionCue alloc] initWithStartTime:cue.startTime endTime:end text:text]];
    }
    return result;
}

@interface CITimedTextXMLCollector : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableArray<CICaptionCue *> *cues;
@property (nonatomic, strong, nullable) NSMutableString *currentText;
@property (nonatomic) NSTimeInterval currentStart;
@property (nonatomic) NSTimeInterval currentDuration;
@end

@implementation CITimedTextXMLCollector

- (instancetype)init {
    self = [super init];
    if (self) _cues = [NSMutableArray array];
    return self;
}

- (void)parser:(NSXMLParser *)parser
 didStartElement:(NSString *)elementName
    namespaceURI:(NSString *)namespaceURI
   qualifiedName:(NSString *)qName
      attributes:(NSDictionary<NSString *, NSString *> *)attributeDict {
    if ([elementName isEqualToString:@"br"] && self.currentText) {
        [self.currentText appendString:@"\n"];
        return;
    }
    if (![elementName isEqualToString:@"text"] && ![elementName isEqualToString:@"p"]) return;
    NSString *startValue = [elementName isEqualToString:@"p"] ? attributeDict[@"t"] : attributeDict[@"start"];
    if (startValue.length == 0) { self.currentText = nil; return; }
    self.currentText = [NSMutableString string];
    if ([elementName isEqualToString:@"p"]) {
        self.currentStart = [attributeDict[@"t"] doubleValue] / 1000.0;
        self.currentDuration = [attributeDict[@"d"] doubleValue] / 1000.0;
    } else {
        self.currentStart = [attributeDict[@"start"] doubleValue];
        self.currentDuration = [attributeDict[@"dur"] doubleValue];
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    [self.currentText appendString:string ?: @""];
}

- (void)parser:(NSXMLParser *)parser
   didEndElement:(NSString *)elementName
    namespaceURI:(NSString *)namespaceURI
   qualifiedName:(NSString *)qName {
    if (!self.currentText || (![elementName isEqualToString:@"text"] && ![elementName isEqualToString:@"p"])) return;
    NSTimeInterval duration = self.currentDuration > 0 ? self.currentDuration : 2.5;
    [self.cues addObject:[[CICaptionCue alloc] initWithStartTime:self.currentStart
                                                        endTime:self.currentStart + duration
                                                           text:self.currentText]];
    self.currentText = nil;
}

@end

@implementation CICaptionParser

+ (NSArray<CICaptionCue *> *)parseYouTubeData:(NSData *)data MIMEType:(NSString *)MIMEType {
    if (data.length == 0) return @[];
    NSString *prefix = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, MIN(data.length, 64))]
                                             encoding:NSUTF8StringEncoding] ?: @"";
    NSString *type = MIMEType.lowercaseString ?: @"";
    if ([type containsString:@"json"] || [prefix containsString:@"\"events\""]) {
        NSArray *cues = [self parseJSON3Data:data];
        if (cues.count > 0) return cues;
    }
    if ([type containsString:@"vtt"] || [prefix containsString:@"WEBVTT"]) {
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        NSArray *cues = [self parseWebVTTString:text];
        if (cues.count > 0) return cues;
    }
    NSArray *XMLCues = [self parseTimedTextXMLData:data];
    if (XMLCues.count > 0) return XMLCues;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return [self parseWebVTTString:text];
}

+ (NSArray<CICaptionCue *> *)parseJSON3Data:(NSData *)data {
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:NSDictionary.class]) return @[];
    NSArray *events = root[@"events"];
    if (![events isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<CICaptionCue *> *cues = [NSMutableArray array];
    for (NSDictionary *event in events) {
        if (![event isKindOfClass:NSDictionary.class]) continue;
        NSNumber *start = event[@"tStartMs"];
        NSArray *segments = event[@"segs"];
        if (![start respondsToSelector:@selector(doubleValue)] || ![segments isKindOfClass:NSArray.class]) continue;
        NSMutableString *line = [NSMutableString string];
        for (NSDictionary *segment in segments) {
            NSString *part = [segment isKindOfClass:NSDictionary.class] ? segment[@"utf8"] : nil;
            if ([part isKindOfClass:NSString.class]) [line appendString:part];
        }
        NSTimeInterval startTime = start.doubleValue / 1000.0;
        NSTimeInterval duration = [event[@"dDurationMs"] doubleValue] / 1000.0;
        if (duration <= 0) duration = 2.5;
        [cues addObject:[[CICaptionCue alloc] initWithStartTime:startTime
                                                      endTime:startTime + duration
                                                         text:line]];
    }
    return CIFinalizeCues(cues);
}

+ (NSArray<CICaptionCue *> *)parseWebVTTString:(NSString *)text {
    if (![text isKindOfClass:NSString.class] || text.length == 0) return @[];
    NSString *normalized = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
        stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSArray<NSString *> *blocks = [normalized componentsSeparatedByString:@"\n\n"];
    NSRegularExpression *timing = [NSRegularExpression regularExpressionWithPattern:@"((?:\\d{1,2}:)?\\d{1,2}:\\d{2}[.,]\\d{3})\\s*-->\\s*((?:\\d{1,2}:)?\\d{1,2}:\\d{2}[.,]\\d{3})" options:0 error:nil];
    NSMutableArray<CICaptionCue *> *cues = [NSMutableArray array];
    for (NSString *block in blocks) {
        NSString *trimmed = [block stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *upper = trimmed.uppercaseString;
        if ([upper hasPrefix:@"NOTE"] || [upper hasPrefix:@"STYLE"] || [upper hasPrefix:@"REGION"]) continue;
        NSTextCheckingResult *match = [timing firstMatchInString:block options:0 range:NSMakeRange(0, block.length)];
        if (!match || match.numberOfRanges < 3) continue;
        NSTimeInterval start = CIParseClock([block substringWithRange:[match rangeAtIndex:1]]);
        NSTimeInterval end = CIParseClock([block substringWithRange:[match rangeAtIndex:2]]);
        if (start < 0 || end <= start) continue;
        NSRange timingLine = [block lineRangeForRange:match.range];
        NSString *payload = NSMaxRange(timingLine) < block.length
            ? [block substringFromIndex:NSMaxRange(timingLine)] : @"";
        [cues addObject:[[CICaptionCue alloc] initWithStartTime:start endTime:end text:payload]];
    }
    return CIFinalizeCues(cues);
}

+ (NSArray<CICaptionCue *> *)parseTimedTextXMLData:(NSData *)data {
    if (data.length == 0) return @[];
    CITimedTextXMLCollector *collector = [CITimedTextXMLCollector new];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = collector;
    if (![parser parse]) return @[];
    return CIFinalizeCues(collector.cues);
}

+ (NSArray<CICaptionCue *> *)parseLRCString:(NSString *)text {
    if (![text isKindOfClass:NSString.class] || text.length == 0) return @[];
    NSRegularExpression *timestamp = [NSRegularExpression regularExpressionWithPattern:@"\\[((?:\\d{1,3}:){1,2}\\d{1,2}(?:[.:]\\d{1,3})?)\\]" options:0 error:nil];
    NSRegularExpression *offsetPattern = [NSRegularExpression regularExpressionWithPattern:@"(?i)\\[offset:([+-]?\\d+)\\]" options:0 error:nil];
    NSTextCheckingResult *offsetMatch = [offsetPattern firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    double offset = offsetMatch.numberOfRanges > 1 ? [[text substringWithRange:[offsetMatch rangeAtIndex:1]] doubleValue] / 1000.0 : 0;
    NSMutableArray<CICaptionCue *> *cues = [NSMutableArray array];
    [text enumerateLinesUsingBlock:^(NSString *line, __unused BOOL *stop) {
        NSArray<NSTextCheckingResult *> *matches = [timestamp matchesInString:line options:0 range:NSMakeRange(0, line.length)];
        if (matches.count == 0) return;
        NSUInteger payloadStart = NSMaxRange(matches.lastObject.range);
        NSString *payload = payloadStart <= line.length ? [line substringFromIndex:payloadStart] : @"";
        payload = CICleanCaptionText(payload);
        // Keep an empty timestamp as an internal gap sentinel. CIFinalizeCues
        // omits its text, but still uses its start time to end the prior line.
        if ([payload hasPrefix:@"*******"]) payload = @"";
        for (NSTextCheckingResult *match in matches) {
            NSString *timestampValue = [line substringWithRange:[match rangeAtIndex:1]];
            double parsed = CIParseLRCTimestamp(timestampValue);
            if (parsed < 0) continue;
            double start = MAX(0, parsed + offset);
            [cues addObject:[[CICaptionCue alloc] initWithStartTime:start endTime:start + 0.05 text:payload]];
        }
    }];
    return CIFinalizeCues(cues);
}

@end
