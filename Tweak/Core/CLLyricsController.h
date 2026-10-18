// The brain: watches CLNowPlayingSource, resolves lyrics (cache, then provider chain), drives
// CLLyricsSyncEngine and publishes everything the UI needs. Foundation only.
// All observers are called on the main queue; every public method is safe to call from any thread.
#import <Foundation/Foundation.h>
#import "Core/CLPlaybackState.h"
#import "Lyrics/CLLyricsTypes.h"
#import "Sync/CLLyricsSyncEngine.h"

NS_ASSUME_NONNULL_BEGIN

@class CLLyricsController;

typedef NS_ENUM(NSInteger, CLLyricsControllerStatus) {
    CLLyricsControllerStatusIdle = 0,      ///< nothing playing, or no usable metadata
    CLLyricsControllerStatusDisabled,      ///< the now-playing app is not enabled for lyrics
    CLLyricsControllerStatusLoading,       ///< a lookup is in flight
    CLLyricsControllerStatusLoaded,        ///< currentLyrics is set (synced, plain or instrumental)
    CLLyricsControllerStatusUnavailable,   ///< every provider missed for this track
};

typedef NS_OPTIONS(NSUInteger, CLLyricsControllerChange) {
    CLLyricsControllerChangePlayback = 1 << 0,   ///< currentState changed
    CLLyricsControllerChangeLyrics   = 1 << 1,   ///< currentLyrics or status changed
    CLLyricsControllerChangeLine     = 1 << 2,   ///< currentLineIndex changed
};

/// Called on the main queue. Read the current values off the controller.
typedef void (^CLLyricsControllerObserverBlock)(CLLyricsController *controller,
                                                CLLyricsControllerChange change);

@interface CLLyricsController : NSObject

+ (instancetype)sharedController;
- (instancetype)init NS_UNAVAILABLE;

#pragma mark Configuration (set these before -start; changing them later re-evaluates)

/// Providers in priority order. Setting this rebuilds the internal CLProviderChain.
@property (nonatomic, copy) NSArray<id<CLLyricsProvider>> *providers;
/// Bundle identifiers allowed to show lyrics. nil means "every app"; an empty set means none.
@property (nonatomic, copy, nullable) NSSet<NSString *> *enabledBundleIdentifiers;
/// Whether `bundleIdentifier` passes that filter (an unknown app never does while one is set).
/// The same rule the controller applies to playback; the layout uses it per Now Playing screen.
- (BOOL)isBundleEnabled:(nullable NSString *)bundleIdentifier;
/// Seconds added to the playback position before picking a line (positive = lyrics run ahead), for
/// lyrics from community and local sources: LRCLIB, the custom endpoint, embedded lyrics.
@property (nonatomic) NSTimeInterval offset;
/// The same for lyrics timed by the playing app's own service (+isServiceTimedSource:): those are
/// timed against that service's audio, so an offset tuned for LRCLIB must not move them (0.9.0).
@property (nonatomic) NSTimeInterval serviceOffset;
/// "spotify", "spotify-cache" and "apple-music": the sources whose timings come from the service
/// that plays the song.
+ (BOOL)isServiceTimedSource:(nullable NSString *)source;

#pragma mark Lifecycle

- (void)start;
- (void)stop;
@property (nonatomic, readonly, getter=isStarted) BOOL started;

#pragma mark Display gating

/// The UI tells the controller whether anything is actually *showing* the current line. The sync
/// engine's tick is a main-queue timer in a system UI process, and while the CarPlay Now Playing
/// screen is offscreen (the driver is in maps, on a call, in another template app) nobody reads
/// the line index — so the last display to go away slows the tick right down, and the first one
/// to come back restores it and re-evaluates immediately.
///
/// These are **balanced** calls: every -displayDidBecomeActive is matched by exactly one
/// -displayDidResignActive. The controller only keeps a count, so two customizers overlapping
/// while the host swaps its Now Playing view controller cannot leave the engine stuck slow (or
/// stuck fast) whichever order their attach/pause/detach calls land in. Safe from any thread; the
/// count is maintained on the main queue.
- (void)displayDidBecomeActive;
- (void)displayDidResignActive;
/// How many active displays are currently counted. Main queue only; for tests and -description.
@property (nonatomic, readonly) NSInteger activeDisplayCount;

#pragma mark Published state

@property (nonatomic, readonly) CLPlaybackState *currentState;
@property (nonatomic, readonly, nullable) CLLyrics *currentLyrics;
@property (nonatomic, readonly) NSInteger currentLineIndex;   ///< CLLyricsNoLine (-1) before the first line
@property (nonatomic, readonly) CLLyricsControllerStatus status;
/// YES when there are synced lines to follow right now.
@property (nonatomic, readonly) BOOL hasSyncedLyrics;
/// Line at `index`, or nil when out of range. Convenience for the UI.
- (nullable CLLyricLine *)lineAtIndex:(NSInteger)index;
/// 0...1 through the current line, for animations.
- (NSTimeInterval)progressWithinCurrentLine;

- (id)addObserver:(CLLyricsControllerObserverBlock)observer;
- (void)removeObserver:(nullable id)token;

#pragma mark Test seam (the tweak never calls these)

/// Like -start, but without subscribing to CLNowPlayingSource — so without dlopen'ing
/// MediaRemote, registering for its notifications, or picking up whatever happens to be playing
/// on the device. The caller feeds playback with -ingestPlaybackState: instead. This exists so
/// the tests tool can exercise app gating, track changes mid-fetch and teardown deterministically
/// (tests/CLLyricsControllerTests.m); carLy itself always calls -start.
- (void)startDetached;
/// Feeds a playback state exactly as the CLNowPlayingSource observer would. No-op unless started.
- (void)ingestPlaybackState:(CLPlaybackState *)state;

#pragma mark Actions

/// Seeks playback so that `index` becomes the current line (no-op when the index is out of range
/// or MediaRemote cannot seek).
- (void)seekToLineAtIndex:(NSInteger)index;
/// "These lyrics are wrong": re-runs the provider chain for the current track, bypassing the
/// cache, and stores whatever comes back.
- (void)reloadLyricsIgnoringCache;
/// Empties the lyrics cache and re-resolves the current track.
- (void)clearCache;

@end

NS_ASSUME_NONNULL_END
