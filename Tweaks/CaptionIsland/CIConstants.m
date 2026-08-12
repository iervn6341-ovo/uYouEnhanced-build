#import "CIConstants.h"
#import "CILogStore.h"

NSString *const CIEnabledKey = @"CaptionIsland.Enabled";
NSString *const CIExternalLyricsEnabledKey = @"CaptionIsland.ExternalLyricsEnabled";
NSString *const CISourcePriorityKey = @"CaptionIsland.SourcePriority";
NSString *const CIShowSourceBadgeKey = @"CaptionIsland.ShowSourceBadge";
NSString *const CIPreferredLanguageKey = @"CaptionIsland.PreferredLanguage";
NSString *const CICaptionLanguagePrioritiesKey =
    @"CaptionIsland.CaptionLanguagePriorities.v1";
NSString *const CIDebugLoggingKey = @"CaptionIsland.DebugLogging";
NSString *const CIDisableForShortsKey = @"CaptionIsland.DisableForShorts";
NSString *const CIMaximumVideoDurationMinutesKey =
    @"CaptionIsland.MaximumVideoDurationMinutes";
NSString *const CIReturnHomeModeKey = @"CaptionIsland.ReturnHomeMode";
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

static NSArray<NSString *> *CINormalizedLanguagePriorities(
    id value
) {
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSCharacterSet *invalidCharacters = [[NSCharacterSet
        characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-"]
        invertedSet];
    for (id candidate in (NSArray *)value) {
        if (![candidate isKindOfClass:NSString.class]) continue;
        NSString *code = [[(NSString *)candidate
            stringByReplacingOccurrencesOfString:@"_" withString:@"-"]
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (code.length == 0 || code.length > 35 ||
            [code rangeOfCharacterFromSet:invalidCharacters].location !=
                NSNotFound ||
            [code hasPrefix:@"-"] || [code hasSuffix:@"-"] ||
            [code containsString:@"--"]) {
            continue;
        }
        NSString *identity = code.lowercaseString;
        if ([seen containsObject:identity]) continue;
        [seen addObject:identity];
        [result addObject:code];
        if (result.count >= 24) break;
    }
    return result.copy;
}

NSArray<NSString *> *CICaptionLanguagePriorities(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray<NSString *> *stored = CINormalizedLanguagePriorities(
        [defaults objectForKey:CICaptionLanguagePrioritiesKey]
    );
    if (stored.count > 0) return stored;

    NSMutableArray<NSString *> *migrated = [NSMutableArray array];
    NSString *legacy = [defaults stringForKey:CIPreferredLanguageKey];
    if (legacy.length > 0) [migrated addObject:legacy];
    [migrated addObjectsFromArray:@[@"zh-Hant", @"en", @"ja"]];
    NSArray<NSString *> *normalized =
        CINormalizedLanguagePriorities(migrated);
    return normalized.count > 0
        ? normalized
        : @[@"zh-Hant", @"en", @"ja"];
}

void CISetCaptionLanguagePriorities(
    NSArray<NSString *> * _Nullable priorities
) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray<NSString *> *normalized =
        CINormalizedLanguagePriorities(priorities);
    if (normalized.count == 0) {
        [defaults removeObjectForKey:CICaptionLanguagePrioritiesKey];
        [defaults removeObjectForKey:CIPreferredLanguageKey];
        return;
    }
    [defaults setObject:normalized
                 forKey:CICaptionLanguagePrioritiesKey];
    // Keep the old single-language key synchronized for older builds that
    // may still read it after a downgrade.
    [defaults setObject:normalized.firstObject
                 forKey:CIPreferredLanguageKey];
}

NSString *CIPreferredLanguage(void) {
    return CICaptionLanguagePriorities().firstObject ?: @"zh-Hant";
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

NSString *const CIDiscardedTitleKeywordsKey =
    @"CaptionIsland.DiscardedTitleKeywords";

// Only the phrases that genuinely cannot be detected structurally. The Chinese
// re-upload notes ("音频优化", "纯享版") used to be hardcoded here too and were
// removed on request: they are channel habits, not a property of video titles, so
// they belong in the user's own list.
NSArray<NSString *> *CIDefaultDiscardedTitleKeywords(void) {
    return @[
        @"Official Music Video",
        @"Official Lyric Video",
        @"Official Video",
        @"Music Video",
        @"Lyric Video",
        @"Official Audio",
        @"Official Visualizer",
    ];
}

NSArray<NSString *> *CIDiscardedTitleKeywords(void) {
    id stored = [NSUserDefaults.standardUserDefaults
        objectForKey:CIDiscardedTitleKeywordsKey];
    if (![stored isKindOfClass:NSArray.class]) {
        return CIDefaultDiscardedTitleKeywords();
    }
    NSMutableArray<NSString *> *keywords = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id candidate in (NSArray *)stored) {
        if (![candidate isKindOfClass:NSString.class]) continue;
        NSString *keyword = [(NSString *)candidate
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
        // A very short phrase would match the tail of ordinary titles, and a very
        // long one is a sentence rather than a suffix.
        if (keyword.length < 2 || keyword.length > 64) continue;
        NSString *identity = keyword.lowercaseString;
        if ([seen containsObject:identity]) continue;
        [seen addObject:identity];
        [keywords addObject:keyword];
        if (keywords.count >= 64) break;
    }
    // An empty stored list is a deliberate "strip nothing", not a missing value,
    // so it is honoured rather than replaced by the defaults.
    return keywords.copy;
}

void CISetDiscardedTitleKeywords(NSArray<NSString *> * _Nullable keywords) {
    if (!keywords) {
        [NSUserDefaults.standardUserDefaults
            removeObjectForKey:CIDiscardedTitleKeywordsKey];
        return;
    }
    [NSUserDefaults.standardUserDefaults
        setObject:keywords forKey:CIDiscardedTitleKeywordsKey];
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
