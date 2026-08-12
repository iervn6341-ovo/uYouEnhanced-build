#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CIPlayerButtonPosition) {
    /// With autoplay, captions and the overflow menu.
    CIPlayerButtonPositionTop = 0,
    /// Beside the fullscreen button, next to the copy-timestamp button.
    CIPlayerButtonPositionBottom = 1,
};

/// Registers the in-player button with YTVideoOverlay and installs the two overlay
/// hooks that supply its image and tap handler.
///
/// Safe to call when YTVideoOverlay is absent: registration is a message to a class
/// looked up by name, and each hook group is gated on its class existing.
FOUNDATION_EXPORT void CIInstallPlayerButton(void);

/// Whether the button is shown. Backed by a Caption Island preference rather than
/// YTVideoOverlay's own key, which is what lets the switch live on this tweak's
/// settings screen instead of under "Player buttons".
FOUNDATION_EXPORT BOOL CIPlayerButtonEnabled(void);
FOUNDATION_EXPORT void CISetPlayerButtonEnabled(BOOL enabled);

/// Which side of the player controls the button sits on.
///
/// This one is stored in YTVideoOverlay's key, because that framework performs the
/// placement and reads the key directly at layout time. Writing it here keeps both
/// settings screens showing the same value with no synchronisation of our own.
FOUNDATION_EXPORT CIPlayerButtonPosition CIPlayerButtonPosition_(void);
FOUNDATION_EXPORT void CISetPlayerButtonPosition(
    CIPlayerButtonPosition position
);

NS_ASSUME_NONNULL_END
