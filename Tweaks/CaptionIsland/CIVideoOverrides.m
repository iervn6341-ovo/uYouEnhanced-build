#import "CIVideoOverrides.h"
#import "CITextUtilities.h"
#import <float.h>
#import <math.h>

static NSString *const CIVideoOverridesDefaultsKey =
    @"CaptionIsland.VideoOverrides.v1";
static NSString *const CIVideoOverrideTitleKey = @"searchTitle";
static NSString *const CIVideoOverrideArtistKey = @"searchArtist";
static NSString *const CIVideoOverrideAdvanceKey = @"captionAdvance";
static NSString *const CIVideoOverrideOriginalTitleKey = @"originalTitle";
static NSString *const CIVideoOverrideUpdatedAtKey = @"updatedAt";
static const NSUInteger CIVideoOverrideMaximumEntries = 500;
static const NSUInteger CIVideoOverrideMaximumVideoIDLength = 128;
static const NSUInteger CIVideoOverrideMaximumTextLength = 256;
static const NSTimeInterval CIVideoOverrideMaximumAdvance = 30.0;

@interface CIVideoOverride ()
@property (nonatomic, copy, readwrite) NSString *searchTitle;
@property (nonatomic, copy, readwrite) NSString *searchArtist;
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
        if (cleanTitle.length == 0 &&
            cleanArtist.length == 0 &&
            fabs(cleanAdvance) < 0.001) {
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
            [all setObject:@{
                CIVideoOverrideTitleKey: cleanTitle,
                CIVideoOverrideArtistKey: cleanArtist,
                CIVideoOverrideAdvanceKey: @(cleanAdvance),
                CIVideoOverrideOriginalTitleKey: cleanOriginalTitle,
                CIVideoOverrideUpdatedAtKey:
                    @(NSDate.date.timeIntervalSince1970),
            } forKey:cleanVideoID];
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
