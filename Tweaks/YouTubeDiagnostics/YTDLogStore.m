#import "YTDLogStore.h"

NSNotificationName const YTDLogStoreDidChangeNotification =
    @"YTDLogStoreDidChangeNotification";

static const NSUInteger YTDMaxLogEntries = 2000;
static const unsigned long long YTDMaxLogFileBytes = 512 * 1024;
static const void *YTDLogQueueSpecificKey = &YTDLogQueueSpecificKey;

static NSString *YTDScrubValue(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length == 0) return @"";
    NSString *scrubbed = [value stringByReplacingOccurrencesOfString:@"\r\n"
                                                           withString:@" ↩︎ "];
    scrubbed = [scrubbed stringByReplacingOccurrencesOfString:@"\r"
                                                    withString:@" ↩︎ "];
    scrubbed = [scrubbed stringByReplacingOccurrencesOfString:@"\n"
                                                    withString:@" ↩︎ "];

    static NSArray<NSArray<NSString *> *> *rules;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        rules = @[
            @[@"(?i)(https?://[^\\s?&#<>]+)(?:\\?[^\\s<>]*)?", @"$1?<query redacted>"],
            @[@"(?i)file://[^\\s<>]+", @"<file URL redacted>"],
            @[@"(?i)\\bBearer\\s+[A-Za-z0-9._~+/=-]+", @"Bearer <redacted>"],
            @[@"(?i)\\b(authorization|cookie|set-cookie)\\b\\s*[:=]\\s*[^,;]+",
              @"$1=<redacted>"],
            @[@"(?i)\\b(api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|visitor[-_ ]?data|device[-_ ]?id)\\b\\s*[:=]\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s,;]+)",
              @"$1=<redacted>"],
            @[@"(?i)\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b",
              @"<email redacted>"],
        ];
    });
    for (NSArray<NSString *> *rule in rules) {
        NSRegularExpression *expression = [NSRegularExpression
            regularExpressionWithPattern:rule[0] options:0 error:nil];
        scrubbed = [expression stringByReplacingMatchesInString:scrubbed
            options:0 range:NSMakeRange(0, scrubbed.length)
            withTemplate:rule[1]];
    }
    if (scrubbed.length > 2000) {
        scrubbed = [[scrubbed substringToIndex:2000] stringByAppendingString:@"…"];
    }
    return scrubbed;
}

@interface YTDLogStore ()
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic, strong) NSMutableArray<NSString *> *entries;
@property (nonatomic, strong) NSDateFormatter *dateFormatter;
@property (nonatomic, copy) NSString *logPath;
@end

@implementation YTDLogStore

+ (instancetype)sharedStore {
    static YTDLogStore *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ store = [YTDLogStore new]; });
    return store;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create(
            "com.youtube.diagnostics.store", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, YTDLogQueueSpecificKey,
                                    (void *)YTDLogQueueSpecificKey, NULL);
        _entries = [NSMutableArray array];
        _dateFormatter = [NSDateFormatter new];
        _dateFormatter.locale =
            [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _dateFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";

        NSString *caches = NSSearchPathForDirectoriesInDomains(
            NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        NSString *directory =
            [caches stringByAppendingPathComponent:@"YouTubeDiagnostics"];
        [NSFileManager.defaultManager createDirectoryAtPath:directory
                                withIntermediateDirectories:YES
                                                 attributes:nil error:nil];
        _logPath = [directory
            stringByAppendingPathComponent:@"YouTubeDiagnostics.log"];
        NSString *existing = [NSString stringWithContentsOfFile:_logPath
            encoding:NSUTF8StringEncoding error:nil];
        for (NSString *line in [existing componentsSeparatedByCharactersInSet:
                                NSCharacterSet.newlineCharacterSet]) {
            if (line.length > 0) [_entries addObject:YTDScrubValue(line)];
        }
        [self trimEntries];
        [self rewriteLogFile];
    }
    return self;
}

- (NSString *)labelForLevel:(YTDLogLevel)level {
    switch (level) {
        case YTDLogLevelDebug: return @"DEBUG";
        case YTDLogLevelInfo: return @"INFO";
        case YTDLogLevelWarning: return @"WARN";
        case YTDLogLevelError: return @"ERROR";
        case YTDLogLevelFault: return @"FAULT";
    }
    return @"INFO";
}

- (void)recordLevel:(YTDLogLevel)level
           category:(NSString *)category
            message:(NSString *)message {
    [self importRecords:@[@{
        @"date": NSDate.date,
        @"level": @(level),
        @"category": category ?: @"General",
        @"message": message ?: @"",
    }]];
}

- (void)importRecords:(NSArray<NSDictionary<NSString *, id> *> *)records {
    if (records.count == 0) return;
    dispatch_async(self.queue, ^{
        for (NSDictionary<NSString *, id> *record in records) {
            NSDate *date = [record[@"date"] isKindOfClass:NSDate.class]
                ? record[@"date"] : NSDate.date;
            YTDLogLevel level = [record[@"level"] respondsToSelector:@selector(integerValue)]
                ? [record[@"level"] integerValue] : YTDLogLevelInfo;
            NSString *category = [record[@"category"] isKindOfClass:NSString.class]
                ? record[@"category"] : @"General";
            NSString *message = [record[@"message"] isKindOfClass:NSString.class]
                ? record[@"message"] : @"";
            category = [YTDScrubValue(category)
                stringByReplacingOccurrencesOfString:@"]" withString:@")"];
            if (category.length > 96) {
                category = [category substringToIndex:96];
            }
            NSString *line = [NSString stringWithFormat:@"%@ [%@] [%@] %@",
                [self.dateFormatter stringFromDate:date],
                [self labelForLevel:level], category, YTDScrubValue(message)];
            [self.entries addObject:line];
        }
        [self trimEntries];
        [self rewriteLogFile];
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter
                postNotificationName:YTDLogStoreDidChangeNotification
                object:self];
        });
    });
}

- (void)trimEntries {
    if (self.entries.count > YTDMaxLogEntries) {
        [self.entries removeObjectsInRange:
            NSMakeRange(0, self.entries.count - YTDMaxLogEntries)];
    }
}

- (void)rewriteLogFile {
    NSMutableArray<NSString *> *tail = [NSMutableArray array];
    unsigned long long bytes = 0;
    for (NSString *entry in self.entries.reverseObjectEnumerator) {
        NSUInteger entryBytes =
            [entry dataUsingEncoding:NSUTF8StringEncoding].length + 1;
        if (entryBytes > YTDMaxLogFileBytes) continue;
        if (bytes + entryBytes > YTDMaxLogFileBytes) break;
        [tail insertObject:entry atIndex:0];
        bytes += entryBytes;
    }
    NSString *text = tail.count > 0
        ? [[tail componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"]
        : @"";
    [text writeToFile:self.logPath atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
}

- (NSArray<NSString *> *)snapshot {
    __block NSArray<NSString *> *snapshot;
    void (^read)(void) = ^{ snapshot = self.entries.copy; };
    if (dispatch_get_specific(YTDLogQueueSpecificKey)) read();
    else dispatch_sync(self.queue, read);
    return snapshot ?: @[];
}

- (NSString *)exportText {
    return [[self snapshot] componentsJoinedByString:@"\n"];
}

- (void)clear {
    dispatch_async(self.queue, ^{
        [self.entries removeAllObjects];
        [NSFileManager.defaultManager removeItemAtPath:self.logPath error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter
                postNotificationName:YTDLogStoreDidChangeNotification
                object:self];
        });
    });
}

@end
