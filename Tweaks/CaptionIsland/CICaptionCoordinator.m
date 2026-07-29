#import "CICaptionCoordinator.h"
#import "CIActivityPresenter.h"
#import "CICaptionParser.h"
#import "CIConstants.h"
#import "CILRCLIBProvider.h"
#import "CILogStore.h"
#import "CILyricsAligner.h"
#import "CITextUtilities.h"
#import "CIToastPresenter.h"
#import "CIYouTubeInspector.h"
#import <UIKit/UIKit.h>
#import <float.h>
#import <math.h>

@interface CICaptionResult : NSObject
@property (nonatomic, copy) NSArray<CICaptionCue *> *cues;
@property (nonatomic) CICaptionSource source;
@end
@implementation CICaptionResult @end

typedef NS_ENUM(NSInteger, CILoadStage) {
    CILoadStageIdle,
    CILoadStageLRCLIB,
    CILoadStagePlainLyrics,
    CILoadStageManualCC,
    CILoadStageASR,
    CILoadStageFinished,
};

// NSNotFound means that the activity is already showing a gap. This separate
// sentinel forces the first post-load render (including an intro gap) to reach
// ActivityKit instead of leaving its loading state on screen.
static const NSInteger CIUnrenderedCueIndex = NSIntegerMin;

static void CIPipelineLog(CILogLevel level, NSString *format, ...) {
    if (format.length == 0) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    [CILogStore.sharedStore recordLevel:level
                               category:@"Pipeline"
                                message:message ?: @""];
}

static NSArray<CICaptionTrack *> *CIMergedCaptionTracks(
    NSArray<CICaptionTrack *> *newTracks,
    NSArray<CICaptionTrack *> *existingTracks) {
    NSMutableArray<CICaptionTrack *> *result = [newTracks mutableCopy] ?: [NSMutableArray array];
    NSMutableSet<NSString *> *URLs = [NSMutableSet set];
    for (CICaptionTrack *track in result) {
        if (track.baseURL.length > 0) [URLs addObject:track.baseURL];
    }
    for (CICaptionTrack *track in existingTracks) {
        if (track.baseURL.length == 0 || [URLs containsObject:track.baseURL]) continue;
        [result addObject:track];
        [URLs addObject:track.baseURL];
    }
    return result.copy;
}

@interface CICaptionCoordinator ()
@property (nonatomic) dispatch_queue_t workQueue;
@property (nonatomic, strong) NSURLSession *captionSession;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *captionTask;
@property (nonatomic, strong) CILRCLIBProvider *lyricsProvider;
@property (nonatomic, strong) NSCache<NSString *, CICaptionResult *> *cache;
@property (nonatomic, strong, nullable) CIVideoContext *context;
@property (nonatomic, copy) NSArray<CICaptionCue *> *cues;
@property (nonatomic) CICaptionSource source;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) NSInteger displayedCueIndex;
@property (nonatomic) NSTimeInterval latestPlaybackTime;
@property (nonatomic) NSTimeInterval lastSubmittedTime;
@property (nonatomic) BOOL suppressed;
@property (nonatomic) BOOL loadInterruptedBySuppression;
@property (nonatomic) BOOL playerVisible;
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL resolved;
@property (nonatomic) CILoadStage loadStage;
@property (nonatomic, copy) NSString *activePlainLyrics;
@property (nonatomic, copy) NSString *lastLRCLIBQueryKey;
@property (nonatomic, copy) NSString *lastNoResultVideoID;
@property (nonatomic) NSUInteger captionRequestToken;
@property (nonatomic) NSTimeInterval contextActivatedAt;
@property (nonatomic, strong) id<CICaptionPresenting> presenter;
- (void)ensurePresenterForCurrentContext;
- (void)tryClockTracks:(NSArray<CICaptionTrack *> *)tracks
                 index:(NSUInteger)index
           plainLyrics:(NSString *)lyrics
               context:(CIVideoContext *)context
            generation:(NSUInteger)generation
              cacheKey:(NSString *)cacheKey
    manualFallbackCues:(NSArray<CICaptionCue *> *)manualFallbackCues
       ASRFallbackCues:(NSArray<CICaptionCue *> *)ASRFallbackCues;
- (void)fetchTrack:(CICaptionTrack *)track
        requestURLs:(NSArray<NSURL *> *)requestURLs
              index:(NSUInteger)index
              token:(NSUInteger)token
         generation:(NSUInteger)generation
         completion:(void (^)(NSArray<CICaptionCue *> *cues))completion;
@end

@implementation CICaptionCoordinator

+ (instancetype)sharedCoordinator {
    static CICaptionCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ coordinator = [CICaptionCoordinator new]; });
    return coordinator;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _workQueue = dispatch_queue_create("com.captionisland.coordinator", attributes);
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = 6.0;
        configuration.timeoutIntervalForResource = 8.0;
        configuration.HTTPMaximumConnectionsPerHost = 1;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _captionSession = [NSURLSession sessionWithConfiguration:configuration];
        _lyricsProvider = [CILRCLIBProvider new];
        _cache = [NSCache new];
        _cache.countLimit = 8;
        _cache.totalCostLimit = 6000;
        _cues = @[];
        _activePlainLyrics = @"";
        _lastLRCLIBQueryKey = @"";
        _lastNoResultVideoID = @"";
        _loadStage = CILoadStageIdle;
        _displayedCueIndex = CIUnrenderedCueIndex;
        _lastSubmittedTime = -DBL_MAX;
        _presenter = CIActivityPresenter.sharedPresenter;
        [NSNotificationCenter.defaultCenter addObserver:self
            selector:@selector(applicationDidBecomeActive:)
            name:UIApplicationDidBecomeActiveNotification
            object:nil];
    }
    return self;
}

- (void)setPresenter:(id<CICaptionPresenting>)presenter {
    if (!presenter) return;
    dispatch_async(self.workQueue, ^{ self->_presenter = presenter; });
}

- (void)applicationDidBecomeActive:(__unused NSNotification *)notification {
    dispatch_async(self.workQueue, ^{
        if (!self.context || !CIPreferenceBool(CIEnabledKey, YES)) return;
        [self ensurePresenterForCurrentContext];
        self.displayedCueIndex = CIUnrenderedCueIndex;
        if (!self.loading) [self renderAtTime:self.latestPlaybackTime];
    });
}

- (void)ensurePresenterForCurrentContext {
    if (!self.context.videoID.length) return;
    if ([self.presenter respondsToSelector:@selector(ensureVideoID:title:)]) {
        [self.presenter ensureVideoID:self.context.videoID title:self.context.title ?: @""];
    } else {
        [self.presenter beginVideoID:self.context.videoID title:self.context.title ?: @""];
    }
}

- (NSString *)cacheKeyForContext:(CIVideoContext *)context {
    BOOL external = CIPreferenceBool(CIExternalLyricsEnabledKey, YES);
    return [NSString stringWithFormat:@"%@|%@|%d", context.videoID, CIPreferredLanguage(), external];
}

- (NSString *)LRCLIBQueryKeyForTitle:(NSString *)title
                              artist:(NSString *)artist
                            duration:(NSTimeInterval)duration {
    return [NSString stringWithFormat:@"%@|%@|%.0f",
        CINormalizedText(title), CINormalizedText(artist), MAX(0, duration)];
}

- (NSString *)LRCLIBQueryKeyForContext:(CIVideoContext *)context {
    if (!context) return @"";
    NSString *title = CISongTitleFromVideoTitle(context.title);
    if (title.length == 0) return @"";
    return [self LRCLIBQueryKeyForTitle:title artist:@"" duration:context.duration];
}

- (void)activateContext:(CIVideoContext *)context {
    if (!context.videoID.length) return;
    self.lastSubmittedTime = -DBL_MAX;
    dispatch_async(self.workQueue, ^{
        if (self.suppressed) {
            self.context = context;
            self.loadInterruptedBySuppression = YES;
            return;
        }
        [self beginContext:context force:NO];
    });
}

- (void)beginContext:(CIVideoContext *)context force:(BOOL)force {
    BOOL sameVideo = [self.context.videoID isEqualToString:context.videoID];
    BOOL hasRicherTracks = context.captionTracks.count > self.context.captionTracks.count;
    BOOL hasRicherMetadata = context.title.length > self.context.title.length ||
        context.author.length > self.context.author.length ||
        (context.duration > 0 && self.context.duration <= 0);
    if (sameVideo) {
        if (context.title.length == 0) context.title = self.context.title;
        if (context.author.length == 0) context.author = self.context.author;
        if (self.context.duration > 0 && context.duration <= 0) context.duration = self.context.duration;
        context.captionTracks = CIMergedCaptionTracks(
            context.captionTracks, self.context.captionTracks);
    }
    CICaptionTrack *oldManual = self.context
        ? [CIYouTubeInspector manualTrackInContext:self.context preferredLanguage:CIPreferredLanguage()] : nil;
    CICaptionTrack *newManual = [CIYouTubeInspector manualTrackInContext:context preferredLanguage:CIPreferredLanguage()];
    CICaptionTrack *oldASR = self.context
        ? [CIYouTubeInspector automaticTrackInContext:self.context preferredLanguage:CIPreferredLanguage()] : nil;
    CICaptionTrack *newASR = [CIYouTubeInspector automaticTrackInContext:context
                                                       preferredLanguage:CIPreferredLanguage()];
    BOOL manualTrackChanged = newManual &&
        ![newManual.baseURL isEqualToString:oldManual.baseURL];
    BOOL ASRTrackChanged = newASR &&
        ![newASR.baseURL isEqualToString:oldASR.baseURL];
    hasRicherTracks = hasRicherTracks || manualTrackChanged || ASRTrackChanged;
    BOOL shouldRefreshYouTubeFallback =
        (manualTrackChanged &&
         ((self.loading && (self.loadStage == CILoadStageManualCC ||
                           self.loadStage == CILoadStageASR)) ||
          (self.cues.count > 0 &&
           (self.source == CICaptionSourceYouTubeManual ||
            self.source == CICaptionSourceYouTubeASR)))) ||
        (ASRTrackChanged &&
         ((self.loading && self.loadStage == CILoadStageASR) ||
          (self.cues.count > 0 && self.source == CICaptionSourceYouTubeASR)));
    BOOL clockTrackChanged = manualTrackChanged || ASRTrackChanged;
    NSString *updatedLRCLIBKey = [self LRCLIBQueryKeyForContext:context];
    BOOL shouldRetryLRCLIB = CIPreferenceBool(CIExternalLyricsEnabledKey, YES) &&
        updatedLRCLIBKey.length > 0 &&
        ![updatedLRCLIBKey isEqualToString:self.lastLRCLIBQueryKey];
    BOOL shouldRefreshPlainTiming = !shouldRetryLRCLIB &&
        self.activePlainLyrics.length > 0 && clockTrackChanged &&
        ((self.loading && self.loadStage == CILoadStagePlainLyrics) ||
         (self.cues.count > 0 && self.source == CICaptionSourceLRCLIBEstimated));
    if (!force && sameVideo && shouldRefreshPlainTiming) {
        NSString *plainLyrics = self.activePlainLyrics;
        self.context = context;
        self.generation++;
        NSUInteger generation = self.generation;
        [self.captionTask cancel];
        self.captionTask = nil;
        [self.lyricsProvider cancel];
        self.loading = YES;
        self.resolved = NO;
        [self loadPlainLyrics:plainLyrics context:context generation:generation
                    cacheKey:[self cacheKeyForContext:context]];
        return;
    }
    if (!force && sameVideo && (self.loading || self.cues.count > 0) &&
        !shouldRefreshYouTubeFallback && !shouldRetryLRCLIB) {
        // Caption tracks often arrive after the player response. Merge them
        // into the active context, but never cancel an in-flight or installed
        // LRCLIB result merely because a lower-priority CC track appeared.
        self.context = context;
        return;
    }
    if (!force && sameVideo && !hasRicherTracks && !hasRicherMetadata &&
        !shouldRetryLRCLIB && self.resolved) return;
    if (!sameVideo) {
        self.contextActivatedAt = NSProcessInfo.processInfo.systemUptime;
        self.lastLRCLIBQueryKey = @"";
        self.lastNoResultVideoID = @"";
    } else if (force) {
        self.lastLRCLIBQueryKey = @"";
    }
    self.generation++;
    NSUInteger generation = self.generation;
    [self.captionTask cancel];
    self.captionTask = nil;
    [self.lyricsProvider cancel];
    self.context = context;
    self.cues = @[];
    self.loading = NO;
    self.resolved = NO;
    self.loadStage = CILoadStageIdle;
    self.activePlainLyrics = @"";
    self.displayedCueIndex = CIUnrenderedCueIndex;
    if (!sameVideo) self.latestPlaybackTime = 0;
    if (!CIPreferenceBool(CIEnabledKey, YES)) {
        self.resolved = YES;
        self.loadStage = CILoadStageFinished;
        [self.presenter end];
        return;
    }
    [self.presenter beginVideoID:context.videoID title:context.title ?: @""];
    self.loading = YES;

    NSString *cacheKey = [self cacheKeyForContext:context];
    [self loadLRCLIBLyricsForContext:context generation:generation cacheKey:cacheKey];
}

- (void)loadLRCLIBLyricsForContext:(CIVideoContext *)context
                        generation:(NSUInteger)generation
                          cacheKey:(NSString *)cacheKey {
    if (generation != self.generation) return;
    self.loadStage = CILoadStageLRCLIB;
    if (!CIPreferenceBool(CIExternalLyricsEnabledKey, YES)) {
        [self loadManualCCForContext:context generation:generation cacheKey:cacheKey
                   ASRFallbackCues:@[]];
        return;
    }

    NSString *songTitle = CISongTitleFromVideoTitle(context.title);
    if (songTitle.length == 0) {
        [self loadManualCCForContext:context generation:generation cacheKey:cacheKey
                   ASRFallbackCues:@[]];
        return;
    }
    NSString *queryKey = [self LRCLIBQueryKeyForTitle:songTitle artist:@""
                                             duration:context.duration];
    if ([self.lastLRCLIBQueryKey isEqualToString:queryKey]) {
        [self loadManualCCForContext:context generation:generation cacheKey:cacheKey
                   ASRFallbackCues:@[]];
        return;
    }
    self.lastLRCLIBQueryKey = queryKey;
    CIPipelineLog(CILogLevelInfo,
        @"Searching LRCLIB for title \"%@\" only (video %.1fs)",
        songTitle, context.duration);
    __weak typeof(self) weakSelf = self;
    [self.lyricsProvider fetchLyricsForTitle:songTitle artist:@"" duration:context.duration
                                  completion:^(CILRCLIBResult *result, NSError *error) {
        dispatch_async(weakSelf.workQueue, ^{
            typeof(self) self = weakSelf;
            if (!self || generation != self.generation) return;
            if (!result) {
                CIPipelineLog(CILogLevelInfo, @"LRCLIB lookup returned no match: %@",
                    error.localizedDescription ?: @"unknown error");
                [self loadManualCCForContext:self.context ?: context generation:generation
                                    cacheKey:cacheKey ASRFallbackCues:@[]];
                return;
            }
            CIPipelineLog(CILogLevelInfo,
                @"Selected source LRCLIB %@: #%ld %@ — %@ (%.1fs, delta %.1fs)",
                result.syncedCues.count > 0 ? @"Synced" : @"Plain",
                (long)result.recordID, result.artistName, result.trackName,
                result.trackDuration, result.durationDifference);
            if (result.syncedCues.count > 0) {
                [self installCues:result.syncedCues source:CICaptionSourceLRCLIBSynced
                      generation:generation cacheKey:cacheKey];
                return;
            }
            [self loadPlainLyrics:result.plainLyrics context:self.context ?: context
                      generation:generation cacheKey:cacheKey];
        });
    }];
}

- (void)loadPlainLyrics:(NSString *)lyrics
                context:(CIVideoContext *)context
             generation:(NSUInteger)generation
               cacheKey:(NSString *)cacheKey {
    if (generation != self.generation) return;
    self.loadStage = CILoadStagePlainLyrics;
    self.activePlainLyrics = lyrics ?: @"";
    if (CINonEmptyLines(lyrics).count == 0) {
        [self loadManualCCForContext:context generation:generation cacheKey:cacheKey
                   ASRFallbackCues:@[]];
        return;
    }
    CICaptionTrack *ASR = [CIYouTubeInspector automaticTrackInContext:context
                                                    preferredLanguage:CIPreferredLanguage()];
    CICaptionTrack *manual = [CIYouTubeInspector manualTrackInContext:context
                                                       preferredLanguage:CIPreferredLanguage()];
    NSMutableArray<CICaptionTrack *> *clockTracks = [NSMutableArray arrayWithCapacity:2];
    if (manual) [clockTracks addObject:manual];
    if (ASR && ![ASR.baseURL isEqualToString:manual.baseURL]) [clockTracks addObject:ASR];
    if (clockTracks.count == 0) {
        NSTimeInterval age = NSProcessInfo.processInfo.systemUptime - self.contextActivatedAt;
        if (age < 0.8) {
            NSTimeInterval delay = 0.8 - MAX(0, age);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           self.workQueue, ^{
                if (generation != self.generation || self.loadStage != CILoadStagePlainLyrics) return;
                [self loadPlainLyrics:lyrics context:self.context ?: context
                           generation:generation cacheKey:cacheKey];
            });
            return;
        }
        NSArray *estimated = [CILyricsAligner estimatedCuesForPlainLyrics:lyrics duration:context.duration];
        if (estimated.count > 0) {
            [self installCues:estimated source:CICaptionSourceLRCLIBEstimated
                  generation:generation cacheKey:cacheKey];
        } else {
            [self loadManualCCForContext:context generation:generation cacheKey:cacheKey
                       ASRFallbackCues:@[]];
        }
        return;
    }
    [self tryClockTracks:clockTracks.copy index:0 plainLyrics:lyrics
                 context:context generation:generation cacheKey:cacheKey
      manualFallbackCues:@[] ASRFallbackCues:@[]];
}

- (void)tryClockTracks:(NSArray<CICaptionTrack *> *)tracks
                 index:(NSUInteger)index
           plainLyrics:(NSString *)lyrics
               context:(CIVideoContext *)context
            generation:(NSUInteger)generation
              cacheKey:(NSString *)cacheKey
    manualFallbackCues:(NSArray<CICaptionCue *> *)manualFallbackCues
       ASRFallbackCues:(NSArray<CICaptionCue *> *)ASRFallbackCues {
    if (generation != self.generation) return;
    if (index >= tracks.count) {
        NSArray<CICaptionCue *> *estimated =
            [CILyricsAligner estimatedCuesForPlainLyrics:lyrics duration:context.duration];
        if (estimated.count > 0) {
            [self installCues:estimated source:CICaptionSourceLRCLIBEstimated
                  generation:generation cacheKey:cacheKey];
        } else if (manualFallbackCues.count > 0) {
            [self installCues:manualFallbackCues source:CICaptionSourceYouTubeManual
                  generation:generation cacheKey:cacheKey];
        } else if (ASRFallbackCues.count > 0) {
            [self installCues:ASRFallbackCues source:CICaptionSourceYouTubeASR
                  generation:generation cacheKey:cacheKey];
        } else {
            [self finishWithoutCaptionsForGeneration:generation];
        }
        return;
    }

    CICaptionTrack *track = tracks[index];
    [self fetchTrack:track generation:generation completion:^(NSArray<CICaptionCue *> *clockCues) {
        NSArray<CICaptionCue *> *aligned =
            [CILyricsAligner alignPlainLyrics:lyrics toASR:clockCues];
        if (aligned.count > 0) {
            [self installCues:aligned source:CICaptionSourceLRCLIBAligned
                  generation:generation cacheKey:cacheKey];
            return;
        }
        NSArray<CICaptionCue *> *nextManual = manualFallbackCues;
        NSArray<CICaptionCue *> *nextASR = ASRFallbackCues;
        if (clockCues.count > 0) {
            if (track.isAutomatic) nextASR = clockCues;
            else nextManual = clockCues;
        }
        [self tryClockTracks:tracks index:index + 1 plainLyrics:lyrics
                     context:self.context ?: context generation:generation
                    cacheKey:cacheKey manualFallbackCues:nextManual
             ASRFallbackCues:nextASR];
    }];
}

- (void)loadManualCCForContext:(CIVideoContext *)context
                    generation:(NSUInteger)generation
                      cacheKey:(NSString *)cacheKey
               ASRFallbackCues:(NSArray<CICaptionCue *> *)ASRFallbackCues {
    if (generation != self.generation) return;
    self.loadStage = CILoadStageManualCC;
    CICaptionTrack *manual = [CIYouTubeInspector manualTrackInContext:context
                                                    preferredLanguage:CIPreferredLanguage()];
    CICaptionResult *cached = [self.cache objectForKey:cacheKey];
    if (manual && cached.cues.count > 0 &&
        cached.source == CICaptionSourceYouTubeManual) {
        [self installCues:cached.cues source:cached.source generation:generation cacheKey:nil];
        return;
    }
    if (!manual) {
        if (ASRFallbackCues.count > 0) {
            [self installCues:ASRFallbackCues source:CICaptionSourceYouTubeASR
                  generation:generation cacheKey:cacheKey];
        } else {
            [self loadASRForContext:context generation:generation cacheKey:cacheKey];
        }
        return;
    }
    CIPipelineLog(CILogLevelInfo, @"Trying source YouTube CC (%@) for %@",
        manual.languageCode, context.videoID);
    [self fetchTrack:manual generation:generation completion:^(NSArray<CICaptionCue *> *cues) {
        if (cues.count > 0) {
            [self installCues:cues source:CICaptionSourceYouTubeManual
                  generation:generation cacheKey:cacheKey];
        } else if (ASRFallbackCues.count > 0) {
            [self installCues:ASRFallbackCues source:CICaptionSourceYouTubeASR
                  generation:generation cacheKey:cacheKey];
        } else {
            [self loadASRForContext:self.context ?: context generation:generation
                          cacheKey:cacheKey];
        }
    }];
}

- (void)loadASRForContext:(CIVideoContext *)context
                generation:(NSUInteger)generation
                  cacheKey:(NSString *)cacheKey {
    if (generation != self.generation) return;
    self.loadStage = CILoadStageASR;
    CICaptionResult *cached = [self.cache objectForKey:cacheKey];
    if (cached.cues.count > 0 && cached.source == CICaptionSourceYouTubeASR) {
        [self installCues:cached.cues source:cached.source generation:generation cacheKey:nil];
        return;
    }
    CICaptionTrack *ASR = [CIYouTubeInspector automaticTrackInContext:context
                                                    preferredLanguage:CIPreferredLanguage()];
    if (!ASR) {
        CIPipelineLog(CILogLevelInfo,
            @"No source YouTube ASR track found among %lu caption track(s) for %@",
            (unsigned long)context.captionTracks.count, context.videoID);
        [self finishWithoutCaptionsForGeneration:generation];
        return;
    }
    CIPipelineLog(CILogLevelInfo, @"Trying source YouTube ASR (%@) for %@",
        ASR.languageCode, context.videoID);
    [self fetchTrack:ASR generation:generation completion:^(NSArray<CICaptionCue *> *cues) {
        if (cues.count > 0) {
            CIPipelineLog(CILogLevelInfo, @"Loaded %lu YouTube ASR cue(s) for %@",
                (unsigned long)cues.count, context.videoID);
            [self installCues:cues source:CICaptionSourceYouTubeASR generation:generation cacheKey:cacheKey];
        } else {
            CIPipelineLog(CILogLevelInfo,
                @"YouTube ASR produced no usable cues for %@", context.videoID);
            [self finishWithoutCaptionsForGeneration:generation];
        }
    }];
}

- (void)fetchTrack:(CICaptionTrack *)track
         generation:(NSUInteger)generation
         completion:(void (^)(NSArray<CICaptionCue *> *cues))completion {
    if (generation != self.generation) return;
    [self.captionTask cancel];
    self.captionRequestToken++;
    NSUInteger token = self.captionRequestToken;
    NSArray<NSURL *> *requestURLs = [CIYouTubeInspector requestURLsForTrack:track];
    if (requestURLs.count == 0) {
        CILog(@"Caption track has no usable source URL (%@, %@)",
            track.languageCode, track.isAutomatic ? @"ASR" : @"manual");
        completion(@[]);
        return;
    }
    [self fetchTrack:track requestURLs:requestURLs index:0 token:token
          generation:generation completion:completion];
}

- (void)fetchTrack:(CICaptionTrack *)track
        requestURLs:(NSArray<NSURL *> *)requestURLs
              index:(NSUInteger)index
              token:(NSUInteger)token
         generation:(NSUInteger)generation
         completion:(void (^)(NSArray<CICaptionCue *> *cues))completion {
    if (generation != self.generation || token != self.captionRequestToken) return;
    if (index >= requestURLs.count) {
        CILog(@"Caption formats exhausted without usable cues (%@, %@)",
            track.languageCode, track.isAutomatic ? @"ASR" : @"manual");
        completion(@[]);
        return;
    }
    NSURL *URL = requestURLs[index];
    NSURLComponents *components = [NSURLComponents componentsWithURL:URL
                                             resolvingAgainstBaseURL:NO];
    NSString *format = @"default";
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name.lowercaseString isEqualToString:@"fmt"] && item.value.length > 0) {
            format = item.value;
            break;
        }
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6.0];
    [request setValue:@"application/json, text/vtt, text/xml, */*"
        forHTTPHeaderField:@"Accept"];
    __weak typeof(self) weakSelf = self;
    __block NSURLSessionDataTask *task;
    task = [self.captionSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(weakSelf.workQueue, ^{
            typeof(self) self = weakSelf;
            if (!self || generation != self.generation ||
                token != self.captionRequestToken || self.captionTask != task) return;
            self.captionTask = nil;
            if (error) {
                CILog(@"Caption %@ request failed (%@): %@",
                    format, track.isAutomatic ? @"ASR" : @"manual",
                    error.localizedDescription);
                [self fetchTrack:track requestURLs:requestURLs index:index + 1
                    token:token generation:generation completion:completion];
                return;
            }
            if ([response isKindOfClass:NSHTTPURLResponse.class]) {
                NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
                if (status < 200 || status >= 300) {
                    CILog(@"Caption %@ request returned HTTP %ld (%@)",
                        format, (long)status, track.isAutomatic ? @"ASR" : @"manual");
                    if (status == 429) {
                        completion(@[]);
                    } else {
                        [self fetchTrack:track requestURLs:requestURLs index:index + 1
                            token:token generation:generation completion:completion];
                    }
                    return;
                }
            }
            if (data.length == 0) {
                CILog(@"Caption %@ response was empty (%@)",
                    format, track.isAutomatic ? @"ASR" : @"manual");
                [self fetchTrack:track requestURLs:requestURLs index:index + 1
                    token:token generation:generation completion:completion];
                return;
            }
            if (data.length > 8 * 1024 * 1024) {
                CILog(@"Caption response exceeded the 8 MiB safety limit");
                completion(@[]);
                return;
            }
            NSString *MIMEType = [(NSHTTPURLResponse *)response MIMEType];
            NSArray *cues = [CICaptionParser parseYouTubeData:data MIMEType:MIMEType];
            if (cues.count > 0) {
                completion(cues);
                return;
            }
            CILog(@"Caption %@ response contained no parseable cues (%lu bytes, MIME %@)",
                format, (unsigned long)data.length, MIMEType ?: @"unknown");
            [self fetchTrack:track requestURLs:requestURLs index:index + 1
                token:token generation:generation completion:completion];
        });
    }];
    self.captionTask = task;
    [task resume];
}

- (void)installCues:(NSArray<CICaptionCue *> *)cues
              source:(CICaptionSource)source
          generation:(NSUInteger)generation
            cacheKey:(NSString *)cacheKey {
    if (generation != self.generation || cues.count == 0) return;
    self.cues = [cues copy];
    self.loading = NO;
    self.resolved = YES;
    self.loadStage = CILoadStageFinished;
    self.source = source;
    self.displayedCueIndex = CIUnrenderedCueIndex;
    CICaptionCue *firstCue = self.cues.firstObject;
    CICaptionCue *lastCue = self.cues.lastObject;
    CIPipelineLog(CILogLevelInfo,
        @"Installed source %@ with %lu cue(s), timeline %.1fs–%.1fs (playback %.1fs)",
        CICaptionSourceLabel(source), (unsigned long)self.cues.count,
        firstCue.startTime, lastCue.endTime, self.latestPlaybackTime);
    BOOL cacheable = source == CICaptionSourceYouTubeManual || source == CICaptionSourceYouTubeASR;
    BOOL usesPlainLyrics = source == CICaptionSourceLRCLIBAligned ||
        source == CICaptionSourceLRCLIBEstimated;
    if (!usesPlainLyrics) self.activePlainLyrics = @"";
    if (cacheKey.length > 0 && cacheable) {
        CICaptionResult *result = [CICaptionResult new];
        result.cues = self.cues;
        result.source = source;
        [self.cache setObject:result forKey:cacheKey cost:self.cues.count];
    }
    [self renderAtTime:self.latestPlaybackTime];
}

- (void)finishWithoutCaptionsForGeneration:(NSUInteger)generation {
    if (generation != self.generation) return;
    self.loading = NO;
    self.resolved = YES;
    self.loadStage = CILoadStageFinished;
    self.cues = @[];
    self.activePlainLyrics = @"";
    self.displayedCueIndex = NSNotFound;
    [self.presenter hide];

    NSString *videoID = self.context.videoID ?: @"";
    NSTimeInterval earliest = self.contextActivatedAt + 5.4;
    NSTimeInterval delay = MAX(0.25, earliest - NSProcessInfo.processInfo.systemUptime);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   self.workQueue, ^{
        [self deliverNoResultToastForGeneration:generation videoID:videoID];
    });
}

- (void)deliverNoResultToastForGeneration:(NSUInteger)generation
                                  videoID:(NSString *)videoID {
    if (!CIPreferenceBool(CIEnabledKey, YES) ||
        generation != self.generation || self.cues.count > 0 ||
        !self.resolved || videoID.length == 0 ||
        ![self.context.videoID isEqualToString:videoID] ||
        [self.lastNoResultVideoID isEqualToString:videoID]) return;
    if (!self.playerVisible) return;
    if (self.suppressed) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)),
                       self.workQueue, ^{
            [self deliverNoResultToastForGeneration:generation videoID:videoID];
        });
        return;
    }
    self.lastNoResultVideoID = videoID;
    CIShowToast(CILocalized(@"NO_MATCHING_RESULT", @"沒有相符的結果"));
}

- (NSInteger)cueIndexAtTime:(NSTimeInterval)time {
    if (self.cues.count == 0) return NSNotFound;
    NSInteger low = 0, high = (NSInteger)self.cues.count - 1, candidate = -1;
    while (low <= high) {
        NSInteger middle = low + (high - low) / 2;
        CICaptionCue *cue = self.cues[(NSUInteger)middle];
        if (cue.startTime <= time) { candidate = middle; low = middle + 1; }
        else high = middle - 1;
    }
    if (candidate < 0) return NSNotFound;
    CICaptionCue *cue = self.cues[(NSUInteger)candidate];
    return time < cue.endTime ? candidate : NSNotFound;
}

- (void)renderAtTime:(NSTimeInterval)time {
    if (!CIPreferenceBool(CIEnabledKey, YES)) return;
    if (self.suppressed) {
        if (self.displayedCueIndex != NSNotFound) {
            self.displayedCueIndex = NSNotFound;
            [self.presenter hide];
        }
        return;
    }
    NSInteger index = [self cueIndexAtTime:time];
    if (index == self.displayedCueIndex) return;
    self.displayedCueIndex = index;
    if (index == NSNotFound) [self.presenter hide];
    else {
        CICaptionCue *cue = self.cues[(NSUInteger)index];
        [self.presenter presentText:cue.text
                             source:self.source
                           cueStart:cue.startTime
                             cueEnd:cue.endTime
                           position:time];
    }
}

- (void)updatePlaybackTime:(NSTimeInterval)time {
    if (!CIPreferenceBool(CIEnabledKey, YES) || !isfinite(time) || time < 0) return;
    // YouTube may report time many times per second. Five samples per second is
    // enough for captions; rendering still happens only when the cue changes.
    if (time >= self.lastSubmittedTime && time - self.lastSubmittedTime < 0.18) return;
    self.lastSubmittedTime = time;
    dispatch_async(self.workQueue, ^{
        self.latestPlaybackTime = time;
        [self renderAtTime:time];
    });
}

- (void)playerViewDidAppear {
    dispatch_async(self.workQueue, ^{
        self.playerVisible = YES;
        if (self.context && CIPreferenceBool(CIEnabledKey, YES)) {
            [self ensurePresenterForCurrentContext];
            self.displayedCueIndex = CIUnrenderedCueIndex;
            if (!self.loading) [self renderAtTime:self.latestPlaybackTime];
        }
        if (self.resolved && self.cues.count == 0 &&
            NSProcessInfo.processInfo.systemUptime >= self.contextActivatedAt + 5.4) {
            [self deliverNoResultToastForGeneration:self.generation
                                            videoID:self.context.videoID ?: @""];
        }
    });
}

- (void)playerViewDidDisappear {
    dispatch_async(self.workQueue, ^{
        self.playerVisible = NO;
    });
}

- (void)playbackDidFinish {
    dispatch_async(self.workQueue, ^{
        self.lastSubmittedTime = -DBL_MAX;
        self.displayedCueIndex = NSNotFound;
        if (self.context && CIPreferenceBool(CIEnabledKey, YES)) {
            [self.presenter hide];
        }
    });
}

- (void)setPlaybackSuppressed:(BOOL)suppressed {
    dispatch_async(self.workQueue, ^{
        if (self.suppressed == suppressed) return;
        self.suppressed = suppressed;
        if (suppressed) {
            if (self.loading) {
                self.loadInterruptedBySuppression = YES;
                self.generation++;
                [self.captionTask cancel];
                self.captionTask = nil;
                [self.lyricsProvider cancel];
                self.loading = NO;
                self.resolved = NO;
                self.loadStage = CILoadStageIdle;
            }
            self.displayedCueIndex = NSNotFound;
            [self.presenter hide];
        }
        else if (self.loadInterruptedBySuppression && self.context) {
            self.loadInterruptedBySuppression = NO;
            [self beginContext:self.context force:YES];
        } else {
            [self renderAtTime:self.latestPlaybackTime];
        }
    });
}

- (void)reloadPreferences {
    dispatch_async(self.workQueue, ^{
        [self.cache removeAllObjects];
        if (self.context && self.suppressed) {
            self.loadInterruptedBySuppression = YES;
        } else if (self.context) {
            [self beginContext:self.context force:YES];
        }
        else [self.presenter end];
    });
}

- (void)stop {
    dispatch_async(self.workQueue, ^{
        self.generation++;
        [self.captionTask cancel];
        [self.lyricsProvider cancel];
        self.context = nil;
        self.cues = @[];
        self.activePlainLyrics = @"";
        self.loading = NO;
        self.resolved = NO;
        self.loadStage = CILoadStageIdle;
        self.loadInterruptedBySuppression = NO;
        self.playerVisible = NO;
        self.displayedCueIndex = CIUnrenderedCueIndex;
        [self.presenter end];
    });
}

@end
