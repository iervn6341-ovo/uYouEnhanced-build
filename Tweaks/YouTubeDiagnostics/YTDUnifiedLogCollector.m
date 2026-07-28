#import "YTDUnifiedLogCollector.h"
#import "YTDLogStore.h"
#import <OSLog/OSLog.h>

static const NSUInteger YTDMaximumEntriesPerCollection = 3000;

@interface YTDUnifiedLogCollector ()
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic, strong) NSDate *startedAt;
@property (nonatomic, strong, nullable) NSDate *lastCollectedAt;
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *recentFingerprints;
@property (nonatomic) BOOL collecting;
@end

@implementation YTDUnifiedLogCollector

+ (instancetype)sharedCollector {
    static YTDUnifiedLogCollector *collector;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ collector = [YTDUnifiedLogCollector new]; });
    return collector;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        dispatch_queue_attr_t attributes =
            dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _queue = dispatch_queue_create(
            "com.youtube.diagnostics.unifiedlog", attributes);
        _startedAt = [NSDate dateWithTimeIntervalSinceNow:-2.0];
        _recentFingerprints = [NSMutableOrderedSet orderedSet];
    }
    return self;
}

- (YTDLogLevel)levelForEntry:(OSLogEntryLog *)entry {
    switch (entry.level) {
        case OSLogEntryLogLevelDebug: return YTDLogLevelDebug;
        case OSLogEntryLogLevelInfo:
        case OSLogEntryLogLevelNotice: return YTDLogLevelInfo;
        case OSLogEntryLogLevelError: return YTDLogLevelError;
        case OSLogEntryLogLevelFault: return YTDLogLevelFault;
        case OSLogEntryLogLevelUndefined: return YTDLogLevelInfo;
    }
    return YTDLogLevelInfo;
}

- (void)collectWithCompletion:
    (void (^)(NSUInteger importedCount, NSError * _Nullable error))completion {
    dispatch_async(self.queue, ^{
        if (self.collecting) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(0, nil);
            });
            return;
        }
        self.collecting = YES;
        NSDate *boundary = NSDate.date;
        NSError *error = nil;
        OSLogStore *store =
            [OSLogStore storeWithScope:OSLogStoreCurrentProcessIdentifier
                                 error:&error];
        if (!store) {
            [self finishWithRecords:@[] boundary:boundary error:error
                         completion:completion];
            return;
        }

        BOOL initialCollection = self.lastCollectedAt == nil;
        OSLogEnumeratorOptions options =
            initialCollection ? OSLogEnumeratorReverse : 0;
        OSLogPosition *position = initialCollection ? nil :
            [store positionWithDate:self.lastCollectedAt];
        OSLogEnumerator *enumerator =
            [store entriesEnumeratorWithOptions:options position:position
                                      predicate:nil error:&error];
        if (!enumerator) {
            [self finishWithRecords:@[] boundary:boundary error:error
                         completion:completion];
            return;
        }

        NSMutableArray<NSDictionary<NSString *, id> *> *records =
            [NSMutableArray array];
        for (OSLogEntry *entry in enumerator) {
            if (![entry isKindOfClass:OSLogEntryLog.class]) continue;
            if (initialCollection &&
                [entry.date compare:self.startedAt] == NSOrderedAscending) break;
            if (!initialCollection &&
                [entry.date compare:self.lastCollectedAt] == NSOrderedAscending) continue;

            OSLogEntryLog *log = (OSLogEntryLog *)entry;
            NSString *message = log.composedMessage ?: @"";
            if (message.length == 0 ||
                [message containsString:@"[YouTubeDiagnostics]"]) continue;
            NSString *category = [NSString stringWithFormat:@"%@/%@ · %@",
                log.subsystem.length > 0 ? log.subsystem : @"YouTube",
                log.category.length > 0 ? log.category : @"default",
                log.sender.length > 0 ? log.sender : @"process"];
            NSString *fingerprint = [NSString stringWithFormat:@"%.6f|%@|%@",
                log.date.timeIntervalSince1970, category, message];
            if ([self.recentFingerprints containsObject:fingerprint]) continue;
            [self.recentFingerprints addObject:fingerprint];
            [records addObject:@{
                @"date": log.date,
                @"level": @([self levelForEntry:log]),
                @"category": category,
                @"message": message,
            }];
            if (records.count >= YTDMaximumEntriesPerCollection) break;
        }
        if (initialCollection) {
            records = [[records reverseObjectEnumerator].allObjects mutableCopy];
        }
        while (self.recentFingerprints.count > 6000) {
            [self.recentFingerprints removeObjectAtIndex:0];
        }
        [self finishWithRecords:records boundary:boundary error:error
                     completion:completion];
    });
}

- (void)finishWithRecords:(NSArray<NSDictionary<NSString *, id> *> *)records
                  boundary:(NSDate *)boundary
                     error:(NSError *)error
                completion:(void (^)(NSUInteger, NSError * _Nullable))completion {
    if (!error) self.lastCollectedAt = boundary;
    self.collecting = NO;
    [YTDLogStore.sharedStore importRecords:records];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(records.count, error);
    });
}

@end
