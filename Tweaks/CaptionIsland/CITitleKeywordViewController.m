#import "CITitleKeywordViewController.h"
#import "CIConstants.h"
#import "CITextUtilities.h"

@interface CITitleKeywordViewController ()
@property (nonatomic, strong) NSMutableArray<NSString *> *keywords;
@property (nonatomic, copy, nullable) void (^completion)(void);
@end

@implementation CITitleKeywordViewController

- (instancetype)initWithCompletion:(void (^)(void))completion {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = CILocalized(@"TITLE_KEYWORDS", @"Discarded title phrases");
        _completion = [completion copy];
        _keywords = [CIDiscardedTitleKeywords().mutableCopy
            ?: [NSMutableArray array] mutableCopy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.hidesBackButton = YES;
    UIBarButtonItem *backButton = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"chevron.backward"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(closeWithoutSaving)];
    backButton.accessibilityLabel = CILocalized(@"BACK", @"Back");
    self.navigationItem.leftBarButtonItem = backButton;
    UIBarButtonItem *saveButton = [[UIBarButtonItem alloc]
        initWithTitle:CILocalized(@"SAVE", @"Save")
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(saveAndClose)];
    UIBarButtonItem *addButton = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                             target:self
                             action:@selector(presentAddKeyword)];
    addButton.accessibilityLabel = CILocalized(@"ADD", @"Add");
    self.navigationItem.rightBarButtonItems = @[saveButton, addButton];
    [self setEditing:YES animated:NO];
}

#pragma mark - Editing

/// Accepts a phrase only if it could plausibly be a suffix.
///
/// The lower bound matters: a one-character phrase would match the tail of
/// ordinary song titles, and because stripping is anchored to the end it would
/// quietly shorten almost everything.
- (BOOL)canAddKeyword:(NSString *)value {
    NSString *keyword = [CICleanCaptionText(value)
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (keyword.length < 2 || keyword.length > 64) return NO;
    if (self.keywords.count >= 64) return NO;
    for (NSString *existing in self.keywords) {
        if ([existing.lowercaseString
                isEqualToString:keyword.lowercaseString]) {
            return NO;
        }
    }
    return YES;
}

- (void)presentAddKeyword {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:CILocalized(
            @"TITLE_KEYWORDS_ADD", @"Add a phrase")
        message:CILocalized(
            @"TITLE_KEYWORDS_ADD_MESSAGE",
            @"Only removed when it appears at the end of a title, and never when it is the whole title. Case is ignored."
        )
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Official Music Video";
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction
        actionWithTitle:CILocalized(@"CANCEL", @"Cancel")
                  style:UIAlertActionStyleCancel
                handler:nil]];
    [alert addAction:[UIAlertAction
        actionWithTitle:CILocalized(@"ADD", @"Add")
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
        typeof(self) self = weakSelf;
        NSString *keyword = [CICleanCaptionText(alert.textFields.firstObject.text)
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![self canAddKeyword:keyword]) return;
        [self.keywords addObject:keyword];
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)restoreDefaults {
    self.keywords = CIDefaultDiscardedTitleKeywords().mutableCopy;
    [self.tableView reloadData];
}

- (void)closeWithoutSaving {
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)saveAndClose {
    CISetDiscardedTitleKeywords(self.keywords.copy);
    if (self.completion) self.completion();
    [self closeWithoutSaving];
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(__unused UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? (NSInteger)self.keywords.count : 1;
}

- (NSString *)tableView:(__unused UITableView *)tableView
titleForFooterInSection:(NSInteger)section {
    if (section != 0) return nil;
    return CILocalized(
        @"TITLE_KEYWORDS_DESCRIPTION",
        @"Each phrase is removed only from the end of a video title, so it can shorten a title but never empty it. An empty list means nothing is removed. Changes apply after Save."
    );
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *identifier = indexPath.section == 0
        ? @"TitleKeyword" : @"TitleKeywordReset";
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault
          reuseIdentifier:identifier];
    }
    if (indexPath.section == 0) {
        cell.textLabel.text = self.keywords[(NSUInteger)indexPath.row];
        cell.textLabel.textColor = UIColor.labelColor;
        cell.textLabel.textAlignment = NSTextAlignmentNatural;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text = CILocalized(
            @"TITLE_KEYWORDS_RESET", @"Restore default phrases");
        cell.textLabel.textColor = UIColor.systemBlueColor;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (BOOL)tableView:(__unused UITableView *)tableView
canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0;
}

- (UITableViewCellEditingStyle)tableView:(__unused UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0
        ? UITableViewCellEditingStyleDelete
        : UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.section != 0) return;
    [self.keywords removeObjectAtIndex:(NSUInteger)indexPath.row];
    [tableView deleteRowsAtIndexPaths:@[indexPath]
                     withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) [self restoreDefaults];
}

@end
