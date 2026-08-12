#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Edits the phrases stripped from the end of a video title before it is searched.
///
/// Deliberately a plain list with no ordering: every phrase is tried against the
/// end of the title independently, so unlike the caption-language screen there is
/// nothing for a sort order to mean.
@interface CITitleKeywordViewController : UITableViewController
- (instancetype)initWithCompletion:(void (^)(void))completion;
@end

NS_ASSUME_NONNULL_END
