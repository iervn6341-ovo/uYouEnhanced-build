#import <Foundation/Foundation.h>
#import "CIModels.h"

NS_ASSUME_NONNULL_BEGIN

@interface CILRCLIBResult : NSObject
@property (nonatomic) NSInteger recordID;
@property (nonatomic, copy) NSString *trackName;
@property (nonatomic, copy) NSString *artistName;
@property (nonatomic, copy) NSString *albumName;
@property (nonatomic) NSTimeInterval trackDuration;
@property (nonatomic) NSTimeInterval durationDifference;
@property (nonatomic, copy) NSArray<CICaptionCue *> *syncedCues;
@property (nonatomic, copy) NSString *plainLyrics;
@end

typedef void (^CILRCLIBCompletion)(CILRCLIBResult * _Nullable result,
                                   NSError * _Nullable error);

@interface CILRCLIBProvider : NSObject
- (void)fetchLyricsForTitle:(NSString *)title
                     artist:(NSString *)artist
                   duration:(NSTimeInterval)duration
                 completion:(CILRCLIBCompletion)completion;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
