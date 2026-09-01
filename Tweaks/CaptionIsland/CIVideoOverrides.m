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
static NSString *const CIVideoOverrideCaptionSourceKey =
    @"captionSourcePreference";
static NSString *const CIVideoOverrideOriginalTitleKey = @"originalTitle";
static NSString *const CIVideoOverrideLyricsSuppressedKey =
    @"lyricsSuppressed";
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
@property (nonatomic, readwrite)
    CIVideoCaptionSourcePreference captionSourcePreference;
@property (nonatomic, readwrite) NSTimeInterval captionAdvanceSeconds;
@property (nonatomic, readwrite) BOOL lyricsSuppressed;
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

static CIVideoCaptionSourcePreference CIVideoOverrideCleanCaptionSource(
    id _Nullable value
) {
    NSInteger rawValue = [value respondsToSelector:@selector(integerValue)]
        ? [value integerValue] : CIVideoCaptionSourcePreferenceInherit;
    switch (rawValue) {
        case CIVideoCaptionSourcePreferenceManualCC:
        case CIVideoCaptionSourcePreferenceASR:
            return (CIVideoCaptionSourcePreference)rawValue;
        default:
            return CIVideoCaptionSourcePreferenceInherit;
    }
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
    result.captionSourcePreference = CIVideoOverrideCleanCaptionSource(
        stored[CIVideoOverrideCaptionSourceKey]
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
    result.lyricsSuppressed =
        [[stored objectForKey:CIVideoOverrideLyricsSuppressedKey]
            respondsToSelector:@selector(boolValue)] &&
        [[stored objectForKey:CIVideoOverrideLyricsSuppressedKey] boolValue];
    result.updatedAt = [[stored objectForKey:CIVideoOverrideUpdatedAtKey]
        respondsToSelector:@selector(doubleValue)]
        ? [[stored objectForKey:CIVideoOverrideUpdatedAtKey]
            doubleValue] : 0;
    if (!isfinite(result.updatedAt) || result.updatedAt < 0) {
        result.updatedAt = 0;
    }
    return result;
}

/// The one place a stored entry is created, merged, pruned or deleted.
///
/// Every writer used to repeat the read-merge-evict-write dance, which is how the
/// language-priority writer ended up silently dropping a field the title writer
/// kept. `mutate` receives the existing entry's decoded fields and returns the
/// ones to store; an entry that ends up carrying no user decision at all is
/// removed rather than written as an empty record.
static void CIUpdateVideoOverride(
    NSString * _Nullable videoID,
    NSString * _Nullable originalTitle,
    void (^mutate)(NSMutableDictionary<NSString *, id> *entry)
) {
    NSString *cleanVideoID = CIVideoOverrideCleanVideoID(videoID);
    if (cleanVideoID.length == 0) return;
    NSString *cleanOriginalTitle = CIVideoOverrideCleanString(
        originalTitle,
        CIVideoOverrideMaximumTextLength
    );

    @synchronized (NSUserDefaults.standardUserDefaults) {
        NSMutableDictionary<NSString *, id> *all =
            [CIVideoOverrideDictionary() mutableCopy];
        BOOL isNewEntry = ![all objectForKey:cleanVideoID];
        NSDictionary<NSString *, id> *existing =
            [[all objectForKey:cleanVideoID] isKindOfClass:NSDictionary.class]
                ? [all objectForKey:cleanVideoID] : @{};

        // Decode every field first, so a writer that only cares about one of
        // them cannot erase the others.
        NSMutableDictionary<NSString *, id> *entry = [NSMutableDictionary
            dictionaryWithCapacity:7];
        entry[CIVideoOverrideTitleKey] = CIVideoOverrideCleanString(
            existing[CIVideoOverrideTitleKey],
            CIVideoOverrideMaximumTextLength
        );
        entry[CIVideoOverrideArtistKey] = CIVideoOverrideCleanString(
            existing[CIVideoOverrideArtistKey],
            CIVideoOverrideMaximumTextLength
        );
        entry[CIVideoOverrideAdvanceKey] = @(CIVideoOverrideClampedAdvance(
            [existing[CIVideoOverrideAdvanceKey]
                respondsToSelector:@selector(doubleValue)]
                ? [existing[CIVideoOverrideAdvanceKey] doubleValue] : 0
        ));
        entry[CIVideoOverrideLanguagesKey] = CIVideoOverrideCleanLanguages(
            existing[CIVideoOverrideLanguagesKey]
        );
        entry[CIVideoOverrideCaptionSourceKey] = @(
            CIVideoOverrideCleanCaptionSource(
                existing[CIVideoOverrideCaptionSourceKey]
            )
        );
        entry[CIVideoOverrideLyricsSuppressedKey] = @(
            [existing[CIVideoOverrideLyricsSuppressedKey]
                respondsToSelector:@selector(boolValue)] &&
            [existing[CIVideoOverrideLyricsSuppressedKey] boolValue]
        );
        NSString *storedOriginalTitle = CIVideoOverrideCleanString(
            existing[CIVideoOverrideOriginalTitleKey],
            CIVideoOverrideMaximumTextLength
        );
        entry[CIVideoOverrideOriginalTitleKey] =
            cleanOriginalTitle.length > 0
                ? cleanOriginalTitle : storedOriginalTitle;

        mutate(entry);

        NSString *title = entry[CIVideoOverrideTitleKey];
        NSString *artist = entry[CIVideoOverrideArtistKey];
        NSArray *languages = entry[CIVideoOverrideLanguagesKey];
        CIVideoCaptionSourcePreference captionSource =
            CIVideoOverrideCleanCaptionSource(
                entry[CIVideoOverrideCaptionSourceKey]
            );
        double advance = [entry[CIVideoOverrideAdvanceKey] doubleValue];
        BOOL suppressed =
            [entry[CIVideoOverrideLyricsSuppressedKey] boolValue];
        if (title.length == 0 && artist.length == 0 &&
            fabs(advance) < 0.001 && languages.count == 0 &&
            captionSource == CIVideoCaptionSourcePreferenceInherit &&
            !suppressed) {
            [all removeObjectForKey:cleanVideoID];
            [NSUserDefaults.standardUserDefaults
                setObject:all.copy forKey:CIVideoOverridesDefaultsKey];
            return;
        }

        if (isNewEntry && all.count >= CIVideoOverrideMaximumEntries) {
            __block NSString *oldestVideoID;
            __block NSTimeInterval oldestUpdate = DBL_MAX;
            [all enumerateKeysAndObjectsUsingBlock:^(
                NSString *candidateVideoID,
                id candidateValue,
                __unused BOOL *stop
            ) {
                NSDictionary<NSString *, id> *candidate =
                    [candidateValue isKindOfClass:NSDictionary.class]
                        ? (NSDictionary<NSString *, id> *)candidateValue : @{};
                NSTimeInterval update =
                    [candidate[CIVideoOverrideUpdatedAtKey]
                        respondsToSelector:@selector(doubleValue)]
                        ? [candidate[CIVideoOverrideUpdatedAtKey] doubleValue]
                        : 0;
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

        // An empty language list is omitted rather than stored, matching what
        // earlier builds wrote so their entries stay byte-comparable.
        if (languages.count == 0) {
            [entry removeObjectForKey:CIVideoOverrideLanguagesKey];
        }
        if (captionSource == CIVideoCaptionSourcePreferenceInherit) {
            [entry removeObjectForKey:CIVideoOverrideCaptionSourceKey];
        }
        if (!suppressed) {
            [entry removeObjectForKey:CIVideoOverrideLyricsSuppressedKey];
        }
        entry[CIVideoOverrideUpdatedAtKey] =
            @(NSDate.date.timeIntervalSince1970);
        [all setObject:entry.copy forKey:cleanVideoID];
        [NSUserDefaults.standardUserDefaults
            setObject:all.copy forKey:CIVideoOverridesDefaultsKey];
    }
}

void CISaveVideoOverride(
    NSString * _Nullable videoID,
    NSString * _Nullable searchTitle,
    NSString * _Nullable searchArtist,
    NSTimeInterval captionAdvanceSeconds,
    NSString * _Nullable originalTitle
) {
    NSString *cleanTitle = CIVideoOverrideCleanString(
        searchTitle, CIVideoOverrideMaximumTextLength);
    NSString *cleanArtist = CIVideoOverrideCleanString(
        searchArtist, CIVideoOverrideMaximumTextLength);
    NSTimeInterval cleanAdvance =
        CIVideoOverrideClampedAdvance(captionAdvanceSeconds);
    CIUpdateVideoOverride(videoID, originalTitle,
        ^(NSMutableDictionary<NSString *, id> *entry) {
        entry[CIVideoOverrideTitleKey] = cleanTitle;
        entry[CIVideoOverrideArtistKey] = cleanArtist;
        entry[CIVideoOverrideAdvanceKey] = @(cleanAdvance);
    });
}

void CISaveVideoCaptionLanguagePriorities(
    NSString * _Nullable videoID,
    NSArray<NSString *> * _Nullable priorities,
    NSString * _Nullable originalTitle
) {
    NSArray<NSString *> *cleanLanguages =
        CIVideoOverrideCleanLanguages(priorities);
    CIUpdateVideoOverride(videoID, originalTitle,
        ^(NSMutableDictionary<NSString *, id> *entry) {
        entry[CIVideoOverrideLanguagesKey] = cleanLanguages;
        if (cleanLanguages.count == 0) {
            entry[CIVideoOverrideCaptionSourceKey] = @(
                CIVideoCaptionSourcePreferenceInherit
            );
        }
    });
}

void CISaveVideoCaptionSelection(
    NSString * _Nullable videoID,
    NSArray<NSString *> * _Nullable priorities,
    CIVideoCaptionSourcePreference sourcePreference,
    NSString * _Nullable originalTitle
) {
    NSArray<NSString *> *cleanLanguages =
        CIVideoOverrideCleanLanguages(priorities);
    CIVideoCaptionSourcePreference cleanSource =
        CIVideoOverrideCleanCaptionSource(@(sourcePreference));
    // A source without a language cannot identify a track. Treat malformed
    // callers as an explicit request to inherit instead of storing a state the
    // player can never fulfil.
    if (cleanLanguages.count == 0) {
        cleanSource = CIVideoCaptionSourcePreferenceInherit;
    }
    CIUpdateVideoOverride(videoID, originalTitle,
        ^(NSMutableDictionary<NSString *, id> *entry) {
        entry[CIVideoOverrideLanguagesKey] = cleanLanguages;
        entry[CIVideoOverrideCaptionSourceKey] = @(cleanSource);
    });
}

void CISaveVideoLyricsSuppressed(
    NSString * _Nullable videoID,
    BOOL suppressed,
    NSString * _Nullable originalTitle
) {
    CIUpdateVideoOverride(videoID, originalTitle,
        ^(NSMutableDictionary<NSString *, id> *entry) {
        entry[CIVideoOverrideLyricsSuppressedKey] = @(suppressed);
    });
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
