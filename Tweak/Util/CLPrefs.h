// Contract: owned by the prefs-model slice. Typed, defaulted, live-reloading view over the
// com.andi.carly preference domain. See CLPrefsKeys.h for the key/type/default
// table this class implements. No UIKit here — colours are exposed as hex strings; use CLColor
// to turn them into UIColor.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main thread after -reload finishes in response to the prefsChanged Darwin
/// notification (or an explicit -reload call). Observe this to re-apply prefs to the UI.
extern NSNotificationName const CLPrefsDidChangeNotification;
/// Posted on the main thread when the clearCache Darwin notification fires. CLPrefs does not
/// touch the lyrics cache itself; components that own on-disk state observe this.
extern NSNotificationName const CLPrefsClearCacheNotification;
/// Posted on the main thread when the resetDefaults Darwin notification fires.
extern NSNotificationName const CLPrefsResetNotification;

/// The preference domain CLPrefs actually reads. Normally CLPrefsDomain (CLPrefsKeys.h); when the
/// environment variable CARLY_PREFS_DOMAIN names a different one, that is used instead.
///
/// The override is a test hook, the CFPreferences counterpart of CLLyricsCache's
/// CARLY_CACHE_DIR: tests/ui writes preferences to drive the layout customizer and would
/// otherwise write, and clear, the settings of a configured install on this very phone. Nothing
/// sets it inside CarPlayTemplateUIHost, so the shipped tweak always uses the real domain.
/// Resolved once per process; anything that writes preferences a CLPrefs instance should see
/// (only tests do) must write to this domain too.
NSString *CLPrefsActiveDomain(void);

/// Singleton snapshot of every carLy preference, typed and defaulted. Reading any property is
/// safe from any thread and never touches disk: -init and -reload do the (small, synchronous)
/// CFPreferences/plist read once and swap in a fully-resolved snapshot atomically.
@interface CLPrefs : NSObject

+ (instancetype)shared;

/// Re-resolves every key from CFPreferences, falling back to reading the plist file directly if
/// CFPreferences has nothing for a key, and finally to the documented default if neither has a
/// value or the stored value is the wrong type. Safe to call from any thread. Also updates
/// CLLogSetDebugEnabled() to match the current debugLogging value. Posts
/// CLPrefsDidChangeNotification on the main thread when done.
///
/// **Asynchronous and coalesced**: the work (one CFPreferencesCopyAppValue — an XPC round trip to
/// cfprefsd — per key, plus a possible plist read) happens on a private serial queue a short
/// moment later, and a burst of calls resolves once. That matters because every specifier in the
/// settings page posts the prefsChanged Darwin notification on change, the notification is
/// delivered on the main run loop, and the main thread here belongs to the process drawing the
/// driver's screen. Read a property right after calling this and you may still see the old value;
/// observe CLPrefsDidChangeNotification instead.
- (void)reload;

/// Synchronous form of -reload: resolves on the calling thread and returns with the new values
/// already published. Used for the very first resolve (the constructor needs `enabled` before it
/// can decide to do anything at all) and by tests; not for the playback path.
- (void)reloadNow;

/// Every resolved value, keyed by the CLPrefKey* constants from CLPrefsKeys.h, already coerced to
/// its native type (NSNumber for bool/int/float, NSString, or NSArray<NSString *>). For debug
/// logging only; not for driving UI (use the typed properties for that).
- (NSDictionary<NSString *, id> *)snapshot;

// MARK: General

@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) BOOL debugLogging;
@property (nonatomic, readonly, copy) NSArray<NSString *> *enabledApps;
@property (nonatomic, readonly) BOOL allApps;

// MARK: Lyrics

@property (nonatomic, readonly) NSInteger lyricsMode;               // the layout: 0 off, 2 No Artwork (full panel), 4 side by side (stored 1 and 3 read as 4)
@property (nonatomic, readonly, copy) NSString *lyricsFontFamily;   // "" = system font
@property (nonatomic, readonly) double lyricsFontSize;
@property (nonatomic, readonly) NSInteger lyricsFontWeight;         // 100...900
@property (nonatomic, readonly, copy) NSString *lyricsCurrentColorHex;
@property (nonatomic, readonly, copy) NSString *lyricsNextColorHex;
@property (nonatomic, readonly) double lyricsNextAlpha;
@property (nonatomic, readonly) NSInteger lyricsAlignment;          // 0 left, 1 center, 2 right
@property (nonatomic, readonly) BOOL lyricsAnimations;
@property (nonatomic, readonly) BOOL lyricsShowPlainWhenUnsynced;
@property (nonatomic, readonly) NSInteger lyricsOffsetMs;            // LRCLIB, custom, embedded
@property (nonatomic, readonly) NSInteger serviceLyricsOffsetMs;     // Spotify's and Apple Music's own lyrics
@property (nonatomic, readonly) BOOL lyricsShowNoteOnGap;
@property (nonatomic, readonly) NSInteger lyricsBackground;         // 0 none, 1 translucent pill, 2 solid
@property (nonatomic, readonly, copy) NSString *lyricsBackgroundColorHex;
@property (nonatomic, readonly) double lyricsBackgroundAlpha;

// MARK: Layout

@property (nonatomic, readonly) double artworkCornerRadius;
@property (nonatomic, readonly) NSInteger backdropStyle;            // 0 the host's blurred artwork backdrop, 1 plain (hidden)
@property (nonatomic, readonly) double backdropOpacity;             // 0...1, opacity of the host's backdrop image (1 = system)
@property (nonatomic, readonly) BOOL tintFromArtwork;
@property (nonatomic, readonly, copy) NSString *accentColorHex;     // "" = system tint
@property (nonatomic, readonly) BOOL showAlbum;
@property (nonatomic, readonly) NSInteger progressBarStyle;         // 0 show, 2 hide (stored 1, the removed thin bar, reads as 0)
@property (nonatomic, readonly) BOOL hidePlaybackRateButton;
@property (nonatomic, readonly) BOOL hideQueueButton;
@property (nonatomic, readonly) BOOL showLyricsButton;               // the microphone for full-screen lyrics
@property (nonatomic, readonly) NSInteger lyricsSide;                // 0 right, 1 left (beside a player column)

// MARK: Sources

@property (nonatomic, readonly, copy) NSArray<NSString *> *providerOrder;
@property (nonatomic, readonly) BOOL embeddedLyricsEnabled;
@property (nonatomic, readonly) BOOL appleMusicLyricsEnabled;
@property (nonatomic, readonly) BOOL lrclibEnabled;
@property (nonatomic, readonly) BOOL spotifyLyricsEnabled;
@property (nonatomic, readonly) BOOL spotifyCacheEnabled;
@property (nonatomic, readonly) BOOL customEndpointEnabled;
@property (nonatomic, readonly, copy) NSString *customEndpointURL;
@property (nonatomic, readonly, copy) NSString *customEndpointHeaderName;
@property (nonatomic, readonly, copy) NSString *customEndpointHeaderValue;
@property (nonatomic, readonly) BOOL offlineOnly;
@property (nonatomic, readonly) NSInteger cacheNegativeHours;

@end

NS_ASSUME_NONNULL_END
