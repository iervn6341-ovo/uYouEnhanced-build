// A Caption Island row in the player's gear/settings sheet.
//
// The sheet is built by YTMenuController, which has no header in this repo and is
// hooked by name. Its one interesting method turns a list of proto row models into
// a list of concrete row objects:
//
//   -actionsForRenderers:fromView:entry:shouldLogItems:firstResponder:
//
// The two are index-parallel, and the shipping tweaks here (YouSpeed,
// YTClassicVideoQuality) rely on that parity to retarget an existing row's handler.
// Appending to the returned array instead of touching `renderers` keeps that parity
// intact: a row we add has no proto model, so inserting one upstream would need a
// fully-formed YTIMenuItemSupportedRenderers and would break the pairing for every
// other row.
#import <UIKit/UIKit.h>

#import "../YouTubeHeader/QTMIcon.h"
#import "../YouTubeHeader/YTActionSheetAction.h"
#import "../YouTubeHeader/YTIElementRenderer.h"
#import "../YouTubeHeader/YTIMenuItemSupportedRenderers.h"
#import "../YouTubeHeader/YTIMenuItemSupportedRenderersElementRendererCompatibilityOptionsExtension.h"
#import "../YouTubeHeader/YTIMenuNavigationItemRenderer.h"

#import "CIConstants.h"
#import "CILogStore.h"
#import "CIGearMenuItem.h"
#import "CIPlayerControlPanel.h"

static NSString *const CIGearMenuItemEnabledKey =
    @"CaptionIsland.GearMenuItemEnabled";

// The proto field the modern element-backed rows carry their identity in.
static const int32_t CIMenuItemIdentifierFieldNumber = 396644439;

BOOL CIGearMenuItemEnabled(void) {
    return [NSUserDefaults.standardUserDefaults
        boolForKey:CIGearMenuItemEnabledKey];
}

void CISetGearMenuItemEnabled(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled
                                          forKey:CIGearMenuItemEnabledKey];
}

/// One row's identifier, from whichever of the two shapes carries it.
///
/// Modern rows are ELM element-backed and hide the identifier in a proto extension;
/// legacy rows expose it directly on the navigation renderer. Reading both is what
/// keeps this working across the two UIs rather than only the one on the test device.
static NSString *CIMenuItemIdentifier(YTIMenuItemSupportedRenderers *renderer) {
    id options = renderer.elementRenderer.compatibilityOptions;
    if ([options respondsToSelector:@selector(messageForFieldNumber:)]) {
        YTIMenuItemSupportedRenderersElementRendererCompatibilityOptionsExtension *
            extension = [options
                messageForFieldNumber:CIMenuItemIdentifierFieldNumber];
        NSString *identifier = extension.menuItemIdentifier;
        if (identifier.length > 0) return identifier;
    }
    if ([renderer respondsToSelector:@selector(menuNavigationItemRenderer)]) {
        id navigation = renderer.menuNavigationItemRenderer;
        if ([navigation respondsToSelector:@selector(menuItemIdentifier)]) {
            NSString *identifier = [navigation menuItemIdentifier];
            if (identifier.length > 0) return identifier;
        }
    }
    return @"";
}

/// Whether this sheet is the player's gear sheet rather than one of the many other
/// YouTube menus that go through the same method.
///
/// Identified by the rows only the player settings sheet carries. Without this the
/// row would also appear on video long-press menus, channel menus and comment menus.
static BOOL CIRenderersArePlayerSettings(
    NSArray<YTIMenuItemSupportedRenderers *> *renderers
) {
    for (YTIMenuItemSupportedRenderers *renderer in renderers) {
        NSString *identifier = CIMenuItemIdentifier(renderer);
        if ([identifier isEqualToString:@"menu_item_video_quality"] ||
            [identifier isEqualToString:@"menu_item_playback_speed"] ||
            [identifier isEqualToString:@"menu_item_captions"] ||
            [identifier isEqualToString:@"menu_item_audio_track"]) {
            return YES;
        }
    }
    return NO;
}

static UIImage *CIGearRowIcon(void) {
    Class iconClass = NSClassFromString(@"QTMIcon");
    if ([iconClass respondsToSelector:@selector(imageWithName:color:)]) {
        UIImage *icon = [iconClass imageWithName:@"ic_closed_caption"
                                          color:nil];
        if (icon) return icon;
    }
    // YouTube's own asset names are not guaranteed across versions, so fall back
    // to a symbol rather than shipping a row with no icon.
    return [UIImage systemImageNamed:@"captions.bubble"];
}

%group CaptionIslandGearMenu

%hook YTMenuController

- (NSMutableArray *)actionsForRenderers:(NSMutableArray *)renderers
                               fromView:(UIView *)fromView
                                  entry:(id)entry
                         shouldLogItems:(BOOL)shouldLogItems
                          firstResponder:(id)firstResponder {
    NSMutableArray *actions = %orig;
    if (!CIGearMenuItemEnabled()) return actions;
    if (![actions isKindOfClass:NSMutableArray.class]) return actions;
    if (!CIRenderersArePlayerSettings(renderers)) return actions;

    Class actionClass = NSClassFromString(@"YTActionSheetAction");
    if (![actionClass respondsToSelector:
            @selector(actionWithTitle:iconImage:style:handler:)]) {
        return actions;
    }
    YTActionSheetAction *action = [actionClass
        actionWithTitle:CILocalized(@"PANEL_TITLE", @"Caption Island")
              iconImage:CIGearRowIcon()
                  style:0
                handler:nil];
    if (!action) return actions;
    // Assigned rather than passed to the factory: the property is typed `id`, and
    // the two tweaks in this repo that drive these rows both store a zero-argument
    // block, which is the form YouTube actually invokes. The factory's declared
    // one-argument signature does not match that.
    action.handler = ^{
        CIPresentPlayerControlPanel(nil);
    };
    action.shouldDismissOnAction = YES;
    [actions addObject:action];
    return actions;
}

%end

%end

void CIInstallGearMenuItem(void) {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        CIGearMenuItemEnabledKey: @YES,
    }];
    if (!NSClassFromString(@"YTMenuController")) {
        [CILogStore.sharedStore recordLevel:CILogLevelWarning
            category:@"PlayerMenu"
            message:@"YTMenuController is absent in this YouTube build; the gear-menu row is unavailable."];
        return;
    }
    %init(CaptionIslandGearMenu);
}
