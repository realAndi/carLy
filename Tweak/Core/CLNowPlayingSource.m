#import "Core/CLNowPlayingSource.h"
#import "Util/CLLog.h"
#import <dlfcn.h>
#import <os/lock.h>

// MediaRemote is a private framework and the Procursus SDK ships no stub for it, so every symbol
// is resolved with dlopen/dlsym. Verified present on iOS 17.3 (21D50), see docs/research/.
static NSString *const kCLMediaRemotePath =
    @"/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote";

typedef void (*CLMRGetNowPlayingInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*CLMRGetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*CLMRGetClientFn)(dispatch_queue_t, void (^)(id));
typedef CFStringRef _Nullable (*CLMRClientStringFn)(id);
typedef void (*CLMRRegisterFn)(dispatch_queue_t);
typedef void (*CLMRSetElapsedTimeFn)(double);
typedef Boolean (*CLMRSendCommandFn)(uint32_t, CFDictionaryRef _Nullable);

static void *sHandle;
static BOOL sLoaded;
static BOOL sRegistered;
static CLMRGetNowPlayingInfoFn sGetNowPlayingInfo;
static CLMRGetIsPlayingFn sGetIsPlaying;
static CLMRGetClientFn sGetClient;
static CLMRClientStringFn sClientBundleIdentifier;
static CLMRClientStringFn sClientParentBundleIdentifier;
static CLMRRegisterFn sRegisterForNotifications;
static CLMRSetElapsedTimeFn sSetElapsedTime;
static CLMRSendCommandFn sSendCommand;

static NSString *sNoteInfoChanged, *sNoteAppChanged, *sNoteIsPlayingChanged;
static NSString *sKeyTitle, *sKeyArtist, *sKeyAlbum, *sKeyDuration, *sKeyElapsed, *sKeyTimestamp,
    *sKeyRate, *sKeyContentID, *sKeyExternalContentID, *sKeyIsAdvertisement;

/// MediaRemote's CFStringRef constants are exported as variables: dlsym gives the address OF the
/// variable, so it has to be dereferenced. On this OS every constant's value equals its own name,
/// which is the fallback if the symbol is missing.
static NSString *CLMRConstant(const char *symbol) {
    if (sHandle) {
        CFStringRef *slot = (CFStringRef *)dlsym(sHandle, symbol);
        if (slot && *slot) {
            id value = (__bridge id)*slot;
            if ([value isKindOfClass:NSString.class] && [value length] > 0) return [value copy];
        }
    }
    return @(symbol);
}

static BOOL CLMediaRemoteLoad(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sHandle = dlopen(kCLMediaRemotePath.UTF8String, RTLD_LAZY);
        if (!sHandle) {
            const char *error = dlerror();
            CLLogError(@"MediaRemote could not be loaded: %s", error ?: "unknown error");
        } else {
            sGetNowPlayingInfo = (CLMRGetNowPlayingInfoFn)dlsym(sHandle, "MRMediaRemoteGetNowPlayingInfo");
            sGetIsPlaying = (CLMRGetIsPlayingFn)dlsym(sHandle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
            sGetClient = (CLMRGetClientFn)dlsym(sHandle, "MRMediaRemoteGetNowPlayingClient");
            sClientBundleIdentifier = (CLMRClientStringFn)dlsym(sHandle, "MRNowPlayingClientGetBundleIdentifier");
            sClientParentBundleIdentifier = (CLMRClientStringFn)dlsym(sHandle, "MRNowPlayingClientGetParentAppBundleIdentifier");
            sRegisterForNotifications = (CLMRRegisterFn)dlsym(sHandle, "MRMediaRemoteRegisterForNowPlayingNotifications");
            sSetElapsedTime = (CLMRSetElapsedTimeFn)dlsym(sHandle, "MRMediaRemoteSetElapsedTime");
            sSendCommand = (CLMRSendCommandFn)dlsym(sHandle, "MRMediaRemoteSendCommand");
            sLoaded = (sGetNowPlayingInfo != NULL);
        }
        sNoteInfoChanged = CLMRConstant("kMRMediaRemoteNowPlayingInfoDidChangeNotification");
        sNoteAppChanged = CLMRConstant("kMRMediaRemoteNowPlayingApplicationDidChangeNotification");
        sNoteIsPlayingChanged = CLMRConstant("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification");
        sKeyTitle = CLMRConstant("kMRMediaRemoteNowPlayingInfoTitle");
        sKeyArtist = CLMRConstant("kMRMediaRemoteNowPlayingInfoArtist");
        sKeyAlbum = CLMRConstant("kMRMediaRemoteNowPlayingInfoAlbum");
        sKeyDuration = CLMRConstant("kMRMediaRemoteNowPlayingInfoDuration");
        sKeyElapsed = CLMRConstant("kMRMediaRemoteNowPlayingInfoElapsedTime");
        sKeyTimestamp = CLMRConstant("kMRMediaRemoteNowPlayingInfoTimestamp");
        sKeyRate = CLMRConstant("kMRMediaRemoteNowPlayingInfoPlaybackRate");
        sKeyContentID = CLMRConstant("kMRMediaRemoteNowPlayingInfoContentItemIdentifier");
        sKeyExternalContentID = CLMRConstant("kMRMediaRemoteNowPlayingInfoExternalContentIdentifier");
        sKeyIsAdvertisement = CLMRConstant("kMRMediaRemoteNowPlayingInfoIsAdvertisement");
        CLLogInfo(@"MediaRemote %@ (info=%d isPlaying=%d client=%d register=%d seek=%d)",
                  sLoaded ? @"ready" : @"unavailable", sGetNowPlayingInfo != NULL, sGetIsPlaying != NULL,
                  sGetClient != NULL, sRegisterForNotifications != NULL, sSetElapsedTime != NULL);
    });
    return sLoaded;
}

#pragma mark - Dictionary readers (every value is untrusted)

static id CLInfoValue(NSDictionary *info, NSString *key) {
    if (![info isKindOfClass:NSDictionary.class] || key.length == 0) return nil;
    return info[key];
}

static NSString *CLInfoString(NSDictionary *info, NSString *key) {
    id value = CLInfoValue(info, key);
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return nil;
}

static double CLInfoDouble(NSDictionary *info, NSString *key) {
    id value = CLInfoValue(info, key);
    if ([value isKindOfClass:NSNumber.class]) return [value doubleValue];
    if ([value isKindOfClass:NSString.class]) return [value doubleValue];
    return 0;
}

static BOOL CLInfoBool(NSDictionary *info, NSString *key) {
    id value = CLInfoValue(info, key);
    if ([value isKindOfClass:NSNumber.class]) return [value boolValue];
    return NO;
}

static NSDate *CLInfoDate(NSDictionary *info, NSString *key) {
    id value = CLInfoValue(info, key);
    if ([value isKindOfClass:NSDate.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [NSDate dateWithTimeIntervalSince1970:[value doubleValue]];
    return nil;
}

/// MediaRemote readings are coalesced into one fetch per this many seconds.
static const NSTimeInterval kCLFetchInterval = 0.1;
/// A MediaRemote reading newer than this outranks metadata pushed in by a hook.
static const NSTimeInterval kCLMediaRemoteFreshness = 2.0;

@implementation CLNowPlayingSource {
    os_unfair_lock _lock;                       // guards the four fields below
    CLPlaybackState *_currentState;
    NSMutableDictionary<NSString *, CLNowPlayingObserverBlock> *_observers;
    NSArray<NSString *> *_lastInfoKeys;
    NSString *_clientBundleIdentifier;

    // main queue only
    BOOL _running;
    BOOL _fetchScheduled;
    NSUInteger _fetchGeneration;
    NSUInteger _clientGeneration;
    CFAbsoluteTime _lastFetchStart;
    CFAbsoluteTime _lastMediaRemoteTrack;
    CLPlaybackState *_externalState;
}

+ (instancetype)sharedSource {
    static CLNowPlayingSource *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] initPrivate]; });
    return shared;
}

- (instancetype)initPrivate {
    self = [super init];
    if (!self) return nil;
    _lock = OS_UNFAIR_LOCK_INIT;
    _observers = [NSMutableDictionary dictionary];
    _currentState = [CLPlaybackState emptyState];
    _lastInfoKeys = @[];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - Lifecycle

- (BOOL)mediaRemoteAvailable {
    return CLMediaRemoteLoad();
}

- (BOOL)canSeek {
    return CLMediaRemoteLoad() && sSetElapsedTime != NULL;
}

- (BOOL)isRunning {
    return _running;
}

- (void)start {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self start]; });
        return;
    }
    if (_running) return;
    _running = YES;

    BOOL available = CLMediaRemoteLoad();
    if (available && sRegisterForNotifications && !sRegistered) {
        sRegisterForNotifications(dispatch_get_main_queue());
        sRegistered = YES;   // never unregistered: that would silence the host's own consumers too
    }
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSString *name in @[ sNoteInfoChanged ?: @"", sNoteAppChanged ?: @"", sNoteIsPlayingChanged ?: @"" ]) {
        if (name.length == 0) continue;
        [center addObserver:self selector:@selector(mediaRemoteDidChange:) name:name object:nil];
    }
    CLLogInfo(@"CLNowPlayingSource started (MediaRemote %@)", available ? @"available" : @"unavailable");
    [self performFetch];
}

- (void)stop {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self stop]; });
        return;
    }
    if (!_running) return;
    _running = NO;
    _fetchGeneration++;    // drop in-flight callbacks
    _clientGeneration++;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    CLLogInfo(@"CLNowPlayingSource stopped");
}

- (void)mediaRemoteDidChange:(NSNotification *)notification {
    if (!_running) return;
    CLLogDebug(@"MediaRemote notification %@", notification.name);
    [self scheduleFetch];
}

#pragma mark - Observers

- (CLPlaybackState *)currentState {
    os_unfair_lock_lock(&_lock);
    CLPlaybackState *state = _currentState;
    os_unfair_lock_unlock(&_lock);
    return state;
}

- (id)addObserver:(CLNowPlayingObserverBlock)observer {
    if (!observer) return nil;
    NSString *token = NSUUID.UUID.UUIDString;
    CLNowPlayingObserverBlock copied = [observer copy];
    os_unfair_lock_lock(&_lock);
    _observers[token] = copied;
    CLPlaybackState *state = _currentState;
    os_unfair_lock_unlock(&_lock);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (state) copied(state);
    });
    return token;
}

- (void)removeObserver:(id)token {
    if (![token isKindOfClass:NSString.class]) return;
    os_unfair_lock_lock(&_lock);
    [_observers removeObjectForKey:token];
    os_unfair_lock_unlock(&_lock);
}

/// Main queue only.
- (void)publishState:(CLPlaybackState *)state {
    if (!state) return;
    os_unfair_lock_lock(&_lock);
    CLPlaybackState *previous = _currentState;
    if ([state isEqualToPlaybackState:previous]) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    _currentState = state;
    NSArray<CLNowPlayingObserverBlock> *observers = _observers.allValues;
    os_unfair_lock_unlock(&_lock);

    if (![state isSameSongAs:previous]) {
        CLLogInfo(@"Now playing: %@", state);
    } else {
        CLLogDebug(@"Playback update: %@", state);
    }
    for (CLNowPlayingObserverBlock observer in observers) {
        observer(state);
    }
}

#pragma mark - Fetching

- (void)refresh {
    [self scheduleFetch];
}

- (void)scheduleFetch {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self scheduleFetch]; });
        return;
    }
    if (_fetchScheduled) return;
    NSTimeInterval sinceLast = CFAbsoluteTimeGetCurrent() - _lastFetchStart;
    if (sinceLast >= kCLFetchInterval || sinceLast < 0) {
        [self performFetch];
        return;
    }
    _fetchScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_time_t when = dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)((kCLFetchInterval - sinceLast) * NSEC_PER_SEC));
    dispatch_after(when, dispatch_get_main_queue(), ^{
        CLNowPlayingSource *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_fetchScheduled = NO;
        [strongSelf performFetch];
    });
}

/// Main queue only.
- (void)performFetch {
    _lastFetchStart = CFAbsoluteTimeGetCurrent();
    if (!CLMediaRemoteLoad() || !sGetNowPlayingInfo) return;

    NSUInteger generation = ++_fetchGeneration;
    __weak typeof(self) weakSelf = self;
    [self refreshClientBundleIdentifier];
    sGetNowPlayingInfo(dispatch_get_main_queue(), ^(CFDictionaryRef rawInfo) {
        CLNowPlayingSource *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSDictionary *info = nil;
        if (rawInfo) {
            id bridged = (__bridge id)rawInfo;
            if ([bridged isKindOfClass:NSDictionary.class]) info = [bridged copy];
        }
        [strongSelf didReceiveInfo:info generation:generation];
    });
}

- (void)didReceiveInfo:(NSDictionary *)info generation:(NSUInteger)generation {
    if (generation != _fetchGeneration) return;

    NSArray<NSString *> *keys = [[info.allKeys valueForKey:@"description"]
                                 sortedArrayUsingSelector:@selector(compare:)] ?: @[];
    os_unfair_lock_lock(&_lock);
    _lastInfoKeys = keys;
    os_unfair_lock_unlock(&_lock);

    __weak typeof(self) weakSelf = self;
    if (sGetIsPlaying) {
        sGetIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            CLNowPlayingSource *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf finishFetchWithInfo:info isPlaying:(playing ? YES : NO) known:YES generation:generation];
        });
    } else {
        [self finishFetchWithInfo:info isPlaying:NO known:NO generation:generation];
    }
}

- (void)finishFetchWithInfo:(NSDictionary *)info
                  isPlaying:(BOOL)isPlaying
                      known:(BOOL)isPlayingKnown
                 generation:(NSUInteger)generation {
    if (generation != _fetchGeneration) return;

    double rate = CLInfoDouble(info, sKeyRate);
    BOOL playing = isPlayingKnown ? isPlaying : (rate > 0.01);
    NSString *contentIdentifier = CLInfoString(info, sKeyContentID) ?: CLInfoString(info, sKeyExternalContentID);

    os_unfair_lock_lock(&_lock);
    NSString *bundle = _clientBundleIdentifier;
    os_unfair_lock_unlock(&_lock);

    CLPlaybackState *state = [[CLPlaybackState alloc] initWithTitle:CLInfoString(info, sKeyTitle)
                                                             artist:CLInfoString(info, sKeyArtist)
                                                              album:CLInfoString(info, sKeyAlbum)
                                                           duration:CLInfoDouble(info, sKeyDuration)
                                                        elapsedTime:CLInfoDouble(info, sKeyElapsed)
                                                          timestamp:CLInfoDate(info, sKeyTimestamp)
                                                       playbackRate:rate
                                                   bundleIdentifier:bundle
                                                  contentIdentifier:contentIdentifier
                                                          isPlaying:playing
                                                    isAdvertisement:CLInfoBool(info, sKeyIsAdvertisement)
                                                             origin:CLPlaybackStateOriginMediaRemote];

    if (state.hasTrackInfo) {
        _lastMediaRemoteTrack = CFAbsoluteTimeGetCurrent();
        if (_externalState && [state isSameSongAs:_externalState]) {
            state = [state stateByFillingGapsFrom:_externalState];   // hook data only fills gaps
        }
        [self publishState:state];
        return;
    }

    // MediaRemote knows nothing. Keep recent hook-provided metadata rather than blanking the UI,
    // and keep the clock we already have for that song instead of restarting it at zero.
    CLPlaybackState *external = _externalState;
    if (external.hasTrackInfo) {
        CLPlaybackState *current = self.currentState;
        CLPlaybackState *base = (current.hasTrackInfo && [current isSameSongAs:external]) ? current : external;
        NSTimeInterval elapsed = base.elapsedTime;
        NSDate *stamp = base.timestamp;
        if (base.isPlaying != playing || (playing && !stamp)) {
            elapsed = base.elapsedNow;      // resample across a play/pause transition
            stamp = playing ? [NSDate date] : nil;
        }
        [self publishState:[base stateByUpdatingElapsedTime:elapsed
                                                  timestamp:stamp
                                               playbackRate:playing ? 1.0 : 0.0
                                                  isPlaying:playing]];
        return;
    }
    [self publishState:state];
}

#pragma mark - Now-playing client (bundle identifier)

/// Main queue only.
- (void)refreshClientBundleIdentifier {
    if (!sGetClient || !sClientBundleIdentifier) return;
    NSUInteger generation = ++_clientGeneration;
    __weak typeof(self) weakSelf = self;
    sGetClient(dispatch_get_main_queue(), ^(id client) {
        CLNowPlayingSource *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_clientGeneration) return;
        NSString *bundle = nil;
        if (client) {
            CFStringRef raw = sClientBundleIdentifier(client);
            if (!raw && sClientParentBundleIdentifier) raw = sClientParentBundleIdentifier(client);
            if (raw) {
                id bridged = (__bridge id)raw;
                if ([bridged isKindOfClass:NSString.class] && [bridged length] > 0) bundle = [bridged copy];
            }
        }
        [strongSelf applyClientBundleIdentifier:bundle];
    });
}

/// Main queue only.
- (void)applyClientBundleIdentifier:(NSString *)bundle {
    if (bundle.length == 0) return;   // keep the last known app instead of blanking it
    os_unfair_lock_lock(&_lock);
    BOOL changed = ![bundle isEqualToString:_clientBundleIdentifier ?: @""];
    if (changed) _clientBundleIdentifier = [bundle copy];
    CLPlaybackState *current = _currentState;
    os_unfair_lock_unlock(&_lock);
    if (!changed) return;
    CLLogDebug(@"Now-playing client is %@", bundle);
    if (current.hasTrackInfo) [self publishState:[current stateBySettingBundleIdentifier:bundle]];
}

#pragma mark - External metadata (host hooks)

- (void)ingestExternalTitle:(NSString *)title
                     artist:(NSString *)artist
                      album:(NSString *)album
                   duration:(NSTimeInterval)duration
           bundleIdentifier:(NSString *)bundleIdentifier
          contentIdentifier:(NSString *)contentIdentifier {
    CLPlaybackState *external = [CLPlaybackState stateWithTitle:title
                                                         artist:artist
                                                          album:album
                                                       duration:duration
                                               bundleIdentifier:bundleIdentifier
                                              contentIdentifier:contentIdentifier
                                                         origin:CLPlaybackStateOriginExternal];
    if (!external.hasTrackInfo) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self applyExternalState:external]; });
        return;
    }
    [self applyExternalState:external];
}

/// Main queue only.
- (void)applyExternalState:(CLPlaybackState *)external {
    _externalState = external;

    CLPlaybackState *current = self.currentState;
    if (current.hasTrackInfo && [current isSameSongAs:external]) {
        [self publishState:[current stateByFillingGapsFrom:external]];
    } else {
        BOOL mediaRemoteFresh = _lastMediaRemoteTrack > 0 &&
            (CFAbsoluteTimeGetCurrent() - _lastMediaRemoteTrack) < kCLMediaRemoteFreshness;
        if (!mediaRemoteFresh) {
            // Assume the hook's track just started; MediaRemote corrects the clock if it can.
            BOOL playing = current.isPlaying;
            [self publishState:[external stateByUpdatingElapsedTime:0
                                                          timestamp:playing ? [NSDate date] : nil
                                                       playbackRate:playing ? 1.0 : 0.0
                                                          isPlaying:playing]];
        } else {
            CLLogDebug(@"Ignoring hook metadata (%@): MediaRemote is fresher", external.title);
        }
    }
    [self scheduleFetch];
}

#pragma mark - Seeking

- (BOOL)canSendCommands {
    return CLMediaRemoteLoad() && sSendCommand != NULL;
}

- (void)sendCommand:(CLPlaybackCommand)command {
    if (!self.canSendCommands) {
        CLLogInfo(@"Playback command %ld requested but MRMediaRemoteSendCommand is unavailable", (long)command);
        return;
    }
    // MRMediaRemoteCommand (MediaRemote.h): TogglePlayPause 2, NextTrack 4, PreviousTrack 5.
    uint32_t value = 0;
    switch (command) {
        case CLPlaybackCommandTogglePlayPause: value = 2; break;
        case CLPlaybackCommandNextTrack: value = 4; break;
        case CLPlaybackCommandPreviousTrack: value = 5; break;
        default: return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sSendCommand) return;
        Boolean sent = sSendCommand(value, NULL);
        CLLogDebug(@"Playback command %u sent=%d", value, (int)sent);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
    });
}

- (void)seekToTime:(NSTimeInterval)time {
    if (!self.canSeek) {
        CLLogInfo(@"Seek requested but MRMediaRemoteSetElapsedTime is unavailable");
        return;
    }
    CLPlaybackState *state = self.currentState;
    double target = (isfinite(time) && time > 0) ? time : 0;
    if (state.duration > 0 && target > state.duration) target = state.duration;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sSetElapsedTime) return;
        CLLogDebug(@"Seeking to %.2fs", target);
        sSetElapsedTime(target);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
    });
}

#pragma mark - Debugging

- (NSString *)debugDescription {
    os_unfair_lock_lock(&_lock);
    NSArray<NSString *> *keys = _lastInfoKeys;
    CLPlaybackState *state = _currentState;
    NSString *bundle = _clientBundleIdentifier;
    NSUInteger observerCount = _observers.count;
    os_unfair_lock_unlock(&_lock);
    return [NSString stringWithFormat:
            @"<CLNowPlayingSource running=%d mediaRemote=%d seek=%d client=%@ observers=%lu\n"
             "  state=%@\n  lastInfoKeys(%lu)=%@>",
            _running, sLoaded, sSetElapsedTime != NULL, bundle ?: @"?", (unsigned long)observerCount,
            state, (unsigned long)keys.count, [keys componentsJoinedByString:@", "]];
}

@end
