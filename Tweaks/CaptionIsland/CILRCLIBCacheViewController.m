#import "CILRCLIBCacheViewController.h"
#import "CIConstants.h"
#import "CILRCLIBProvider.h"

/// Read-only view of one cached entry's stored lyrics.
@interface CILRCLIBCacheDetailViewController : UIViewController
@property (nonatomic, strong) CILRCLIBCacheEntry *entry;
@end

@implementation CILRCLIBCacheDetailViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.entry.trackName.length > 0
        ? self.entry.trackName
        : CILocalized(@"LRCLIB_CACHE", @"Saved lyrics");
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel *subtitle = [UILabel new];
    subtitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    subtitle.textColor = UIColor.secondaryLabelColor;
    subtitle.numberOfLines = 0;
    subtitle.text = [NSString stringWithFormat:@"%@%@",
        self.entry.artistName.length > 0 ? self.entry.artistName : @"—",
        self.entry.hasSyncedTimeline
            ? CILocalized(@"LRCLIB_CACHE_SYNCED_SUFFIX", @" · synced")
            : CILocalized(@"LRCLIB_CACHE_PLAIN_SUFFIX", @" · plain text")];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;

    UITextView *textView = [UITextView new];
    textView.editable = NO;
    textView.selectable = YES;
    textView.alwaysBounceVertical = YES;
    textView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    textView.textColor = UIColor.labelColor;
    textView.font = [UIFont monospacedSystemFontOfSize:12
                                                weight:UIFontWeightRegular];
    textView.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    textView.layer.cornerRadius = 10;
    textView.text = self.entry.lyricsText;
    textView.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:subtitle];
    [self.view addSubview:textView];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [subtitle.topAnchor constraintEqualToAnchor:guide.topAnchor constant:10],
        [subtitle.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor
                                              constant:12],
        [subtitle.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor
                                               constant:-12],
        [textView.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor
                                           constant:10],
        [textView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor
                                              constant:8],
        [textView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor
                                               constant:-8],
        [textView.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor
                                             constant:-8],
    ]];
}

@end

@interface CILRCLIBCacheViewController ()
    <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *deleteMatchingButton;
@property (nonatomic, strong) UITableView *tableView;
/// Everything in the cache, reloaded from disk on appearance.
@property (nonatomic, copy) NSArray<CILRCLIBCacheEntry *> *allEntries;
/// The subset matching the search text; identical to allEntries when empty.
@property (nonatomic, copy) NSArray<CILRCLIBCacheEntry *> *visibleEntries;
@end

@implementation CILRCLIBCacheViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = CILocalized(@"LRCLIB_CACHE", @"Saved lyrics");
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.allEntries = @[];
    self.visibleEntries = @[];

    self.searchBar = [UISearchBar new];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = CILocalized(
        @"LRCLIB_CACHE_SEARCH_PLACEHOLDER",
        @"Search song, artist or album"
    );
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;

    self.statusLabel = [UILabel new];
    self.statusLabel.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIButtonConfiguration *configuration =
        UIButtonConfiguration.tintedButtonConfiguration;
    configuration.title = CILocalized(
        @"LRCLIB_CACHE_DELETE_MATCHING",
        @"Delete matching"
    );
    configuration.image = [UIImage systemImageNamed:@"trash"];
    configuration.imagePlacement = NSDirectionalRectEdgeLeading;
    configuration.imagePadding = 6;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    configuration.baseForegroundColor = UIColor.systemRedColor;
    configuration.baseBackgroundColor =
        [UIColor.systemRedColor colorWithAlphaComponent:0.12];
    self.deleteMatchingButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.deleteMatchingButton.configuration = configuration;
    [self.deleteMatchingButton addTarget:self
                                  action:@selector(confirmDeleteMatching)
                        forControlEvents:UIControlEventTouchUpInside];
    self.deleteMatchingButton.translatesAutoresizingMaskIntoConstraints = NO;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero
                                                  style:UITableViewStyleInsetGrouped];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.keyboardDismissMode =
        UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:self.searchBar];
    [self.view addSubview:self.statusLabel];
    [self.view addSubview:self.deleteMatchingButton];
    [self.view addSubview:self.tableView];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.topAnchor constraintEqualToAnchor:guide.topAnchor
                                                constant:4],
        [self.searchBar.leadingAnchor
            constraintEqualToAnchor:guide.leadingAnchor constant:8],
        [self.searchBar.trailingAnchor
            constraintEqualToAnchor:guide.trailingAnchor constant:-8],
        [self.statusLabel.topAnchor
            constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.statusLabel.leadingAnchor
            constraintEqualToAnchor:guide.leadingAnchor constant:16],
        [self.statusLabel.trailingAnchor
            constraintEqualToAnchor:guide.trailingAnchor constant:-16],
        [self.deleteMatchingButton.topAnchor
            constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:8],
        [self.deleteMatchingButton.leadingAnchor
            constraintEqualToAnchor:guide.leadingAnchor constant:16],
        [self.deleteMatchingButton.trailingAnchor
            constraintEqualToAnchor:guide.trailingAnchor constant:-16],
        [self.deleteMatchingButton.heightAnchor constraintEqualToConstant:42],
        [self.tableView.topAnchor
            constraintEqualToAnchor:self.deleteMatchingButton.bottomAnchor
                           constant:6],
        [self.tableView.leadingAnchor
            constraintEqualToAnchor:guide.leadingAnchor],
        [self.tableView.trailingAnchor
            constraintEqualToAnchor:guide.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor],
    ]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadFromDisk];
}

- (void)reloadFromDisk {
    self.allEntries = [CILRCLIBProvider cachedLyricEntries];
    [self applyFilter];
}

- (void)applyFilter {
    NSString *needle = [self.searchBar.text
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    if (needle.length == 0) {
        self.visibleEntries = self.allEntries;
    } else {
        NSMutableArray<CILRCLIBCacheEntry *> *matches =
            [NSMutableArray arrayWithCapacity:self.allEntries.count];
        for (CILRCLIBCacheEntry *entry in self.allEntries) {
            if ([entry.searchIndex containsString:needle]) {
                [matches addObject:entry];
            }
        }
        self.visibleEntries = matches;
    }
    [self updateStatus];
    [self.tableView reloadData];
}

- (void)updateStatus {
    BOOL filtering = self.visibleEntries.count != self.allEntries.count;
    self.statusLabel.text = filtering
        ? [NSString stringWithFormat:CILocalized(
              @"LRCLIB_CACHE_FILTER_COUNT",
              @"%lu of %lu saved songs match"
          ), (unsigned long)self.visibleEntries.count,
             (unsigned long)self.allEntries.count]
        : [NSString stringWithFormat:CILocalized(
              @"LRCLIB_CACHE_TOTAL_COUNT",
              @"%lu songs saved · kept until you delete them"
          ), (unsigned long)self.allEntries.count];
    self.deleteMatchingButton.enabled = self.visibleEntries.count > 0;
    self.deleteMatchingButton.alpha =
        self.deleteMatchingButton.enabled ? 1.0 : 0.4;
}

- (NSString *)subtitleForEntry:(CILRCLIBCacheEntry *)entry {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (entry.artistName.length > 0) [parts addObject:entry.artistName];
    if (entry.trackDuration > 0 && isfinite(entry.trackDuration)) {
        [parts addObject:[NSString stringWithFormat:@"%d:%02d",
            (int)(entry.trackDuration / 60.0),
            (int)fmod(entry.trackDuration, 60.0)]];
    }
    [parts addObject:entry.hasSyncedTimeline
        ? CILocalized(@"LRCLIB_CACHE_SYNCED", @"synced")
        : CILocalized(@"LRCLIB_CACHE_PLAIN", @"plain text")];
    [parts addObject:[NSString stringWithFormat:CILocalized(
        @"LRCLIB_CACHE_LINE_COUNT", @"%lu lines"
    ), (unsigned long)entry.lineCount]];
    return [parts componentsJoinedByString:@" · "];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(__unused UITableView *)tableView
 numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)self.visibleEntries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const identifier = @"CILRCLIBCacheCell";
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
          reuseIdentifier:identifier];
    }
    CILRCLIBCacheEntry *entry = self.visibleEntries[(NSUInteger)indexPath.row];
    cell.textLabel.text = entry.trackName;
    cell.detailTextLabel.text = [self subtitleForEntry:entry];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (NSString *)tableView:(__unused UITableView *)tableView
    titleForFooterInSection:(__unused NSInteger)section {
    return self.allEntries.count == 0
        ? CILocalized(
              @"LRCLIB_CACHE_EMPTY",
              @"No lyrics saved yet. Playing a video that finds lyrics saves them here."
          )
        : nil;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    CILRCLIBCacheDetailViewController *detail =
        [CILRCLIBCacheDetailViewController new];
    detail.entry = self.visibleEntries[(NSUInteger)indexPath.row];
    if (self.navigationController) {
        [self.navigationController pushViewController:detail animated:YES];
    } else {
        [self presentViewController:
            [[UINavigationController alloc]
                initWithRootViewController:detail]
                          animated:YES
                        completion:nil];
    }
}

- (UISwipeActionsConfiguration *)tableView:(__unused UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    __weak typeof(self) weakSelf = self;
    NSUInteger row = (NSUInteger)indexPath.row;
    UIContextualAction *delete = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
        title:CILocalized(@"DELETE", @"Delete")
        handler:^(__unused UIContextualAction *action,
                  __unused UIView *sourceView,
                  void (^completion)(BOOL)) {
            typeof(self) self = weakSelf;
            if (!self || row >= self.visibleEntries.count) {
                completion(NO);
                return;
            }
            [CILRCLIBProvider removeCachedEntriesWithKeys:
                @[self.visibleEntries[row].cacheKey]];
            [self reloadFromDisk];
            completion(YES);
        }];
    return [UISwipeActionsConfiguration
        configurationWithActions:@[delete]];
}

#pragma mark - UISearchBarDelegate

- (void)searchBar:(__unused UISearchBar *)searchBar
    textDidChange:(__unused NSString *)searchText {
    [self applyFilter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

#pragma mark - Bulk delete

- (void)confirmDeleteMatching {
    NSArray<CILRCLIBCacheEntry *> *targets = self.visibleEntries;
    if (targets.count == 0) return;
    BOOL filtering = targets.count != self.allEntries.count;
    NSString *message = filtering
        ? [NSString stringWithFormat:CILocalized(
              @"LRCLIB_CACHE_DELETE_MATCHING_CONFIRM",
              @"Delete the %lu songs matching this search?"
          ), (unsigned long)targets.count]
        : [NSString stringWithFormat:CILocalized(
              @"LRCLIB_CACHE_DELETE_ALL_CONFIRM",
              @"Delete all %lu saved songs?"
          ), (unsigned long)targets.count];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:CILocalized(
            @"LRCLIB_CACHE_DELETE_MATCHING",
            @"Delete matching"
        )
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:CILocalized(@"CANCEL", @"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction
        actionWithTitle:CILocalized(@"DELETE", @"Delete")
        style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            typeof(self) self = weakSelf;
            if (!self) return;
            NSMutableArray<NSString *> *keys =
                [NSMutableArray arrayWithCapacity:targets.count];
            for (CILRCLIBCacheEntry *entry in targets) {
                [keys addObject:entry.cacheKey];
            }
            [CILRCLIBProvider removeCachedEntriesWithKeys:keys];
            [self reloadFromDisk];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
