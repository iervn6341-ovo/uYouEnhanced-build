#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^CILanguagePrioritySaveBlock)(
    NSArray<NSString *> *priorities
);

FOUNDATION_EXPORT NSArray<NSString *> *
    CIAvailableCaptionLanguageCodes(void);
FOUNDATION_EXPORT NSString *
    CICaptionLanguageTitle(NSString *code);
FOUNDATION_EXPORT NSString *
    CICaptionLanguagePrioritySummary(NSArray<NSString *> *priorities);

@interface CILanguagePriorityViewController : UITableViewController

- (instancetype)initWithTitle:(NSString *)title
                   priorities:(NSArray<NSString *> *)priorities
             resetActionTitle:(NSString *)resetActionTitle
                   completion:(CILanguagePrioritySaveBlock)completion;

@end

NS_ASSUME_NONNULL_END
