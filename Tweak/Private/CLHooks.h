// Entry points the tweak's %ctor uses to drive the CarPlayUI hooks. Implemented in
// Tweak/Hooks/NowPlayingHooks.x (the %init(...) calls have to live in the file that declares the
// %groups, so Tweak.x drives them through this C API).
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs the hook groups whose classes are present in this process. Idempotent: every group is
/// initialised at most once, so this may be called again later (after another framework loaded)
/// to pick up a class that was missing the first time. Re-dispatches itself to the main queue
/// when called from anywhere else.
void CLInstallNowPlayingHooks(void);

/// Master switch, mirroring the `enabled` preference. While NO every hook body calls %orig and
/// returns without doing any of our work. Main thread only.
void CLHooksSetActive(BOOL active);
BOOL CLHooksActive(void);

/// Re-applies preferences to every Now Playing controller we are attached to. Main thread only.
void CLHooksApplyPrefsToAttachedControllers(void);

/// Detaches every layout customizer we created and forgets them, leaving the host's own layout
/// untouched. Used when the tweak is switched off at runtime. Main thread only.
void CLHooksDetachAll(void);

/// Posted (main thread, object = the controller) whenever a CPUINowPlayingViewController is about
/// to appear. In the Music app that means Apple Music's CarPlay Now Playing is on screen.
extern NSString *const CLNowPlayingScreenWillAppearNotification;

#pragma mark Apple Music app (Tweak/Hooks/MusicAppHooks.x)

/// Installs the MRNowPlayingPlayerClient hook that records the Music app's now-playing item into
/// CLMusicItemRegistry (and marks the registry live). Call only in com.apple.Music. Idempotent.
void CLInstallMusicAppHooks(void);
/// Master switch for that hook; safe from any thread.
void CLMusicAppHooksSetActive(BOOL active);
/// Records the current item again (CarPlay connected mid-song). Any thread; no-op until the hook
/// has seen a player client.
void CLMusicAppRecordNowPlaying(void);

#pragma mark Spotify app (Tweak/Hooks/SpotifyAppHooks.x)

/// Installs the NSURLSessionTask -resume hook that shows Spotify's API requests to
/// CLSpotifyRequestTemplate. Call only in com.spotify.client. Idempotent; safe from the constructor.
void CLInstallSpotifyAppHooks(void);
/// Master switch for that hook; safe from any thread.
void CLSpotifyAppHooksSetActive(BOOL active);

/// Runs `block`, swallowing and logging any NSException so that nothing we do can tear down the
/// CarPlay screen. `what` only ever appears in the error log.
void CLSafePerform(NSString *what, dispatch_block_t block);

NS_ASSUME_NONNULL_END
