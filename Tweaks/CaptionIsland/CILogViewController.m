#import "CILogViewController.h"
#import "CILogStore.h"
#import "CIConstants.h"

@interface CILogViewController ()
@property (nonatomic, strong) UISegmentedControl *filterControl;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextView *textView;
@end

@implementation CILogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = CILocalized(@"LOG_PREVIEW", @"Log Preview");
    self.view.backgroundColor = UIColor.systemBackgroundColor;

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

    [self.view addSubview:self.filterControl];
    [self.view addSubview:self.statusLabel];
    [self.view addSubview:self.textView];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.filterControl.topAnchor constraintEqualToAnchor:guide.topAnchor constant:10],
        [self.filterControl.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:12],
        [self.filterControl.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-12],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.filterControl.bottomAnchor constant:8],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.filterControl.leadingAnchor],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.filterControl.trailingAnchor],
        [self.textView.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:8],
        [self.textView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:8],
        [self.textView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-8],
        [self.textView.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-8],
    ]];

    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                     target:self action:@selector(shareLogs)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                     target:self action:@selector(refresh)],
    ];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:CILocalized(@"CLEAR", @"Clear")
                                         style:UIBarButtonItemStylePlain
                                        target:self action:@selector(confirmClear)];
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
    controller.popoverPresentationController.barButtonItem =
        self.navigationItem.rightBarButtonItems.firstObject;
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
