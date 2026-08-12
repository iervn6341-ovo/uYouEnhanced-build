// The in-player Caption Island button.
//
// Registration goes through YTVideoOverlay rather than hooking the overlay
// directly: that framework already owns placement (anchored off the fullscreen
// button and walking left), visibility, the fullscreen superview swap, and the
// user-facing Enabled/Position/Order settings rows. Hooking the player bar here
// would mean re-deriving all of it and fighting the six visibility hooks it
// installs. Our only contributions are an image and a tap handler.
#import <UIKit/UIKit.h>

#import "../YTVideoOverlay/Header.h"
#import "../YTVideoOverlay/Init.x"

#import "CIConstants.h"
#import "CIPlayerButton.h"
#import "CIPlayerControlPanel.h"

// Must differ from "CaptionIsland". YTVideoOverlay titles its settings rows with
// _LOC(TweakBundle(key), @"ENABLED"), resolving that bundle exactly the way
// CIConstants does, so reusing the tweak's own key would label the button switch
// with CaptionIsland.bundle's existing ENABLED string — "Enable Live Activity" —
// and find no POSITION string at all.
static NSString *const CIButtonTweakKey = @"CaptionIslandLyrics";
// Passed to YTVideoOverlay as ToggleKey, which makes it read this key instead of
// its own "YTVideoOverlay-<name>-Enabled" and suppresses the duplicate switch it
// would otherwise draw in its own settings section.
static NSString *const CIPlayerButtonEnabledKey =
    @"CaptionIsland.PlayerButtonEnabled";
// YTVideoOverlay's own position key. Not mirrored into a Caption Island key: the
// framework reads this one directly during layout, so a copy could disagree.
static NSString *CIPlayerButtonPositionKey(void) {
    return [NSString stringWithFormat:@"YTVideoOverlay-%@-Position",
        CIButtonTweakKey];
}

BOOL CIPlayerButtonEnabled(void) {
    return [NSUserDefaults.standardUserDefaults
        boolForKey:CIPlayerButtonEnabledKey];
}

void CISetPlayerButtonEnabled(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled
                                          forKey:CIPlayerButtonEnabledKey];
}

CIPlayerButtonPosition CIPlayerButtonPosition_(void) {
    return [NSUserDefaults.standardUserDefaults
        integerForKey:CIPlayerButtonPositionKey()] ==
            CIPlayerButtonPositionTop
        ? CIPlayerButtonPositionTop : CIPlayerButtonPositionBottom;
}

void CISetPlayerButtonPosition(CIPlayerButtonPosition position) {
    [NSUserDefaults.standardUserDefaults setInteger:position
        forKey:CIPlayerButtonPositionKey()];
}

@interface YTMainAppControlsOverlayView (CaptionIslandButton)
- (void)didPressCaptionIsland:(id)arg;
@end

@interface YTInlinePlayerBarContainerView (CaptionIslandButton)
- (void)didPressCaptionIsland:(id)arg;
@end

/// The glyph, sized and coloured to match YouTube's own overlay controls.
///
/// An SF Symbol rather than bundled art: it removes a packaging failure mode
/// (art that silently does not reach the .bundle leaves an invisible button),
/// and it already matches the weight of the controls beside it. Rendered
/// non-template because YTVideoOverlay sets the image directly on the button
/// without configuring a tint.
static UIImage *CIButtonImage(void) {
    static UIImage *image;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration
                configurationWithPointSize:OVERLAY_BUTTON_SIZE
                                    weight:UIImageSymbolWeightRegular];
        UIImage *symbol = [UIImage systemImageNamed:@"captions.bubble"
                                  withConfiguration:configuration];
        if (!symbol) {
            symbol = [UIImage systemImageNamed:@"text.bubble"
                             withConfiguration:configuration];
        }
        image = [symbol imageWithTintColor:UIColor.whiteColor
                            renderingMode:UIImageRenderingModeAlwaysOriginal];
    });
    return image;
}

%group CaptionIslandButtonTop

%hook YTMainAppControlsOverlayView

- (UIImage *)buttonImage:(NSString *)tweakId {
    return [tweakId isEqualToString:CIButtonTweakKey]
        ? CIButtonImage() : %orig;
}

%new(v@:@)
- (void)didPressCaptionIsland:(id)arg {
    // The panel resolves its own presenter by walking the presented-controller
    // chain, so the overlay's own controller is not needed and nil is expected.
    CIPresentPlayerControlPanel(nil);
}

%end

%end

%group CaptionIslandButtonBottom

%hook YTInlinePlayerBarContainerView

- (UIImage *)buttonImage:(NSString *)tweakId {
    return [tweakId isEqualToString:CIButtonTweakKey]
        ? CIButtonImage() : %orig;
}

%new(v@:@)
- (void)didPressCaptionIsland:(id)arg {
    CIPresentPlayerControlPanel(nil);
}

%end

%end

void CIInstallPlayerButton(void) {
    // YTVideoOverlay defaults a newly registered tweak to disabled and to the
    // top-right slot. Seed both so the button appears beside the fullscreen
    // control without the user having to find the setting first;
    // registerDefaults never overwrites a value the user has already chosen.
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        CIPlayerButtonEnabledKey: @YES,
        CIPlayerButtonPositionKey(): @(CIPlayerButtonPositionBottom),
    }];
    initYTVideoOverlay(CIButtonTweakKey, @{
        AccessibilityLabelKey: CILocalized(@"PANEL_TITLE", @"Caption Island"),
        SelectorKey: @"didPressCaptionIsland:",
        // Our key, so the switch lives on the Caption Island settings screen and
        // YTVideoOverlay does not draw a second one of its own.
        ToggleKey: CIPlayerButtonEnabledKey,
    });
    if (NSClassFromString(@"YTMainAppControlsOverlayView")) {
        %init(CaptionIslandButtonTop);
    }
    if (NSClassFromString(@"YTInlinePlayerBarContainerView")) {
        %init(CaptionIslandButtonBottom);
    }
}
