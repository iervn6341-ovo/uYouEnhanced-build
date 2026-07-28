#import "YTDiagnosticsViewController.h"
#import "YTDLogStore.h"
#import "YTDUnifiedLogCollector.h"

static NSString *YTDLocalized(NSString *traditionalChinese,
                              NSString *english,
                              NSString *japanese) {
    NSString *language = NSLocale.preferredLanguages.firstObject.lowercaseString;
    if ([language hasPrefix:@"zh"]) return traditionalChinese;
    if ([language hasPrefix:@"ja"]) return japanese;
    return english;
}

@interface YTDiagnosticsViewController ()
@property (nonatomic, strong) UISegmentedControl *filterControl;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIButton *refreshButton;
@property (nonatomic, strong) UIButton *shareButton;
@property (nonatomic, strong) UIButton *clearButton;
@property (nonatomic, copy) NSString *collectionStatus;
@end

@implementation YTDiagnosticsViewController

- (UIButton *)actionButtonWithTitle:(NSString *)title
                         systemImage:(NSString *)systemImage
                               color:(UIColor *)color
                              action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration = UIButtonConfiguration.tintedButtonConfiguration;
    configuration.title = title;
    configuration.image = [UIImage systemImageNamed:systemImage];
    configuration.imagePlacement = NSDirectionalRectEdgeLeading;
    configuration.imagePadding = 6;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    configuration.baseForegroundColor = color;
    configuration.baseBackgroundColor = [color colorWithAlphaComponent:0.12];
    button.configuration = configuration;
    [button addTarget:self action:action
      forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = YTDLocalized(@"YouTube 診斷記錄",
                              @"YouTube Diagnostics",
                              @"YouTube 診断ログ");
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.collectionStatus = @"";
    self.navigationItem.hidesBackButton = YES;
    UIBarButtonItem *back = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"chevron.backward"]
        style:UIBarButtonItemStylePlain target:self action:@selector(closePreview)];
    back.accessibilityLabel = YTDLocalized(@"返回", @"Back", @"戻る");
    self.navigationItem.leftBarButtonItem = back;

    self.filterControl = [[UISegmentedControl alloc] initWithItems:@[
        YTDLocalized(@"全部", @"All", @"すべて"),
        YTDLocalized(@"警告", @"Warnings", @"警告"),
        YTDLocalized(@"錯誤", @"Errors", @"エラー"),
    ]];
    self.filterControl.selectedSegmentIndex = 0;
    [self.filterControl addTarget:self action:@selector(refreshFromStore)
                 forControlEvents:UIControlEventValueChanged];
    self.filterControl.translatesAutoresizingMaskIntoConstraints = NO;

    self.statusLabel = [UILabel new];
    self.statusLabel.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.numberOfLines = 2;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.refreshButton = [self
        actionButtonWithTitle:YTDLocalized(@"擷取", @"Capture", @"取得")
        systemImage:@"arrow.clockwise" color:UIColor.systemBlueColor
        action:@selector(captureUnifiedLogs)];
    self.shareButton = [self
        actionButtonWithTitle:YTDLocalized(@"分享", @"Share", @"共有")
        systemImage:@"square.and.arrow.up" color:UIColor.systemBlueColor
        action:@selector(shareLogs)];
    self.clearButton = [self
        actionButtonWithTitle:YTDLocalized(@"清除", @"Clear", @"消去")
        systemImage:@"trash" color:UIColor.systemRedColor
        action:@selector(confirmClear)];
    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.refreshButton, self.shareButton, self.clearButton
    ]];
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.distribution = UIStackViewDistributionFillEqually;
    actions.spacing = 8;
    actions.translatesAutoresizingMaskIntoConstraints = NO;

    self.textView = [UITextView new];
    self.textView.editable = NO;
    self.textView.selectable = YES;
    self.textView.alwaysBounceVertical = YES;
    self.textView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.textView.textColor = UIColor.labelColor;
    self.textView.font =
        [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    self.textView.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    self.textView.layer.cornerRadius = 12;
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:self.filterControl];
    [self.view addSubview:self.statusLabel];
    [self.view addSubview:actions];
    [self.view addSubview:self.textView];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.filterControl.topAnchor constraintEqualToAnchor:guide.topAnchor constant:10],
        [self.filterControl.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:12],
        [self.filterControl.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-12],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.filterControl.bottomAnchor constant:8],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.filterControl.leadingAnchor],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.filterControl.trailingAnchor],
        [actions.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:8],
        [actions.leadingAnchor constraintEqualToAnchor:self.filterControl.leadingAnchor],
        [actions.trailingAnchor constraintEqualToAnchor:self.filterControl.trailingAnchor],
        [actions.heightAnchor constraintEqualToConstant:42],
        [self.textView.topAnchor constraintEqualToAnchor:actions.bottomAnchor constant:10],
        [self.textView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:8],
        [self.textView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-8],
        [self.textView.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-8],
    ]];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(refreshFromStore)
        name:YTDLogStoreDidChangeNotification object:nil];
    [self captureUnifiedLogs];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)closePreview {
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (NSArray<NSString *> *)filteredLines:(NSArray<NSString *> *)lines {
    if (self.filterControl.selectedSegmentIndex == 0) return lines;
    BOOL warnings = self.filterControl.selectedSegmentIndex == 1;
    NSPredicate *predicate = [NSPredicate predicateWithBlock:
        ^BOOL(NSString *line, __unused NSDictionary *bindings) {
            if (warnings) {
                return [line containsString:@"[WARN]"] ||
                    [line containsString:@"[ERROR]"] ||
                    [line containsString:@"[FAULT]"];
            }
            return [line containsString:@"[ERROR]"] ||
                [line containsString:@"[FAULT]"];
        }];
    return [lines filteredArrayUsingPredicate:predicate];
}

- (void)refreshFromStore {
    NSArray<NSString *> *all = YTDLogStore.sharedStore.snapshot;
    NSArray<NSString *> *visible = [self filteredLines:all];
    self.textView.text = visible.count > 0
        ? [visible componentsJoinedByString:@"\n"]
        : YTDLocalized(@"目前沒有符合條件的 YouTube 記錄。",
                       @"No matching YouTube diagnostics yet.",
                       @"一致する YouTube 診断ログはありません。");
    NSString *privacy = YTDLocalized(
        @"遮蔽憑證、Cookie、電子郵件與 URL 查詢參數",
        @"credentials, cookies, email, and URL queries are redacted",
        @"認証情報、Cookie、メール、URL クエリは編集されます");
    self.statusLabel.text = [NSString stringWithFormat:@"%lu %@ · %@",
        (unsigned long)all.count, self.collectionStatus, privacy];
}

- (void)captureUnifiedLogs {
    self.refreshButton.enabled = NO;
    self.collectionStatus =
        YTDLocalized(@"· 正在擷取", @"· capturing", @"· 取得中");
    [self refreshFromStore];
    __weak typeof(self) weakSelf = self;
    [YTDUnifiedLogCollector.sharedCollector collectWithCompletion:
        ^(NSUInteger count, NSError *error) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.refreshButton.enabled = YES;
            if (error) {
                strongSelf.collectionStatus =
                    YTDLocalized(@"· 系統 Log 無法讀取",
                                 @"· unified log unavailable",
                                 @"· システムログ取得不可");
                [YTDLogStore.sharedStore recordLevel:YTDLogLevelWarning
                    category:@"Collector"
                    message:[NSString stringWithFormat:
                        @"Unified log collection failed: %@ (%ld)",
                        error.domain, (long)error.code]];
            } else {
                strongSelf.collectionStatus = [NSString stringWithFormat:
                    YTDLocalized(@"· 新增 %lu 筆",
                                 @"· %lu new",
                                 @"· %lu 件追加"),
                    (unsigned long)count];
            }
            [strongSelf refreshFromStore];
        }];
}

- (void)shareLogs {
    NSString *logs = YTDLogStore.sharedStore.exportText;
    if (logs.length == 0) return;
    UIActivityViewController *controller = [[UIActivityViewController alloc]
        initWithActivityItems:@[logs] applicationActivities:nil];
    controller.popoverPresentationController.sourceView = self.shareButton;
    controller.popoverPresentationController.sourceRect = self.shareButton.bounds;
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)confirmClear {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:YTDLocalized(@"清除 YouTube 診斷記錄",
                                              @"Clear YouTube Diagnostics",
                                              @"YouTube 診断ログを消去")
        message:YTDLocalized(@"這不會清除 YouTube 本身的資料。",
                             @"This does not remove YouTube app data.",
                             @"YouTube アプリのデータは削除されません。")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:YTDLocalized(@"取消", @"Cancel", @"キャンセル")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction
        actionWithTitle:YTDLocalized(@"清除", @"Clear", @"消去")
        style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            [YTDLogStore.sharedStore clear];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
