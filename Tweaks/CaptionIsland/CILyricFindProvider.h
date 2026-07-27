#import <Foundation/Foundation.h>
#import "CIModels.h"

NS_ASSUME_NONNULL_BEGIN

@interface CILyricsResult : NSObject
@property (nonatomic, copy) NSArray<CICaptionCue *> *syncedCues;
@property (nonatomic, copy) NSString *plainLyrics;
@property (nonatomic, copy) NSString *copyrightNotice;
@property (nonatomic, copy) NSString *writerCredit;
@end

typedef void (^CILyricsCompletion)(CILyricsResult * _Nullable result,
                                   NSError * _Nullable error);

@protocol CILyricsProviding <NSObject>
- (void)fetchLyricsForTitle:(NSString *)title
                     artist:(NSString *)artist
                   duration:(NSTimeInterval)duration
              displayAPIKey:(NSString *)displayAPIKey
                     LRCKey:(NSString *)LRCKey
                  territory:(NSString *)territory
                 completion:(CILyricsCompletion)completion;
- (void)cancel;
@end

@interface CILyricFindProvider : NSObject <CILyricsProviding>
@end

NS_ASSUME_NONNULL_END
