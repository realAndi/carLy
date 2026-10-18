// carLy entry point.
//
// The constructor does the least it possibly can: read preferences, install the hooks, and hand
// the rest to the main queue. Two reasons for that shape.
//
//   * A %ctor runs from a dyld image initializer. CLNowPlayingSource resolves MediaRemote with
//     dlopen(), and calling dlopen() from an initializer can deadlock on the loader lock — so the
//     engine is started one main-queue turn later, never from the constructor itself.
//   * CarPlayTemplateUIHost is a system UI process. Anything slow here is time the CarPlay screen
//     is not on the display.
//
// Three processes load carLy (carLy.plist): CarPlayTemplateUIHost, which only runs while a
// head unit is connected, and — since 0.8.0 — the Music app, whose CarPlay UI runs in-process
// (PLAN.md §2). The Music app also runs without a car, so there the engine (MediaRemote, lyrics
// lookups, network) starts only while a CarPlay scene is connected, and stops when it goes away.
// The hooks are installed either way; without a CarPlay screen they have nothing to attach to.
// Since 0.9.0 Spotify loads it too, for one job only: fetching Spotify's own lyrics with Spotify's
// login when the host asks (CLSpotifyLyricsService). No engine, no UI hooks and no lyrics cache run
// there.
//
// Preferences are wired in exactly one place — here — so the lyrics engine stays testable from
// the tests/ tool with no preference plist at all.

#import <UIKit/UIKit.h>
#import <unistd.h>

#import "CLHooks.h"

#import "Core/CLLyricsController.h"
#import "Core/CLNowPlayingSource.h"
#import "Lyrics/CLLyricsCache.h"
#import "Lyrics/CLProviderFactory.h"
#import "Lyrics/CLSpotifyCacheProvider.h"
#import "Lyrics/CLSpotifyLyricsService.h"
#import "Util/CLLog.h"
#import "Util/CLPrefs.h"
#import "Util/CLPrefsKeys.h"

#ifndef CL_VERSION
#define CL_VERSION "dev"
#endif

/// YES once the tweak is activated (the `enabled` preference is on). Main thread only.
static BOOL gEngineRunning = NO;
/// YES while CLNowPlayingSource and CLLyricsController are started. In CarPlayTemplateUIHost this
/// follows gEngineRunning; in the Music app it also needs a CarPlay screen. Main thread only.
static BOOL gEngineStarted = NO;
/// Retained notification tokens; deliberately never removed (process-lifetime observers).
static id gPrefsChangedToken;
static id gClearCacheToken;
static id gResetToken;
static id gAppLaunchedToken;
static id gSceneTokens[3];
static id gNowPlayingAppearedToken;

#pragma mark - Process

static BOOL CLIsMusicProcess(void) {
    static BOOL isMusic;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        isMusic = [[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.Music"];
    });
    return isMusic;
}

static BOOL CLIsSpotifyProcess(void) {
    static BOOL isSpotify;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        isSpotify = [[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.spotify.client"];
    });
    return isSpotify;
}

/// The processes carLy.plist names. A bundle filter matches any process that has loaded the named
/// bundle, so anything else that ever matches stays untouched rather than being treated as the host.
static BOOL CLIsKnownProcess(void) {
    NSString *bundleIdentifier = [NSBundle mainBundle].bundleIdentifier;
    return CLIsMusicProcess() || CLIsSpotifyProcess() ||
           [bundleIdentifier isEqualToString:@"com.apple.CarPlayTemplateUIHost"];
}

#pragma mark - Provider chain

/// Builds the provider chain in the user's order, honouring each provider's own enable flag.
/// The rules themselves live in CLProviderFactory (a plain class, so tests/ can reach them); this
/// is only the adapter that reads them out of CLPrefs.
static NSArray<id<CLLyricsProvider>> *CLBuildProviders(CLPrefs *prefs) {
    NSArray<NSString *> *identifiers =
        [CLProviderFactory identifiersForOrder:prefs.providerOrder
                               embeddedEnabled:prefs.embeddedLyricsEnabled
                             appleMusicEnabled:prefs.appleMusicLyricsEnabled
                          spotifyLyricsEnabled:prefs.spotifyLyricsEnabled
                           spotifyCacheEnabled:prefs.spotifyCacheEnabled
                                 lrclibEnabled:prefs.lrclibEnabled
                         customEndpointEnabled:prefs.customEndpointEnabled
                                   offlineOnly:prefs.offlineOnly];
    return [CLProviderFactory providersForIdentifiers:identifiers
                                    customEndpointURL:prefs.customEndpointURL
                                 customEndpointHeader:prefs.customEndpointHeaderName
                           customEndpointHeaderValue:prefs.customEndpointHeaderValue];
}

/// Apps whose tracks this process looks lyrics up for (nil = every app). Apple Music's CarPlay
/// screen is drawn by the Music app, every other app's by CarPlayTemplateUIHost, so each process
/// only handles its own: otherwise both would look up (and hit LRCLIB for) every song while Music's
/// CarPlay scene is connected. With All Apps on, the host keeps looking everything up, as it always
/// did; the Music app still only handles Apple Music.
static NSSet<NSString *> *CLEnabledAppsForThisProcess(CLPrefs *prefs) {
    static NSString *const music = @"com.apple.Music";
    if (CLIsMusicProcess()) {
        BOOL musicEnabled = prefs.allApps || [prefs.enabledApps containsObject:music];
        return musicEnabled ? [NSSet setWithObject:music] : [NSSet set];
    }
    if (prefs.allApps) return nil;
    NSMutableSet<NSString *> *apps = [NSMutableSet setWithArray:prefs.enabledApps ?: @[]];
    [apps removeObject:music];
    return apps;
}

/// Pushes the current preferences into the engine. Pure object work: no disk, no network, safe to
/// call from the constructor and again on every preference change.
static void CLApplyPreferences(void) {
    CLPrefs *prefs = [CLPrefs shared];
    CLLyricsController *controller = [CLLyricsController sharedController];

    NSArray<id<CLLyricsProvider>> *providers = CLBuildProviders(prefs);
    controller.providers = providers;
    controller.enabledBundleIdentifiers = CLEnabledAppsForThisProcess(prefs);
    controller.offset = (NSTimeInterval)prefs.lyricsOffsetMs / 1000.0;
    controller.serviceOffset = (NSTimeInterval)prefs.serviceLyricsOffsetMs / 1000.0;

    NSInteger hours = prefs.cacheNegativeHours;
    if (hours < 1) hours = 1;
    if (hours > 24 * 30) hours = 24 * 30;
    [CLLyricsCache sharedCache].negativeTTL = (NSTimeInterval)hours * 3600.0;

    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:providers.count];
    for (id<CLLyricsProvider> provider in providers) {
        NSString *identifier = [provider respondsToSelector:@selector(identifier)] ? provider.identifier : nil;
        [names addObject:identifier ?: NSStringFromClass([provider class])];
    }
    CLLogInfo(@"providers: [%@]%@ | apps: %@ | offset: %ld ms (Spotify/Apple Music: %ld ms) | negative TTL: %ld h",
              [names componentsJoinedByString:@", "],
              prefs.offlineOnly ? @" (offline only)" : @"",
              prefs.allApps ? @"all" : [prefs.enabledApps componentsJoinedByString:@", "],
              (long)prefs.lyricsOffsetMs, (long)prefs.serviceLyricsOffsetMs, (long)hours);
}

#pragma mark - Hooks and engine

/// Every hook group this process wants. Idempotent per group, so safe to call again whenever a
/// framework may have loaded since.
static void CLInstallHooks(void) {
    CLInstallNowPlayingHooks();
    if (CLIsMusicProcess()) CLInstallMusicAppHooks();
}

/// CarPlayUI may not be loaded when the constructor runs. Installing hooks is idempotent per
/// group, so retry a few times rather than assume.
static void CLScheduleHookInstallRetries(void) {
    static BOOL scheduled = NO;
    if (scheduled) return;
    scheduled = YES;

    gAppLaunchedToken =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            CLInstallHooks();
        }];
    for (NSNumber *delay in @[ @1.0, @5.0 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CLInstallHooks();
        });
    }
}

/// Starts MediaRemote and the lyrics controller. Never from the constructor: see the note at the
/// top of this file. Main thread only.
static void CLStartEngine(NSString *reason) {
    if (!gEngineRunning || gEngineStarted) return;
    gEngineStarted = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        CLSafePerform(@"start engine", ^{
            if (!gEngineRunning || !gEngineStarted) return;
            CLInstallHooks();
            [[CLNowPlayingSource sharedSource] start];
            [[CLLyricsController sharedController] start];
            if (CLIsMusicProcess()) CLMusicAppRecordNowPlaying();
            CLHooksApplyPrefsToAttachedControllers();
            CLLogInfo(@"engine started (%@; MediaRemote available: %d)", reason,
                      (int)[CLNowPlayingSource sharedSource].mediaRemoteAvailable);
        });
    });
}

/// Main thread only.
static void CLStopEngine(NSString *reason) {
    if (!gEngineStarted) return;
    gEngineStarted = NO;
    [[CLLyricsController sharedController] stop];
    CLLogInfo(@"engine stopped (%@)", reason);
}

#pragma mark - CarPlay scenes (Music app)

/// The Music app's CarPlay scenes that are connected right now: recognised by idiom or role when
/// they connect, or learnt from the window of a CarPlayUI Now Playing screen. Weak, and pruned on
/// every scene disconnect, so the engine stops once none of them is left.
static NSHashTable<UIScene *> *CLCarPlayScenes(void) {
    static NSHashTable *scenes;
    if (!scenes) scenes = [NSHashTable weakObjectsHashTable];
    return scenes;
}

/// A scene on a car screen. The idiom is the public signal; the role catches a scene whose screen
/// is not set up yet.
static BOOL CLSceneIsCarPlay(UIScene *scene) {
    if (![scene isKindOfClass:[UIWindowScene class]]) return NO;
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    BOOL carIdiom = windowScene.screen.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomCarPlay ||
                    windowScene.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomCarPlay;
    NSString *role = scene.session.role ?: @"";
    BOOL carRole = [role rangeOfString:@"CarPlay" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                   [role hasPrefix:@"CPTemplateApplication"];
    return carIdiom || carRole;
}

/// Remembers `scene` as a CarPlay scene (logging what it calls itself, once) and starts the engine.
static void CLAddCarPlayScene(UIScene *scene, NSString *event) {
    if (!gEngineRunning || !scene) return;
    // CarPlayUI may only have been loaded for this scene: retry every event, not just the first.
    CLInstallHooks();
    if (![CLCarPlayScenes() containsObject:scene]) {
        [CLCarPlayScenes() addObject:scene];
        UIWindowScene *windowScene = [scene isKindOfClass:[UIWindowScene class]] ? (UIWindowScene *)scene : nil;
        CLLogInfo(@"[music] CarPlay scene %@ %@ (role %@, screen idiom %ld)", NSStringFromClass([scene class]),
                  event, scene.session.role ?: @"?", (long)windowScene.screen.traitCollection.userInterfaceIdiom);
    }
    CLStartEngine([NSString stringWithFormat:@"CarPlay scene %@", event]);
}

static void CLCarPlaySceneConnected(UIScene *scene, NSString *event) {
    if (!gEngineRunning || !CLSceneIsCarPlay(scene)) return;
    CLAddCarPlayScene(scene, event);
}

static void CLCarPlaySceneDisconnected(UIScene *scene) {
    [CLCarPlayScenes() removeObject:scene];
    // Also drops scenes that went away without a notification (the table is weak), and anything
    // UIKit no longer lists as connected.
    NSSet<UIScene *> *connected = [UIApplication sharedApplication].connectedScenes ?: [NSSet set];
    for (UIScene *known in CLCarPlayScenes().allObjects) {
        if (known == scene || ![connected containsObject:known]) [CLCarPlayScenes() removeObject:known];
    }
    if (gEngineStarted && CLCarPlayScenes().allObjects.count == 0) CLStopEngine(@"CarPlay disconnected");
}

/// A CarPlayUI Now Playing screen only exists on a car display, so its window's scene is a CarPlay
/// scene even when neither idiom nor role said so. The window is attached a moment after
/// -viewWillAppear:, hence the next turn.
static void CLNowPlayingScreenAppeared(UIViewController *controller) {
    CLStartEngine(@"CarPlay Now Playing appeared");
    __weak UIViewController *weakController = controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        CLSafePerform(@"now playing scene", ^{
            UIWindowScene *scene = weakController.viewIfLoaded.window.windowScene;
            if (scene) CLAddCarPlayScene(scene, @"from its Now Playing screen");
        });
    });
}

static void CLObserveCarPlayScenes(void) {
    static BOOL observing = NO;
    if (observing) return;
    observing = YES;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    NSOperationQueue *main = [NSOperationQueue mainQueue];
    gSceneTokens[0] = [center addObserverForName:UISceneWillConnectNotification object:nil queue:main
                                      usingBlock:^(NSNotification *note) {
        CLSafePerform(@"scene connect", ^{ CLCarPlaySceneConnected(note.object, @"connected"); });
    }];
    gSceneTokens[1] = [center addObserverForName:UISceneDidActivateNotification object:nil queue:main
                                      usingBlock:^(NSNotification *note) {
        CLSafePerform(@"scene activate", ^{ CLCarPlaySceneConnected(note.object, @"active"); });
    }];
    gSceneTokens[2] = [center addObserverForName:UISceneDidDisconnectNotification object:nil queue:main
                                      usingBlock:^(NSNotification *note) {
        CLSafePerform(@"scene disconnect", ^{ CLCarPlaySceneDisconnected(note.object); });
    }];
    // Belt and braces: a Now Playing screen from CarPlayUI only exists on a car display.
    gNowPlayingAppearedToken = [center addObserverForName:CLNowPlayingScreenWillAppearNotification
                                                   object:nil
                                                    queue:main
                                               usingBlock:^(NSNotification *note) {
        CLSafePerform(@"now playing appeared", ^{
            if ([note.object isKindOfClass:[UIViewController class]]) CLNowPlayingScreenAppeared(note.object);
        });
    }];
}

#pragma mark - Activation

static void CLActivate(void) {
    if (gEngineRunning) return;
    gEngineRunning = YES;

    CLApplyPreferences();
    CLHooksSetActive(YES);
    if (CLIsMusicProcess()) CLMusicAppHooksSetActive(YES);
    CLInstallHooks();
    CLScheduleHookInstallRetries();

    if (!CLIsMusicProcess()) {
        CLStartEngine(@"CarPlayTemplateUIHost");
        return;
    }
    CLObserveCarPlayScenes();
    // Already on a car screen (the tweak was switched on while connected)?
    dispatch_async(dispatch_get_main_queue(), ^{
        CLSafePerform(@"find CarPlay scenes", ^{
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                CLCarPlaySceneConnected(scene, @"already connected");
            }
            if (!gEngineStarted) CLLogInfo(@"[music] no CarPlay screen yet; the engine waits for one");
        });
    });
}

static void CLDeactivate(void) {
    if (!gEngineRunning) return;
    gEngineRunning = NO;

    CLHooksSetActive(NO);
    CLMusicAppHooksSetActive(NO);
    CLHooksDetachAll();
    CLStopEngine(@"disabled");
    [CLCarPlayScenes() removeAllObjects];
    CLLogInfo(@"deactivated: 'enabled' is off. Hooks stay installed but do nothing but %%orig.");
}

#pragma mark - Spotify (0.9.0)

/// Runs the lyrics service in Spotify while the host may ask it anything: the tweak is on, the
/// Spotify source is on, and Offline Only is off (the service's one job is a network request).
/// Called from the constructor and on every preference change; main thread.
static void CLSpotifyApplyPreferences(void) {
    static BOOL running = NO;
    CLPrefs *prefs = [CLPrefs shared];
    BOOL wanted = prefs.enabled && prefs.spotifyLyricsEnabled && !prefs.offlineOnly;
    if (wanted) {
        CLInstallSpotifyAppHooks();
        CLSpotifyAppHooksSetActive(YES);
        [[CLSpotifyLyricsService sharedService] start];
    } else {
        CLSpotifyAppHooksSetActive(NO);
        [[CLSpotifyLyricsService sharedService] stop];
    }
    if (wanted != running) {
        CLLogInfo(@"[spotify] Spotify lyrics %@ (enabled %d, source %d, offline only %d)", wanted ? @"on" : @"off",
                  (int)prefs.enabled, (int)prefs.spotifyLyricsEnabled, (int)prefs.offlineOnly);
    }
    running = wanted;
}

#pragma mark - Preference notifications

static void CLObservePreferences(void) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    NSOperationQueue *main = [NSOperationQueue mainQueue];

    gPrefsChangedToken = [center addObserverForName:CLPrefsDidChangeNotification
                                             object:nil
                                              queue:main
                                         usingBlock:^(NSNotification *note) {
        CLSafePerform(@"prefs changed", ^{
            // CLPrefs has already re-resolved every value and updated the debug-log gate.
            if (CLIsSpotifyProcess()) {
                CLSpotifyApplyPreferences();
                return;
            }
            if ([CLPrefs shared].enabled) {
                if (!gEngineRunning) {
                    CLLogInfo(@"enabled by preference change");
                    CLActivate();
                } else {
                    CLApplyPreferences();
                    CLHooksApplyPrefsToAttachedControllers();
                }
            } else {
                CLDeactivate();
            }
        });
    }];

    gClearCacheToken = [center addObserverForName:CLPrefsClearCacheNotification
                                           object:nil
                                            queue:main
                                       usingBlock:^(NSNotification *note) {
        CLSafePerform(@"clear cache", ^{
            if (CLIsSpotifyProcess()) return;   // no lyrics cache in Spotify
            // Works whether or not the tweak is enabled: the user asked for the disk to be tidied.
            [[CLLyricsController sharedController] clearCache];
            [CLSpotifyCacheProvider clearDatabaseCopies];
            CLLogInfo(@"lyrics cache and Spotify database copies cleared");
        });
    }];

    gResetToken = [center addObserverForName:CLPrefsResetNotification
                                      object:nil
                                       queue:main
                                  usingBlock:^(NSNotification *note) {
        CLSafePerform(@"reset defaults", ^{
            // The Prefs bundle deletes the keys; we just re-read, which posts
            // CLPrefsDidChangeNotification and lands in the handler above.
            CLLogInfo(@"preferences reset to defaults; reloading");
            [[CLPrefs shared] reload];
        });
    }];
}

#pragma mark - Constructor

%ctor {
    @autoreleasepool {
        @try {
            CLPrefs *prefs = [CLPrefs shared];
            CLLogSetDebugEnabled(prefs.debugLogging);
            CLLogInfo(@"carLy %s loaded into %@ (pid %d, debug %d, log: %@)",
                      CL_VERSION,
                      [NSBundle mainBundle].bundleIdentifier ?: @"(unknown process)",
                      (int)getpid(), (int)prefs.debugLogging, CLLogFilePath());

            if (!CLIsKnownProcess()) {
                CLLogInfo(@"not a process carLy works in; staying inert");
                return;
            }

            // Registered even when disabled: flipping the master switch in Settings has to reach
            // a process that is already running, without a respring.
            CLObservePreferences();

            if (CLIsSpotifyProcess()) {
                // The hook goes in now, so Spotify's first API requests already teach the template
                // its login; the service (an NSURLSession, a notification registration, a file write)
                // starts one main-queue turn later, like the engine elsewhere.
                if (prefs.enabled && prefs.spotifyLyricsEnabled && !prefs.offlineOnly) {
                    CLInstallSpotifyAppHooks();
                    CLSpotifyAppHooksSetActive(YES);
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    CLSafePerform(@"start Spotify lyrics", ^{ CLSpotifyApplyPreferences(); });
                });
                return;
            }

            if (!prefs.enabled) {
                CLLogInfo(@"'enabled' is off — idle, watching for preference changes");
                return;
            }
            CLActivate();
        } @catch (NSException *exception) {
            CLLogError(@"constructor raised %@: %@ — carLy is inert for this launch",
                       exception.name, exception.reason);
        }
    }
}
