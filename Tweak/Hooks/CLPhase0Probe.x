// PLAN.md §5, Phase 0 — the one-shot probe.
//
// Testing this tweak needs a real head unit, and a drive is expensive. So the first time a Now
// Playing screen appears with debugLogging on, we answer every open question in the plan at once
// and write it all to <NSCachesDirectory>/carLy/log.txt:
//
//   1. the real view hierarchy and layout class of CPUINowPlayingViewController
//   2. whether MediaRemote works inside this process, and what keys it hands back
//   3. whether this sandbox can reach the network (a single GET to lrclib.net)
//   4. whether it can read Spotify's container (access(2) + errno, no guessing)
//   5. which cache directory is actually writable from here
//   6. what is in the navigation bar, so the Phase 2 toggle button has somewhere to go
//
// Nothing here changes any state. UIKit is read on the main thread, every disk and network check
// runs on a background queue, and the whole thing is inert unless the user turned debugLogging on.

#import <UIKit/UIKit.h>
#import <errno.h>
#import <objc/runtime.h>
#import <string.h>
#import <unistd.h>

#import "CLHooks.h"
#import "CLPhase0Probe.h"
#import "CarPlayUI.h"

#import "Core/CLNowPlayingSource.h"
#import "Util/CLLog.h"
#import "Util/CLPrefs.h"
#import "Util/CLPrefsKeys.h"
#import "Util/CLRuntime.h"
#import "Util/CLSpotifyContainer.h"

#ifndef CL_VERSION
#define CL_VERSION "dev"
#endif

static NSString *const kCLProbeRepository = @"https://github.com/realAndi/carLy";
static NSString *const kCLProbeURL =
    @"https://lrclib.net/api/get?track_name=Yellow&artist_name=Coldplay&duration=267";

#pragma mark - Main-thread (UIKit) half

/// The preference snapshot with the user's own secrets taken out. customEndpointHeaderValue is
/// typically an API key the user owns, and a URL template can carry one in a query parameter, so
/// neither is ever written to a log file that gets pasted into a bug report.
static NSDictionary<NSString *, id> *CLProbeRedactedPrefs(void) {
    NSDictionary<NSString *, id> *snapshot = [CLPrefs shared].snapshot;
    if (![snapshot isKindOfClass:[NSDictionary class]]) return @{};
    NSMutableDictionary<NSString *, id> *redacted = [snapshot mutableCopy];
    id headerValue = redacted[CLPrefKeyCustomEndpointHeaderValue];
    if ([headerValue isKindOfClass:[NSString class]] && ((NSString *)headerValue).length) {
        redacted[CLPrefKeyCustomEndpointHeaderValue] = @"<redacted>";
    }
    id url = redacted[CLPrefKeyCustomEndpointURL];
    if ([url isKindOfClass:[NSString class]] && ((NSString *)url).length) {
        NSString *host = [NSURL URLWithString:(NSString *)url].host;
        redacted[CLPrefKeyCustomEndpointURL] =
            host.length ? [NSString stringWithFormat:@"<set: %@>", host] : @"<set>";
    }
    return redacted;
}

static NSString *CLProbeDescribeBarButtonItem(UIBarButtonItem *item) {
    if (![item isKindOfClass:[UIBarButtonItem class]]) return @"(not a UIBarButtonItem)";
    NSMutableString *description =
        [NSMutableString stringWithFormat:@"%@", NSStringFromClass(object_getClass(item))];
    if (item.title.length) [description appendFormat:@" title=%@", item.title];
    if (item.image) [description appendString:@" image=yes"];
    if (item.customView) {
        [description appendFormat:@" customView=%@", NSStringFromClass(object_getClass(item.customView))];
    }
    if (item.action) [description appendFormat:@" action=%@", NSStringFromSelector(item.action)];
    if (item.target) [description appendFormat:@" target=%@", NSStringFromClass(object_getClass(item.target))];
    [description appendFormat:@" enabled=%d tag=%ld", (int)item.enabled, (long)item.tag];
    return description;
}

static void CLProbeLogBarButtonItems(UIViewController *controller) {
    UINavigationItem *navigationItem = controller.navigationItem;
    if (!navigationItem) {
        CLLogInfo(@"[probe] navigationItem is nil");
        return;
    }
    CLLogInfo(@"[probe] navigationItem title=%@ titleView=%@ hidesBackButton=%d",
              navigationItem.title ?: @"(nil)",
              navigationItem.titleView ? NSStringFromClass(object_getClass(navigationItem.titleView)) : @"(nil)",
              (int)navigationItem.hidesBackButton);

    NSArray<UIBarButtonItem *> *left = navigationItem.leftBarButtonItems ?: @[];
    NSArray<UIBarButtonItem *> *right = navigationItem.rightBarButtonItems ?: @[];
    CLLogInfo(@"[probe] bar button items: %lu left, %lu right",
              (unsigned long)left.count, (unsigned long)right.count);
    for (NSUInteger i = 0; i < left.count; i++) {
        CLLogInfo(@"[probe]   left[%lu] %@", (unsigned long)i, CLProbeDescribeBarButtonItem(left[i]));
    }
    for (NSUInteger i = 0; i < right.count; i++) {
        CLLogInfo(@"[probe]   right[%lu] %@", (unsigned long)i, CLProbeDescribeBarButtonItem(right[i]));
    }

    for (NSString *name in @[ @"_playbackQueueBarButtonItem", @"_rightTitleLabelBarButtonItem",
                              @"_activityIndicatorBarButtonItem" ]) {
        id item = CLIvar(controller, name);
        CLLogInfo(@"[probe]   %@ = %@", name,
                  item ? CLProbeDescribeBarButtonItem(item) : @"(nil / absent)");
    }
}

static void CLProbeLogViewHierarchy(UIViewController *controller) {
    UIView *view = controller.isViewLoaded ? controller.view : nil;
    if (!view) {
        CLLogInfo(@"[probe] the controller's view is not loaded yet");
        return;
    }
    CLLogInfo(@"[probe] controller %@ view %@ bounds %@ traits %@",
              NSStringFromClass(object_getClass(controller)),
              NSStringFromClass(object_getClass(view)),
              NSStringFromCGRect(view.bounds),
              @(view.traitCollection.userInterfaceStyle));

    id nowPlayingView = CLIvar(controller, @"_nowPlayingView");
    id layout = CLIvar(nowPlayingView, @"_nowPlayingLayout");
    CLLogInfo(@"[probe] _nowPlayingView=%@ _nowPlayingLayout=%@ _artworkView=%@",
              nowPlayingView ? NSStringFromClass(object_getClass(nowPlayingView)) : @"(nil)",
              layout ? NSStringFromClass(object_getClass(layout)) : @"(nil)",
              CLIvar(controller, @"_artworkView")
                  ? NSStringFromClass(object_getClass(CLIvar(controller, @"_artworkView")))
                  : @"(nil)");
    for (NSString *name in @[ @"_songDetailsView", @"_progressView", @"_transportControlView",
                              @"_playModeControlView", @"_artworkViewBrick" ]) {
        id subview = CLIvar(nowPlayingView, name);
        CLLogInfo(@"[probe]   %@ = %@", name,
                  subview ? NSStringFromClass(object_getClass(subview)) : @"(nil / absent)");
    }
    CLLogInfo(@"[probe] view hierarchy:\n%@", CLViewHierarchy(view));
}

#pragma mark - Background half: disk

static void CLProbeAccess(NSString *label, NSString *path) {
    if (path.length == 0) {
        CLLogInfo(@"[probe] %@ : path unknown (container not resolved)", label);
        return;
    }
    const char *filesystemPath = path.fileSystemRepresentation;
    if (filesystemPath == NULL) {
        CLLogInfo(@"[probe] %@ : %@ (unrepresentable path)", label, path);
        return;
    }
    errno = 0;
    int readable = access(filesystemPath, R_OK);
    int readErrno = errno;
    errno = 0;
    int exists = access(filesystemPath, F_OK);
    int existsErrno = errno;
    CLLogInfo(@"[probe] %@ : %@ exists=%d(%s) readable=%d(%s)", label, path,
              exists == 0, exists == 0 ? "ok" : strerror(existsErrno),
              readable == 0, readable == 0 ? "ok" : strerror(readErrno));
}

static void CLProbeWritable(NSString *path) {
    if (path.length == 0) return;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    if (![fileManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error]) {
        CLLogInfo(@"[probe] %@ : cannot create (%@)", path, error.localizedDescription ?: @"unknown");
        return;
    }
    NSString *file = [path stringByAppendingPathComponent:@".carly-write-probe"];
    NSError *writeError = nil;
    BOOL wrote = [[@"probe" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:file
                                                                        options:NSDataWritingAtomic
                                                                          error:&writeError];
    if (wrote) {
        [fileManager removeItemAtPath:file error:NULL];
        CLLogInfo(@"[probe] %@ : WRITABLE", path);
    } else {
        CLLogInfo(@"[probe] %@ : not writable (%@)", path, writeError.localizedDescription ?: @"unknown");
    }
}

static void CLProbeDisk(void) {
    CLLogInfo(@"[probe] --- Spotify container ---");
    NSString *container = [CLSpotifyContainer dataContainerPath];
    CLLogInfo(@"[probe] dataContainerPath = %@", container ?: @"(nil — not found or sandboxed)");
    CLProbeAccess(@"Cache.db", [CLSpotifyContainer cacheDatabasePath]);
    CLProbeAccess(@"fsCachedData", [CLSpotifyContainer fsCachedDataDirectory]);
    CLProbeAccess(@"lyrics_offline.sqlite3", [CLSpotifyContainer offlineLyricsDatabasePath]);
    CLLogInfo(@"[probe] isPathReadable(Cache.db) = %d",
              (int)[CLSpotifyContainer isPathReadable:[CLSpotifyContainer cacheDatabasePath]]);

    CLLogInfo(@"[probe] --- writable cache locations ---");
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    CLLogInfo(@"[probe] NSCachesDirectory = %@", caches ?: @"(nil)");
    if (caches.length) CLProbeWritable([caches stringByAppendingPathComponent:@"carLy"]);
    CLProbeWritable(@"/var/mobile/Library/Caches/carLy");
    CLProbeWritable(@"/var/jb/var/mobile/Library/Caches/carLy");
    CLLogInfo(@"[probe] log file = %@", CLLogFilePath());
}

#pragma mark - Background half: network

static void CLProbeNetwork(void) {
    if ([CLPrefs shared].offlineOnly) {
        CLLogInfo(@"[probe] network check skipped (offlineOnly is on)");
        return;
    }
    NSURL *url = [NSURL URLWithString:kCLProbeURL];
    if (!url) {
        CLLogInfo(@"[probe] network check skipped (bad probe URL)");
        return;
    }
    NSString *client = [NSString stringWithFormat:@"carLy %s (%@)", CL_VERSION, kCLProbeRepository];
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 8.0;
    configuration.timeoutIntervalForResource = 20.0;
    configuration.HTTPShouldSetCookies = NO;
    configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
    configuration.HTTPAdditionalHeaders = @{ @"Lrclib-Client": client,
                                             @"User-Agent": client,
                                             @"Accept": @"application/json" };
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    NSDate *started = [NSDate date];

    CLLogInfo(@"[probe] GET %@", kCLProbeURL);
    NSURLSessionDataTask *task = [session dataTaskWithURL:url
                                       completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        double elapsed = -[started timeIntervalSinceNow];
        if (error) {
            CLLogInfo(@"[probe] network: FAILED after %.2fs — %@ %ld: %@", elapsed,
                      error.domain, (long)error.code, error.localizedDescription);
        } else {
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
                                   ? ((NSHTTPURLResponse *)response).statusCode
                                   : -1;
            BOOL synced = NO;
            if (data.length) {
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                if ([json isKindOfClass:[NSDictionary class]]) {
                    id value = ((NSDictionary *)json)[@"syncedLyrics"];
                    synced = [value isKindOfClass:[NSString class]] && ((NSString *)value).length > 0;
                }
            }
            // Never the lyrics themselves — only whether the field was there.
            CLLogInfo(@"[probe] network: OK after %.2fs — HTTP %ld, %lu bytes, syncedLyrics=%d",
                      elapsed, (long)status, (unsigned long)data.length, (int)synced);
        }
        [session finishTasksAndInvalidate];
        CLLogInfo(@"[probe] ---- end of Phase 0 probe ----");
    }];
    [task resume];
}

#pragma mark - Entry point

void CLRunPhase0ProbeOnce(UIViewController *controller) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ CLRunPhase0ProbeOnce(controller); });
        return;
    }
    static BOOL done = NO;
    if (done) return;
    // Not marked done until it actually runs, so switching debugLogging on mid-drive still arms it.
    if (![CLPrefs shared].debugLogging) return;
    done = YES;

    CLSafePerform(@"phase 0 probe (main)", ^{
        CLLogInfo(@"[probe] ---- carLy %s Phase 0 probe ----", CL_VERSION);
        CLLogInfo(@"[probe] process %@ (pid %d), iOS %@",
                  [NSBundle mainBundle].bundleIdentifier ?: @"(unknown)",
                  (int)getpid(), [UIDevice currentDevice].systemVersion);
        CLLogInfo(@"[probe] prefs: %@", CLProbeRedactedPrefs());

        if (controller) {
            CLProbeLogViewHierarchy(controller);
            CLProbeLogBarButtonItems(controller);
        } else {
            CLLogInfo(@"[probe] no view controller supplied; skipping the UIKit half");
        }

        CLNowPlayingSource *source = [CLNowPlayingSource sharedSource];
        CLLogInfo(@"[probe] MediaRemote available=%d canSeek=%d running=%d",
                  (int)source.mediaRemoteAvailable, (int)source.canSeek, (int)source.isRunning);
        CLLogInfo(@"[probe] now playing source: %@", [source debugDescription]);
    });

    // Disk and network never on the main thread: the container walk stats hundreds of
    // directories and this process is drawing the screen the driver is looking at.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CLSafePerform(@"phase 0 probe (disk)", ^{ CLProbeDisk(); });
        CLSafePerform(@"phase 0 probe (network)", ^{ CLProbeNetwork(); });
    });
}
