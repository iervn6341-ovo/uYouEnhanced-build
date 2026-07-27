#import <UIKit/UIKit.h>
#import "CIModels.h"

NS_ASSUME_NONNULL_BEGIN

@protocol CICaptionPresenting <NSObject>
- (void)presentText:(NSString *)text
             source:(CICaptionSource)source
    copyrightNotice:(NSString *)copyrightNotice
       writerCredit:(NSString *)writerCredit;
- (void)hide;
@end

@interface CIOverlayPresenter : NSObject <CICaptionPresenting>
+ (instancetype)sharedPresenter;
@end

NS_ASSUME_NONNULL_END
