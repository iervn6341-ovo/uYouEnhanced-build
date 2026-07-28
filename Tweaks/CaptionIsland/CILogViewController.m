#import "CILogViewController.h"
#import "CILogStore.h"
#import "CIConstants.h"

@interface CILogViewController ()
@property (nonatomic, strong) UISegmentedControl *filterControl;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIButton *refreshButton;
@property (nonatomic, strong) UIButton *shareButton;
@property (nonatomic, strong) UIButton *clearButton;
@end

@implementation CILogViewController

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
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = CILocalized(@"LOG_PREVIEW", @"Log Preview");
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.hidesBackButton = YES;
    UIBarButtonItem *backButton = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"chevron.backward"]
        style:UIBarButtonItemStylePlain target:self action:@selector(closePreview)];
    backButton.accessibilityLabel = CILocalized(@"BACK", @"Back");
    self.navigationItem.leftBarButtonItem = backButton;

    self.filterControl = [[UISegmentedControl alloc] initWithItems:@[
        CILocalized(@"LOG_ALL", @"All"),
        CILocalized(@"LOG_WARNINGS", @"Warnings"),
        CILocalized(@"LOG_ERRORS", @"Errors"),
    ]];
    self.filterControl.selectedSegmentIndex = 0;
    [self.filterControl addTarget:self action:@selector(refresh)
                 forControlEvents:UIControlEventValueChanged];
    self.filterControl.translatesAutoresizingMaskIntoConstraints = NO;

    self.statusLabel = [UILabel new];
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.textView = [UITextView new];
    self.textView.editable = NO;
    self.textView.selectable = YES;
    self.textView.alwaysBounceVertical = YES;
    self.textView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.textView.textColor = UIColor.labelColor;
    self.textView.font = [UIFont monospacedSystemFontOfSize:11
                                                   weight:UIFontWeightRegular];
    self.textView.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    self.textView.layer.cornerRadius = 10;
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;

    self.refreshButton = [self
        actionButtonWithTitle:CILocalized(@"REFRESH", @"Refresh")
        systemImage:@"arrow.clockwise" color:UIColor.systemBlueColor
        action:@selector(refresh)];
    self.shareButton = [self
        actionButtonWithTitle:CILocalized(@"SHARE", @"Share")
        systemImage:@"square.and.arrow.up" color:UIColor.systemBlueColor
        action:@selector(shareLogs)];
    self.clearButton = [self
        actionButtonWithTitle:CILocalized(@"CLEAR", @"Clear")
        systemImage:@"trash" color:UIColor.systemRedColor
        action:@selector(confirmClear)];
    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.refreshButton, self.shareButton, self.clearButton
    ]];
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.alignment = UIStackViewAlignmentFill;
    actions.distribution = UIStackViewDistributionFillEqually;
    actions.spacing = 8;
    actions.translatesAutoresizingMaskIntoConstraints = NO;

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
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh)
        name:CILogStoreDidChangeNotification object:nil];
    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
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
    NSString *needle = self.filterControl.selectedSegmentIndex == 1 ? @"[WARN]" : @"[ERROR]";
    NSPredicate *predicate = [NSPredicate predicateWithBlock:
        ^BOOL(NSString *line, __unused NSDictionary *bindings) {
            return [line containsString:needle];
        }];
    return [lines filteredArrayUsingPredicate:predicate];
}

- (void)refresh {
    NSArray<NSString *> *all = CILogStore.sharedStore.snapshot;
    NSArray<NSString *> *visible = [self filteredLines:all];
    NSString *text = [visible componentsJoinedByString:@"\n"];
    BOOL wasAtBottom = self.textView.contentOffset.y + self.textView.bounds.size.height >=
        self.textView.contentSize.height - 24;
    self.textView.text = text.length > 0 ? text :
        CILocalized(@"LOG_EMPTY", @"No CaptionIsland logs yet.");
    self.statusLabel.text = [NSString stringWithFormat:
        CILocalized(@"LOG_COUNT_FORMAT", @"%lu entries · lyrics, URLs, cookies, and authorization data are not recorded"),
        (unsigned long)all.count];
    if (wasAtBottom && self.textView.text.length > 0) {
        [self.textView scrollRangeToVisible:NSMakeRange(self.textView.text.length - 1, 1)];
    }
}

- (void)shareLogs {
    NSString *logs = CILogStore.sharedStore.exportText;
    if (logs.length == 0) return;
    UIActivityViewController *controller =
        [[UIActivityViewController alloc] initWithActivityItems:@[logs] applicationActivities:nil];
    controller.popoverPresentationController.sourceView = self.shareButton;
    controller.popoverPresentationController.sourceRect = self.shareButton.bounds;
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)confirmClear {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:CILocalized(@"CLEAR_LOGS", @"Clear Logs")
        message:CILocalized(@"CLEAR_LOGS_CONFIRMATION", @"Remove all CaptionIsland diagnostic logs?")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:CILocalized(@"CANCEL", @"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:CILocalized(@"CLEAR", @"Clear")
        style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            [CILogStore.sharedStore clear];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
