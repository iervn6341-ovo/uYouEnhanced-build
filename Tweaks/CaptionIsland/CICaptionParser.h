#import <Foundation/Foundation.h>
#import "CIModels.h"

NS_ASSUME_NONNULL_BEGIN

@interface CICaptionParser : NSObject
+ (NSArray<CICaptionCue *> *)parseYouTubeData:(NSData *)data
                                    MIMEType:(nullable NSString *)MIMEType;
+ (NSArray<CICaptionCue *> *)parseJSON3Data:(NSData *)data;
+ (NSArray<CICaptionCue *> *)parseWebVTTString:(NSString *)text;
+ (NSArray<CICaptionCue *> *)parseTimedTextXMLData:(NSData *)data;
+ (NSArray<CICaptionCue *> *)parseLRCString:(NSString *)text;
@end

NS_ASSUME_NONNULL_END
