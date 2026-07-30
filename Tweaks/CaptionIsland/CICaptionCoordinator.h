#import <Foundation/Foundation.h>
#import "CICaptionPresenting.h"
#import "CIModels.h"

NS_ASSUME_NONNULL_BEGIN

@interface CICaptionCoordinator : NSObject
+ (instancetype)sharedCoordinator;
- (void)activateContext:(CIVideoContext *)context;
- (void)updatePlaybackTime:(NSTimeInterval)time;
- (void)synchronizePlaybackAtPosition:(NSTimeInterval)position
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
- (void)setPlaybackSuppressed:(BOOL)suppressed;
- (void)playbackDidFinish;
- (void)playerViewDidAppear;
- (void)playerViewDidDisappear;
- (void)prepareForExternalPlayback;
- (void)reloadPreferences;
- (void)stop;
- (void)setPresenter:(id<CICaptionPresenting>)presenter;
@end

NS_ASSUME_NONNULL_END
