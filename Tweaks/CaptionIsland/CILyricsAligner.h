#import <Foundation/Foundation.h>
#import "CIModels.h"

NS_ASSUME_NONNULL_BEGIN

@interface CILyricsAligner : NSObject
+ (NSArray<CICaptionCue *> *)alignPlainLyrics:(NSString *)lyrics
                                      toASR:(NSArray<CICaptionCue *> *)ASRCues;
+ (NSArray<CICaptionCue *> *)estimatedCuesForPlainLyrics:(NSString *)lyrics
                                                duration:(NSTimeInterval)duration;
@end

NS_ASSUME_NONNULL_END
