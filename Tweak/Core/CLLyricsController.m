#import "Core/CLLyricsController.h"
#import "Core/CLNowPlayingSource.h"
#import "Lyrics/CLLyricsCache.h"
#import "Lyrics/CLProviderChain.h"
#import "Util/CLLog.h"
#import <os/lock.h>

static void CLControllerRunOnMain(dispatch_block_t block) {
    if (!block) return;
    if (NSThread.isMainThread) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

/// Observers are supplied by the UI layer and run inside a dispatch block with no handler above
/// it; inside CarPlayTemplateUIHost an escaping NSException aborts the whole process. One
/// observer that raises must not take down the others, or the host.
static void CLControllerSafePerform(NSString *what, dispatch_block_t block) {
    if (!block) return;
    @try {
        block();
    } @catch (NSException *exception) {
        CLLogError(@"[controller] %@ raised %@: %@", what ?: @"(work)", exception.name, exception.reason);
    }
}

/// Sync-engine tick while at least one display is on screen, and while none is. The idle value
/// is the engine's own maximum (CLLyricsSyncEngine clamps to 1 s), which is as slow as the tick
/// can go without stopping: a stopped clock would have to be caught up on resume, while a 1 Hz
/// one keeps the published line index within a second of the truth the whole time.
static const NSTimeInterval kCLDisplayActiveTick = 0.1;
static const NSTimeInterval kCLDisplayIdleTick = 1.0;

/// How long a track change waits for the rest of its metadata before looking anything up. Spotify
/// publishes a new track as a burst, and the new content identifier and duration can land before
/// the new title and artist: looking up that half-updated state costs three LRCLIB requests
/// (against a ~8 per minute budget) and writes a negative-cache entry for a song that does not exist.
static const NSTimeInterval kCLTrackSettleDelay = 0.3;

/// How long a new track may wait when it arrives still carrying the previous song's title and
/// artist. Spotify 9.1.82 on CarPlay delivers the real ones about a second after the new content
/// identifier (seen on every skip in one simulator session); the lookup runs as soon as they land,
/// and a song that genuinely shares its predecessor's title (a repeat, another version) is looked
/// up when this runs out.
static const NSTimeInterval kCLStaleMetadataWait = 1.5;

static BOOL CLSameTitleAndArtist(CLTrack *a, CLTrack *b) {
    if (!a || !b) return NO;
    NSStringCompareOptions options = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    return [(a.title ?: @"") compare:(b.title ?: @"") options:options] == NSOrderedSame &&
           [(a.artist ?: @"") compare:(b.artist ?: @"") options:options] == NSOrderedSame;
}

@implementation CLLyricsController {
    os_unfair_lock _lock;                      // guards everything in this first group
    CLPlaybackState *_currentState;
    CLLyrics *_currentLyrics;
    NSInteger _currentLineIndex;
    CLLyricsControllerStatus _status;
    NSArray<id<CLLyricsProvider>> *_providers;
    NSSet<NSString *> *_enabledBundleIdentifiers;
    NSMutableDictionary<NSString *, CLLyricsControllerObserverBlock> *_observers;

    // main queue only
    BOOL _started;
    CLLyricsSyncEngine *_syncEngine;
    CLProviderChain *_chain;
    id _sourceToken;
    id _activeResolutionToken;
    NSUInteger _resolveGeneration;
    /// The track the last lookup asked for. A later state for the same content identifier whose
    /// title or artist no longer match it is a metadata update that arrived late, and is looked up again.
    CLTrack *_lookedUpTrack;
    /// YES between -scheduleSettledLookupAfter: and its timer firing (or a teardown dropping it).
    BOOL _settledLookupPending;
    /// Set when a new content identifier arrived with the previous song's title and artist: those,
    /// so the real metadata is recognised the moment it differs from them.
    CLTrack *_staleMetadataTrack;
    dispatch_queue_t _lookupQueue;
    /// How many attached, un-paused displays are reading the line index (see -displayDidBecomeActive).
    NSInteger _activeDisplays;
    /// The two sync offsets; the engine gets the one that matches the current lyrics' source.
    NSTimeInterval _offset;
    NSTimeInterval _serviceOffset;
}

+ (instancetype)sharedController {
    static CLLyricsController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] initPrivate]; });
    return shared;
}

- (instancetype)initPrivate {
    self = [super init];
    if (!self) return nil;
    _lock = OS_UNFAIR_LOCK_INIT;
    _observers = [NSMutableDictionary dictionary];
    _providers = @[];
    _currentState = [CLPlaybackState emptyState];
    _currentLineIndex = CLLyricsNoLine;
    _status = CLLyricsControllerStatusIdle;
    _syncEngine = [[CLLyricsSyncEngine alloc] init];
    _lookupQueue = dispatch_queue_create("com.andi.carly.lookup", DISPATCH_QUEUE_SERIAL);
    return self;
}

#pragma mark - Published state (lock-protected readers)

- (CLPlaybackState *)currentState {
    os_unfair_lock_lock(&_lock);
    CLPlaybackState *state = _currentState;
    os_unfair_lock_unlock(&_lock);
    return state;
}

- (CLLyrics *)currentLyrics {
    os_unfair_lock_lock(&_lock);
    CLLyrics *lyrics = _currentLyrics;
    os_unfair_lock_unlock(&_lock);
    return lyrics;
}

- (NSInteger)currentLineIndex {
    os_unfair_lock_lock(&_lock);
    NSInteger index = _currentLineIndex;
    os_unfair_lock_unlock(&_lock);
    return index;
}

- (CLLyricsControllerStatus)status {
    os_unfair_lock_lock(&_lock);
    CLLyricsControllerStatus status = _status;
    os_unfair_lock_unlock(&_lock);
    return status;
}

- (BOOL)hasSyncedLyrics {
    CLLyrics *lyrics = self.currentLyrics;
    return lyrics.kind == CLLyricsKindSynced && lyrics.lines.count > 0;
}

- (CLLyricLine *)lineAtIndex:(NSInteger)index {
    NSArray<CLLyricLine *> *lines = self.currentLyrics.lines;
    if (index < 0 || index >= (NSInteger)lines.count) return nil;
    return lines[(NSUInteger)index];
}

- (NSTimeInterval)progressWithinCurrentLine {
    return [_syncEngine progressWithinCurrentLine];
}

- (BOOL)isStarted {
    return _started;
}

#pragma mark - Display gating

- (NSInteger)activeDisplayCount {
    return _activeDisplays;
}

- (void)displayDidBecomeActive {
    CLControllerRunOnMain(^{
        self->_activeDisplays += 1;
        if (self->_activeDisplays != 1) return;   // another display was already watching
        self->_syncEngine.tickInterval = kCLDisplayActiveTick;
        // The index may be up to one idle tick stale; correct it before anything draws it.
        [self->_syncEngine reevaluate];
        CLLogDebug(@"[controller] display active: sync tick %.2fs", kCLDisplayActiveTick);
    });
}

- (void)displayDidResignActive {
    CLControllerRunOnMain(^{
        if (self->_activeDisplays <= 0) {
            // Unbalanced call. Never let the count go negative: a negative count would swallow the
            // next -displayDidBecomeActive and leave the engine slow for the rest of the drive.
            self->_activeDisplays = 0;
            return;
        }
        self->_activeDisplays -= 1;
        if (self->_activeDisplays > 0) return;
        self->_syncEngine.tickInterval = kCLDisplayIdleTick;
        CLLogDebug(@"[controller] no display left: sync tick %.2fs", kCLDisplayIdleTick);
    });
}

#pragma mark - Observers

- (id)addObserver:(CLLyricsControllerObserverBlock)observer {
    if (!observer) return nil;
    NSString *token = NSUUID.UUID.UUIDString;
    CLLyricsControllerObserverBlock copied = [observer copy];
    os_unfair_lock_lock(&_lock);
    _observers[token] = copied;
    os_unfair_lock_unlock(&_lock);
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        CLLyricsController *strongSelf = weakSelf;
        if (!strongSelf) return;
        CLControllerSafePerform(@"initial observer callback", ^{
            copied(strongSelf, CLLyricsControllerChangePlayback | CLLyricsControllerChangeLyrics |
                               CLLyricsControllerChangeLine);
        });
    });
    return token;
}

- (void)removeObserver:(id)token {
    if (![token isKindOfClass:NSString.class]) return;
    os_unfair_lock_lock(&_lock);
    [_observers removeObjectForKey:token];
    os_unfair_lock_unlock(&_lock);
}

- (void)notifyObservers:(CLLyricsControllerChange)change {
    if (change == 0) return;
    os_unfair_lock_lock(&_lock);
    NSArray<CLLyricsControllerObserverBlock> *observers = _observers.allValues;
    os_unfair_lock_unlock(&_lock);
    if (observers.count == 0) return;
    CLControllerRunOnMain(^{
        for (CLLyricsControllerObserverBlock observer in observers) {
            CLControllerSafePerform(@"observer", ^{ observer(self, change); });
        }
    });
}

#pragma mark - Configuration

- (NSArray<id<CLLyricsProvider>> *)providers {
    os_unfair_lock_lock(&_lock);
    NSArray<id<CLLyricsProvider>> *providers = _providers;
    os_unfair_lock_unlock(&_lock);
    return providers;
}

- (void)setProviders:(NSArray<id<CLLyricsProvider>> *)providers {
    NSMutableArray<id<CLLyricsProvider>> *clean = [NSMutableArray array];
    for (id candidate in providers) {
        if ([candidate conformsToProtocol:@protocol(CLLyricsProvider)] &&
            [candidate respondsToSelector:@selector(fetchLyricsForTrack:completion:)]) {
            [clean addObject:candidate];
        } else if (candidate) {
            CLLogError(@"Ignoring provider %@: does not implement CLLyricsProvider", [candidate class]);
        }
    }
    NSArray<id<CLLyricsProvider>> *resolved = [clean copy];

    os_unfair_lock_lock(&_lock);
    _providers = resolved;
    os_unfair_lock_unlock(&_lock);

    CLControllerRunOnMain(^{
        self->_chain = resolved.count ? [[CLProviderChain alloc] initWithProviders:resolved] : nil;
        CLLogInfo(@"Providers: %@", [[resolved valueForKey:@"identifier"] componentsJoinedByString:@", "] ?: @"(none)");
        if (!self->_started) return;
        // A new provider set deserves a fresh look for anything we could not resolve before.
        if (!self.currentLyrics && self.currentState.hasTrackInfo) {
            [self resolveLyricsForState:self.currentState ignoringCache:YES];
        }
    });
}

- (NSSet<NSString *> *)enabledBundleIdentifiers {
    os_unfair_lock_lock(&_lock);
    NSSet<NSString *> *set = _enabledBundleIdentifiers;
    os_unfair_lock_unlock(&_lock);
    return set;
}

- (void)setEnabledBundleIdentifiers:(NSSet<NSString *> *)enabledBundleIdentifiers {
    NSSet<NSString *> *copied = nil;
    if ([enabledBundleIdentifiers isKindOfClass:NSSet.class]) copied = [enabledBundleIdentifiers copy];
    os_unfair_lock_lock(&_lock);
    _enabledBundleIdentifiers = copied;
    os_unfair_lock_unlock(&_lock);
    CLControllerRunOnMain(^{
        if (!self->_started) return;
        [self handlePlaybackState:self.currentState];
    });
}

- (NSTimeInterval)offset {
    return _offset;
}

- (void)setOffset:(NSTimeInterval)offset {
    CLControllerRunOnMain(^{
        self->_offset = offset;
        [self applyOffsetForLyrics:self.currentLyrics];
    });
}

- (NSTimeInterval)serviceOffset {
    return _serviceOffset;
}

- (void)setServiceOffset:(NSTimeInterval)serviceOffset {
    CLControllerRunOnMain(^{
        self->_serviceOffset = serviceOffset;
        [self applyOffsetForLyrics:self.currentLyrics];
    });
}

+ (BOOL)isServiceTimedSource:(NSString *)source {
    static NSSet<NSString *> *sources;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sources = [NSSet setWithArray:@[ @"spotify", @"spotify-cache", @"apple-music" ]]; });
    return source.length > 0 && [sources containsObject:source];
}

/// Main queue only. The engine re-evaluates the line itself when the value changes.
- (void)applyOffsetForLyrics:(CLLyrics *)lyrics {
    _syncEngine.offset = [CLLyricsController isServiceTimedSource:lyrics.source] ? _serviceOffset : _offset;
}

- (BOOL)isBundleEnabled:(NSString *)bundleIdentifier {
    NSSet<NSString *> *enabled = self.enabledBundleIdentifiers;
    if (!enabled) return YES;                        // nil = every app
    if (bundleIdentifier.length == 0) return NO;     // unknown app while a filter is set
    return [enabled containsObject:bundleIdentifier];
}

#pragma mark - Lifecycle

- (void)start {
    [self startSubscribingToSource:YES];
}

- (void)startDetached {
    [self startSubscribingToSource:NO];
}

- (void)ingestPlaybackState:(CLPlaybackState *)state {
    CLControllerRunOnMain(^{ [self handlePlaybackState:state]; });
}

- (void)startSubscribingToSource:(BOOL)subscribe {
    CLControllerRunOnMain(^{
        if (self->_started) return;
        self->_started = YES;

        __weak typeof(self) weakSelf = self;
        self->_syncEngine.onLineChanged = ^(NSInteger lineIndex) {
            CLLyricsController *strongSelf = weakSelf;
            if (!strongSelf) return;
            os_unfair_lock_lock(&strongSelf->_lock);
            strongSelf->_currentLineIndex = lineIndex;
            os_unfair_lock_unlock(&strongSelf->_lock);
            CLLogDebug(@"Line %ld", (long)lineIndex);
            [strongSelf notifyObservers:CLLyricsControllerChangeLine];
        };

        if (subscribe) {
            CLNowPlayingSource *source = CLNowPlayingSource.sharedSource;
            self->_sourceToken = [source addObserver:^(CLPlaybackState *state) {
                [weakSelf handlePlaybackState:state];
            }];
            [source start];
        }
        CLLogInfo(@"CLLyricsController started (providers=%lu, apps=%@%@)",
                  (unsigned long)self.providers.count,
                  self.enabledBundleIdentifiers ? [self.enabledBundleIdentifiers.allObjects componentsJoinedByString:@","] : @"all",
                  subscribe ? @"" : @", detached from the now-playing source");
    });
}

- (void)stop {
    CLControllerRunOnMain(^{
        if (!self->_started) return;
        self->_started = NO;
        // Only when we actually subscribed: -startDetached never touched the shared source, and
        // stopping it here would reach into MediaRemote on behalf of a controller that never used
        // it (the tests tool starts detached for exactly that reason).
        if (self->_sourceToken) {
            CLNowPlayingSource *source = CLNowPlayingSource.sharedSource;
            [source removeObserver:self->_sourceToken];
            self->_sourceToken = nil;
            [source stop];
        }
        [self cancelActiveResolution];
        [self->_syncEngine stop];
        self->_syncEngine.lines = nil;
        [self setLyrics:nil status:CLLyricsControllerStatusIdle];
        CLLogInfo(@"CLLyricsController stopped");
    });
}

#pragma mark - Playback handling (main queue only)

- (void)handlePlaybackState:(CLPlaybackState *)state {
    if (!state) return;
    os_unfair_lock_lock(&_lock);
    CLPlaybackState *previous = _currentState;
    _currentState = state;
    CLLyricsControllerStatus status = _status;
    os_unfair_lock_unlock(&_lock);
    [self notifyObservers:CLLyricsControllerChangePlayback];
    if (!_started) return;

    // "Nothing is playing" is idle, not disabled, whatever the app filter says: a stopped player
    // reports no bundle identifier either, and calling that "disabled for (unknown app)" would
    // both mislabel the state and log a line every time playback stops.
    if (!state.hasTrackInfo) {
        if (status != CLLyricsControllerStatusIdle) {
            [self teardownLyricsWithStatus:CLLyricsControllerStatusIdle];
        }
        return;
    }

    if (![self isBundleEnabled:state.bundleIdentifier]) {
        if (status != CLLyricsControllerStatusDisabled) {
            CLLogInfo(@"Lyrics disabled for %@", state.bundleIdentifier ?: @"(unknown app)");
            [self teardownLyricsWithStatus:CLLyricsControllerStatusDisabled];
        }
        return;
    }

    if (state.isAdvertisement) {
        if (status != CLLyricsControllerStatusIdle) {
            [self teardownLyricsWithStatus:CLLyricsControllerStatusIdle];
        }
        return;
    }

    [_syncEngine updateWithPlaybackState:state];

    BOOL sameSong = previous.hasTrackInfo && [previous isSameSongAs:state];
    // Same content identifier, different title or artist: CLPlaybackState deliberately calls that
    // the same song, but the lookup ran on the half-updated metadata and has to run again.
    BOOL metadataMoved = _lookedUpTrack && ![_lookedUpTrack isSameSongAs:state.track];
    BOOL needsLookup = !sameSong || metadataMoved ||
                       status == CLLyricsControllerStatusDisabled ||
                       status == CLLyricsControllerStatusIdle;

    NSString *previousIdentity = previous.contentIdentity;
    NSString *identity = state.contentIdentity;
    BOOL newIdentifier = previousIdentity.length > 0 && identity.length > 0 &&
                         ![previousIdentity isEqualToString:identity];
    if (newIdentifier && previous.hasTrackInfo && CLSameTitleAndArtist(previous.track, state.track)) {
        // A new track still wearing the previous one's title: wait for the real one.
        _staleMetadataTrack = previous.track;
    } else if (_staleMetadataTrack && !CLSameTitleAndArtist(_staleMetadataTrack, state.track)) {
        // The real title arrived: look it up now instead of waiting out kCLStaleMetadataWait.
        _staleMetadataTrack = nil;
        if (_settledLookupPending) [self scheduleSettledLookupAfter:kCLTrackSettleDelay];
    }

    // A pending lookup reads the newest state when it fires, so it already covers this one.
    if (needsLookup && !_settledLookupPending) {
        [self scheduleSettledLookupAfter:(_staleMetadataTrack ? kCLStaleMetadataWait : kCLTrackSettleDelay)];
    }
}

/// Main queue only. Takes the previous song's lyrics down now and looks up whatever is playing
/// `delay` from now. The generation bump is what drops the timer when a teardown, another
/// resolution or a reschedule gets there first.
- (void)scheduleSettledLookupAfter:(NSTimeInterval)delay {
    [self cancelActiveResolution];
    NSUInteger generation = ++_resolveGeneration;
    _settledLookupPending = YES;
    _syncEngine.lines = nil;
    [self setLyrics:nil status:CLLyricsControllerStatusLoading];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CLLyricsController *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_resolveGeneration) return;
        strongSelf->_settledLookupPending = NO;
        if (!strongSelf->_started) return;
        [strongSelf resolveLyricsForState:strongSelf.currentState ignoringCache:NO];
    });
}

/// Main queue only.
- (void)teardownLyricsWithStatus:(CLLyricsControllerStatus)status {
    [self cancelActiveResolution];
    _resolveGeneration++;
    _settledLookupPending = NO;
    _lookedUpTrack = nil;
    _staleMetadataTrack = nil;
    [_syncEngine stop];
    _syncEngine.lines = nil;
    [self setLyrics:nil status:status];
}

/// Main queue only. Publishes lyrics + status and notifies once.
- (void)setLyrics:(CLLyrics *)lyrics status:(CLLyricsControllerStatus)status {
    os_unfair_lock_lock(&_lock);
    BOOL changed = (_currentLyrics != lyrics) || (_status != status);
    _currentLyrics = lyrics;
    _status = status;
    if (!lyrics) _currentLineIndex = CLLyricsNoLine;
    os_unfair_lock_unlock(&_lock);
    if (changed) [self notifyObservers:CLLyricsControllerChangeLyrics | CLLyricsControllerChangeLine];
}

#pragma mark - Resolution (main queue only)

- (void)cancelActiveResolution {
    if (_activeResolutionToken && _chain) {
        [_chain cancel:_activeResolutionToken];
    }
    _activeResolutionToken = nil;
}

- (void)resolveLyricsForState:(CLPlaybackState *)state ignoringCache:(BOOL)ignoringCache {
    CLTrack *track = state.track;
    if (!track) {
        [self teardownLyricsWithStatus:CLLyricsControllerStatusIdle];
        return;
    }

    [self cancelActiveResolution];
    NSUInteger generation = ++_resolveGeneration;
    _settledLookupPending = NO;
    _lookedUpTrack = track;
    _syncEngine.lines = nil;
    [self setLyrics:nil status:CLLyricsControllerStatusLoading];
    CLLogInfo(@"Resolving lyrics for \"%@\" — %@ (%.0fs)%@", track.title, track.artist, track.duration,
              ignoringCache ? @" [cache bypassed]" : @"");

    if (ignoringCache) {
        [self startChainForTrack:track generation:generation];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(_lookupQueue, ^{
        // Off the main thread: the cache may hit the disk.
        CLLyrics *cached = [CLLyricsCache.sharedCache lyricsForTrack:track];
        dispatch_async(dispatch_get_main_queue(), ^{
            CLLyricsController *strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf->_resolveGeneration) return;
            if (cached) {
                CLLogInfo(@"Cache hit for \"%@\" (%@, %lu lines)", track.title,
                          cached.source ?: @"?", (unsigned long)cached.lines.count);
                [strongSelf applyLyrics:cached generation:generation];
            } else {
                [strongSelf startChainForTrack:track generation:generation];
            }
        });
    });
}

- (void)startChainForTrack:(CLTrack *)track generation:(NSUInteger)generation {
    CLProviderChain *chain = _chain;
    if (!chain) {
        CLLogInfo(@"No lyrics providers configured");
        [self applyLyrics:nil generation:generation];
        return;
    }

    __weak typeof(self) weakSelf = self;
    id token = [chain resolveLyricsForTrack:track completion:^(CLLyrics *lyrics, NSError *error) {
        CLControllerRunOnMain(^{
            CLLyricsController *strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf->_resolveGeneration) return;
            strongSelf->_activeResolutionToken = nil;
            if (error) {
                CLLogInfo(@"Lyrics lookup for \"%@\" failed: %@", track.title,
                          error.localizedDescription ?: error.domain);
            }
            if (lyrics) {
                CLLogInfo(@"Lyrics for \"%@\": kind=%ld source=%@ lines=%lu", track.title,
                          (long)lyrics.kind, lyrics.source ?: @"?", (unsigned long)lyrics.lines.count);
                // An all-miss carries an error when a provider failed transiently (LRCLIB 503/429,
                // no connectivity, a dropped request). Writing that into the negative cache would
                // pin "no lyrics" on the song for the whole negative TTL over a momentary blip, so
                // only a clean miss — every provider answered, none of them had it — is cached.
                // The same goes for plain text that came with an error: the provider that failed
                // might have had synced lines, so it is shown now and looked up again next time.
                BOOL definitive = lyrics.kind == CLLyricsKindSynced ||
                                  lyrics.kind == CLLyricsKindInstrumental;
                if (definitive || error == nil) {
                    [CLLyricsCache.sharedCache storeLyrics:lyrics forTrack:track];
                } else {
                    CLLogDebug(@"Not caching \"%@\" (kind=%ld): the result came with an error",
                               track.title, (long)lyrics.kind);
                }
            }
            [strongSelf applyLyrics:lyrics generation:generation];
        });
    }];
    _activeResolutionToken = token;
}

/// Main queue only.
- (void)applyLyrics:(CLLyrics *)lyrics generation:(NSUInteger)generation {
    if (generation != _resolveGeneration) return;

    BOOL usable = lyrics != nil && lyrics.kind != CLLyricsKindNone;
    CLLyrics *published = usable ? lyrics : nil;
    [self applyOffsetForLyrics:published];
    _syncEngine.lines = (published.kind == CLLyricsKindSynced) ? published.lines : nil;
    [_syncEngine updateWithPlaybackState:self.currentState];
    [self setLyrics:published
             status:usable ? CLLyricsControllerStatusLoaded : CLLyricsControllerStatusUnavailable];
}

#pragma mark - Actions

- (void)seekToLineAtIndex:(NSInteger)index {
    CLControllerRunOnMain(^{
        NSTimeInterval time = [self->_syncEngine playbackTimeForLineAtIndex:index];
        if (time < 0) return;
        CLLogInfo(@"Seeking to line %ld (%.2fs)", (long)index, time);
        [CLNowPlayingSource.sharedSource seekToTime:time];

        // Move our own clock straight away so the UI does not wait for the round trip.
        CLPlaybackState *state = self.currentState;
        if (state.hasTrackInfo) {
            CLPlaybackState *optimistic = [state stateByUpdatingElapsedTime:time
                                                                  timestamp:[NSDate date]
                                                               playbackRate:state.playbackRate
                                                                  isPlaying:state.isPlaying];
            os_unfair_lock_lock(&self->_lock);
            self->_currentState = optimistic;
            os_unfair_lock_unlock(&self->_lock);
            [self->_syncEngine updateWithPlaybackState:optimistic];
            [self notifyObservers:CLLyricsControllerChangePlayback];
        }
    });
}

- (void)reloadLyricsIgnoringCache {
    CLControllerRunOnMain(^{
        CLPlaybackState *state = self.currentState;
        if (!self->_started || !state.hasTrackInfo || ![self isBundleEnabled:state.bundleIdentifier]) return;
        [self resolveLyricsForState:state ignoringCache:YES];
    });
}

- (void)clearCache {
    CLControllerRunOnMain(^{
        // Asynchronous on purpose: this arrives on the main thread of a system UI process and the
        // disk half is a directory walk plus one unlink per cached track. The in-memory cache is
        // already empty when -clearWithCompletion: returns, so the re-resolve below cannot pick
        // up a stale entry even though the files are still going away behind it.
        [CLLyricsCache.sharedCache clearWithCompletion:^(NSUInteger removedCount) {
            CLLogInfo(@"Lyrics cache cleared (%lu entries)", (unsigned long)removedCount);
        }];
        CLPlaybackState *state = self.currentState;
        if (self->_started && state.hasTrackInfo && [self isBundleEnabled:state.bundleIdentifier]) {
            [self resolveLyricsForState:state ignoringCache:YES];
        }
    });
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<CLLyricsController started=%d status=%ld line=%ld displays=%ld lyrics=%@ state=%@>",
            _started, (long)self.status, (long)self.currentLineIndex, (long)_activeDisplays,
            self.currentLyrics.source ?: @"none", self.currentState];
}

@end
