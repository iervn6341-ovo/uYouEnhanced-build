#import "uYouPlus.h"
#import <objc/message.h>
#import <os/log.h>

@interface DownloadsManager : NSObject
- (void)mergeAudioWithVideoForDownloadItem:(id)downloadItem;
- (void)executeCallback:(long long)executionId :(int)returnCode;
@end

@interface MobileFFmpeg : NSObject
+ (int)executeAsync:(NSString *)command withCallback:(id)callback;
@end

static NSString *const UYEForceAACThreadKey = @"UYEForceAACForUYouMerge";

static id UYEObjectForSelector(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL UYEBoolForSelector(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
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

        const unsigned char *bytes =
            static_cast<const unsigned char *>(header.bytes);
        BOOL isMatroskaOrWebM = bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3;
        BOOL isOgg = bytes[0] == 'O' && bytes[1] == 'g' && bytes[2] == 'g' && bytes[3] == 'S';
        return isMatroskaOrWebM || isOgg;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL UYEIsUYouMergeCommand(NSString *command) {
    if (![command isKindOfClass:[NSString class]]) return NO;

    NSString *lowercaseCommand = command.lowercaseString;
    return [lowercaseCommand containsString:@"_audio."] &&
           [lowercaseCommand containsString:@"_video."] &&
           [lowercaseCommand containsString:@"-c:v copy"] &&
           [lowercaseCommand containsString:@"-c:a copy"];
}

static NSString *UYEPatchUYouMergeCommand(NSString *command, BOOL forceAAC) {
    if (!UYEIsUYouMergeCommand(command)) return command;

    NSString *patchedCommand = command;
    if (forceAAC) {
        patchedCommand = [patchedCommand stringByReplacingOccurrencesOfString:@"-c:a copy"
                                                                   withString:@"-c:a aac -b:a 192k"];
    }

    // uYou 3.0.4 reuses <videoID>.mkv/.mp4 but does not pass -y. A partial
    // output left by a failed attempt therefore makes every retry exit with
    // rc=1 before the merge begins.
    return [NSString stringWithFormat:@"-y -nostdin %@", patchedCommand];
}

%hook MobileFFmpeg

+ (int)executeAsync:(NSString *)command withCallback:(id)callback {
    BOOL forceAAC = [[NSThread currentThread].threadDictionary[UYEForceAACThreadKey] boolValue];
    NSString *patchedCommand = UYEPatchUYouMergeCommand(command, forceAAC);

    if (patchedCommand != command) {
        os_log_with_type(OS_LOG_DEFAULT,
                         OS_LOG_TYPE_DEFAULT,
                         "[uYouEnhanced] Patched uYou FFmpeg merge command (overwrite=yes, transcodeAudio=%{public}s)",
                         forceAAC ? "yes" : "no");
    }

    return %orig(patchedCommand, callback);
}

%end

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

- (void)mergeAudioWithVideoForDownloadItem:(id)downloadItem {
    id uYouItem = UYEObjectForSelector(downloadItem, NSSelectorFromString(@"uYouItem"));
    id audioFormat = UYEObjectForSelector(uYouItem, NSSelectorFromString(@"audioFormat"));
    id videoFormat = UYEObjectForSelector(uYouItem, NSSelectorFromString(@"videoFormat"));
    BOOL isMP4Output = UYEBoolForSelector(uYouItem, NSSelectorFromString(@"isMP4"));
    BOOL forceAAC = isMP4Output && UYEFormatNeedsFFmpeg(audioFormat);

    NSMutableDictionary *threadDictionary = [NSThread currentThread].threadDictionary;
    id previousForceAACValue = threadDictionary[UYEForceAACThreadKey];
    threadDictionary[UYEForceAACThreadKey] = @(forceAAC);

    os_log_with_type(OS_LOG_DEFAULT,
                     OS_LOG_TYPE_DEFAULT,
                     "[uYouEnhanced] Starting uYou FFmpeg merge (audio=%{public}@, video=%{public}@, output=%{public}s)",
                     audioFormat,
                     videoFormat,
                     isMP4Output ? "mp4" : "mkv");

    @try {
        %orig;
    } @finally {
        if (previousForceAACValue) {
            threadDictionary[UYEForceAACThreadKey] = previousForceAACValue;
        } else {
            [threadDictionary removeObjectForKey:UYEForceAACThreadKey];
        }
    }
}

- (void)executeCallback:(long long)executionId :(int)returnCode {
    os_log_with_type(OS_LOG_DEFAULT,
                     returnCode == 0 ? OS_LOG_TYPE_DEFAULT : OS_LOG_TYPE_ERROR,
                     "[uYouEnhanced] uYou FFmpeg finished (execution=%{public}lld, rc=%{public}d)",
                     executionId,
                     returnCode);

    Class configClass = NSClassFromString(@"MobileFFmpegConfig");
    if (returnCode != 0 && configClass) {
        NSString *commandOutput = UYEObjectForSelector(configClass,
                                                       NSSelectorFromString(@"getLastCommandOutput"));
        if (commandOutput.length > 4000) {
            commandOutput = [commandOutput substringFromIndex:commandOutput.length - 4000];
        }
        if (commandOutput.length > 0) {
            os_log_with_type(OS_LOG_DEFAULT,
                             OS_LOG_TYPE_ERROR,
                             "[uYouEnhanced] FFmpeg error output: %{public}@",
                             commandOutput);
        }
    }

    %orig;
}

%end
