#import "CIVideoOverrides.h"
#import "CITextUtilities.h"
#import <float.h>
#import <math.h>

static NSString *const CIVideoOverridesDefaultsKey =
    @"CaptionIsland.VideoOverrides.v1";
static NSString *const CIVideoOverrideTitleKey = @"searchTitle";
static NSString *const CIVideoOverrideArtistKey = @"searchArtist";
static NSString *const CIVideoOverrideAdvanceKey = @"captionAdvance";
static NSString *const CIVideoOverrideLanguagesKey =
    @"captionLanguagePriorities";
static NSString *const CIVideoOverrideOriginalTitleKey = @"originalTitle";
static NSString *const CIVideoOverrideUpdatedAtKey = @"updatedAt";
static const NSUInteger CIVideoOverrideMaximumEntries = 500;
static const NSUInteger CIVideoOverrideMaximumVideoIDLength = 128;
static const NSUInteger CIVideoOverrideMaximumTextLength = 256;
static const NSTimeInterval CIVideoOverrideMaximumAdvance = 30.0;

@interface CIVideoOverride ()
@property (nonatomic, copy, readwrite) NSString *searchTitle;
@property (nonatomic, copy, readwrite) NSString *searchArtist;
@property (nonatomic, copy, readwrite)
    NSArray<NSString *> *captionLanguagePriorities;
@property (nonatomic, readwrite) NSTimeInterval captionAdvanceSeconds;
@property (nonatomic, copy, readwrite) NSString *originalTitle;
@property (nonatomic, readwrite) NSTimeInterval updatedAt;
@end

@implementation CIVideoOverride

- (instancetype)init {
    self = [super init];
    if (self) {
        _searchTitle = @"";
        _searchArtist = @"";
        _captionLanguagePriorities = @[];
        _originalTitle = @"";
    }
    return self;
}

@end

static NSString *CIVideoOverrideCleanString(
    id _Nullable value,
    NSUInteger maximumLength
) {
    NSString *stringValue = [value isKindOfClass:NSString.class]
        ? (NSString *)value : @"";
    NSString *clean = CICleanCaptionText(stringValue);
    if (clean.length > maximumLength) {
        clean = [clean substringToIndex:maximumLength];
    }
    return clean;
}

static NSString *CIVideoOverrideCleanVideoID(
    NSString * _Nullable videoID
) {
    return CIVideoOverrideCleanString(
        videoID,
        CIVideoOverrideMaximumVideoIDLength
    );
}

static NSTimeInterval CIVideoOverrideClampedAdvance(
    NSTimeInterval value
) {
    if (!isfinite(value)) return 0;
    return MAX(
        -CIVideoOverrideMaximumAdvance,
        MIN(CIVideoOverrideMaximumAdvance, value)
    );
}

static NSArray<NSString *> *CIVideoOverrideCleanLanguages(
    id _Nullable value
) {
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *languages = [NSMutableArray array];
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
        [languages addObject:code];
        if (languages.count >= 24) break;
    }
    return languages.copy;
}

static NSDictionary<NSString *, id> *CIVideoOverrideDictionary(void) {
    id value = [NSUserDefaults.standardUserDefaults
        objectForKey:CIVideoOverridesDefaultsKey];
    return [value isKindOfClass:NSDictionary.class]
        ? (NSDictionary<NSString *, id> *)value : @{};
}

CIVideoOverride * _Nullable CIVideoOverrideForVideoID(
    NSString * _Nullable videoID
) {
    NSString *cleanVideoID = CIVideoOverrideCleanVideoID(videoID);
    if (cleanVideoID.length == 0) return nil;
    NSDictionary<NSString *, id> *stored;
    @synchronized (NSUserDefaults.standardUserDefaults) {
        id value =
            [CIVideoOverrideDictionary() objectForKey:cleanVideoID];
        stored = [value isKindOfClass:NSDictionary.class]
            ? [(NSDictionary *)value copy] : nil;
    }
    if (!stored) return nil;

    CIVideoOverride *result = [CIVideoOverride new];
    result.searchTitle = CIVideoOverrideCleanString(
        stored[CIVideoOverrideTitleKey],
        CIVideoOverrideMaximumTextLength
    );
    result.searchArtist = CIVideoOverrideCleanString(
        stored[CIVideoOverrideArtistKey],
        CIVideoOverrideMaximumTextLength
    );
    result.captionLanguagePriorities =
        CIVideoOverrideCleanLanguages(
            stored[CIVideoOverrideLanguagesKey]
        );
    result.originalTitle = CIVideoOverrideCleanString(
        stored[CIVideoOverrideOriginalTitleKey],
        CIVideoOverrideMaximumTextLength
    );
    result.captionAdvanceSeconds = CIVideoOverrideClampedAdvance(
        [[stored objectForKey:CIVideoOverrideAdvanceKey]
            respondsToSelector:@selector(doubleValue)]
            ? [[stored objectForKey:CIVideoOverrideAdvanceKey]
                doubleValue] : 0
    );
    result.updatedAt = [[stored objectForKey:CIVideoOverrideUpdatedAtKey]
        respondsToSelector:@selector(doubleValue)]
        ? [[stored objectForKey:CIVideoOverrideUpdatedAtKey]
            doubleValue] : 0;
    if (!isfinite(result.updatedAt) || result.updatedAt < 0) {
        result.updatedAt = 0;
    }
    return result;
}

void CISaveVideoOverride(
    NSString * _Nullable videoID,
    NSString * _Nullable searchTitle,
    NSString * _Nullable searchArtist,
    NSTimeInterval captionAdvanceSeconds,
    NSString * _Nullable originalTitle
) {
    NSString *cleanVideoID = CIVideoOverrideCleanVideoID(videoID);
    if (cleanVideoID.length == 0) return;
    NSString *cleanTitle = CIVideoOverrideCleanString(
        searchTitle,
        CIVideoOverrideMaximumTextLength
    );
    NSString *cleanArtist = CIVideoOverrideCleanString(
        searchArtist,
        CIVideoOverrideMaximumTextLength
    );
    NSString *cleanOriginalTitle = CIVideoOverrideCleanString(
        originalTitle,
        CIVideoOverrideMaximumTextLength
    );
    NSTimeInterval cleanAdvance =
        CIVideoOverrideClampedAdvance(captionAdvanceSeconds);

    @synchronized (NSUserDefaults.standardUserDefaults) {
        NSMutableDictionary<NSString *, id> *all =
            [CIVideoOverrideDictionary() mutableCopy];
        NSDictionary<NSString *, id> *existing =
            [[all objectForKey:cleanVideoID]
                isKindOfClass:NSDictionary.class]
                ? [all objectForKey:cleanVideoID] : @{};
        NSArray<NSString *> *languages =
            CIVideoOverrideCleanLanguages(
                existing[CIVideoOverrideLanguagesKey]
            );
        if (cleanTitle.length == 0 &&
            cleanArtist.length == 0 &&
            fabs(cleanAdvance) < 0.001 &&
            languages.count == 0) {
            [all removeObjectForKey:cleanVideoID];
        } else {
            if (![all objectForKey:cleanVideoID] &&
                all.count >= CIVideoOverrideMaximumEntries) {
                __block NSString *oldestVideoID;
                __block NSTimeInterval oldestUpdate = DBL_MAX;
                [all enumerateKeysAndObjectsUsingBlock:^(
                    NSString *candidateVideoID,
                    id candidateValue,
                    __unused BOOL *stop
                ) {
                    NSDictionary<NSString *, id> *candidate =
                        [candidateValue isKindOfClass:NSDictionary.class]
                            ? (NSDictionary<NSString *, id> *)candidateValue
                            : @{};
                    NSTimeInterval update =
                        [[candidate objectForKey:
                            CIVideoOverrideUpdatedAtKey]
                            respondsToSelector:@selector(doubleValue)]
                            ? [[candidate objectForKey:
                                CIVideoOverrideUpdatedAtKey]
                                doubleValue] : 0;
                    if (!isfinite(update) || update < 0) update = 0;
                    if (update < oldestUpdate) {
                        oldestUpdate = update;
                        oldestVideoID = candidateVideoID;
                    }
                }];
                if (oldestVideoID.length > 0) {
                    [all removeObjectForKey:oldestVideoID];
                }
            }
            NSMutableDictionary<NSString *, id> *entry = [@{
                CIVideoOverrideTitleKey: cleanTitle,
                CIVideoOverrideArtistKey: cleanArtist,
                CIVideoOverrideAdvanceKey: @(cleanAdvance),
                CIVideoOverrideOriginalTitleKey: cleanOriginalTitle,
                CIVideoOverrideUpdatedAtKey:
                    @(NSDate.date.timeIntervalSince1970),
            } mutableCopy];
            if (languages.count > 0) {
                entry[CIVideoOverrideLanguagesKey] = languages;
            }
            [all setObject:entry.copy forKey:cleanVideoID];
        }
        [NSUserDefaults.standardUserDefaults
            setObject:all.copy
            forKey:CIVideoOverridesDefaultsKey];
    }
}

void CISaveVideoCaptionLanguagePriorities(
    NSString * _Nullable videoID,
    NSArray<NSString *> * _Nullable priorities,
    NSString * _Nullable originalTitle
) {
    NSString *cleanVideoID = CIVideoOverrideCleanVideoID(videoID);
    if (cleanVideoID.length == 0) return;
    NSArray<NSString *> *cleanLanguages =
        CIVideoOverrideCleanLanguages(priorities);
    NSString *cleanOriginalTitle = CIVideoOverrideCleanString(
        originalTitle,
        CIVideoOverrideMaximumTextLength
    );

    @synchronized (NSUserDefaults.standardUserDefaults) {
        NSMutableDictionary<NSString *, id> *all =
            [CIVideoOverrideDictionary() mutableCopy];
        NSDictionary<NSString *, id> *existing =
            [[all objectForKey:cleanVideoID]
                isKindOfClass:NSDictionary.class]
                ? [all objectForKey:cleanVideoID] : @{};
        NSString *title = CIVideoOverrideCleanString(
            existing[CIVideoOverrideTitleKey],
            CIVideoOverrideMaximumTextLength
        );
        NSString *artist = CIVideoOverrideCleanString(
            existing[CIVideoOverrideArtistKey],
            CIVideoOverrideMaximumTextLength
        );
        NSTimeInterval advance = CIVideoOverrideClampedAdvance(
            [existing[CIVideoOverrideAdvanceKey]
                respondsToSelector:@selector(doubleValue)]
                ? [existing[CIVideoOverrideAdvanceKey] doubleValue]
                : 0
        );
        NSString *storedOriginalTitle = CIVideoOverrideCleanString(
            existing[CIVideoOverrideOriginalTitleKey],
            CIVideoOverrideMaximumTextLength
        );
        if (cleanOriginalTitle.length == 0) {
            cleanOriginalTitle = storedOriginalTitle;
        }

        if (title.length == 0 && artist.length == 0 &&
            fabs(advance) < 0.001 && cleanLanguages.count == 0) {
            [all removeObjectForKey:cleanVideoID];
        } else {
            if (![all objectForKey:cleanVideoID] &&
                all.count >= CIVideoOverrideMaximumEntries) {
                __block NSString *oldestVideoID;
                __block NSTimeInterval oldestUpdate = DBL_MAX;
                [all enumerateKeysAndObjectsUsingBlock:^(
                    NSString *candidateVideoID,
                    id candidateValue,
                    __unused BOOL *stop
                ) {
                    NSDictionary<NSString *, id> *candidate =
                        [candidateValue isKindOfClass:NSDictionary.class]
                            ? candidateValue : @{};
                    NSTimeInterval update =
                        [candidate[CIVideoOverrideUpdatedAtKey]
                            respondsToSelector:@selector(doubleValue)]
                            ? [candidate[CIVideoOverrideUpdatedAtKey]
                                doubleValue] : 0;
                    if (!isfinite(update) || update < 0) update = 0;
                    if (update < oldestUpdate) {
                        oldestUpdate = update;
                        oldestVideoID = candidateVideoID;
                    }
                }];
                if (oldestVideoID.length > 0) {
                    [all removeObjectForKey:oldestVideoID];
                }
            }
            NSMutableDictionary<NSString *, id> *entry = [@{
                CIVideoOverrideTitleKey: title,
                CIVideoOverrideArtistKey: artist,
                CIVideoOverrideAdvanceKey: @(advance),
                CIVideoOverrideOriginalTitleKey: cleanOriginalTitle,
                CIVideoOverrideUpdatedAtKey:
                    @(NSDate.date.timeIntervalSince1970),
            } mutableCopy];
            if (cleanLanguages.count > 0) {
                entry[CIVideoOverrideLanguagesKey] = cleanLanguages;
            }
            [all setObject:entry.copy forKey:cleanVideoID];
        }
        [NSUserDefaults.standardUserDefaults
            setObject:all.copy
            forKey:CIVideoOverridesDefaultsKey];
    }
}

void CIClearVideoOverride(NSString * _Nullable videoID) {
    NSString *cleanVideoID = CIVideoOverrideCleanVideoID(videoID);
    if (cleanVideoID.length == 0) return;
    @synchronized (NSUserDefaults.standardUserDefaults) {
        NSMutableDictionary<NSString *, id> *all =
            [CIVideoOverrideDictionary() mutableCopy];
        [all removeObjectForKey:cleanVideoID];
        [NSUserDefaults.standardUserDefaults
            setObject:all.copy
            forKey:CIVideoOverridesDefaultsKey];
    }
}

NSUInteger CIVideoOverrideCount(void) {
    @synchronized (NSUserDefaults.standardUserDefaults) {
        return CIVideoOverrideDictionary().count;
    }
}
