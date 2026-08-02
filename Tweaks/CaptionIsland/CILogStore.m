#import "CILogStore.h"
#import "CIConstants.h"
#import <os/log.h>

NSNotificationName const CILogStoreDidChangeNotification = @"CILogStoreDidChangeNotification";

static const NSUInteger CIMaxLogEntries = 500;
static const unsigned long long CIMaxLogFileBytes = 128 * 1024;
static const void *CILogQueueSpecificKey = &CILogQueueSpecificKey;

static NSString *CIScrubLogValue(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length == 0) return @"";

    NSString *scrubbed = value;
    NSArray<NSString *> *rawLines = [scrubbed componentsSeparatedByCharactersInSet:
        NSCharacterSet.newlineCharacterSet];
    NSMutableArray<NSString *> *nonemptyLines = [NSMutableArray array];
    for (NSString *line in rawLines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length > 0) [nonemptyLines addObject:trimmed];
    }
    if (nonemptyLines.count > 2) {
        scrubbed = [NSString stringWithFormat:@"%@ <%@>",
            nonemptyLines.firstObject, @"multiline payload redacted"];
    } else {
        scrubbed = [scrubbed stringByReplacingOccurrencesOfString:@"\r\n"
                                                       withString:@" ↩︎ "];
        scrubbed = [scrubbed stringByReplacingOccurrencesOfString:@"\r"
                                                       withString:@" ↩︎ "];
        scrubbed = [scrubbed stringByReplacingOccurrencesOfString:@"\n"
                                                       withString:@" ↩︎ "];
    }

    static NSArray<NSArray *> *rules;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        rules = @[
            @[@"(?i)\\b(?:https?|file)://[^\\s<>]+", @"<URL redacted>"],
            @[@"(?i)\\bwww\\.[^\\s<>]+", @"<URL redacted>"],
            @[@"(?i)\\bBearer\\s+[A-Za-z0-9._~+/=-]+", @"Bearer <redacted>"],
            @[@"(?i)\\b(authorization|cookie|set-cookie)\\b\\s*[:=]\\s*.*",
              @"$1=<redacted>"],
            @[@"(?i)\\b(api[-_ ]?key|(?:access|refresh|push|device|apns|relay)[-_ ]?token)\\b\\s*[:=]\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s,;]+)",
              @"$1=<redacted>"],
            @[@"(?i)\\b(plainLyrics|syncedLyrics|lyricText|captionText|lyrics?)\\b\\s*[:=]\\s*.*",
              @"$1=<text redacted>"],
        ];
    });
    for (NSArray *rule in rules) {
        NSRegularExpression *expression = [NSRegularExpression
            regularExpressionWithPattern:rule[0] options:0 error:nil];
        scrubbed = [expression stringByReplacingMatchesInString:scrubbed
            options:0 range:NSMakeRange(0, scrubbed.length) withTemplate:rule[1]];
    }

    if (scrubbed.length > 1000) {
        scrubbed = [[scrubbed substringToIndex:1000] stringByAppendingString:@"…"];
    }
    return scrubbed;
}

@interface CILogStore ()
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic, strong) NSMutableArray<NSString *> *entries;
@property (nonatomic, strong) NSDateFormatter *dateFormatter;
@property (nonatomic, copy) NSString *logPath;
- (void)rewriteLogFile;
@end

@implementation CILogStore

+ (instancetype)sharedStore {
    static CILogStore *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ store = [CILogStore new]; });
    return store;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.captionisland.log", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, CILogQueueSpecificKey,
                                    (void *)CILogQueueSpecificKey, NULL);
        _entries = [NSMutableArray array];
        _dateFormatter = [NSDateFormatter new];
        _dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _dateFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";

        NSString *caches = NSSearchPathForDirectoriesInDomains(
            NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        NSString *directory = [caches stringByAppendingPathComponent:@"CaptionIsland"];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
        _logPath = [directory stringByAppendingPathComponent:@"CaptionIsland.log"];
        NSString *existing = [NSString stringWithContentsOfFile:_logPath
                                                       encoding:NSUTF8StringEncoding
                                                          error:nil];
        if (existing.length > 0) {
            NSArray<NSString *> *lines = [existing componentsSeparatedByCharactersInSet:
                NSCharacterSet.newlineCharacterSet];
            for (NSString *line in lines) {
                if (line.length > 0) [_entries addObject:CIScrubLogValue(line)];
            }
            if (_entries.count > CIMaxLogEntries) {
                [_entries removeObjectsInRange:
                    NSMakeRange(0, _entries.count - CIMaxLogEntries)];
            }
        }
        [self rewriteLogFile];
    }
    return self;
}

- (NSString *)labelForLevel:(CILogLevel)level {
    switch (level) {
        case CILogLevelDebug: return @"DEBUG";
        case CILogLevelInfo: return @"INFO";
        case CILogLevelWarning: return @"WARN";
        case CILogLevelError: return @"ERROR";
    }
    return @"INFO";
}

- (void)recordLevel:(CILogLevel)level
           category:(NSString *)category
             format:(NSString *)format, ... {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    [self recordLevel:level category:category message:message];
}

- (void)recordLevel:(CILogLevel)level
           category:(NSString *)category
            message:(NSString *)message {
    if (level == CILogLevelDebug && !CIPreferenceBool(CIDebugLoggingKey, NO)) return;
    NSString *safeCategory = CIScrubLogValue(category.length > 0 ? category : @"General");
    safeCategory = [safeCategory stringByReplacingOccurrencesOfString:@"]" withString:@")"];
    if (safeCategory.length > 48) safeCategory = [safeCategory substringToIndex:48];
    NSString *safeMessage = CIScrubLogValue(message ?: @"");

    dispatch_async(self.queue, ^{
        NSString *line = [NSString stringWithFormat:@"%@ [%@] [%@] %@",
            [self.dateFormatter stringFromDate:NSDate.date],
            [self labelForLevel:level], safeCategory, safeMessage];
        [self.entries addObject:line];
        if (self.entries.count > CIMaxLogEntries) {
            [self.entries removeObjectsInRange:
                NSMakeRange(0, self.entries.count - CIMaxLogEntries)];
        }
        [self appendLineToFile:line];

        if (CIPreferenceBool(CIDebugLoggingKey, NO)) {
            // line is already scrubbed by CIScrubLogValue above, so mark it
            // public: otherwise the unified log redacts it to <private> and
            // this diagnostic toggle stops being useful for field debugging.
            // %{public} is only parsed by the os_log()/os_trace() macro
            // family, not NSLog, so this must go through os_log directly.
            os_log(OS_LOG_DEFAULT, "[CaptionIsland] %{public}@", line);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter
                postNotificationName:CILogStoreDidChangeNotification object:self];
        });
    });
}

- (void)appendLineToFile:(NSString *)line {
    NSData *data = [[line stringByAppendingString:@"\n"]
        dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0 || self.logPath.length == 0) return;

    NSDictionary *attributes = [[NSFileManager defaultManager]
        attributesOfItemAtPath:self.logPath error:nil];
    unsigned long long existingBytes = [attributes[NSFileSize] unsignedLongLongValue];
    if (existingBytes + data.length > CIMaxLogFileBytes) {
        [self rewriteLogFile];
        return;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.logPath]) {
        [data writeToFile:self.logPath atomically:YES];
        return;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:self.logPath];
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
    } @catch (__unused NSException *exception) {
    } @finally {
        [handle closeFile];
    }
}

- (void)rewriteLogFile {
    if (self.logPath.length == 0) return;
    NSMutableArray<NSString *> *tailLines = [NSMutableArray array];
    unsigned long long byteCount = 0;
    for (NSString *entry in self.entries.reverseObjectEnumerator) {
        NSUInteger entryBytes = [entry dataUsingEncoding:NSUTF8StringEncoding].length + 1;
        if (entryBytes > CIMaxLogFileBytes) continue;
        if (byteCount + entryBytes > CIMaxLogFileBytes) break;
        [tailLines insertObject:entry atIndex:0];
        byteCount += entryBytes;
    }
    NSString *tail = tailLines.count > 0
        ? [[tailLines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"]
        : @"";
    [tail writeToFile:self.logPath atomically:YES
            encoding:NSUTF8StringEncoding error:nil];
}

- (NSArray<NSString *> *)snapshot {
    __block NSArray<NSString *> *snapshot;
    void (^readBlock)(void) = ^{ snapshot = self.entries.copy; };
    if (dispatch_get_specific(CILogQueueSpecificKey)) readBlock();
    else dispatch_sync(self.queue, readBlock);
    return snapshot ?: @[];
}

- (NSString *)exportText {
    return [[self snapshot] componentsJoinedByString:@"\n"];
}

- (void)clear {
    dispatch_async(self.queue, ^{
        [self.entries removeAllObjects];
        [[NSFileManager defaultManager] removeItemAtPath:self.logPath error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter
                postNotificationName:CILogStoreDidChangeNotification object:self];
        });
    });
}

@end
