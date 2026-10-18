#import "CLPrefs.h"
#import "CLPrefsKeys.h"
#import "CLLog.h"
#import "UI/CLLayoutGeometry.h"
#import <CoreFoundation/CoreFoundation.h>
#import <os/lock.h>

NSNotificationName const CLPrefsDidChangeNotification = @"CLPrefsDidChangeNotification";
NSNotificationName const CLPrefsClearCacheNotification = @"CLPrefsClearCacheNotification";
NSNotificationName const CLPrefsResetNotification = @"CLPrefsResetNotification";

NSString *CLPrefsActiveDomain(void) {
    static NSString *domain;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *override = getenv("CARLY_PREFS_DOMAIN");
        NSString *candidate = (override != NULL) ? @(override) : nil;
        candidate = [candidate stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        // A CFPreferences domain is a bare identifier. Anything with a path separator in it would
        // turn the plist fallback below into an arbitrary file read, so it is refused.
        BOOL usable = candidate.length > 0 && candidate.length < 256 &&
                      [candidate rangeOfString:@"/"].location == NSNotFound;
        domain = usable ? [candidate copy] : CLPrefsDomain;
    });
    return domain;
}

@interface CLPrefs ()
- (NSDictionary<NSString *, id> *)loadPlistFallback;
- (NSDictionary<NSString *, id> *)currentValues;
- (id)valueForResolvedKey:(NSString *)key;
@end

/// How long a burst of prefsChanged notifications is coalesced before the values are re-read.
/// Every specifier in the settings page posts on change, so dragging a slider posts on every
/// step; without this each step would cost a full re-resolve (dozens of cfprefsd round trips).
static const NSTimeInterval kCLPrefsReloadDebounce = 0.15;

// MARK: - Typed coercion helpers
//
// Each takes the raw value read from CFPreferences/the plist fallback (which may be nil, or of
// any type a malformed/hand-edited plist could contain) and returns a value of the correct native
// type, falling back to `def` whenever the raw value is missing or not the expected kind. Numeric
// ranges documented in CLPrefsKeys.h are clamped separately by the callers below so a bad manual
// edit degrades to a safe value instead of breaking layout math.

static BOOL CLPrefsBool(id raw, BOOL def) {
    if ([raw isKindOfClass:[NSNumber class]]) return [(NSNumber *)raw boolValue];
    return def;
}

static NSInteger CLPrefsInt(id raw, NSInteger def) {
    if ([raw isKindOfClass:[NSNumber class]]) return [(NSNumber *)raw integerValue];
    return def;
}

static double CLPrefsDouble(id raw, double def) {
    if ([raw isKindOfClass:[NSNumber class]]) return [(NSNumber *)raw doubleValue];
    return def;
}

static NSString *CLPrefsString(id raw, NSString *def) {
    if ([raw isKindOfClass:[NSString class]]) return (NSString *)raw;
    return def;
}

static NSArray<NSString *> *CLPrefsStringArray(id raw, NSArray<NSString *> *def) {
    if (![raw isKindOfClass:[NSArray class]]) return def;
    for (id item in (NSArray *)raw) {
        if (![item isKindOfClass:[NSString class]]) return def;
    }
    return [(NSArray *)raw copy];
}

static NSInteger CLClampInt(NSInteger value, NSInteger lo, NSInteger hi) {
    if (value < lo) return lo;
    if (value > hi) return hi;
    return value;
}

static double CLClampDouble(double value, double lo, double hi) {
    if (value < lo) return lo;
    if (value > hi) return hi;
    return value;
}

static void CLPrefsDarwinCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                   const void *object, CFDictionaryRef userInfo);

@implementation CLPrefs {
    os_unfair_lock _lock;
    NSDictionary<NSString *, id> *_values;   // fully resolved, guarded by _lock
    dispatch_queue_t _reloadQueue;           // every re-resolve after the first one runs here
    uint64_t _reloadGeneration;              // guarded by _lock; coalesces a burst of posts
    BOOL _cfprefsdEverAnswered;              // guarded by _lock; see -reloadNow
}

+ (instancetype)shared {
    static CLPrefs *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _reloadQueue = dispatch_queue_create("com.andi.carly.prefs",
                                              DISPATCH_QUEUE_SERIAL);
        // The very first resolve is synchronous: the %ctor asks for `enabled` and `debugLogging`
        // immediately and has nothing sensible to do with a half-populated snapshot. Every later
        // one is debounced onto _reloadQueue (see -reload).
        [self reloadNow];

        CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
        const void *observer = (__bridge const void *)self;
        CFNotificationCenterAddObserver(center, observer, CLPrefsDarwinCallback,
                                         (__bridge CFStringRef)CLPrefsDarwinNotificationPrefsChanged,
                                         NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(center, observer, CLPrefsDarwinCallback,
                                         (__bridge CFStringRef)CLPrefsDarwinNotificationClearCache,
                                         NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(center, observer, CLPrefsDarwinCallback,
                                         (__bridge CFStringRef)CLPrefsDarwinNotificationResetDefaults,
                                         NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    return self;
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge const void *)self);
}

// MARK: - Darwin notification relay

static void CLPrefsDarwinCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                   const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)object; (void)userInfo;
    if (!observer || !name) return;
    CLPrefs *prefs = (__bridge CLPrefs *)observer;
    NSString *notificationName = (__bridge NSString *)name;

    if ([notificationName isEqualToString:CLPrefsDarwinNotificationPrefsChanged]) {
        // Darwin notifications are delivered on the main run loop, and re-resolving every key is
        // dozens of synchronous cfprefsd round trips: -reload coalesces and does that work on its
        // own queue, then posts CLPrefsDidChangeNotification on main.
        [prefs reload];
    } else if ([notificationName isEqualToString:CLPrefsDarwinNotificationClearCache]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:CLPrefsClearCacheNotification
                                                                  object:prefs];
        });
    } else if ([notificationName isEqualToString:CLPrefsDarwinNotificationResetDefaults]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:CLPrefsResetNotification
                                                                  object:prefs];
        });
    }
}

// MARK: - Loading

/// Reads the plist directly for the one case CFPreferences cannot cover: a process that gets no
/// answer at all out of cfprefsd for this domain. Tries the un-prefixed path first, then the
/// rootless-jailbreak path, and returns the first that actually contains something.
/// Never mix this with cfprefsd's answers per key — see -reloadNow for why.
- (NSDictionary<NSString *, id> *)loadPlistFallback {
    static NSArray<NSString *> *candidatePaths;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *file = [CLPrefsActiveDomain() stringByAppendingPathExtension:@"plist"];
        candidatePaths = @[
            [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:file],
            [@"/var/jb/var/mobile/Library/Preferences" stringByAppendingPathComponent:file],
        ];
    });
    for (NSString *path in candidatePaths) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (dict.count > 0) return dict;
    }
    return @{};
}

/// Coalesced, off-main re-resolve. Safe to call from any thread and as often as the settings page
/// likes; the values are published atomically and CLPrefsDidChangeNotification is posted once per
/// burst, on the main thread.
- (void)reload {
    os_unfair_lock_lock(&_lock);
    uint64_t generation = ++_reloadGeneration;
    os_unfair_lock_unlock(&_lock);

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCLPrefsReloadDebounce * NSEC_PER_SEC)),
                   _reloadQueue, ^{
        CLPrefs *strongSelf = weakSelf;
        if (!strongSelf) return;
        os_unfair_lock_lock(&strongSelf->_lock);
        BOOL superseded = (generation != strongSelf->_reloadGeneration);
        os_unfair_lock_unlock(&strongSelf->_lock);
        if (superseded) return;       // another post landed while we waited; that one will do it
        [strongSelf reloadNow];
    });
}

/// Turns "what is stored for this key" into the whole resolved snapshot: every default, every
/// type coercion and every documented clamp lives here and nowhere else. `raw` returns the stored
/// value for a key, or nil when it is not set.
- (NSDictionary<NSString *, id> *)resolvedValuesWithRawResolver:(id _Nullable (^)(NSString *key))raw {
    NSMutableDictionary<NSString *, id> *resolved = [NSMutableDictionary dictionaryWithCapacity:48];

    // General
    resolved[CLPrefKeyEnabled] = @(CLPrefsBool(raw(CLPrefKeyEnabled), YES));
    resolved[CLPrefKeyDebugLogging] = @(CLPrefsBool(raw(CLPrefKeyDebugLogging), NO));
    resolved[CLPrefKeyEnabledApps] = CLPrefsStringArray(raw(CLPrefKeyEnabledApps),
                                                          (@[@"com.spotify.client", @"com.apple.Music"]));
    resolved[CLPrefKeyAllApps] = @(CLPrefsBool(raw(CLPrefKeyAllApps), NO));

    // Lyrics
    // 1 was the two-line overlay until 0.5.0; it reads as side by side (UI/CLLayoutGeometry.h).
    resolved[CLPrefKeyLyricsMode] = @(CLLayoutModeNormalize(CLPrefsInt(raw(CLPrefKeyLyricsMode), 4)));
    resolved[CLPrefKeyLyricsFontFamily] = CLPrefsString(raw(CLPrefKeyLyricsFontFamily), @"");
    resolved[CLPrefKeyLyricsFontSize] = @(MAX(1.0, CLPrefsDouble(raw(CLPrefKeyLyricsFontSize), 24.0)));
    resolved[CLPrefKeyLyricsFontWeight] = @(CLClampInt(CLPrefsInt(raw(CLPrefKeyLyricsFontWeight), 600), 100, 900));
    resolved[CLPrefKeyLyricsCurrentColor] = CLPrefsString(raw(CLPrefKeyLyricsCurrentColor), @"#FFFFFF");
    resolved[CLPrefKeyLyricsNextColor] = CLPrefsString(raw(CLPrefKeyLyricsNextColor), @"#FFFFFF");
    resolved[CLPrefKeyLyricsNextAlpha] = @(CLClampDouble(CLPrefsDouble(raw(CLPrefKeyLyricsNextAlpha), 0.45), 0.0, 1.0));
    resolved[CLPrefKeyLyricsAlignment] = @(CLClampInt(CLPrefsInt(raw(CLPrefKeyLyricsAlignment), 0), 0, 2));
    resolved[CLPrefKeyLyricsAnimations] = @(CLPrefsBool(raw(CLPrefKeyLyricsAnimations), YES));
    resolved[CLPrefKeyLyricsShowPlainWhenUnsynced] = @(CLPrefsBool(raw(CLPrefKeyLyricsShowPlainWhenUnsynced), YES));
    resolved[CLPrefKeyLyricsOffsetMs] = @(CLPrefsInt(raw(CLPrefKeyLyricsOffsetMs), 0));
    resolved[CLPrefKeyServiceLyricsOffsetMs] = @(CLPrefsInt(raw(CLPrefKeyServiceLyricsOffsetMs), 0));
    resolved[CLPrefKeyLyricsShowNoteOnGap] = @(CLPrefsBool(raw(CLPrefKeyLyricsShowNoteOnGap), YES));
    resolved[CLPrefKeyLyricsBackground] = @(CLClampInt(CLPrefsInt(raw(CLPrefKeyLyricsBackground), 0), 0, 2));
    resolved[CLPrefKeyLyricsBackgroundColor] = CLPrefsString(raw(CLPrefKeyLyricsBackgroundColor), @"#000000");
    resolved[CLPrefKeyLyricsBackgroundAlpha] = @(CLClampDouble(CLPrefsDouble(raw(CLPrefKeyLyricsBackgroundAlpha), 0.35), 0.0, 1.0));

    // Layout
    resolved[CLPrefKeyArtworkCornerRadius] = @(MAX(0.0, CLPrefsDouble(raw(CLPrefKeyArtworkCornerRadius), 12.0)));
    resolved[CLPrefKeyBackdropStyle] = @(CLClampInt(CLPrefsInt(raw(CLPrefKeyBackdropStyle), 0), 0, 1));
    resolved[CLPrefKeyBackdropOpacity] = @(CLClampDouble(CLPrefsDouble(raw(CLPrefKeyBackdropOpacity), 1.0), 0.0, 1.0));
    resolved[CLPrefKeyTintFromArtwork] = @(CLPrefsBool(raw(CLPrefKeyTintFromArtwork), NO));
    resolved[CLPrefKeyAccentColor] = CLPrefsString(raw(CLPrefKeyAccentColor), @"");
    resolved[CLPrefKeyShowAlbum] = @(CLPrefsBool(raw(CLPrefKeyShowAlbum), YES));
    // 1 was the thin bar until 0.5.0; it reads as the system bar.
    NSInteger progressStyle = CLClampInt(CLPrefsInt(raw(CLPrefKeyProgressBarStyle), 0), 0, 2);
    resolved[CLPrefKeyProgressBarStyle] = @(progressStyle == 1 ? 0 : progressStyle);
    resolved[CLPrefKeyHidePlaybackRateButton] = @(CLPrefsBool(raw(CLPrefKeyHidePlaybackRateButton), NO));
    resolved[CLPrefKeyHideQueueButton] = @(CLPrefsBool(raw(CLPrefKeyHideQueueButton), NO));
    resolved[CLPrefKeyShowLyricsButton] = @(CLPrefsBool(raw(CLPrefKeyShowLyricsButton), YES));
    resolved[CLPrefKeyLyricsSide] = @(CLClampInt(CLPrefsInt(raw(CLPrefKeyLyricsSide), 0), 0, 1));

    // Sources
    resolved[CLPrefKeyProviderOrder] = CLPrefsStringArray(raw(CLPrefKeyProviderOrder),
                                                            (@[@"embedded", @"apple-music", @"spotify",
                                                               @"spotify-cache", @"lrclib", @"custom"]));
    resolved[CLPrefKeyEmbeddedLyricsEnabled] = @(CLPrefsBool(raw(CLPrefKeyEmbeddedLyricsEnabled), YES));
    resolved[CLPrefKeyAppleMusicLyricsEnabled] = @(CLPrefsBool(raw(CLPrefKeyAppleMusicLyricsEnabled), YES));
    resolved[CLPrefKeyLRCLibEnabled] = @(CLPrefsBool(raw(CLPrefKeyLRCLibEnabled), YES));
    resolved[CLPrefKeySpotifyLyricsEnabled] = @(CLPrefsBool(raw(CLPrefKeySpotifyLyricsEnabled), YES));
    resolved[CLPrefKeySpotifyCacheEnabled] = @(CLPrefsBool(raw(CLPrefKeySpotifyCacheEnabled), YES));
    resolved[CLPrefKeyCustomEndpointEnabled] = @(CLPrefsBool(raw(CLPrefKeyCustomEndpointEnabled), NO));
    resolved[CLPrefKeyCustomEndpointURL] = CLPrefsString(raw(CLPrefKeyCustomEndpointURL), @"");
    resolved[CLPrefKeyCustomEndpointHeaderName] = CLPrefsString(raw(CLPrefKeyCustomEndpointHeaderName), @"");
    resolved[CLPrefKeyCustomEndpointHeaderValue] = CLPrefsString(raw(CLPrefKeyCustomEndpointHeaderValue), @"");
    resolved[CLPrefKeyOfflineOnly] = @(CLPrefsBool(raw(CLPrefKeyOfflineOnly), NO));
    resolved[CLPrefKeyCacheNegativeHours] = @(MAX((NSInteger)0, CLPrefsInt(raw(CLPrefKeyCacheNegativeHours), 24)));

    return [resolved copy];
}

- (void)reloadNow {
    NSString *domain = CLPrefsActiveDomain();
    // Give cfprefsd a chance to hand back the latest value for this domain before we read it.
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);

    __block BOOL cfprefsdAnswered = NO;
    NSDictionary<NSString *, id> *snapshot =
        [self resolvedValuesWithRawResolver:^id(NSString *key) {
            id value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                                     (__bridge CFStringRef)domain));
            if (value != nil) cfprefsdAnswered = YES;
            return value;
        }];

    // The plist on disk is a *bootstrap*, not a second opinion. cfprefsd flushes a domain to its
    // file lazily, so the file can still hold a value that has already been removed — and mixing
    // the two sources per key would then resurrect it. "Reset to Defaults" removes every key at
    // once, which is exactly the case that used to come back from disk seconds later.
    //
    // So the file is read only while cfprefsd has never answered anything for this domain, in
    // this process: that covers a fresh install and a process that cannot reach cfprefsd at all
    // (where the file is the only source there is, on every reload), and nothing else. One key
    // answered, ever, and cfprefsd is the sole authority from then on.
    os_unfair_lock_lock(&_lock);
    if (cfprefsdAnswered) _cfprefsdEverAnswered = YES;
    BOOL everAnswered = _cfprefsdEverAnswered;
    os_unfair_lock_unlock(&_lock);

    if (!everAnswered) {
        NSDictionary<NSString *, id> *fallback = [self loadPlistFallback];
        if (fallback.count > 0) {
            // cfprefsdAnswered is NO, so every key above came back nil: the file is the only
            // source for all of them and no mixing can happen.
            snapshot = [self resolvedValuesWithRawResolver:^id(NSString *key) { return fallback[key]; }];
        }
    }

    os_unfair_lock_lock(&_lock);
    _values = snapshot;
    os_unfair_lock_unlock(&_lock);

    CLLogSetDebugEnabled([(NSNumber *)snapshot[CLPrefKeyDebugLogging] boolValue]);
    CLLogDebug(@"CLPrefs reloaded (%lu keys)", (unsigned long)snapshot.count);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:CLPrefsDidChangeNotification object:self];
    });
}

- (NSDictionary<NSString *, id> *)snapshot {
    return [self currentValues];
}

// MARK: - Thread-safe read

- (NSDictionary<NSString *, id> *)currentValues {
    os_unfair_lock_lock(&_lock);
    NSDictionary<NSString *, id> *values = _values;
    os_unfair_lock_unlock(&_lock);
    return values ?: @{};
}

- (id)valueForResolvedKey:(NSString *)key {
    return [self currentValues][key];
}

// MARK: - General

- (BOOL)enabled { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyEnabled] boolValue]; }
- (BOOL)debugLogging { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyDebugLogging] boolValue]; }
- (NSArray<NSString *> *)enabledApps { return (NSArray<NSString *> *)[self valueForResolvedKey:CLPrefKeyEnabledApps] ?: @[]; }
- (BOOL)allApps { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyAllApps] boolValue]; }

// MARK: - Lyrics

- (NSInteger)lyricsMode { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyLyricsMode] integerValue]; }
- (NSString *)lyricsFontFamily { return (NSString *)[self valueForResolvedKey:CLPrefKeyLyricsFontFamily] ?: @""; }
- (double)lyricsFontSize { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyLyricsFontSize] doubleValue]; }
- (NSInteger)lyricsFontWeight { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyLyricsFontWeight] integerValue]; }
- (NSString *)lyricsCurrentColorHex { return (NSString *)[self valueForResolvedKey:CLPrefKeyLyricsCurrentColor] ?: @"#FFFFFF"; }
- (NSString *)lyricsNextColorHex { return (NSString *)[self valueForResolvedKey:CLPrefKeyLyricsNextColor] ?: @"#FFFFFF"; }
- (double)lyricsNextAlpha { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyLyricsNextAlpha] doubleValue]; }
- (NSInteger)lyricsAlignment { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyLyricsAlignment] integerValue]; }
- (BOOL)lyricsAnimations { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyLyricsAnimations] boolValue]; }
- (BOOL)lyricsShowPlainWhenUnsynced { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyLyricsShowPlainWhenUnsynced] boolValue]; }
- (NSInteger)lyricsOffsetMs { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyLyricsOffsetMs] integerValue]; }
- (NSInteger)serviceLyricsOffsetMs { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyServiceLyricsOffsetMs] integerValue]; }
- (BOOL)lyricsShowNoteOnGap { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyLyricsShowNoteOnGap] boolValue]; }
- (NSInteger)lyricsBackground { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyLyricsBackground] integerValue]; }
- (NSString *)lyricsBackgroundColorHex { return (NSString *)[self valueForResolvedKey:CLPrefKeyLyricsBackgroundColor] ?: @"#000000"; }
- (double)lyricsBackgroundAlpha { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyLyricsBackgroundAlpha] doubleValue]; }

// MARK: - Layout

- (double)artworkCornerRadius { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyArtworkCornerRadius] doubleValue]; }
- (NSInteger)backdropStyle { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyBackdropStyle] integerValue]; }
- (double)backdropOpacity { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyBackdropOpacity] doubleValue]; }
- (BOOL)tintFromArtwork { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyTintFromArtwork] boolValue]; }
- (NSString *)accentColorHex { return (NSString *)[self valueForResolvedKey:CLPrefKeyAccentColor] ?: @""; }
- (BOOL)showAlbum { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyShowAlbum] boolValue]; }
- (NSInteger)progressBarStyle { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyProgressBarStyle] integerValue]; }
- (BOOL)hidePlaybackRateButton { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyHidePlaybackRateButton] boolValue]; }
- (BOOL)hideQueueButton { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyHideQueueButton] boolValue]; }
- (BOOL)showLyricsButton { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyShowLyricsButton] boolValue]; }
- (NSInteger)lyricsSide { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyLyricsSide] integerValue]; }

// MARK: - Sources

- (NSArray<NSString *> *)providerOrder { return (NSArray<NSString *> *)[self valueForResolvedKey:CLPrefKeyProviderOrder] ?: @[]; }
- (BOOL)embeddedLyricsEnabled { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyEmbeddedLyricsEnabled] boolValue]; }
- (BOOL)appleMusicLyricsEnabled { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyAppleMusicLyricsEnabled] boolValue]; }
- (BOOL)lrclibEnabled { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyLRCLibEnabled] boolValue]; }
- (BOOL)spotifyLyricsEnabled { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeySpotifyLyricsEnabled] boolValue]; }
- (BOOL)spotifyCacheEnabled { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeySpotifyCacheEnabled] boolValue]; }
- (BOOL)customEndpointEnabled { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyCustomEndpointEnabled] boolValue]; }
- (NSString *)customEndpointURL { return (NSString *)[self valueForResolvedKey:CLPrefKeyCustomEndpointURL] ?: @""; }
- (NSString *)customEndpointHeaderName { return (NSString *)[self valueForResolvedKey:CLPrefKeyCustomEndpointHeaderName] ?: @""; }
- (NSString *)customEndpointHeaderValue { return (NSString *)[self valueForResolvedKey:CLPrefKeyCustomEndpointHeaderValue] ?: @""; }
- (BOOL)offlineOnly { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyOfflineOnly] boolValue]; }
- (NSInteger)cacheNegativeHours { return [(NSNumber *)[self valueForResolvedKey:CLPrefKeyCacheNegativeHours] integerValue]; }

@end
