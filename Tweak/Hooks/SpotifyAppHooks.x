// Spotify app hooks (com.spotify.client only, 0.9.0).
//
// carLy loads into Spotify for one reason: Spotify's own lyrics need Spotify's login, and only
// Spotify's process has it (PLAN.md Phase 3, Option B). One hook watches the requests Spotify sends
// to its own API and lets CLSpotifyRequestTemplate keep the newest headers in memory;
// CLSpotifyLyricsService then fetches `color-lyrics/v2/track/<id>` with them whenever the CarPlay
// host asks through CLSpotifyBridge. Nothing of Spotify's UI is touched.
//
// The hook point, verified in the 17.3 shared cache (CFNetwork): -[NSURLSessionTask resume] is
// implemented by NSURLSessionTask itself and overridden by no data, upload or download task class
// (__NSCFLocalSessionTask and its subclasses only add -_onqueue_resume), so every task any session
// in Spotify starts passes through it, completion-handler, delegate and Swift async alike. It runs
// for every task Spotify starts (images, audio, everything), so the body is a flag read and a host
// suffix check before anything else.
//
// Same rules as every other hook: %orig first, nothing that can throw escapes, and the switch turns
// the body into a plain %orig.

#import <objc/runtime.h>
#import <stdatomic.h>

#import "CLHooks.h"
#import "Lyrics/CLSpotifyLyricsService.h"
#import "Lyrics/CLSpotifyRequestTemplate.h"
#import "Util/CLLog.h"

/// Mirrors "the Spotify source is on"; read on whatever thread resumes a task, hence atomic.
static atomic_bool gSpotifyHooksActive = false;

static void CLSpotifyObserveTask(NSURLSessionTask *task) {
    @try {
        NSURLRequest *request = task.currentRequest ?: task.originalRequest;
        if (![CLSpotifyRequestTemplate isSpotifyAPIHost:request.URL.host]) return;
        if ([[CLSpotifyRequestTemplate sharedTemplate] observeRequest:request]) {
            [[CLSpotifyLyricsService sharedService] requestTemplateDidChange];
        }
    } @catch (NSException *exception) {
        CLLogError(@"[spotify] observing a request raised %@: %@", exception.name, exception.reason);
    }
}

%group CLGroupSpotifyNetworking

%hook NSURLSessionTask

- (void)resume {
    %orig;
    if (!atomic_load(&gSpotifyHooksActive)) return;
    CLSpotifyObserveTask(self);
}

%end

%end  // CLGroupSpotifyNetworking

#pragma mark - Public entry points (CLHooks.h)

void CLSpotifyAppHooksSetActive(BOOL active) {
    atomic_store(&gSpotifyHooksActive, active ? true : false);
}

void CLInstallSpotifyAppHooks(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class taskClass = objc_getClass("NSURLSessionTask");
    if (!taskClass || ![taskClass instancesRespondToSelector:@selector(resume)] ||
        ![taskClass instancesRespondToSelector:@selector(currentRequest)]) {
        CLLogInfo(@"[spotify] NSURLSessionTask -resume not found; Spotify lyrics are unavailable");
        return;
    }
    installed = YES;
    %init(CLGroupSpotifyNetworking);
    CLLogInfo(@"[spotify] installed NSURLSessionTask -resume");
}
