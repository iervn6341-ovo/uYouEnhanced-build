#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTDUnifiedLogCollector : NSObject

+ (instancetype)sharedCollector;

- (void)collectWithCompletion:
    (void (^)(NSUInteger importedCount, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
