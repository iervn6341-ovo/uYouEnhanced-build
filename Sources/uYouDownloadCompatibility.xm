#import "uYouPlus.h"
#import <objc/message.h>

@interface DownloadsManager : NSObject
- (void)mergeAudioWithVideoForDownloadItem:(id)downloadItem;
@end

static id UYEObjectForSelector(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL UYEFormatNeedsFFmpeg(id format) {
    if (![format isKindOfClass:[NSString class]]) return NO;

    NSString *normalizedFormat = [(NSString *)format lowercaseString];
    static NSArray<NSString *> *incompatibleFormats;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        incompatibleFormats = @[@"webm", @"opus", @"ogg", @"matroska", @"mkv"];
    });

    for (NSString *incompatibleFormat in incompatibleFormats) {
        if ([normalizedFormat containsString:incompatibleFormat]) return YES;
    }
    return NO;
}

static BOOL UYEFileNeedsFFmpeg(id path) {
    if (![path isKindOfClass:[NSString class]] || [(NSString *)path length] == 0) return NO;

    @try {
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:(NSString *)path];
        if (!fileHandle) return NO;

        NSData *header = [fileHandle readDataOfLength:4];
        [fileHandle closeFile];
        if (header.length < 4) return NO;

        const unsigned char *bytes = header.bytes;
        BOOL isMatroskaOrWebM = bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3;
        BOOL isOgg = bytes[0] == 'O' && bytes[1] == 'g' && bytes[2] == 'g' && bytes[3] == 'S';
        return isMatroskaOrWebM || isOgg;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

%hook DownloadsManager

- (void)mergeAudioWithMP4VideoForDownloadItem:(id)downloadItem {
    // uYou 3.0.4 chooses AVFoundation from the video format alone. Newer
    // YouTube responses can pair MP4 video with WebM/Opus audio, which makes
    // that merge stall after both network tasks have already reached 100%.
    id uYouItem = UYEObjectForSelector(downloadItem, NSSelectorFromString(@"uYouItem"));
    id audioFormat = UYEObjectForSelector(uYouItem, NSSelectorFromString(@"audioFormat"));
    id videoFormat = UYEObjectForSelector(uYouItem, NSSelectorFromString(@"videoFormat"));
    id temporaryAudioPath = UYEObjectForSelector(uYouItem, NSSelectorFromString(@"tmpAudioPath"));
    id temporaryVideoPath = UYEObjectForSelector(uYouItem, NSSelectorFromString(@"tmpVideoPath"));

    BOOL needsFFmpeg = UYEFormatNeedsFFmpeg(audioFormat) ||
                       UYEFormatNeedsFFmpeg(videoFormat) ||
                       UYEFileNeedsFFmpeg(temporaryAudioPath) ||
                       UYEFileNeedsFFmpeg(temporaryVideoPath);

    if (needsFFmpeg && [self respondsToSelector:@selector(mergeAudioWithVideoForDownloadItem:)]) {
        NSLog(@"[uYouEnhanced] Routing incompatible uYou download through FFmpeg (audio=%@, video=%@)",
              audioFormat, videoFormat);
        [self mergeAudioWithVideoForDownloadItem:downloadItem];
        return;
    }

    %orig;
}

%end
