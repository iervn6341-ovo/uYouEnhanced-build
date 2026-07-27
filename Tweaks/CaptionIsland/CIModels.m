#import "CIModels.h"

@implementation CICaptionCue

- (instancetype)initWithStartTime:(NSTimeInterval)startTime
                          endTime:(NSTimeInterval)endTime
                             text:(NSString *)text {
    self = [super init];
    if (self) {
        _startTime = MAX(0, startTime);
        _endTime = MAX(_startTime + 0.05, endTime);
        _text = [text copy] ?: @"";
    }
    return self;
}

@end

@implementation CICaptionTrack

- (instancetype)init {
    self = [super init];
    if (self) {
        _baseURL = @"";
        _languageCode = @"";
        _displayName = @"";
        _kind = @"";
        _vssID = @"";
    }
    return self;
}

- (BOOL)isAutomatic {
    if ([self.kind.lowercaseString isEqualToString:@"asr"] ||
        [self.vssID.lowercaseString hasPrefix:@"a."]) return YES;
    NSURLComponents *components = [NSURLComponents componentsWithString:self.baseURL];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name.lowercaseString isEqualToString:@"kind"] &&
            [item.value.lowercaseString isEqualToString:@"asr"]) return YES;
    }
    return NO;
}

@end

@implementation CIVideoContext

- (instancetype)init {
    self = [super init];
    if (self) {
        _videoID = @"";
        _title = @"";
        _author = @"";
        _captionTracks = @[];
    }
    return self;
}

@end

NSString *CICaptionSourceLabel(CICaptionSource source) {
    switch (source) {
        case CICaptionSourceLRCLIBSynced: return @"LRCLIB";
        case CICaptionSourceLRCLIBAligned: return @"LRCLIB·ALIGN";
        case CICaptionSourceLRCLIBEstimated: return @"LRCLIB·EST";
        case CICaptionSourceYouTubeManual: return @"CC";
        case CICaptionSourceYouTubeASR: return @"ASR";
    }
    return @"";
}
