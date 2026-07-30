#import <Foundation/Foundation.h>
#import "CICaptionPresenting.h"
#import "CIModels.h"

NS_ASSUME_NONNULL_BEGIN

@interface CICaptionCoordinator : NSObject
+ (instancetype)sharedCoordinator;
- (void)activateContext:(CIVideoContext *)context;
- (void)currentVideoContextWithCompletion:
    (void (^)(CIVideoContext * _Nullable context))completion;
- (void)updatePlaybackTime:(NSTimeInterval)time;
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
