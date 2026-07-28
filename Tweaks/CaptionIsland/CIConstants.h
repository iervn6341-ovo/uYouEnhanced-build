#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const CIEnabledKey;
FOUNDATION_EXPORT NSString *const CIExternalLyricsEnabledKey;
FOUNDATION_EXPORT NSString *const CIShowSourceBadgeKey;
FOUNDATION_EXPORT NSString *const CIPreferredLanguageKey;
FOUNDATION_EXPORT NSString *const CIDebugLoggingKey;

FOUNDATION_EXPORT BOOL CIPreferenceBool(NSString *key, BOOL defaultValue);
FOUNDATION_EXPORT NSString *CIPreferredLanguage(void);
FOUNDATION_EXPORT NSString *CILocalized(NSString *key, NSString *fallback);
FOUNDATION_EXPORT NSBundle * _Nullable CIBundle(void);
FOUNDATION_EXPORT void CIDebugLog(NSString *format, ...)
    NS_FORMAT_FUNCTION(1, 2);

#define CILog(format, ...) CIDebugLog((format), ##__VA_ARGS__)

NS_ASSUME_NONNULL_END
