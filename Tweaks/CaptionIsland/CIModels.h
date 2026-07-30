#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CICaptionSource) {
    CICaptionSourceLRCLIBSynced,
    CICaptionSourceLRCLIBAligned,
    CICaptionSourceLRCLIBEstimated,
    CICaptionSourceYouTubeManual,
    CICaptionSourceYouTubeASR,
};

@interface CICaptionCue : NSObject
@property (nonatomic, readonly) NSTimeInterval startTime;
@property (nonatomic, readonly) NSTimeInterval endTime;
@property (nonatomic, copy, readonly) NSString *text;
- (instancetype)initWithStartTime:(NSTimeInterval)startTime
                          endTime:(NSTimeInterval)endTime
                             text:(NSString *)text;
@end

@interface CICaptionTrack : NSObject
@property (nonatomic, copy) NSString *baseURL;
@property (nonatomic, copy) NSString *languageCode;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *vssID;
@property (nonatomic, readonly, getter=isAutomatic) BOOL automatic;
@end

@interface CIVideoContext : NSObject
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *author;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic, getter=isShorts) BOOL shorts;
@property (nonatomic, copy) NSArray<CICaptionTrack *> *captionTracks;
@end

FOUNDATION_EXPORT NSString *CICaptionSourceLabel(CICaptionSource source);

NS_ASSUME_NONNULL_END
