#import "CICaptionCoordinator.h"
#import "CIActivityPresenter.h"
#import "CICaptionParser.h"
#import "CICaptionTiming.h"
#import "CIConstants.h"
#import "CILRCLIBProvider.h"
#import "CILogStore.h"
#import "CILyricsAligner.h"
#import "CITextUtilities.h"
#import "CIToastPresenter.h"
#import "CIYouTubeInspector.h"
#import "CIVideoEligibility.h"
#import "CIVideoOverrides.h"
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
static const NSTimeInterval CILRCLIBContextSettleDelay = 0.9;

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
@property (nonatomic) NSTimeInterval activeCaptionAdvanceSeconds;
@property (nonatomic) BOOL suppressed;
@property (nonatomic) BOOL loadInterruptedBySuppression;
@property (atomic) BOOL policyExcluded;
@property (nonatomic) BOOL playerVisible;
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL resolved;
@property (nonatomic) CILoadStage loadStage;
@property (nonatomic, copy) NSString *activePlainLyrics;
@property (nonatomic, copy) NSString *lastLRCLIBQueryKey;
@property (nonatomic, copy) NSString *lastNoResultVideoID;
@property (nonatomic, copy) NSString *policyExclusionSignature;
@property (nonatomic) NSUInteger captionRequestToken;
@property (nonatomic) NSTimeInterval contextActivatedAt;
@property (nonatomic) NSTimeInterval lastExternalPreparationUptime;
@property (nonatomic, strong, nullable) dispatch_source_t cueBoundaryTimer;
@property (nonatomic) NSUInteger cueBoundaryGeneration;
@property (nonatomic) NSTimeInterval scheduledCueBoundaryTime;
@property (nonatomic) NSTimeInterval playbackAnchorTime;
@property (nonatomic) NSTimeInterval playbackAnchorUptime;
@property (nonatomic) BOOL playbackAdvancing;
@property (nonatomic) BOOL didLogCueBoundaryScheduler;
@property (nonatomic) BOOL youtubeSourcesExhausted;
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
- (void)loadLRCLIBLyricsForContext:(CIVideoContext *)context
                        generation:(NSUInteger)generation
                          cacheKey:(NSString *)cacheKey;
- (void)fetchLRCLIBCandidates:(NSArray<CISongQuery *> *)candidates
                      context:(CIVideoContext *)context
                   generation:(NSUInteger)generation
                     cacheKey:(NSString *)cacheKey;
- (void)loadManualCCForContext:(CIVideoContext *)context
                    generation:(NSUInteger)generation
                      cacheKey:(NSString *)cacheKey
               ASRFallbackCues:(NSArray<CICaptionCue *> *)ASRFallbackCues;
- (void)loadASRForContext:(CIVideoContext *)context
               generation:(NSUInteger)generation
                  cacheKey:(NSString *)cacheKey;
- (void)fallbackAfterLRCLIBForContext:(CIVideoContext *)context
                           generation:(NSUInteger)generation
                             cacheKey:(NSString *)cacheKey;
- (void)fallbackAfterYouTubeForContext:(CIVideoContext *)context
                            generation:(NSUInteger)generation
                              cacheKey:(NSString *)cacheKey;
- (void)fetchTrack:(CICaptionTrack *)track
        requestURLs:(NSArray<NSURL *> *)requestURLs
              index:(NSUInteger)index
              token:(NSUInteger)token
         generation:(NSUInteger)generation
         completion:(void (^)(NSArray<CICaptionCue *> *cues))completion;
- (void)cancelCueBoundaryTimer;
- (NSTimeInterval)estimatedAdvancingPlaybackTime;
- (void)scheduleCueBoundaryFromPlaybackTime:(NSTimeInterval)time;
- (NSTimeInterval)nextCueBoundaryAfterPlaybackTime:
    (NSTimeInterval)time;
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
        _policyExclusionSignature = @"";
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
        if (!self.context ||
            !CIPreferenceBool(CIEnabledKey, YES)) return;
        if (self.policyExcluded) {
            [self.presenter end];
            return;
        }
        [self ensurePresenterForCurrentContext];
        self.displayedCueIndex = CIUnrenderedCueIndex;
        if (!self.loading) [self renderAtTime:self.latestPlaybackTime];
    });
}

- (void)ensurePresenterForCurrentContext {
    if (!self.context.videoID.length || self.policyExcluded) return;
    if ([self.presenter respondsToSelector:@selector(ensureVideoID:title:)]) {
        [self.presenter ensureVideoID:self.context.videoID title:self.context.title ?: @""];
    } else {
        [self.presenter beginVideoID:self.context.videoID title:self.context.title ?: @""];
    }
}

- (void)effectiveLRCLIBMetadataForContext:(CIVideoContext *)context
                                    title:(NSString * __autoreleasing *)title
                                   artist:(NSString * __autoreleasing *)artist {
    NSString *automaticTitle = @"";
    NSString *automaticArtist = @"";
    CISplitSongMetadata(
        context.title,
        context.author,
        &automaticTitle,
        &automaticArtist
    );
    CIVideoOverride *override =
        CIVideoOverrideForVideoID(context.videoID);
    NSString *effectiveTitle = override.searchTitle.length > 0
        ? override.searchTitle : automaticTitle;
    NSString *effectiveArtist;
    if (override.searchArtist.length > 0) {
        effectiveArtist = override.searchArtist;
    } else if (override.searchTitle.length > 0) {
        // A custom title with an intentionally empty artist means title-only
        // lookup. This gives the settings UI a deterministic way to suppress
        // an incorrect automatically inferred artist.
        effectiveArtist = @"";
    } else {
        effectiveArtist = automaticArtist;
    }
    if (title) *title = effectiveTitle ?: @"";
    if (artist) *artist = effectiveArtist ?: @"";
}

// The readings of this video's title to offer LRCLIB, most likely first.
//
// A title the user typed into the override screen is a decision, not a guess, so
// it is searched on its own — expanding it into alternative readings would spend
// requests second-guessing an answer that was already given. Only an
// automatically parsed title fans out.
- (NSArray<CISongQuery *> *)LRCLIBReadingsForContext:
    (CIVideoContext *)context {
    CIVideoOverride *override =
        CIVideoOverrideForVideoID(context.videoID);
    if (override.searchTitle.length > 0) {
        NSString *title = @"";
        NSString *artist = @"";
        [self effectiveLRCLIBMetadataForContext:context
                                          title:&title
                                         artist:&artist];
        return @[[CISongQuery queryWithTitle:title
                                     artist:artist
                                     origin:@"override"]];
    }
    return CISongQueryCandidates(context.title, context.author);
}

- (NSArray<NSString *> *)captionLanguagePrioritiesForContext:
    (CIVideoContext *)context {
    CIVideoOverride *override =
        CIVideoOverrideForVideoID(context.videoID);
    return override.captionLanguagePriorities.count > 0
        ? override.captionLanguagePriorities
        : CICaptionLanguagePriorities();
}

- (CIVideoCaptionSourcePreference)captionSourcePreferenceForContext:
    (CIVideoContext *)context {
    return CIVideoOverrideForVideoID(context.videoID).captionSourcePreference;
}

- (NSString *)cacheKeyForContext:(CIVideoContext *)context {
    BOOL external = CIPreferenceBool(CIExternalLyricsEnabledKey, YES);
    NSString *queryTitle = @"";
    NSString *queryArtist = @"";
    [self effectiveLRCLIBMetadataForContext:context
                                      title:&queryTitle
                                     artist:&queryArtist];
    CIVideoOverride *override =
        CIVideoOverrideForVideoID(context.videoID);
    NSString *languages = [[self
        captionLanguagePrioritiesForContext:context]
        componentsJoinedByString:@","];
    return [NSString stringWithFormat:@"%@|%@|%@|%d|%ld|%ld|%@|%@|%.3f",
        context.videoID,
        languages,
        CILRCLIBBaseURL(),
        external,
        (long)CISourcePriority(),
        (long)override.captionSourcePreference,
        CINormalizedText(queryTitle),
        CINormalizedText(queryArtist),
        override.captionAdvanceSeconds];
}

- (NSString *)LRCLIBQueryKeyForContext:(CIVideoContext *)context {
    if (context.videoID.length == 0) return @"";
    return [NSString stringWithFormat:@"%@|%@",
        context.videoID, CILRCLIBBaseURL()];
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

- (void)currentVideoContextWithCompletion:
    (void (^)(CIVideoContext * _Nullable context))completion {
    if (!completion) return;
    dispatch_async(self.workQueue, ^{
        CIVideoContext *snapshot = nil;
        if (self.context.videoID.length > 0) {
            snapshot = [CIVideoContext new];
            snapshot.videoID = self.context.videoID ?: @"";
            snapshot.title = self.context.title ?: @"";
            snapshot.author = self.context.author ?: @"";
            snapshot.duration = self.context.duration;
            snapshot.shorts = self.context.isShorts;
            snapshot.captionTracks = self.context.captionTracks ?: @[];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(snapshot);
        });
    });
}

- (BOOL)excludeContextIfNeeded:(CIVideoContext *)context {
    CIVideoExclusionReason reason = CIVideoExclusionReasonNone;
    NSInteger maximumMinutes = CIMaximumVideoDurationMinutes();
    BOOL featureEnabled = CIPreferenceBool(CIEnabledKey, YES);
    if (featureEnabled) {
        reason = CIVideoExclusionReasonForPlayback(
            context.isShorts,
            CIPreferenceBool(CIDisableForShortsKey, YES),
            context.duration,
            maximumMinutes
        );
    }
    if (reason == CIVideoExclusionReasonNone) {
        if (self.policyExcluded) {
            self.policyExcluded = NO;
            self.policyExclusionSignature = @"";
            self.lastNoResultVideoID = @"";
            if (featureEnabled) {
                CIPipelineLog(CILogLevelInfo,
                    @"Caption activity is eligible again for video %@ after a settings or metadata change.",
                    context.videoID);
            }
        }
        return NO;
    }

    NSString *signature = [NSString stringWithFormat:@"%@|%ld|%ld",
        context.videoID, (long)reason, (long)maximumMinutes];
    BOOL exclusionChanged =
        !self.policyExcluded ||
        ![self.policyExclusionSignature isEqualToString:signature];
    self.context = context;
    self.policyExcluded = YES;
    self.policyExclusionSignature = signature;
    if (!exclusionChanged) return YES;

    self.generation++;
    [self.captionTask cancel];
    self.captionTask = nil;
    [self.lyricsProvider cancel];
    self.cues = @[];
    self.activePlainLyrics = @"";
    self.loading = NO;
    self.resolved = YES;
    self.loadStage = CILoadStageFinished;
    self.loadInterruptedBySuppression = NO;
    self.activeCaptionAdvanceSeconds = 0;
    self.playbackAdvancing = NO;
    [self cancelCueBoundaryTimer];
    self.youtubeSourcesExhausted = NO;
    self.displayedCueIndex = CIUnrenderedCueIndex;
    if (UIApplication.sharedApplication.applicationState ==
        UIApplicationStateActive) {
        [self.presenter end];
    } else {
        // Keep an already-running activity dormant during background
        // autoplay. ActivityKit cannot ordinarily start a replacement from
        // the background when the next eligible video begins.
        [self.presenter hide];
    }

    if (reason == CIVideoExclusionReasonShorts) {
        CIPipelineLog(CILogLevelInfo,
            @"Caption activity is disabled for Shorts video %@.",
            context.videoID);
    } else {
        CIPipelineLog(CILogLevelInfo,
            @"Caption activity is disabled for video %@ because its %.1f-minute duration exceeds the %ld-minute limit.",
            context.videoID, context.duration / 60.0, (long)maximumMinutes);
    }
    return YES;
}

- (void)beginContext:(CIVideoContext *)context force:(BOOL)force {
    BOOL sameVideo = [self.context.videoID isEqualToString:context.videoID];
    // A same-video metadata or caption-track refresh can race with the PiP
    // handoff after YouTube has stopped delivering foreground time callbacks.
    // Preserve the verified playback state across that reload; otherwise the
    // reset below cancels the only cue-boundary timer and the Live Activity
    // remains on the first post-PiP line indefinitely.
    BOOL preserveAdvancingPlayback =
        sameVideo && self.playbackAdvancing;
    NSTimeInterval preservedPlaybackTime =
        preserveAdvancingPlayback
            ? [self estimatedAdvancingPlaybackTime]
            : self.latestPlaybackTime;
    BOOL hasRicherTracks = context.captionTracks.count > self.context.captionTracks.count;
    BOOL hasRicherMetadata = context.title.length > self.context.title.length ||
        context.author.length > self.context.author.length ||
        (context.duration > 0 && self.context.duration <= 0) ||
        context.isShorts != self.context.isShorts;
    if (sameVideo) {
        if (context.title.length == 0) context.title = self.context.title;
        if (context.author.length == 0) context.author = self.context.author;
        if (self.context.duration > 0 && context.duration <= 0) context.duration = self.context.duration;
        context.shorts =
            context.isShorts || self.context.isShorts;
        context.captionTracks = CIMergedCaptionTracks(
            context.captionTracks, self.context.captionTracks);
    }
    BOOL wasPolicyExcluded = self.policyExcluded;
    if ([self excludeContextIfNeeded:context]) return;
    if (wasPolicyExcluded) force = YES;

    CICaptionTrack *oldManual = self.context
        ? [CIYouTubeInspector
            manualTrackInContext:self.context
            preferredLanguages:[self
                captionLanguagePrioritiesForContext:self.context]]
        : nil;
    CICaptionTrack *newManual = [CIYouTubeInspector
        manualTrackInContext:context
        preferredLanguages:[self
            captionLanguagePrioritiesForContext:context]];
    CICaptionTrack *oldASR = self.context
        ? [CIYouTubeInspector
            automaticTrackInContext:self.context
            preferredLanguages:[self
                captionLanguagePrioritiesForContext:self.context]]
        : nil;
    CICaptionTrack *newASR = [CIYouTubeInspector automaticTrackInContext:context
        preferredLanguages:[self
            captionLanguagePrioritiesForContext:context]];
    BOOL manualTrackChanged = newManual &&
        ![newManual.baseURL isEqualToString:oldManual.baseURL];
    BOOL ASRTrackChanged = newASR &&
        ![newASR.baseURL isEqualToString:oldASR.baseURL];
    hasRicherTracks = hasRicherTracks || manualTrackChanged || ASRTrackChanged;
    CIVideoCaptionSourcePreference videoSourcePreference =
        [self captionSourcePreferenceForContext:context];
    BOOL YouTubeFirst =
        videoSourcePreference != CIVideoCaptionSourcePreferenceInherit ||
        CISourcePriority() == CISourcePriorityYouTubeFirst;
    BOOL installedLRCLIB =
        self.source == CICaptionSourceLRCLIBSynced ||
        self.source == CICaptionSourceLRCLIBAligned ||
        self.source == CICaptionSourceLRCLIBEstimated;
    BOOL shouldRefreshYouTubeFallback =
        (manualTrackChanged &&
         ((self.loading && (self.loadStage == CILoadStageManualCC ||
                           self.loadStage == CILoadStageASR ||
                           (YouTubeFirst &&
                            (self.loadStage == CILoadStageLRCLIB ||
                             self.loadStage == CILoadStagePlainLyrics)))) ||
          (self.cues.count > 0 &&
           (self.source == CICaptionSourceYouTubeManual ||
            self.source == CICaptionSourceYouTubeASR ||
            (YouTubeFirst && installedLRCLIB))))) ||
        (ASRTrackChanged &&
         ((self.loading &&
           (self.loadStage == CILoadStageASR ||
            (YouTubeFirst &&
             (self.loadStage == CILoadStageLRCLIB ||
              self.loadStage == CILoadStagePlainLyrics)))) ||
          (self.cues.count > 0 &&
           (self.source == CICaptionSourceYouTubeASR ||
            (YouTubeFirst && installedLRCLIB)))));
    BOOL clockTrackChanged = manualTrackChanged || ASRTrackChanged;
    NSString *updatedLRCLIBKey = [self LRCLIBQueryKeyForContext:context];
    BOOL YouTubeSourceInControl =
        (self.loading &&
         (self.loadStage == CILoadStageManualCC ||
          self.loadStage == CILoadStageASR)) ||
        (self.cues.count > 0 &&
         (self.source == CICaptionSourceYouTubeManual ||
          self.source == CICaptionSourceYouTubeASR));
    BOOL shouldRetryLRCLIB = CIPreferenceBool(CIExternalLyricsEnabledKey, YES) &&
        !(YouTubeFirst && YouTubeSourceInControl) &&
        updatedLRCLIBKey.length > 0 &&
        ![updatedLRCLIBKey isEqualToString:self.lastLRCLIBQueryKey];
    BOOL shouldRefreshPlainTiming = !YouTubeFirst &&
        !shouldRetryLRCLIB &&
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
    if (YouTubeFirst && clockTrackChanged) {
        // A late higher-priority YouTube track may cancel an in-flight or
        // installed LRCLIB result. If that track is unusable, allow this
        // generation to query LRCLIB again instead of treating the cancelled
        // earlier attempt as a completed fallback.
        self.lastLRCLIBQueryKey = @"";
    }
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
    CIVideoOverride *override =
        CIVideoOverrideForVideoID(context.videoID);
    self.activeCaptionAdvanceSeconds =
        override.captionAdvanceSeconds;
    [self cancelCueBoundaryTimer];
    self.playbackAdvancing = preserveAdvancingPlayback;
    if (preserveAdvancingPlayback) {
        self.latestPlaybackTime = preservedPlaybackTime;
        self.playbackAnchorTime = preservedPlaybackTime;
        self.playbackAnchorUptime =
            NSProcessInfo.processInfo.systemUptime;
    }
    self.youtubeSourcesExhausted = NO;
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
    if (fabs(self.activeCaptionAdvanceSeconds) >= 0.001) {
        CIPipelineLog(CILogLevelInfo,
            @"Applying %.3fs caption advance for video %@ (positive is earlier).",
            self.activeCaptionAdvanceSeconds, context.videoID);
    }
    videoSourcePreference = override.captionSourcePreference;
    if (videoSourcePreference ==
        CIVideoCaptionSourcePreferenceManualCC) {
        CIPipelineLog(CILogLevelInfo,
            @"Per-video source override: selected YouTube CC → LRCLIB fallback.");
        [self loadManualCCForContext:context
                         generation:generation
                           cacheKey:cacheKey
                    ASRFallbackCues:@[]];
    } else if (videoSourcePreference ==
               CIVideoCaptionSourcePreferenceASR) {
        CIPipelineLog(CILogLevelInfo,
            @"Per-video source override: selected YouTube ASR → LRCLIB fallback.");
        [self loadASRForContext:context
                    generation:generation
                      cacheKey:cacheKey];
    } else if (CISourcePriority() == CISourcePriorityYouTubeFirst) {
        CIPipelineLog(CILogLevelInfo,
            @"Source priority: YouTube CC → YouTube ASR → LRCLIB.");
        [self loadManualCCForContext:context
                         generation:generation
                           cacheKey:cacheKey
                    ASRFallbackCues:@[]];
    } else {
        CIPipelineLog(CILogLevelInfo,
            @"Source priority: LRCLIB → YouTube CC → YouTube ASR.");
        [self loadLRCLIBLyricsForContext:context
                             generation:generation
                               cacheKey:cacheKey];
    }
}

- (void)loadLRCLIBLyricsForContext:(CIVideoContext *)context
                        generation:(NSUInteger)generation
                          cacheKey:(NSString *)cacheKey {
    if (generation != self.generation) return;
    self.loadStage = CILoadStageLRCLIB;
    if (!CIPreferenceBool(CIExternalLyricsEnabledKey, YES)) {
        [self fallbackAfterLRCLIBForContext:context
                                 generation:generation
                                   cacheKey:cacheKey];
        return;
    }
    // The user looked at this video's matches and rejected all of them. That is a
    // decision, not a failed lookup, so it is honoured before any request is made
    // and it never expires the way a cached miss does.
    if (CIVideoOverrideForVideoID(context.videoID).lyricsSuppressed) {
        CIPipelineLog(CILogLevelInfo,
            @"LRCLIB is switched off for this video by an explicit choice; skipping the lookup.");
        [self fallbackAfterLRCLIBForContext:context
                                 generation:generation
                                   cacheKey:cacheKey];
        return;
    }

    NSString *songTitle = @"";
    [self effectiveLRCLIBMetadataForContext:context
                                      title:&songTitle
                                     artist:NULL];
    if (songTitle.length == 0) {
        [self fallbackAfterLRCLIBForContext:context
                                 generation:generation
                                   cacheKey:cacheKey];
        return;
    }
    NSString *queryKey = [self LRCLIBQueryKeyForContext:context];
    if ([self.lastLRCLIBQueryKey isEqualToString:queryKey]) {
        [self fallbackAfterLRCLIBForContext:context
                                 generation:generation
                                   cacheKey:cacheKey];
        return;
    }
    self.lastLRCLIBQueryKey = queryKey;
    CIPipelineLog(CILogLevelDebug,
        @"Waiting %.1fs for stable LRCLIB metadata before using the one-request video budget.",
        CILRCLIBContextSettleDelay);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(CILRCLIBContextSettleDelay * NSEC_PER_SEC)),
        self.workQueue, ^{
        if (generation != self.generation) return;
        CIVideoContext *latestContext = self.context ?: context;
        NSString *latestTitle = @"";
        [self effectiveLRCLIBMetadataForContext:latestContext
                                          title:&latestTitle
                                         artist:NULL];
        NSString *latestCacheKey =
            [self cacheKeyForContext:latestContext];
        if (latestTitle.length == 0) {
            [self fallbackAfterLRCLIBForContext:latestContext
                                     generation:generation
                                       cacheKey:latestCacheKey];
            return;
        }
        NSArray<CISongQuery *> *candidates =
            [self LRCLIBReadingsForContext:latestContext];
        NSMutableArray<NSString *> *descriptions =
            [NSMutableArray arrayWithCapacity:candidates.count];
        for (CISongQuery *candidate in candidates) {
            [descriptions addObject:candidate.artist.length > 0
                ? [NSString stringWithFormat:@"%@:\"%@\"/\"%@\"",
                    candidate.origin, candidate.title, candidate.artist]
                : [NSString stringWithFormat:@"%@:\"%@\"",
                    candidate.origin, candidate.title]];
        }
        CIPipelineLog(CILogLevelInfo,
            @"LRCLIB lookup over %lu reading(s) of the title (video %.1fs): %@",
            (unsigned long)candidates.count, latestContext.duration,
            [descriptions componentsJoinedByString:@", "]);
        [self fetchLRCLIBCandidates:candidates
                            context:latestContext
                         generation:generation
                           cacheKey:latestCacheKey];
    });
}

- (void)fetchLRCLIBCandidates:(NSArray<CISongQuery *> *)candidates
                      context:(CIVideoContext *)context
                   generation:(NSUInteger)generation
                     cacheKey:(NSString *)cacheKey {
    if (generation != self.generation) return;
    __weak typeof(self) weakSelf = self;
    [self.lyricsProvider fetchLyricsForCandidates:candidates
                                        duration:context.duration
                                  completion:^(CILRCLIBResult *result, NSError *error) {
        dispatch_async(weakSelf.workQueue, ^{
            typeof(self) self = weakSelf;
            if (!self || generation != self.generation) return;
            if (!result) {
                CIPipelineLog(CILogLevelInfo, @"LRCLIB lookup returned no match: %@",
                    error.localizedDescription ?: @"unknown error");
                [self fallbackAfterLRCLIBForContext:self.context ?: context
                                         generation:generation
                                           cacheKey:cacheKey];
                return;
            }
            CIPipelineLog(CILogLevelInfo,
                @"Selected source LRCLIB %@%@: #%ld %@ — %@ (%.1fs, delta %.1fs)",
                result.syncedCues.count > 0 ? @"Synced" : @"Plain",
                result.fromPersistentCache ? @" [persistent cache]" : @"",
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

- (void)fallbackAfterLRCLIBForContext:(CIVideoContext *)context
                           generation:(NSUInteger)generation
                             cacheKey:(NSString *)cacheKey {
    if (generation != self.generation) return;
    BOOL videoPrefersYouTube =
        [self captionSourcePreferenceForContext:context] !=
            CIVideoCaptionSourcePreferenceInherit;
    if ((videoPrefersYouTube ||
         CISourcePriority() == CISourcePriorityYouTubeFirst) &&
        self.youtubeSourcesExhausted) {
        [self finishWithoutCaptionsForGeneration:generation];
        return;
    }
    [self loadManualCCForContext:context
                     generation:generation
                       cacheKey:cacheKey
                ASRFallbackCues:@[]];
}

- (void)fallbackAfterYouTubeForContext:(CIVideoContext *)context
                            generation:(NSUInteger)generation
                              cacheKey:(NSString *)cacheKey {
    if (generation != self.generation) return;
    BOOL videoPrefersYouTube =
        [self captionSourcePreferenceForContext:context] !=
            CIVideoCaptionSourcePreferenceInherit;
    if ((videoPrefersYouTube ||
         CISourcePriority() == CISourcePriorityYouTubeFirst) &&
        CIPreferenceBool(CIExternalLyricsEnabledKey, YES) &&
        !self.youtubeSourcesExhausted) {
        self.youtubeSourcesExhausted = YES;
        [self loadLRCLIBLyricsForContext:context
                             generation:generation
                               cacheKey:cacheKey];
        return;
    }
    [self finishWithoutCaptionsForGeneration:generation];
}

- (void)loadPlainLyrics:(NSString *)lyrics
                context:(CIVideoContext *)context
             generation:(NSUInteger)generation
               cacheKey:(NSString *)cacheKey {
    if (generation != self.generation) return;
    self.loadStage = CILoadStagePlainLyrics;
    self.activePlainLyrics = lyrics ?: @"";
    if (CINonEmptyLines(lyrics).count == 0) {
        [self fallbackAfterLRCLIBForContext:context
                                 generation:generation
                                   cacheKey:cacheKey];
        return;
    }
    NSArray<NSString *> *languages =
        [self captionLanguagePrioritiesForContext:context];
    CICaptionTrack *ASR = [CIYouTubeInspector
        automaticTrackInContext:context
        preferredLanguages:languages];
    CICaptionTrack *manual = [CIYouTubeInspector
        manualTrackInContext:context
        preferredLanguages:languages];
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
            [self fallbackAfterLRCLIBForContext:context
                                     generation:generation
                                       cacheKey:cacheKey];
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
    CICaptionTrack *manual = [CIYouTubeInspector
        manualTrackInContext:context
        preferredLanguages:[self
            captionLanguagePrioritiesForContext:context]];
    CICaptionResult *cached = [self.cache objectForKey:cacheKey];
    if (manual && cached.cues.count > 0 &&
        cached.source == CICaptionSourceYouTubeManual) {
        [self installCues:cached.cues source:cached.source generation:generation cacheKey:nil];
        return;
    }
    if (!manual) {
        if ([self captionSourcePreferenceForContext:context] ==
            CIVideoCaptionSourcePreferenceManualCC) {
            [self fallbackAfterYouTubeForContext:context
                                      generation:generation
                                        cacheKey:cacheKey];
        } else if (ASRFallbackCues.count > 0) {
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
        } else if ([self captionSourcePreferenceForContext:
                        self.context ?: context] ==
                   CIVideoCaptionSourcePreferenceManualCC) {
            [self fallbackAfterYouTubeForContext:self.context ?: context
                                      generation:generation
                                        cacheKey:cacheKey];
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
    CICaptionTrack *ASR = [CIYouTubeInspector
        automaticTrackInContext:context
        preferredLanguages:[self
            captionLanguagePrioritiesForContext:context]];
    if (!ASR) {
        NSTimeInterval contextAge =
            NSProcessInfo.processInfo.systemUptime -
            self.contextActivatedAt;
        BOOL selectedASR =
            [self captionSourcePreferenceForContext:context] ==
                CIVideoCaptionSourcePreferenceASR;
        if ((selectedASR ||
             CISourcePriority() == CISourcePriorityYouTubeFirst) &&
            !self.youtubeSourcesExhausted &&
            contextAge < 0.8) {
            NSTimeInterval delay = 0.8 - MAX(0, contextAge);
            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    (int64_t)(delay * NSEC_PER_SEC)
                ),
                self.workQueue,
                ^{
                    if (generation != self.generation ||
                        self.loadStage != CILoadStageASR) return;
                    if (selectedASR) {
                        [self loadASRForContext:self.context ?: context
                                    generation:generation
                                      cacheKey:cacheKey];
                    } else {
                        [self loadManualCCForContext:
                                self.context ?: context
                                             generation:generation
                                               cacheKey:cacheKey
                                        ASRFallbackCues:@[]];
                    }
                }
            );
            return;
        }
        CIPipelineLog(CILogLevelInfo,
            @"No source YouTube ASR track found among %lu caption track(s) for %@",
            (unsigned long)context.captionTracks.count, context.videoID);
        [self fallbackAfterYouTubeForContext:context
                                  generation:generation
                                    cacheKey:cacheKey];
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
            [self fallbackAfterYouTubeForContext:self.context ?: context
                                      generation:generation
                                        cacheKey:cacheKey];
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
    if (self.playbackAdvancing) {
        self.latestPlaybackTime =
            [self estimatedAdvancingPlaybackTime];
    }
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
    if (self.playbackAdvancing) {
        [self scheduleCueBoundaryFromPlaybackTime:
            self.latestPlaybackTime];
    }
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
        self.policyExcluded ||
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
    if (!CIPreferenceBool(CIEnabledKey, YES) || self.policyExcluded) return;
    if (self.suppressed) {
        if (self.displayedCueIndex != NSNotFound) {
            self.displayedCueIndex = NSNotFound;
            [self.presenter hide];
        }
        return;
    }
    NSTimeInterval advance = self.activeCaptionAdvanceSeconds;
    NSTimeInterval effectiveTime =
        CIAdjustedCaptionLookupTime(time, advance);
    NSInteger index = [self cueIndexAtTime:effectiveTime];
    if (index == self.displayedCueIndex) return;
    self.displayedCueIndex = index;
    if (index == NSNotFound) [self.presenter hide];
    else {
        CICaptionCue *cue = self.cues[(NSUInteger)index];
        NSUInteger nextIndex = (NSUInteger)index + 1;
        CICaptionCue *nextCue = nextIndex < self.cues.count
            ? self.cues[nextIndex] : nil;
        NSTimeInterval shiftedCueStart =
            CIAdjustedCaptionBoundary(cue.startTime, advance);
        NSTimeInterval shiftedCueEnd =
            MAX(shiftedCueStart + 0.05, cue.endTime - advance);
        NSTimeInterval shiftedNextCueStart = nextCue
            ? CIAdjustedCaptionBoundary(nextCue.startTime, advance) : 0;
        NSTimeInterval shiftedNextCueEnd = nextCue
            ? MAX(shiftedNextCueStart + 0.05,
                  nextCue.endTime - advance) : 0;
        SEL extendedSelector =
            @selector(presentText:source:cueStart:cueEnd:position:nextText:nextCueStart:nextCueEnd:);
        if ([self.presenter respondsToSelector:extendedSelector]) {
            [self.presenter presentText:cue.text
                                 source:self.source
                               cueStart:shiftedCueStart
                                 cueEnd:shiftedCueEnd
                               position:time
                               nextText:nextCue.text ?: @""
                           nextCueStart:shiftedNextCueStart
                             nextCueEnd:shiftedNextCueEnd];
        } else {
            [self.presenter presentText:cue.text
                                 source:self.source
                               cueStart:shiftedCueStart
                                 cueEnd:shiftedCueEnd
                               position:time];
        }
    }
}

- (void)updatePlaybackTime:(NSTimeInterval)time {
    [self updatePlaybackTime:time playing:YES];
}

- (void)updatePlaybackTime:(NSTimeInterval)time
                   playing:(BOOL)playing {
    if (!CIPreferenceBool(CIEnabledKey, YES) ||
        self.policyExcluded || !isfinite(time) || time < 0) return;
    dispatch_async(self.workQueue, ^{
        BOOL playbackStateChanged =
            self.playbackAdvancing != playing;
        // YouTube may report time many times per second. Five samples per
        // second is enough to keep the wall-clock anchor accurate; ActivityKit
        // is still updated only when the cue changes.
        if (!playbackStateChanged &&
            time >= self.lastSubmittedTime &&
            time - self.lastSubmittedTime < 0.18) return;
        self.lastSubmittedTime = time;
        self.latestPlaybackTime = time;
        self.playbackAdvancing = playing;
        self.playbackAnchorTime = time;
        self.playbackAnchorUptime =
            NSProcessInfo.processInfo.systemUptime;
        [self renderAtTime:time];
        if (playing) {
            [self scheduleCueBoundaryFromPlaybackTime:time];
        } else {
            [self cancelCueBoundaryTimer];
        }
    });
}

- (NSTimeInterval)nextCueBoundaryAfterPlaybackTime:
    (NSTimeInterval)time {
    if (self.cues.count == 0 || !isfinite(time) || time < 0) {
        return DBL_MAX;
    }
    NSTimeInterval effectiveTime =
        CIAdjustedCaptionLookupTime(
            time,
            self.activeCaptionAdvanceSeconds
        );
    NSInteger currentIndex =
        [self cueIndexAtTime:effectiveTime];
    NSTimeInterval boundary = DBL_MAX;
    if (currentIndex != NSNotFound) {
        CICaptionCue *currentCue =
            self.cues[(NSUInteger)currentIndex];
        NSTimeInterval currentEnd = MAX(
            CIAdjustedCaptionBoundary(
                currentCue.startTime,
                self.activeCaptionAdvanceSeconds
            ) + 0.05,
            currentCue.endTime -
                self.activeCaptionAdvanceSeconds
        );
        if (currentEnd > time + 0.01) {
            boundary = currentEnd;
        }
    }

    // A following cue may overlap the current cue. In that case the binary
    // lookup switches at the following start, before the current end.
    NSInteger low = 0;
    NSInteger high = (NSInteger)self.cues.count;
    while (low < high) {
        NSInteger middle = low + (high - low) / 2;
        CICaptionCue *cue = self.cues[(NSUInteger)middle];
        NSTimeInterval shiftedStart =
            CIAdjustedCaptionBoundary(
                cue.startTime,
                self.activeCaptionAdvanceSeconds
            );
        if (shiftedStart <= time + 0.01) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    if (low < (NSInteger)self.cues.count) {
        CICaptionCue *nextCue = self.cues[(NSUInteger)low];
        NSTimeInterval nextStart =
            CIAdjustedCaptionBoundary(
                nextCue.startTime,
                self.activeCaptionAdvanceSeconds
            );
        boundary = MIN(boundary, nextStart);
    }
    return boundary;
}

- (void)cancelCueBoundaryTimer {
    self.cueBoundaryGeneration++;
    dispatch_source_t timer = self.cueBoundaryTimer;
    if (timer) {
        dispatch_source_cancel(timer);
        self.cueBoundaryTimer = nil;
    }
    self.scheduledCueBoundaryTime = 0;
}

- (NSTimeInterval)estimatedAdvancingPlaybackTime {
    NSTimeInterval time = self.latestPlaybackTime;
    if (!self.playbackAdvancing ||
        self.playbackAnchorUptime <= 0) return time;
    NSTimeInterval uptime =
        NSProcessInfo.processInfo.systemUptime;
    NSTimeInterval estimate =
        self.playbackAnchorTime +
        MAX(0, uptime - self.playbackAnchorUptime);
    return isfinite(estimate) && estimate >= 0
        ? MAX(time, estimate) : time;
}

- (void)scheduleCueBoundaryFromPlaybackTime:
    (NSTimeInterval)time {
    if (!self.playbackAdvancing || self.suppressed ||
        self.policyExcluded || self.cues.count == 0) {
        [self cancelCueBoundaryTimer];
        return;
    }
    NSTimeInterval boundary =
        [self nextCueBoundaryAfterPlaybackTime:time];
    if (!isfinite(boundary) || boundary == DBL_MAX) {
        [self cancelCueBoundaryTimer];
        return;
    }
    NSTimeInterval delay = boundary - time;
    if (delay < 0.02) delay = 0.02;
    if (delay > 3600) {
        [self cancelCueBoundaryTimer];
        return;
    }
    if (self.cueBoundaryTimer &&
        fabs(self.scheduledCueBoundaryTime - boundary) < 0.04) {
        return;
    }

    [self cancelCueBoundaryTimer];
    NSUInteger generation = self.cueBoundaryGeneration;
    self.scheduledCueBoundaryTime = boundary;
    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER,
        0,
        0,
        self.workQueue
    );
    if (!timer) return;
    self.cueBoundaryTimer = timer;
    dispatch_source_set_timer(
        timer,
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)llround(delay * NSEC_PER_SEC)
        ),
        DISPATCH_TIME_FOREVER,
        (uint64_t)(0.03 * NSEC_PER_SEC)
    );
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        typeof(self) self = weakSelf;
        if (!self ||
            generation != self.cueBoundaryGeneration ||
            self.cueBoundaryTimer != timer) return;
        self.cueBoundaryTimer = nil;
        self.scheduledCueBoundaryTime = 0;
        if (!self.playbackAdvancing) return;

        NSTimeInterval uptime =
            NSProcessInfo.processInfo.systemUptime;
        NSTimeInterval estimatedTime =
            self.playbackAnchorTime +
            MAX(0, uptime - self.playbackAnchorUptime);
        // Ensure floating-point rounding cannot leave the lookup on the old
        // cue when the one-shot fires exactly at the boundary.
        estimatedTime = MAX(estimatedTime, boundary + 0.015);
        self.latestPlaybackTime = estimatedTime;
        self.lastSubmittedTime = estimatedTime;
        NSInteger previousIndex = self.displayedCueIndex;
        [self renderAtTime:estimatedTime];
        [self scheduleCueBoundaryFromPlaybackTime:estimatedTime];

        if (!self.didLogCueBoundaryScheduler) {
            self.didLogCueBoundaryScheduler = YES;
            [CILogStore.sharedStore recordLevel:CILogLevelInfo
                category:@"Background"
                message:@"Cue-boundary caption scheduling is active and no longer depends on ActivityKit staleDate."];
        }
        [CILogStore.sharedStore recordLevel:CILogLevelDebug
            category:@"Background"
            format:@"Cue boundary %.3fs fired at estimated playback %.3fs (cue %ld → %ld).",
                   boundary, estimatedTime,
                   (long)previousIndex,
                   (long)self.displayedCueIndex];
    });
    dispatch_resume(timer);
}

- (void)playerViewDidAppear {
    dispatch_async(self.workQueue, ^{
        self.playerVisible = YES;
        if (self.context && !self.policyExcluded &&
            CIPreferenceBool(CIEnabledKey, YES)) {
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

- (void)prepareForExternalPlayback {
    dispatch_async(self.workQueue, ^{
        if (!self.context || !CIPreferenceBool(CIEnabledKey, YES) ||
            self.suppressed || self.policyExcluded) return;
        NSTimeInterval uptime = NSProcessInfo.processInfo.systemUptime;
        if (self.lastExternalPreparationUptime > 0 &&
            uptime - self.lastExternalPreparationUptime < 1.0) return;
        self.lastExternalPreparationUptime = uptime;
        [self ensurePresenterForCurrentContext];
        self.displayedCueIndex = CIUnrenderedCueIndex;
        if (self.playbackAdvancing) {
            self.latestPlaybackTime =
                [self estimatedAdvancingPlaybackTime];
        }
        if (!self.loading) [self renderAtTime:self.latestPlaybackTime];
        if (self.playbackAdvancing) {
            [self scheduleCueBoundaryFromPlaybackTime:
                self.latestPlaybackTime];
        }
        if ([self.presenter respondsToSelector:
                @selector(refreshPresentationForReason:)]) {
            [self.presenter refreshPresentationForReason:
                @"external playback transition"];
        }
        [CILogStore.sharedStore recordLevel:CILogLevelInfo
            category:@"Background"
            message:@"Prepared caption activity for Lock Screen or Picture in Picture playback."];
    });
}

- (void)refreshPresentationForReason:(NSString *)reason {
    NSString *copiedReason = [reason copy] ?: @"presentation transition";
    dispatch_async(self.workQueue, ^{
        if (!self.context || self.policyExcluded || self.suppressed ||
            !CIPreferenceBool(CIEnabledKey, YES)) return;
        [self ensurePresenterForCurrentContext];
        self.displayedCueIndex = CIUnrenderedCueIndex;
        if (self.playbackAdvancing) {
            self.latestPlaybackTime =
                [self estimatedAdvancingPlaybackTime];
        }
        if (!self.loading) [self renderAtTime:self.latestPlaybackTime];
        if (self.playbackAdvancing) {
            [self scheduleCueBoundaryFromPlaybackTime:
                self.latestPlaybackTime];
        }
        if ([self.presenter respondsToSelector:
                @selector(refreshPresentationForReason:)]) {
            [self.presenter refreshPresentationForReason:copiedReason];
        }
    });
}

- (void)playbackDidFinish {
    dispatch_async(self.workQueue, ^{
        self.playbackAdvancing = NO;
        [self cancelCueBoundaryTimer];
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
            [self cancelCueBoundaryTimer];
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
            if (self.playbackAdvancing) {
                [self scheduleCueBoundaryFromPlaybackTime:
                    self.latestPlaybackTime];
            }
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
        self.activeCaptionAdvanceSeconds = 0;
        self.youtubeSourcesExhausted = NO;
        self.loading = NO;
        self.resolved = NO;
        self.loadStage = CILoadStageIdle;
        self.loadInterruptedBySuppression = NO;
        self.policyExcluded = NO;
        self.policyExclusionSignature = @"";
        self.playerVisible = NO;
        self.displayedCueIndex = CIUnrenderedCueIndex;
        self.playbackAdvancing = NO;
        [self cancelCueBoundaryTimer];
        [self.presenter end];
    });
}

@end
