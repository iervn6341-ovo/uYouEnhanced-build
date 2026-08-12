#import <Foundation/Foundation.h>
#import "CICaptionPresenting.h"
#import "CIModels.h"
#import "CITextUtilities.h"

NS_ASSUME_NONNULL_BEGIN

@interface CICaptionCoordinator : NSObject
+ (instancetype)sharedCoordinator;
- (void)activateContext:(CIVideoContext *)context;
- (void)currentVideoContextWithCompletion:
    (void (^)(CIVideoContext * _Nullable context))completion;

/// The readings of this video's title that a lookup would search, most likely
/// first. Exposed so the in-player panel can browse exactly what the automatic
/// path would have searched rather than re-deriving it and drifting.
- (NSArray<CISongQuery *> *)LRCLIBReadingsForContext:(CIVideoContext *)context;
- (void)updatePlaybackTime:(NSTimeInterval)time;
- (void)updatePlaybackTime:(NSTimeInterval)time playing:(BOOL)playing;
- (void)setPlaybackSuppressed:(BOOL)suppressed;
- (void)playbackDidFinish;
- (void)playerViewDidAppear;
- (void)playerViewDidDisappear;
- (void)prepareForExternalPlayback;
- (void)refreshPresentationForReason:(NSString *)reason;
- (void)reloadPreferences;
- (void)stop;
- (void)setPresenter:(id<CICaptionPresenting>)presenter;
@end

NS_ASSUME_NONNULL_END
