#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, YTDLogLevel) {
    YTDLogLevelDebug,
    YTDLogLevelInfo,
    YTDLogLevelWarning,
    YTDLogLevelError,
    YTDLogLevelFault,
};

FOUNDATION_EXPORT NSNotificationName const YTDLogStoreDidChangeNotification;

@interface YTDLogStore : NSObject

+ (instancetype)sharedStore;

- (void)recordLevel:(YTDLogLevel)level
           category:(NSString *)category
            message:(NSString *)message;

/// Each record accepts `date`, `level`, `category`, and `message`.
- (void)importRecords:(NSArray<NSDictionary<NSString *, id> *> *)records;

- (NSArray<NSString *> *)snapshot;
- (NSString *)exportText;
- (void)clear;

@end

NS_ASSUME_NONNULL_END
