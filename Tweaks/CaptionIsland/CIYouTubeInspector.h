#import <Foundation/Foundation.h>
#import "CIModels.h"

NS_ASSUME_NONNULL_BEGIN

@interface CIYouTubeInspector : NSObject
+ (nullable CIVideoContext *)contextFromPlaybackData:(nullable id)playbackData
                                    playerController:(nullable id)playerController;
+ (nullable CICaptionTrack *)manualTrackInContext:(CIVideoContext *)context
                                preferredLanguage:(NSString *)preferredLanguage;
+ (nullable CICaptionTrack *)automaticTrackInContext:(CIVideoContext *)context
                                   preferredLanguage:(NSString *)preferredLanguage;
+ (nullable NSURL *)requestURLForTrack:(CICaptionTrack *)track;
+ (NSArray<NSURL *> *)requestURLsForTrack:(CICaptionTrack *)track;
@end

NS_ASSUME_NONNULL_END
