#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Adds a Caption Island row to the player's gear/settings sheet.
///
/// No-ops when YouTube's menu controller is missing, so a YouTube version that
/// renames it costs the row rather than the tweak.
FOUNDATION_EXPORT void CIInstallGearMenuItem(void);

FOUNDATION_EXPORT BOOL CIGearMenuItemEnabled(void);
FOUNDATION_EXPORT void CISetGearMenuItemEnabled(BOOL enabled);

NS_ASSUME_NONNULL_END
