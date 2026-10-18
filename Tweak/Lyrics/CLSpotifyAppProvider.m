#import "CLSpotifyAppProvider.h"
#import "CLSpotifyBridge.h"
#import "CLSpotifyBridgeResponse.h"
#import "Util/CLLog.h"

#import <errno.h>
#import <math.h>
#import <notify.h>
#import <signal.h>

NSString *const CLSpotifyAppProviderErrorDomain = @"CLSpotifyAppProviderErrorDomain";

static NSString *const kCLSpotifyAppIdentifier = @"spotify";
static const NSTimeInterval kCLDefaultTimeout = 6.0;
static const NSTimeInterval kCLDefaultUnauthorizedTimeout = 3.0;
/// How often a waiting lookup looks for its answer when no notification arrives.
static const NSTimeInterval kCLPollInterval = 0.25;

// Waiter dictionary keys.
static NSString *const kCLWaiterTrackID = @"trackID";
static NSString *const kCLWaiterCompletion = @"completion";
static NSString *const kCLWaiterDeadline = @"deadline";
static NSString *const kCLWaiterStarted = @"started";

#pragma mark - Shared state (CLSpotifyAppQueue only)

/// Every instance shares one queue, one list of waiting lookups, one poll timer and one
/// notification registration: there is one bridge, and two waiters for the same track (a chain run
/// again after a settings change) must both get the one answer.
static dispatch_queue_t CLSpotifyAppQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.andi.carly.spotify-app", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSMutableArray<NSMutableDictionary *> *gWaiters;
static dispatch_source_t gPollTimer;
/// What the last "is anyone answering in Spotify" check said, so the log says it once per change:
/// 0 unknown, -1 nobody, otherwise the pid that answers.
static pid_t gLastReportedPID;

static NSError *CLSpotifyAppError(CLSpotifyAppProviderError code, NSString *message) {
    return [NSError errorWithDomain:CLSpotifyAppProviderErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: message ?: @"Spotify lyrics unavailable" }];
}

/// kill(pid, 0) finds the process before it checks permission, so only ESRCH means "gone"; EPERM is a
/// live process this sandbox may not signal.
static BOOL CLProcessIsAlive(pid_t pid) {
    if (pid <= 0) return NO;
    if (kill(pid, 0) == 0) return YES;
    return errno == EPERM;
}

static void CLSpotifyAppDeliver(NSDictionary *waiter, CLSpotifyBridgeResponse *response) {
    CLLyricsCompletion completion = waiter[kCLWaiterCompletion];
    NSString *trackID = waiter[kCLWaiterTrackID];
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - [waiter[kCLWaiterStarted] doubleValue];
    switch (response.status) {
        case CLSpotifyBridgeResponseStatusLyrics: {
            CLLyrics *lyrics = response.lyrics;
            if (lyrics.source.length == 0) lyrics.source = kCLSpotifyAppIdentifier;
            CLLogInfo(@"[spotify] %@: %@ lyrics from Spotify, %lu lines, in %.2fs", trackID,
                      lyrics.kind == CLLyricsKindSynced ? @"synced" : @"plain", (unsigned long)lyrics.lines.count, elapsed);
            completion(lyrics, nil);
            break;
        }
        case CLSpotifyBridgeResponseStatusNoLyrics:
            CLLogInfo(@"[spotify] %@: Spotify has no lyrics for this track (HTTP %ld, %.2fs)", trackID,
                      (long)response.httpStatus, elapsed);
            completion(nil, nil);
            break;
        case CLSpotifyBridgeResponseStatusError:
            CLLogInfo(@"[spotify] %@: Spotify could not fetch lyrics: %@ (%.2fs)", trackID, response.message ?: @"?", elapsed);
            completion(nil, CLSpotifyAppError(CLSpotifyAppProviderErrorSpotify, response.message));
            break;
    }
}

static void CLSpotifyAppStopPolling(void) {
    if (!gPollTimer) return;
    dispatch_source_cancel(gPollTimer);
    gPollTimer = nil;
}

/// Hands every waiter its answer, or its timeout. Queue only.
static void CLSpotifyAppCheckWaiters(void) {
    if (gWaiters.count == 0) {
        CLSpotifyAppStopPolling();
        return;
    }
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSMutableDictionary<NSString *, CLSpotifyBridgeResponse *> *answers = [NSMutableDictionary dictionary];
    for (NSMutableDictionary *waiter in [gWaiters copy]) {
        NSString *trackID = waiter[kCLWaiterTrackID];
        CLSpotifyBridgeResponse *response = answers[trackID];
        if (!response) {
            response = [CLSpotifyBridge responseForTrackID:trackID];
            if (response) answers[trackID] = response;
        }
        if (response) {
            [gWaiters removeObjectIdenticalTo:waiter];
            CLSpotifyAppDeliver(waiter, response);
            continue;
        }
        if (now < [waiter[kCLWaiterDeadline] doubleValue]) continue;

        [gWaiters removeObjectIdenticalTo:waiter];
        BOOL stillWanted = NO;
        for (NSDictionary *other in gWaiters) {
            if ([other[kCLWaiterTrackID] isEqualToString:trackID]) stillWanted = YES;
        }
        if (!stillWanted) [CLSpotifyBridge removeRequestForTrackID:trackID];
        NSDictionary *status = [CLSpotifyBridge status];
        NSString *message = [NSString stringWithFormat:@"no answer from Spotify within %.1fs (pid %@, login %@, last: %@)",
                             now - [waiter[kCLWaiterStarted] doubleValue], status[CLSpotifyBridgeStatusPID] ?: @"?",
                             [status[CLSpotifyBridgeStatusAuthorized] boolValue] ? @"seen" : @"not seen",
                             status[CLSpotifyBridgeStatusLastResult] ?: @"nothing yet"];
        CLLogInfo(@"[spotify] %@: %@", trackID, message);
        CLLyricsCompletion completion = waiter[kCLWaiterCompletion];
        completion(nil, CLSpotifyAppError(CLSpotifyAppProviderErrorTimedOut, message));
    }
    // Every waiter for these tracks has its answer now; a later lookup asks again.
    for (NSString *trackID in answers) [CLSpotifyBridge removeResponseForTrackID:trackID];
    if (gWaiters.count == 0) CLSpotifyAppStopPolling();
}

static void CLSpotifyAppStartPolling(void) {
    if (gPollTimer) return;
    gPollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, CLSpotifyAppQueue());
    uint64_t interval = (uint64_t)(kCLPollInterval * NSEC_PER_SEC);
    dispatch_source_set_timer(gPollTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval), interval, interval / 5);
    dispatch_source_set_event_handler(gPollTimer, ^{ CLSpotifyAppCheckWaiters(); });
    dispatch_resume(gPollTimer);
}

/// The response notification, registered on first use. Queue only.
static void CLSpotifyAppStartListening(void) {
    static BOOL attempted = NO;
    if (attempted) return;
    attempted = YES;
    int token = 0;
    uint32_t status = notify_register_dispatch(CLSpotifyBridgeResponseNotification.UTF8String, &token,
                                               CLSpotifyAppQueue(), ^(int unused) {
        CLSpotifyAppCheckWaiters();
    });
    if (status != NOTIFY_STATUS_OK) {
        CLLogInfo(@"[spotify] cannot listen for Spotify's answers (notify status %u); polling only", status);
    }
}

@implementation CLSpotifyAppProvider

- (instancetype)init {
    self = [super init];
    if (self) {
        _timeout = kCLDefaultTimeout;
        _unauthorizedTimeout = kCLDefaultUnauthorizedTimeout;
    }
    return self;
}

- (NSString *)identifier {
    return kCLSpotifyAppIdentifier;
}

- (void)fetchLyricsForTrack:(CLTrack *)track completion:(CLLyricsCompletion)completion {
    if (!completion) return;
    NSString *trackID = [track respondsToSelector:@selector(spotifyTrackID)] ? track.spotifyTrackID : nil;
    if (![CLSpotifyBridge isValidTrackID:trackID]) {
        completion(nil, nil);   // not a Spotify track: no disk, no queue hop
        return;
    }
    NSTimeInterval timeout = self.timeout > 0 ? self.timeout : kCLDefaultTimeout;
    NSTimeInterval unauthorizedTimeout = self.unauthorizedTimeout > 0 ? self.unauthorizedTimeout : kCLDefaultUnauthorizedTimeout;
    NSTimeInterval duration = (isfinite(track.duration) && track.duration > 0) ? track.duration : 0;
    NSDictionary *info = @{ CLSpotifyBridgeRequestTitle: track.title ?: @"",
                            CLSpotifyBridgeRequestArtist: track.artist ?: @"",
                            CLSpotifyBridgeRequestDuration: @(duration) };
    CLLyricsCompletion copied = [completion copy];

    dispatch_async(CLSpotifyAppQueue(), ^{
        CLSpotifyAppStartListening();

        NSDictionary *status = [CLSpotifyBridge status];
        id rawPID = status[CLSpotifyBridgeStatusPID];
        pid_t pid = [rawPID isKindOfClass:[NSNumber class]] ? (pid_t)[(NSNumber *)rawPID intValue] : 0;
        if (!status || !CLProcessIsAlive(pid)) {
            if (gLastReportedPID != -1) {
                CLLogInfo(@"[spotify] carLy is not running in Spotify (%@); Spotify tracks fall back to the other "
                          @"sources until Spotify is restarted", status ? [NSString stringWithFormat:@"pid %d is gone", pid]
                                                                    : @"no status in the bridge");
            }
            gLastReportedPID = -1;
            copied(nil, CLSpotifyAppError(CLSpotifyAppProviderErrorNotRunning, @"carLy is not running in Spotify"));
            return;
        }
        BOOL authorized = [status[CLSpotifyBridgeStatusAuthorized] boolValue];
        if (gLastReportedPID != pid) {
            CLLogInfo(@"[spotify] carLy %@ answers in Spotify (pid %d, login %@, API host %@)",
                      status[CLSpotifyBridgeStatusVersion] ?: @"?", pid, authorized ? @"seen" : @"not seen yet",
                      status[CLSpotifyBridgeStatusHost] ?: @"?");
        }
        gLastReportedPID = pid;

        [CLSpotifyBridge removeResponseForTrackID:trackID];   // never read an answer to an older question
        if (![CLSpotifyBridge writeRequestForTrackID:trackID info:info]) {
            copied(nil, CLSpotifyAppError(CLSpotifyAppProviderErrorBridge,
                                          [NSString stringWithFormat:@"cannot write to %@", [CLSpotifyBridge directory]]));
            return;
        }
        [CLSpotifyBridge postNotification:CLSpotifyBridgeRequestNotification];

        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (!gWaiters) gWaiters = [NSMutableArray array];
        [gWaiters addObject:[@{ kCLWaiterTrackID: trackID,
                                kCLWaiterCompletion: copied,
                                kCLWaiterDeadline: @(now + (authorized ? timeout : unauthorizedTimeout)),
                                kCLWaiterStarted: @(now) } mutableCopy]];
        CLLogDebug(@"[spotify] asked Spotify for %@ (waiting up to %.0fs)", trackID, authorized ? timeout : unauthorizedTimeout);
        CLSpotifyAppStartPolling();
    });
}

@end
