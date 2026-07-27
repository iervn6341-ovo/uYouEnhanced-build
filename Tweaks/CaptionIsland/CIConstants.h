#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const CIEnabledKey;
FOUNDATION_EXPORT NSString *const CIOverlayEnabledKey;
FOUNDATION_EXPORT NSString *const CIExternalLyricsEnabledKey;
FOUNDATION_EXPORT NSString *const CIShowSourceBadgeKey;
FOUNDATION_EXPORT NSString *const CIPreferredLanguageKey;
FOUNDATION_EXPORT NSString *const CILyricFindTerritoryKey;
FOUNDATION_EXPORT NSString *const CIDebugLoggingKey;

FOUNDATION_EXPORT BOOL CIPreferenceBool(NSString *key, BOOL defaultValue);
FOUNDATION_EXPORT NSString *CIPreferredLanguage(void);
FOUNDATION_EXPORT NSString *CILocalized(NSString *key, NSString *fallback);
FOUNDATION_EXPORT NSBundle * _Nullable CIBundle(void);

#define CILog(format, ...) do { \
    if (CIPreferenceBool(CIDebugLoggingKey, NO)) { \
        NSLog((@"[CaptionIsland] " format), ##__VA_ARGS__); \
    } \
} while (0)

NS_ASSUME_NONNULL_END
