#import <Foundation/Foundation.h>
#import "CIModels.h"

NS_ASSUME_NONNULL_BEGIN

@protocol CICaptionPresenting <NSObject>
- (void)beginVideoID:(NSString *)videoID title:(NSString *)title;
@optional
- (void)ensureVideoID:(NSString *)videoID title:(NSString *)title;
- (void)refreshPresentationForReason:(NSString *)reason;
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
