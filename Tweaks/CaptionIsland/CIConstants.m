#import "CIConstants.h"

NSString *const CIEnabledKey = @"CaptionIsland.Enabled";
NSString *const CIOverlayEnabledKey = @"CaptionIsland.OverlayEnabled";
NSString *const CIExternalLyricsEnabledKey = @"CaptionIsland.ExternalLyricsEnabled";
NSString *const CIShowSourceBadgeKey = @"CaptionIsland.ShowSourceBadge";
NSString *const CIPreferredLanguageKey = @"CaptionIsland.PreferredLanguage";
NSString *const CILyricFindTerritoryKey = @"CaptionIsland.LyricFindTerritory";
NSString *const CIDebugLoggingKey = @"CaptionIsland.DebugLogging";

BOOL CIPreferenceBool(NSString *key, BOOL defaultValue) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:key] ? [defaults boolForKey:key] : defaultValue;
}

NSString *CIPreferredLanguage(void) {
    NSString *value = [NSUserDefaults.standardUserDefaults stringForKey:CIPreferredLanguageKey];
    return value.length > 0 ? value : @"zh-Hant";
}

NSBundle *CIBundle(void) {
    static NSBundle *bundle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = [NSBundle.mainBundle pathForResource:@"CaptionIsland" ofType:@"bundle"];
        if (path.length > 0) bundle = [NSBundle bundleWithPath:path];
    });
    return bundle;
}

NSString *CILocalized(NSString *key, NSString *fallback) {
    NSBundle *bundle = CIBundle();
    return bundle ? [bundle localizedStringForKey:key value:fallback table:nil] : fallback;
}
