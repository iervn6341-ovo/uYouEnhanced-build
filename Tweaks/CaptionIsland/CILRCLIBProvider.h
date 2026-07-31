#import <Foundation/Foundation.h>
#import "CIModels.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const CILRCLIBBaseURLKey;
FOUNDATION_EXPORT NSString *CILRCLIBDefaultBaseURL(void);
FOUNDATION_EXPORT NSString *CILRCLIBBaseURL(void);
FOUNDATION_EXPORT NSString * _Nullable CINormalizedLRCLIBBaseURL(
    NSString * _Nullable value,
    NSError * _Nullable * _Nullable error
);
FOUNDATION_EXPORT NSURL *CILRCLIBSearchEndpointURL(void);
FOUNDATION_EXPORT NSURL *CILRCLIBGetEndpointURL(void);

@interface CILRCLIBResult : NSObject
@property (nonatomic) NSInteger recordID;
@property (nonatomic, copy) NSString *trackName;
@property (nonatomic, copy) NSString *artistName;
@property (nonatomic, copy) NSString *albumName;
@property (nonatomic) NSTimeInterval trackDuration;
@property (nonatomic) NSTimeInterval durationDifference;
@property (nonatomic, copy) NSArray<CICaptionCue *> *syncedCues;
@property (nonatomic, copy) NSString *plainLyrics;
@property (nonatomic) BOOL fromPersistentCache;
@end

typedef void (^CILRCLIBCompletion)(CILRCLIBResult * _Nullable result,
                                   NSError * _Nullable error);

@interface CILRCLIBProvider : NSObject
+ (void)clearPersistentCache;
- (void)fetchLyricsForTitle:(NSString *)title
                     artist:(NSString *)artist
                   duration:(NSTimeInterval)duration
                 completion:(CILRCLIBCompletion)completion;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
