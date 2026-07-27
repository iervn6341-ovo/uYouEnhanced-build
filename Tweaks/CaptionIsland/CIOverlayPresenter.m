#import "CIOverlayPresenter.h"
#import "CIConstants.h"

@interface CIOverlayPresenter ()
@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, strong) UIView *pillView;
@property (nonatomic, strong) UILabel *captionLabel;
@property (nonatomic, strong) UILabel *sourceLabel;
@property (nonatomic, copy) NSString *lastText;
@end

@implementation CIOverlayPresenter

+ (instancetype)sharedPresenter {
    static CIOverlayPresenter *presenter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ presenter = [CIOverlayPresenter new]; });
    return presenter;
}

- (UIWindow *)activeWindow {
    UIWindow *fallback;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
            if (!window.hidden && window.alpha > 0 && window.windowLevel == UIWindowLevelNormal) fallback = window;
        }
    }
    return fallback;
}

- (void)installIfNeeded {
    UIWindow *window = [self activeWindow];
    if (!window) return;
    if (self.pillView.superview == window) return;
    [self.pillView removeFromSuperview];

    UIView *pill = self.pillView ?: [UIView new];
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    pill.userInteractionEnabled = NO;
    pill.backgroundColor = [UIColor colorWithWhite:0 alpha:0.92];
    pill.layer.cornerRadius = 19;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.layer.shadowColor = UIColor.blackColor.CGColor;
    pill.layer.shadowOpacity = 0.24;
    pill.layer.shadowRadius = 8;
    pill.layer.shadowOffset = CGSizeMake(0, 3);
    pill.alpha = 0;

    if (!self.captionLabel) {
        self.captionLabel = [UILabel new];
        self.captionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.captionLabel.textColor = UIColor.whiteColor;
        self.captionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        self.captionLabel.adjustsFontForContentSizeCategory = YES;
        self.captionLabel.numberOfLines = 2;
        self.captionLabel.textAlignment = NSTextAlignmentCenter;
        self.captionLabel.lineBreakMode = NSLineBreakByTruncatingTail;

        self.sourceLabel = [UILabel new];
        self.sourceLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.sourceLabel.textColor = [UIColor colorWithWhite:0.82 alpha:1];
        self.sourceLabel.font = [UIFont monospacedSystemFontOfSize:8 weight:UIFontWeightSemibold];
        self.sourceLabel.textAlignment = NSTextAlignmentCenter;
        [self.sourceLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                          forAxis:UILayoutConstraintAxisHorizontal];

        UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:@[
            self.captionLabel, self.sourceLabel
        ]];
        topRow.translatesAutoresizingMaskIntoConstraints = NO;
        topRow.axis = UILayoutConstraintAxisHorizontal;
        topRow.alignment = UIStackViewAlignmentCenter;
        topRow.spacing = 7;
        [pill addSubview:topRow];
        [NSLayoutConstraint activateConstraints:@[
            [topRow.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:14],
            [topRow.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-10],
            [topRow.topAnchor constraintEqualToAnchor:pill.topAnchor constant:7],
            [topRow.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-7],
            [self.sourceLabel.widthAnchor constraintGreaterThanOrEqualToConstant:18],
        ]];
    }
    self.pillView = pill;
    self.hostWindow = window;
    [window addSubview:pill];
    [NSLayoutConstraint activateConstraints:@[
        [pill.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
        [pill.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:4],
        [pill.widthAnchor constraintLessThanOrEqualToAnchor:window.widthAnchor constant:-28],
        [pill.widthAnchor constraintGreaterThanOrEqualToConstant:145],
        [pill.heightAnchor constraintGreaterThanOrEqualToConstant:38],
    ]];
}

- (void)presentText:(NSString *)text
             source:(CICaptionSource)source
    copyrightNotice:(NSString *)copyrightNotice
       writerCredit:(NSString *)writerCredit {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!CIPreferenceBool(CIEnabledKey, YES) ||
            !CIPreferenceBool(CIOverlayEnabledKey, YES) || text.length == 0) {
            [self hide];
            return;
        }
        [self installIfNeeded];
        if (!self.pillView.superview) return;
        [self.hostWindow bringSubviewToFront:self.pillView];
        BOOL changed = ![self.lastText isEqualToString:text];
        self.lastText = text;
        if (changed && self.pillView.alpha >= 1) {
            [UIView transitionWithView:self.captionLabel duration:0.12
                               options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionBeginFromCurrentState
                            animations:^{ self.captionLabel.text = text; } completion:nil];
        } else {
            self.captionLabel.text = text;
        }
        BOOL LRCLIBSource = source == CICaptionSourceLRCLIBSynced ||
            source == CICaptionSourceLRCLIBAligned || source == CICaptionSourceLRCLIBEstimated;
        BOOL showBadge = LRCLIBSource || CIPreferenceBool(CIShowSourceBadgeKey, YES);
        self.sourceLabel.hidden = !showBadge;
        self.sourceLabel.text = showBadge ? CICaptionSourceLabel(source) : @"";
        self.pillView.userInteractionEnabled = NO;
        self.pillView.accessibilityLabel = text;
        self.pillView.accessibilityHint = nil;
        if (self.pillView.alpha < 1) {
            self.pillView.transform = CGAffineTransformMakeScale(0.96, 0.96);
            [UIView animateWithDuration:0.18 animations:^{
                self.pillView.alpha = 1;
                self.pillView.transform = CGAffineTransformIdentity;
            }];
        }
    });
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.lastText = @"";
        self.pillView.userInteractionEnabled = NO;
        if (!self.pillView || self.pillView.alpha <= 0) return;
        [UIView animateWithDuration:0.16 animations:^{ self.pillView.alpha = 0; }];
    });
}

@end
