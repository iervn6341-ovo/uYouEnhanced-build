#import "CILanguagePriorityViewController.h"
#import "CIConstants.h"

NSArray<NSString *> *CIAvailableCaptionLanguageCodes(void) {
    return @[
        @"zh-Hant", @"zh-Hans", @"en", @"ja", @"ko",
        @"es", @"fr", @"de", @"pt", @"it", @"ru",
        @"id", @"th", @"vi", @"ar", @"hi", @"nl",
        @"pl", @"tr", @"uk", @"sv", @"fi", @"da",
        @"no", @"cs", @"el", @"he", @"ms", @"tl",
    ];
}

NSString *CICaptionLanguageTitle(NSString *code) {
    NSString *normalized = [[code ?: @""
        stringByReplacingOccurrencesOfString:@"_" withString:@"-"]
        lowercaseString];
    if ([normalized isEqualToString:@"zh-hant"] ||
        [normalized isEqualToString:@"zh-tw"] ||
        [normalized isEqualToString:@"zh-hk"]) {
        return CILocalized(
            @"LANGUAGE_TRADITIONAL_CHINESE",
            @"Traditional Chinese"
        );
    }
    if ([normalized isEqualToString:@"zh-hans"] ||
        [normalized isEqualToString:@"zh-cn"] ||
        [normalized isEqualToString:@"zh-sg"]) {
        return CILocalized(
            @"LANGUAGE_SIMPLIFIED_CHINESE",
            @"Simplified Chinese"
        );
    }
    if ([normalized isEqualToString:@"en"]) {
        return CILocalized(@"LANGUAGE_ENGLISH", @"English");
    }
    if ([normalized isEqualToString:@"ja"]) {
        return CILocalized(@"LANGUAGE_JAPANESE", @"Japanese");
    }
    if ([normalized isEqualToString:@"ko"]) {
        return CILocalized(@"LANGUAGE_KOREAN", @"Korean");
    }

    NSString *base = [normalized
        componentsSeparatedByString:@"-"].firstObject;
    NSString *localized = [NSLocale.currentLocale
        localizedStringForLanguageCode:base];
    return localized.length > 0 ? localized : code;
}

NSString *CICaptionLanguagePrioritySummary(
    NSArray<NSString *> *priorities
) {
    if (priorities.count == 0) {
        return CILocalized(@"LANGUAGE_PRIORITY_INHERIT", @"Use global order");
    }
    NSUInteger visibleCount = MIN((NSUInteger)3, priorities.count);
    NSMutableArray<NSString *> *titles =
        [NSMutableArray arrayWithCapacity:visibleCount];
    for (NSUInteger index = 0; index < visibleCount; index++) {
        [titles addObject:CICaptionLanguageTitle(priorities[index])];
    }
    NSString *summary = [titles componentsJoinedByString:@" → "];
    return priorities.count > visibleCount
        ? [summary stringByAppendingString:@"…"]
        : summary;
}

@interface CILanguagePriorityViewController ()
@property (nonatomic, strong) NSMutableArray<NSString *> *priorities;
@property (nonatomic, copy) NSString *resetActionTitle;
@property (nonatomic, copy) CILanguagePrioritySaveBlock completion;
@end

@implementation CILanguagePriorityViewController

- (instancetype)initWithTitle:(NSString *)title
                   priorities:(NSArray<NSString *> *)priorities
             resetActionTitle:(NSString *)resetActionTitle
                   completion:(CILanguagePrioritySaveBlock)completion {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = title;
        _resetActionTitle = [resetActionTitle copy] ?: @"";
        _completion = [completion copy];
        NSMutableArray<NSString *> *ordered =
            [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (NSString *code in priorities) {
            if (![code isKindOfClass:NSString.class] ||
                code.length == 0) {
                continue;
            }
            NSString *identity = [[code
                stringByReplacingOccurrencesOfString:@"_"
                                          withString:@"-"]
                lowercaseString];
            if ([seen containsObject:identity]) continue;
            [seen addObject:identity];
            [ordered addObject:code];
        }
        _priorities = ordered;
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
                             action:@selector(presentAddLanguage)];
    addButton.accessibilityLabel = CILocalized(
        @"LANGUAGE_PRIORITY_ADD",
        @"Add language"
    );
    self.navigationItem.rightBarButtonItems =
        @[saveButton, addButton];
    self.tableView.allowsSelectionDuringEditing = YES;
    [self setEditing:YES animated:NO];
}

static BOOL CIValidCaptionLanguageCode(NSString *value) {
    NSString *code = [[value ?: @""
        stringByReplacingOccurrencesOfString:@"_" withString:@"-"]
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (code.length == 0 || code.length > 35 ||
        [code hasPrefix:@"-"] || [code hasSuffix:@"-"] ||
        [code containsString:@"--"]) {
        return NO;
    }
    NSCharacterSet *invalid = [[NSCharacterSet
        characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-"]
        invertedSet];
    return [code rangeOfCharacterFromSet:invalid].location ==
        NSNotFound;
}

- (BOOL)containsLanguageCode:(NSString *)code {
    NSString *identity = [[code
        stringByReplacingOccurrencesOfString:@"_" withString:@"-"]
        lowercaseString];
    for (NSString *existing in self.priorities) {
        if ([[[existing
            stringByReplacingOccurrencesOfString:@"_" withString:@"-"]
            lowercaseString] isEqualToString:identity]) {
            return YES;
        }
    }
    return NO;
}

- (void)addLanguageCode:(NSString *)code {
    NSString *normalized = [[code
        stringByReplacingOccurrencesOfString:@"_" withString:@"-"]
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!CIValidCaptionLanguageCode(normalized) ||
        [self containsLanguageCode:normalized]) {
        return;
    }
    [self.priorities addObject:normalized];
    [self.tableView reloadData];
}

- (void)presentCustomLanguageCode {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:CILocalized(
            @"LANGUAGE_PRIORITY_CUSTOM",
            @"Custom language code"
        )
        message:CILocalized(
            @"LANGUAGE_PRIORITY_CUSTOM_DESCRIPTION",
            @"Enter a YouTube/BCP-47 language code, for example yue-Hant or en-GB."
        )
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"yue-Hant";
        field.autocapitalizationType =
            UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction
        actionWithTitle:CILocalized(@"CANCEL", @"Cancel")
        style:UIAlertActionStyleCancel
        handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction
        actionWithTitle:CILocalized(@"ADD", @"Add")
        style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            typeof(self) self = weakSelf;
            NSString *code = alert.textFields.firstObject.text;
            if (!CIValidCaptionLanguageCode(code)) {
                return;
            }
            [self addLanguageCode:code];
        }]];
    [self presentViewController:alert
                       animated:YES
                     completion:nil];
}

- (void)presentAddLanguage {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:CILocalized(
            @"LANGUAGE_PRIORITY_ADD",
            @"Add language"
        )
        message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSString *code in CIAvailableCaptionLanguageCodes()) {
        if ([self containsLanguageCode:code]) continue;
        NSString *title = [NSString stringWithFormat:@"%@ · %@",
            CICaptionLanguageTitle(code), code];
        [sheet addAction:[UIAlertAction
            actionWithTitle:title
            style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                [weakSelf addLanguageCode:code];
            }]];
    }
    [sheet addAction:[UIAlertAction
        actionWithTitle:CILocalized(
            @"LANGUAGE_PRIORITY_CUSTOM",
            @"Custom language code"
        )
        style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            [weakSelf presentCustomLanguageCode];
        }]];
    [sheet addAction:[UIAlertAction
        actionWithTitle:CILocalized(@"CANCEL", @"Cancel")
        style:UIAlertActionStyleCancel
        handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(
        CGRectGetMaxX(self.view.bounds) - 44,
        CGRectGetMinY(self.view.bounds) + 44,
        1,
        1
    );
    [self presentViewController:sheet
                       animated:YES
                     completion:nil];
}

- (void)closeWithoutSaving {
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)saveAndClose {
    if (self.completion) self.completion(self.priorities.copy);
    [self closeWithoutSaving];
}

- (NSInteger)numberOfSectionsInTableView:
    (__unused UITableView *)tableView {
    return self.resetActionTitle.length > 0 ? 2 : 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? (NSInteger)self.priorities.count : 1;
}

- (NSString *)tableView:(__unused UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section {
    return section == 0
        ? CILocalized(
            @"LANGUAGE_PRIORITY_ORDER_HEADER",
            @"Highest priority first"
        )
        : nil;
}

- (NSString *)tableView:(__unused UITableView *)tableView
 titleForFooterInSection:(NSInteger)section {
    if (section != 0) return nil;
    return CILocalized(
        @"LANGUAGE_PRIORITY_ORDER_DESCRIPTION",
        @"Drag languages into order, delete unneeded priorities, or use + to add one. Unlisted source languages remain a last fallback; auto-translated tracks are excluded. Changes apply after Save."
    );
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *identifier = indexPath.section == 0
        ? @"CaptionLanguage" : @"CaptionLanguageReset";
    UITableViewCell *cell = [tableView
        dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
          reuseIdentifier:identifier];
    }
    if (indexPath.section == 0) {
        NSString *code = self.priorities[indexPath.row];
        cell.textLabel.text = CICaptionLanguageTitle(code);
        cell.detailTextLabel.text = code;
        cell.textLabel.textColor = UIColor.labelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.showsReorderControl = YES;
    } else {
        cell.textLabel.text = self.resetActionTitle;
        cell.detailTextLabel.text = nil;
        cell.textLabel.textColor = UIColor.systemBlueColor;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.showsReorderControl = NO;
    }
    return cell;
}

- (BOOL)tableView:(__unused UITableView *)tableView
 canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0;
}

- (UITableViewCellEditingStyle)tableView:
    (__unused UITableView *)tableView
 editingStyleForRowAtIndexPath:
    (__unused NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleDelete;
}

- (void)tableView:(UITableView *)tableView
 commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
 forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete ||
        indexPath.section != 0) {
        return;
    }
    [self.priorities removeObjectAtIndex:indexPath.row];
    [tableView deleteRowsAtIndexPaths:@[indexPath]
                     withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (BOOL)tableView:(__unused UITableView *)tableView
 canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0;
}

- (void)tableView:(__unused UITableView *)tableView
 moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath
       toIndexPath:(NSIndexPath *)destinationIndexPath {
    NSString *language = self.priorities[sourceIndexPath.row];
    [self.priorities removeObjectAtIndex:sourceIndexPath.row];
    [self.priorities insertObject:language
                         atIndex:destinationIndexPath.row];
}

- (NSIndexPath *)tableView:(__unused UITableView *)tableView
 targetIndexPathForMoveFromRowAtIndexPath:
    (__unused NSIndexPath *)sourceIndexPath
                   toProposedIndexPath:
    (NSIndexPath *)proposedDestinationIndexPath {
    if (proposedDestinationIndexPath.section == 0) {
        return proposedDestinationIndexPath;
    }
    return [NSIndexPath indexPathForRow:
        MAX(0, (NSInteger)self.priorities.count - 1)
                             inSection:0];
}

- (void)tableView:(__unused UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 1) return;
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.completion) self.completion(@[]);
    [self closeWithoutSaving];
}

@end
