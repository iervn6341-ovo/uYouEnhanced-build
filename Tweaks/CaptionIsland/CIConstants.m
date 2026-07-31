#import "CIConstants.h"
#import "CILogStore.h"

NSString *const CIEnabledKey = @"CaptionIsland.Enabled";
NSString *const CIExternalLyricsEnabledKey = @"CaptionIsland.ExternalLyricsEnabled";
NSString *const CISourcePriorityKey = @"CaptionIsland.SourcePriority";
NSString *const CIShowSourceBadgeKey = @"CaptionIsland.ShowSourceBadge";
NSString *const CIPreferredLanguageKey = @"CaptionIsland.PreferredLanguage";
NSString *const CIDebugLoggingKey = @"CaptionIsland.DebugLogging";
NSString *const CIDisableForShortsKey = @"CaptionIsland.DisableForShorts";
NSString *const CIMaximumVideoDurationMinutesKey =
    @"CaptionIsland.MaximumVideoDurationMinutes";
NSString *const CIReturnHomeModeKey = @"CaptionIsland.ReturnHomeMode";
NSString *const CIContinuedBackgroundProcessingEnabledKey =
    @"CaptionIsland.ContinuedBackgroundProcessingEnabled";
NSNotificationName const CIYouPiPAutomaticPiPSuppressedNotification =
    @"CaptionIsland.YouPiPAutomaticPiPSuppressed";

BOOL CIPreferenceBool(NSString *key, BOOL defaultValue) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:key] ? [defaults boolForKey:key] : defaultValue;
}

NSInteger CIPreferenceInteger(NSString *key, NSInteger defaultValue) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:key]
        ? [defaults integerForKey:key]
        : defaultValue;
}

CISourcePriorityMode CISourcePriority(void) {
    NSInteger value = CIPreferenceInteger(
        CISourcePriorityKey,
        CISourcePriorityLRCLIBFirst
    );
    switch (value) {
        case CISourcePriorityLRCLIBFirst:
        case CISourcePriorityYouTubeFirst:
            return (CISourcePriorityMode)value;
        default:
            return CISourcePriorityLRCLIBFirst;
    }
}

CIReturnHomeMode CICurrentReturnHomeMode(void) {
    NSInteger value = CIPreferenceInteger(
        CIReturnHomeModeKey,
        CIReturnHomeModeYouPiP
    );
    switch (value) {
        case CIReturnHomeModeYouPiP:
        case CIReturnHomeModeCaptionIsland:
            return (CIReturnHomeMode)value;
        default:
            return CIReturnHomeModeYouPiP;
    }
}

NSInteger CIMaximumVideoDurationMinutes(void) {
    NSInteger value =
        CIPreferenceInteger(CIMaximumVideoDurationMinutesKey, 5);
    if (value == 0) return 0;
    return value > 0 && value <= 180 ? value : 5;
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

void CIDebugLog(NSString *format, ...) {
    if (!CIPreferenceBool(CIDebugLoggingKey, NO) || format.length == 0) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    [CILogStore.sharedStore recordLevel:CILogLevelDebug
                               category:@"Pipeline"
                                message:message ?: @""];
}
