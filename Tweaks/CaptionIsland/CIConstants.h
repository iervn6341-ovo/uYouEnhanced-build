#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CISourcePriorityMode) {
    CISourcePriorityLRCLIBFirst = 0,
    CISourcePriorityYouTubeFirst = 1,
};

typedef NS_ENUM(NSInteger, CIReturnHomeMode) {
    CIReturnHomeModeYouPiP = 0,
    CIReturnHomeModeCaptionIsland = 1,
};

FOUNDATION_EXPORT NSString *const CIEnabledKey;
FOUNDATION_EXPORT NSString *const CIExternalLyricsEnabledKey;
FOUNDATION_EXPORT NSString *const CISourcePriorityKey;
FOUNDATION_EXPORT NSString *const CIShowSourceBadgeKey;
FOUNDATION_EXPORT NSString *const CIPreferredLanguageKey;
FOUNDATION_EXPORT NSString *const CICaptionLanguagePrioritiesKey;
FOUNDATION_EXPORT NSString *const CIDebugLoggingKey;
FOUNDATION_EXPORT NSString *const CIDiscardedTitleKeywordsKey;
FOUNDATION_EXPORT NSString *const CIDisableForShortsKey;
FOUNDATION_EXPORT NSString *const CIMaximumVideoDurationMinutesKey;
FOUNDATION_EXPORT NSString *const CIReturnHomeModeKey;
FOUNDATION_EXPORT NSNotificationName const
    CIYouPiPAutomaticPiPSuppressedNotification;

FOUNDATION_EXPORT BOOL CIPreferenceBool(NSString *key, BOOL defaultValue);
FOUNDATION_EXPORT NSInteger CIPreferenceInteger(NSString *key, NSInteger defaultValue);
FOUNDATION_EXPORT CISourcePriorityMode CISourcePriority(void);
FOUNDATION_EXPORT CIReturnHomeMode CICurrentReturnHomeMode(void);
FOUNDATION_EXPORT NSInteger CIMaximumVideoDurationMinutes(void);
FOUNDATION_EXPORT NSString *CIPreferredLanguage(void);
FOUNDATION_EXPORT NSArray<NSString *> *
    CICaptionLanguagePriorities(void);
FOUNDATION_EXPORT void CISetCaptionLanguagePriorities(
    NSArray<NSString *> * _Nullable priorities
);
/// Phrases stripped from the end of a video title before it is searched.
///
/// Only anchored to the end, so a phrase can never delete a whole title. The
/// defaults are the unbracketed video-format suffixes that have no structural
/// marker to detect them by; everything else is left to the user, because which
/// re-upload notes a channel adds is not something a shipped list can predict.
FOUNDATION_EXPORT NSArray<NSString *> *CIDiscardedTitleKeywords(void);
FOUNDATION_EXPORT NSArray<NSString *> *CIDefaultDiscardedTitleKeywords(void);
FOUNDATION_EXPORT void CISetDiscardedTitleKeywords(
    NSArray<NSString *> * _Nullable keywords
);

FOUNDATION_EXPORT NSString *CILocalized(NSString *key, NSString *fallback);
FOUNDATION_EXPORT NSBundle * _Nullable CIBundle(void);
FOUNDATION_EXPORT void CIDebugLog(NSString *format, ...)
    NS_FORMAT_FUNCTION(1, 2);

#define CILog(format, ...) CIDebugLog((format), ##__VA_ARGS__)

NS_ASSUME_NONNULL_END
