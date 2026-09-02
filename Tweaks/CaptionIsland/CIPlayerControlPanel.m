#import "CIPlayerControlPanel.h"
#import "CICaptionCoordinator.h"
#import "CIConstants.h"
#import "CILRCLIBProvider.h"
#import "CILanguagePriorityViewController.h"
#import "CIModels.h"
#import "CITextUtilities.h"
#import "CIToastPresenter.h"
#import "CIVideoOverrides.h"

// The same ±30s ceiling the settings screen enforces, so a value saved here can
// never be one the settings screen would reject.
static const NSTimeInterval CIPanelMaximumAdvance = 30.0;
// Offered nudges. Coarse and fine in both directions covers the two things users
// actually do: fix a whole line of drift, then trim it.
static const NSTimeInterval CIPanelCoarseStep = 3.0;
static const NSTimeInterval CIPanelFineStep = 0.5;

/// The panel background: real Liquid Glass on iOS 26, system material before it.
///
/// `UIGlassEffect` cannot be named at compile time because this tweak is built
/// against the iOS 17.5 SDK, so it is resolved by name and type-checked before
/// use. A failed lookup is the normal path on every current OS, not an error.
static UIVisualEffect *CIPanelBackgroundEffect(void) {
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (glassClass) {
        id candidate = [[glassClass alloc] init];
        if ([candidate isKindOfClass:UIVisualEffect.class]) {
            return candidate;
        }
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
}

/// The topmost controller that can actually present a modal.
static UIViewController *CIPanelPresenter(UIViewController *hint) {
    UIViewController *root = hint;
    if (!root) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow && window.rootViewController) {
                    root = window.rootViewController;
                    break;
                }
            }
            if (root) break;
        }
    }
    while (root.presentedViewController &&
           !root.presentedViewController.isBeingDismissed) {
        root = root.presentedViewController;
    }
    return root;
}

@interface CIPlayerControlPanelViewController : UIViewController
@property (nonatomic, strong, nullable) CIVideoContext *context;
@property (nonatomic, strong) UIStackView *content;
@property (nonatomic, strong) UILabel *advanceValueLabel;
/// The lyric-browse section, rebuilt in place as the search progresses.
@property (nonatomic, strong) UIStackView *lyricSection;
/// Its own provider instance rather than the coordinator's: browsing must not
/// cancel the playback lookup, and each instance owns its request token. Both
/// share the on-disk cache, which is why a write bumps the cache generation.
@property (nonatomic, strong, nullable) CILRCLIBProvider *browseProvider;
@property (nonatomic, copy, nullable)
    NSArray<CILRCLIBResult *> *browseMatches;
/// The one parsed reading (or manually entered title) chosen for the current
/// browse. Playback still pins the selected result to the video's normal query.
@property (nonatomic, copy, nullable)
    NSArray<CISongQuery *> *activeBrowseReadings;
@property (nonatomic, copy, nullable) NSString *activeBrowseTitle;
@property (nonatomic) BOOL browsing;
@property (nonatomic, copy, nullable) NSString *browseMessage;
- (void)presentBrowseMenu;
- (void)presentCustomBrowsePrompt;
- (void)beginBrowseWithReadings:(NSArray<CISongQuery *> *)readings;
@end

@implementation CIPlayerControlPanelViewController

#pragma mark - Model

- (CIVideoOverride *)override {
    return CIVideoOverrideForVideoID(self.context.videoID);
}

- (NSTimeInterval)currentAdvance {
    return self.override.captionAdvanceSeconds;
}

/// Saves a new advance value without disturbing the title/artist override.
///
/// `CISaveVideoOverride` writes all three fields at once, so the existing search
/// title and artist have to be read back and passed through; omitting them would
/// silently erase a title the user typed on the settings screen.
- (void)commitAdvance:(NSTimeInterval)advance {
    CIVideoOverride *existing = self.override;
    NSTimeInterval clamped =
        MAX(-CIPanelMaximumAdvance, MIN(CIPanelMaximumAdvance, advance));
    // Collapse float noise so repeated ±0.5 taps cannot drift to 2.9999999.
    clamped = round(clamped * 10.0) / 10.0;
    CISaveVideoOverride(
        self.context.videoID,
        existing.searchTitle,
        existing.searchArtist,
        clamped,
        self.context.title
    );
    [CICaptionCoordinator.sharedCoordinator reloadPreferences];
    [self refreshAdvanceLabel];
}

- (void)refreshAdvanceLabel {
    NSTimeInterval advance = self.currentAdvance;
    NSString *text;
    if (fabs(advance) < 0.05) {
        text = CILocalized(@"PANEL_TIMING_IN_SYNC", @"No offset");
    } else {
        text = [NSString stringWithFormat:@"%@%.1f s",
            advance > 0 ? @"+" : @"−", fabs(advance)];
    }
    self.advanceValueLabel.text = text;
}

#pragma mark - Actions

- (void)nudgeAdvance:(UIButton *)sender {
    [self commitAdvance:self.currentAdvance + (NSTimeInterval)sender.tag / 10.0];
}

- (void)resetAdvance {
    [self commitAdvance:0];
}

- (void)selectLanguage:(UIButton *)sender {
    NSArray<CICaptionTrack *> *tracks = self.selectableTracks;
    NSInteger index = sender.tag;
    NSArray<NSString *> *priorities = @[];
    CIVideoCaptionSourcePreference sourcePreference =
        CIVideoCaptionSourcePreferenceInherit;
    if (index >= 0 && index < (NSInteger)tracks.count) {
        CICaptionTrack *track = tracks[(NSUInteger)index];
        priorities = @[track.languageCode ?: @""];
        sourcePreference = track.isAutomatic
            ? CIVideoCaptionSourcePreferenceASR
            : CIVideoCaptionSourcePreferenceManualCC;
    }
    CISaveVideoCaptionSelection(
        self.context.videoID,
        priorities,
        sourcePreference,
        self.context.title
    );
    [CICaptionCoordinator.sharedCoordinator reloadPreferences];
    if (priorities.count > 0) {
        CICaptionTrack *track = tracks[(NSUInteger)index];
        CIShowToast([NSString stringWithFormat:CILocalized(
            @"PANEL_CAPTION_SELECTED",
            @"This video now uses %@ · %@ before LRCLIB."
        ), CICaptionLanguageTitle(track.languageCode),
           track.isAutomatic ? @"ASR" : @"CC"]);
    } else {
        CIShowToast(CILocalized(
            @"VIDEO_LANGUAGE_PRIORITY_RESET_DONE",
            @"This video now uses the global language order."
        ));
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dismissPanel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Caption tracks

/// The video's own caption tracks, de-duplicated by language and source kind.
///
/// A video routinely carries both a manual and an automatic track for one
/// language. They must remain separate choices because the player's selection is
/// also a per-video source override. Auto-translated tracks never reach here: the
/// inspector rejects `tlang` URLs before a context is built.
- (NSArray<CICaptionTrack *> *)selectableTracks {
    NSMutableArray<CICaptionTrack *> *tracks = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (CICaptionTrack *track in self.context.captionTracks) {
        NSString *code = track.languageCode ?: @"";
        NSString *identity = [NSString stringWithFormat:@"%@|%d",
            code.lowercaseString, track.isAutomatic];
        if (code.length == 0 || [seen containsObject:identity]) continue;
        [seen addObject:identity];
        [tracks addObject:track];
    }
    return tracks;
}

#pragma mark - Layout helpers

- (UILabel *)sectionHeaderWithText:(NSString *)text {
    UILabel *label = [UILabel new];
    label.text = text.uppercaseString;
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    label.textColor = UIColor.secondaryLabelColor;
    return label;
}

- (UIButton *)pillButtonWithTitle:(NSString *)title
                           action:(SEL)action
                              tag:(NSInteger)tag
                         selected:(BOOL)selected {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = tag;
    // A configuration rather than the deprecated contentEdgeInsets/titleLabel
    // pair: on a configuration-based button those are ignored, so setting them
    // would silently produce an unpadded button.
    UIButtonConfiguration *configuration =
        [UIButtonConfiguration plainButtonConfiguration];
    configuration.contentInsets =
        NSDirectionalEdgeInsetsMake(10, 14, 10, 14);
    configuration.attributedTitle = [[NSAttributedString alloc]
        initWithString:title
            attributes:@{
                NSFontAttributeName:
                    [UIFont systemFontOfSize:15 weight:UIFontWeightMedium],
            }];
    button.configuration = configuration;
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.7;
    button.layer.cornerRadius = 12;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.backgroundColor = selected
        ? [UIColor.labelColor colorWithAlphaComponent:0.16]
        : [UIColor.labelColor colorWithAlphaComponent:0.07];
    [button setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    [button addTarget:self action:action
        forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIStackView *)rowWithViews:(NSArray<UIView *> *)views {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:views];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 8;
    return row;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    UIVisualEffectView *background = [[UIVisualEffectView alloc]
        initWithEffect:CIPanelBackgroundEffect()];
    background.frame = self.view.bounds;
    background.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:background];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];

    self.content = [UIStackView new];
    self.content.axis = UILayoutConstraintAxisVertical;
    self.content.spacing = 10;
    self.content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:self.content];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [self.content.topAnchor
            constraintEqualToAnchor:scroll.topAnchor constant:16],
        [self.content.leadingAnchor
            constraintEqualToAnchor:scroll.leadingAnchor constant:20],
        [self.content.trailingAnchor
            constraintEqualToAnchor:scroll.trailingAnchor constant:-20],
        [self.content.bottomAnchor
            constraintEqualToAnchor:scroll.bottomAnchor constant:-16],
        [self.content.widthAnchor
            constraintEqualToAnchor:scroll.widthAnchor constant:-40],
    ]];

    [self buildContent];
}

- (void)buildContent {
    UILabel *title = [UILabel new];
    title.text = CILocalized(@"PANEL_TITLE", @"Caption Island");
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    [self.content addArrangedSubview:title];

    if (self.context.videoID.length == 0) {
        UILabel *empty = [UILabel new];
        empty.text = CILocalized(
            @"VIDEO_OVERRIDE_NO_VIDEO",
            @"Open a video first, then return here."
        );
        empty.numberOfLines = 0;
        empty.textColor = UIColor.secondaryLabelColor;
        [self.content addArrangedSubview:empty];
        return;
    }

    UILabel *subtitle = [UILabel new];
    subtitle.text = self.context.title ?: @"";
    subtitle.font = [UIFont systemFontOfSize:13];
    subtitle.textColor = UIColor.secondaryLabelColor;
    subtitle.numberOfLines = 2;
    [self.content addArrangedSubview:subtitle];

    [self.content addArrangedSubview:[self sectionHeaderWithText:
        CILocalized(@"PANEL_TIMING", @"Caption timing")]];

    self.advanceValueLabel = [UILabel new];
    self.advanceValueLabel.font =
        [UIFont monospacedDigitSystemFontOfSize:17
                                         weight:UIFontWeightSemibold];
    self.advanceValueLabel.textAlignment = NSTextAlignmentCenter;
    [self.content addArrangedSubview:self.advanceValueLabel];
    [self refreshAdvanceLabel];

    // Tags carry tenths of a second so the whole row shares one action.
    [self.content addArrangedSubview:[self rowWithViews:@[
        [self pillButtonWithTitle:@"− 3 s"
            action:@selector(nudgeAdvance:)
            tag:(NSInteger)(-CIPanelCoarseStep * 10) selected:NO],
        [self pillButtonWithTitle:@"− 0.5"
            action:@selector(nudgeAdvance:)
            tag:(NSInteger)(-CIPanelFineStep * 10) selected:NO],
        [self pillButtonWithTitle:CILocalized(@"PANEL_TIMING_RESET", @"Reset")
            action:@selector(resetAdvance) tag:0 selected:NO],
        [self pillButtonWithTitle:@"+ 0.5"
            action:@selector(nudgeAdvance:)
            tag:(NSInteger)(CIPanelFineStep * 10) selected:NO],
        [self pillButtonWithTitle:@"+ 3 s"
            action:@selector(nudgeAdvance:)
            tag:(NSInteger)(CIPanelCoarseStep * 10) selected:NO],
    ]]];

    UILabel *timingHint = [UILabel new];
    timingHint.text = CILocalized(
        @"PANEL_TIMING_HINT",
        @"Positive values show captions earlier. Saved for this video."
    );
    timingHint.font = [UIFont systemFontOfSize:12];
    timingHint.textColor = UIColor.tertiaryLabelColor;
    timingHint.numberOfLines = 0;
    [self.content addArrangedSubview:timingHint];

    [self buildLanguageSection];

    self.lyricSection = [UIStackView new];
    self.lyricSection.axis = UILayoutConstraintAxisVertical;
    self.lyricSection.spacing = 8;
    [self.content addArrangedSubview:self.lyricSection];
    [self rebuildLyricSection];

    UIButton *close = [self pillButtonWithTitle:
        CILocalized(@"PANEL_CLOSE", @"Done")
        action:@selector(dismissPanel) tag:0 selected:NO];
    [self.content addArrangedSubview:close];
}

#pragma mark - Lyric chooser

- (NSArray<CISongQuery *> *)readings {
    return [CICaptionCoordinator.sharedCoordinator
        LRCLIBReadingsForContext:self.context];
}

- (void)rebuildLyricSection {
    for (UIView *view in self.lyricSection.arrangedSubviews.copy) {
        [self.lyricSection removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    [self.lyricSection addArrangedSubview:[self sectionHeaderWithText:
        CILocalized(@"PANEL_LYRICS", @"Lyrics for this video")]];

    if (self.override.lyricsSuppressed) {
        UILabel *state = [UILabel new];
        state.text = CILocalized(
            @"PANEL_LYRICS_SUPPRESSED_STATE",
            @"Lyrics are switched off for this video."
        );
        state.font = [UIFont systemFontOfSize:12];
        state.textColor = UIColor.tertiaryLabelColor;
        state.numberOfLines = 0;
        [self.lyricSection addArrangedSubview:state];
        [self.lyricSection addArrangedSubview:[self pillButtonWithTitle:
            CILocalized(@"PANEL_LYRICS_ALLOW", @"Turn lyrics back on")
            action:@selector(allowLyrics) tag:0 selected:NO]];
        return;
    }

    if (self.browsing) {
        UILabel *progress = [UILabel new];
        progress.text = [NSString stringWithFormat:CILocalized(
            @"PANEL_LYRICS_SEARCHING_QUERY",
            @"Searching LRCLIB for “%@”…"
        ), self.activeBrowseTitle ?: @""];
        progress.font = [UIFont systemFontOfSize:13];
        progress.textColor = UIColor.secondaryLabelColor;
        progress.numberOfLines = 0;
        [self.lyricSection addArrangedSubview:progress];
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        [self.lyricSection addArrangedSubview:spinner];
        return;
    }

    if (!self.browseMatches) {
        UILabel *hint = [UILabel new];
        // One selected reading is searched at a time so the user controls both
        // the query and the number of rate-limited requests this action spends.
        hint.text = CILocalized(
            @"PANEL_LYRICS_HINT",
            @"Choose one possible song title to list every LRCLIB result, or enter a title yourself."
        );
        hint.font = [UIFont systemFontOfSize:12];
        hint.textColor = UIColor.tertiaryLabelColor;
        hint.numberOfLines = 0;
        [self.lyricSection addArrangedSubview:hint];
        [self.lyricSection addArrangedSubview:[self pillButtonWithTitle:
            CILocalized(@"PANEL_LYRICS_SEARCH", @"Search all results")
            action:@selector(presentBrowseMenu) tag:0 selected:NO]];
        [self.lyricSection addArrangedSubview:[self pillButtonWithTitle:
            CILocalized(@"PANEL_LYRICS_SUPPRESS", @"Show no lyrics for this video")
            action:@selector(suppressLyrics) tag:0 selected:NO]];
        return;
    }

    if (self.browseMatches.count == 0) {
        UILabel *empty = [UILabel new];
        empty.text = self.browseMessage.length > 0
            ? self.browseMessage
            : CILocalized(@"NO_MATCHING_RESULT", @"No matching results");
        empty.font = [UIFont systemFontOfSize:12];
        empty.textColor = UIColor.tertiaryLabelColor;
        empty.numberOfLines = 0;
        [self.lyricSection addArrangedSubview:empty];
    } else {
        UILabel *count = [UILabel new];
        count.text = [NSString stringWithFormat:CILocalized(
            @"PANEL_LYRICS_COUNT", @"%lu results, closest length first"
        ), (unsigned long)self.browseMatches.count];
        count.font = [UIFont systemFontOfSize:12];
        count.textColor = UIColor.secondaryLabelColor;
        [self.lyricSection addArrangedSubview:count];

        NSInteger index = 0;
        for (CILRCLIBResult *match in self.browseMatches) {
            [self.lyricSection addArrangedSubview:
                [self rowForMatch:match tag:index]];
            index++;
        }
    }
    [self.lyricSection addArrangedSubview:[self pillButtonWithTitle:
        CILocalized(@"PANEL_LYRICS_SEARCH_AGAIN", @"Search another title")
        action:@selector(presentBrowseMenu) tag:0 selected:NO]];
    [self.lyricSection addArrangedSubview:[self pillButtonWithTitle:
        CILocalized(@"PANEL_LYRICS_SUPPRESS", @"Show no lyrics for this video")
        action:@selector(suppressLyrics) tag:0 selected:NO]];
}

/// One result row. Everything the automatic scorer would have judged on is shown,
/// so a rejected match is explainable rather than mysterious.
- (UIButton *)rowForMatch:(CILRCLIBResult *)match tag:(NSInteger)tag {
    NSMutableArray<NSString *> *detail = [NSMutableArray array];
    if (match.trackDuration > 0) {
        [detail addObject:[NSString stringWithFormat:@"%ld:%02ld",
            (long)(match.trackDuration / 60),
            (long)fmod(floor(match.trackDuration), 60)]];
    }
    if (match.durationDifference >= 0) {
        [detail addObject:[NSString stringWithFormat:
            CILocalized(@"PANEL_LYRICS_DELTA", @"%+.0fs vs video"),
            match.trackDuration - (self.context.duration ?: 0)]];
    }
    [detail addObject:match.syncedCues.count > 0
        ? CILocalized(@"LRCLIB_CACHE_SYNCED", @"synced")
        : CILocalized(@"LRCLIB_CACHE_PLAIN", @"plain text")];

    NSString *title = [NSString stringWithFormat:@"%@ — %@\n%@",
        match.artistName.length > 0 ? match.artistName : @"?",
        match.trackName,
        [detail componentsJoinedByString:@"  ·  "]];
    UIButton *button = [self pillButtonWithTitle:title
        action:@selector(selectMatch:) tag:tag selected:NO];
    button.titleLabel.numberOfLines = 0;
    button.titleLabel.adjustsFontSizeToFitWidth = NO;
    button.contentHorizontalAlignment =
        UIControlContentHorizontalAlignmentLeft;
    return button;
}

- (NSString *)browseMenuTitleForReading:(CISongQuery *)reading {
    NSString *label = reading.artist.length > 0
        ? [NSString stringWithFormat:@"%@ — %@", reading.title, reading.artist]
        : reading.title;
    if (label.length > 110) {
        label = [[label substringToIndex:109] stringByAppendingString:@"…"];
    }
    return label;
}

- (void)presentBrowseMenu {
    NSArray<CISongQuery *> *readings = self.readings;
    if (readings.count == 0) return;
    UIAlertController *menu = [UIAlertController
        alertControllerWithTitle:CILocalized(
            @"PANEL_LYRICS_CHOOSE_QUERY",
            @"Choose a song title to search"
        )
        message:CILocalized(
            @"PANEL_LYRICS_CHOOSE_QUERY_HINT",
            @"Only the selected interpretation is searched."
        )
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (CISongQuery *reading in readings) {
        [menu addAction:[UIAlertAction
            actionWithTitle:[self browseMenuTitleForReading:reading]
            style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                // The dash in the menu is presentation only. Preserve the artist
                // as structured metadata so manual q= search can send
                // `title artist` with a plain space and, if that finds nothing,
                // retry the same pair in reverse order.
                CISongQuery *selected = [CISongQuery
                    queryWithTitle:reading.title
                             artist:reading.artist
                             origin:reading.origin];
                [weakSelf beginBrowseWithReadings:@[selected]];
            }]];
    }
    [menu addAction:[UIAlertAction
        actionWithTitle:CILocalized(
            @"PANEL_LYRICS_CUSTOM_QUERY", @"Enter a song title…")
        style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            // Let the action sheet finish its automatic dismissal before the
            // text-entry alert is presented by the same controller.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(0.25 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                [weakSelf presentCustomBrowsePrompt];
            });
        }]];
    [menu addAction:[UIAlertAction
        actionWithTitle:CILocalized(@"CANCEL", @"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = menu.popoverPresentationController;
    if (popover) {
        popover.sourceView = self.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
            CGRectGetMaxY(self.view.bounds) - 1, 1, 1);
        popover.permittedArrowDirections = 0;
    }
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)presentCustomBrowsePrompt {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:CILocalized(
            @"PANEL_LYRICS_CUSTOM_QUERY", @"Enter a song title…")
        message:CILocalized(
            @"PANEL_LYRICS_CUSTOM_QUERY_HINT",
            @"Enter the track name LRCLIB should search."
        )
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = self.readings.firstObject.title ?: @"";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.returnKeyType = UIReturnKeySearch;
    }];
    [alert addAction:[UIAlertAction
        actionWithTitle:CILocalized(@"CANCEL", @"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction
        actionWithTitle:CILocalized(@"SEARCH", @"Search")
        style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *title = CICleanCaptionText(alert.textFields.firstObject.text);
            if (title.length == 0) {
                CIShowToast(CILocalized(
                    @"PANEL_LYRICS_CUSTOM_QUERY_EMPTY",
                    @"Enter a song title to search."
                ));
                return;
            }
            CISongQuery *reading = [CISongQuery queryWithTitle:title
                artist:@"" origin:@"manual"];
            [weakSelf beginBrowseWithReadings:@[reading]];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)beginBrowseWithReadings:(NSArray<CISongQuery *> *)readings {
    if (readings.count == 0) return;
    self.activeBrowseReadings = readings.copy;
    self.activeBrowseTitle = readings.firstObject.title ?: @"";
    self.browsing = YES;
    self.browseMatches = nil;
    self.browseMessage = nil;
    [self rebuildLyricSection];
    if (!self.browseProvider) self.browseProvider = [CILRCLIBProvider new];
    __weak typeof(self) weakSelf = self;
    [self.browseProvider fetchAllMatchesForCandidates:readings
                                            duration:self.context.duration
                                          completion:
        ^(NSArray<CILRCLIBResult *> *matches, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            self.browsing = NO;
            self.browseMatches = matches ?: @[];
            self.browseMessage = error.localizedDescription;
            [self rebuildLyricSection];
        });
    }];
}

- (void)selectMatch:(UIButton *)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= (NSInteger)self.browseMatches.count) return;
    CILRCLIBResult *match = self.browseMatches[(NSUInteger)index];
    // Picking also lifts a previous "no lyrics" decision; the two are the same
    // choice expressed two ways and leaving both set would be contradictory. It
    // also clears a CC/ASR panel override: explicitly choosing an LRCLIB row must
    // not leave an older YouTube-source choice silently winning on reload.
    CISaveVideoLyricsSuppressed(self.context.videoID, NO, self.context.title);
    CISaveVideoCaptionSelection(
        self.context.videoID,
        @[],
        CIVideoCaptionSourcePreferenceInherit,
        self.context.title
    );
    NSArray<CISongQuery *> *pinReadings = self.readings;
    if (pinReadings.count == 0) pinReadings = self.activeBrowseReadings;
    [self.browseProvider pinResult:match
                    forCandidates:pinReadings
                         duration:self.context.duration];
    [CICaptionCoordinator.sharedCoordinator reloadPreferences];
    CIShowToast([NSString stringWithFormat:
        CILocalized(@"PANEL_LYRICS_SELECTED", @"Using “%@” for this video."),
        match.trackName]);
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)suppressLyrics {
    CISaveVideoLyricsSuppressed(self.context.videoID, YES, self.context.title);
    [CICaptionCoordinator.sharedCoordinator reloadPreferences];
    CIShowToast(CILocalized(
        @"PANEL_LYRICS_SUPPRESSED_STATE",
        @"Lyrics are switched off for this video."
    ));
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)allowLyrics {
    CISaveVideoLyricsSuppressed(self.context.videoID, NO, self.context.title);
    [CICaptionCoordinator.sharedCoordinator reloadPreferences];
    [self rebuildLyricSection];
}

- (void)buildLanguageSection {
    NSArray<CICaptionTrack *> *tracks = self.selectableTracks;
    [self.content addArrangedSubview:[self sectionHeaderWithText:
        CILocalized(@"PANEL_LANGUAGE", @"YouTube caption language")]];

    if (tracks.count == 0) {
        UILabel *none = [UILabel new];
        none.text = CILocalized(
            @"PANEL_LANGUAGE_NONE",
            @"This video has no YouTube caption tracks, so only LRCLIB lyrics can be shown."
        );
        none.font = [UIFont systemFontOfSize:12];
        none.textColor = UIColor.tertiaryLabelColor;
        none.numberOfLines = 0;
        [self.content addArrangedSubview:none];
        return;
    }

    NSArray<NSString *> *saved = self.override.captionLanguagePriorities;
    NSString *selectedCode = saved.firstObject;
    CIVideoCaptionSourcePreference selectedSource =
        self.override.captionSourcePreference;
    NSInteger index = 0;
    for (CICaptionTrack *track in tracks) {
        NSString *name = CICaptionLanguageTitle(track.languageCode);
        // The badge matches what the caption itself will show, so the choice and
        // its consequence are described in the same vocabulary.
        NSString *label = [NSString stringWithFormat:@"%@  ·  %@",
            name, track.isAutomatic ? @"ASR" : @"CC"];
        CIVideoCaptionSourcePreference trackSource = track.isAutomatic
            ? CIVideoCaptionSourcePreferenceASR
            : CIVideoCaptionSourcePreferenceManualCC;
        BOOL selected = selectedCode.length > 0 &&
            [track.languageCode isEqualToString:selectedCode] &&
            selectedSource == trackSource;
        UIButton *button = [self pillButtonWithTitle:label
            action:@selector(selectLanguage:) tag:index selected:selected];
        button.contentHorizontalAlignment =
            UIControlContentHorizontalAlignmentLeft;
        [self.content addArrangedSubview:button];
        index++;
    }

    UIButton *inherit = [self pillButtonWithTitle:
        CILocalized(@"LANGUAGE_PRIORITY_INHERIT", @"Use global order")
        action:@selector(selectLanguage:) tag:-1
        selected:selectedCode.length == 0 &&
            selectedSource == CIVideoCaptionSourcePreferenceInherit];
    inherit.contentHorizontalAlignment =
        UIControlContentHorizontalAlignmentLeft;
    [self.content addArrangedSubview:inherit];
}

@end

void CIPresentPlayerControlPanel(UIViewController *sourceViewController) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [CICaptionCoordinator.sharedCoordinator
            currentVideoContextWithCompletion:^(CIVideoContext *context) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIViewController *presenter =
                    CIPanelPresenter(sourceViewController);
                if (!presenter) return;
                CIPlayerControlPanelViewController *panel =
                    [CIPlayerControlPanelViewController new];
                panel.context = context;
                panel.modalPresentationStyle =
                    UIModalPresentationPageSheet;
                UISheetPresentationController *sheet =
                    panel.sheetPresentationController;
                if (sheet) {
                    sheet.detents = @[
                        UISheetPresentationControllerDetent.mediumDetent,
                        UISheetPresentationControllerDetent.largeDetent,
                    ];
                    sheet.prefersGrabberVisible = YES;
                    // Liquid Glass reads as a floating surface, so let the
                    // corners match rather than sitting square against it.
                    sheet.preferredCornerRadius = 28;
                }
                [presenter presentViewController:panel
                                       animated:YES
                                     completion:nil];
            });
        }];
    });
}
