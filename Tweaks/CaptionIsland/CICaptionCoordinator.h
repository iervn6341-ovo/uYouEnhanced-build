#import <Foundation/Foundation.h>
#import "CIModels.h"
#import "CIOverlayPresenter.h"

NS_ASSUME_NONNULL_BEGIN

@interface CICaptionCoordinator : NSObject
+ (instancetype)sharedCoordinator;
- (void)activateContext:(CIVideoContext *)context;
- (void)updatePlaybackTime:(NSTimeInterval)time;
- (void)setPlaybackSuppressed:(BOOL)suppressed;
- (void)playerViewDidAppear;
- (void)playerViewDidDisappear;
- (void)reloadPreferences;
- (void)stop;
// A future ActivityKit bridge can replace the in-app presenter without
// changing caption selection, networking, or timing logic.
- (void)setPresenter:(id<CICaptionPresenting>)presenter;
@end

NS_ASSUME_NONNULL_END
