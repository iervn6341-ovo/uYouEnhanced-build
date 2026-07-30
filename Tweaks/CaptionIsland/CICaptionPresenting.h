#import <Foundation/Foundation.h>
#import "CIModels.h"

NS_ASSUME_NONNULL_BEGIN

@protocol CICaptionPresenting <NSObject>
- (void)beginVideoID:(NSString *)videoID title:(NSString *)title;
@optional
- (void)ensureVideoID:(NSString *)videoID title:(NSString *)title;
- (void)configureRemoteTimelineWithCues:
            (NSArray<CICaptionCue *> *)cues
                              source:(CICaptionSource)source
                            position:(NSTimeInterval)position
                            duration:(NSTimeInterval)duration;
- (void)clearRemoteTimelineAtPosition:
            (NSTimeInterval)position
                              duration:(NSTimeInterval)duration;
- (void)synchronizeRemotePlaybackAtPosition:
            (NSTimeInterval)position
                                    playing:(BOOL)playing
                                       rate:(double)rate
                                      force:(BOOL)force;
- (void)synchronizeRemotePlaybackCriticalAtPosition:
            (NSTimeInterval)position
                                            playing:(BOOL)playing
                                               rate:(double)rate
                                    expectedVideoID:
                                        (NSString *)expectedVideoID
                                         completion:
                                             (void (^)(BOOL attempted))
                                                 completion;
- (void)presentText:(NSString *)text
             source:(CICaptionSource)source
           cueStart:(NSTimeInterval)cueStart
             cueEnd:(NSTimeInterval)cueEnd
           position:(NSTimeInterval)position
           nextText:(NSString *)nextText
       nextCueStart:(NSTimeInterval)nextCueStart
         nextCueEnd:(NSTimeInterval)nextCueEnd;
@required
- (void)presentText:(NSString *)text
             source:(CICaptionSource)source
           cueStart:(NSTimeInterval)cueStart
             cueEnd:(NSTimeInterval)cueEnd
           position:(NSTimeInterval)position;
- (void)hide;
- (void)end;
@end

NS_ASSUME_NONNULL_END
