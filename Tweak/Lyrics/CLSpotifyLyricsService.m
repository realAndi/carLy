#import "CLSpotifyLyricsService.h"
#import "CLSpotifyBridge.h"
#import "CLSpotifyBridgeResponse.h"
#import "CLSpotifyColorLyricsDecoder.h"
#import "CLSpotifyRequestTemplate.h"
#import "Util/CLLog.h"

#import <notify.h>
#import <stdatomic.h>
#import <unistd.h>

#ifndef CL_VERSION
#define CL_VERSION "dev"
#endif

/// The lyrics' source identifier, the same as the host's provider ("spotify").
static NSString *const kCLSpotifyLyricsSource = @"spotify";
/// A request older than this is dropped unanswered: the host stopped waiting for it long ago.
static const NSTimeInterval kCLRequestMaximumAge = 30.0;
/// Leftovers from either side (a response nobody read, a request nobody answered) go after this.
static const NSTimeInterval kCLPruneAge = 120.0;

@implementation CLSpotifyLyricsService {
    dispatch_queue_t _queue;
    NSURLSessionConfiguration *_configuration;
    atomic_bool _running;
    // _queue only
    BOOL _listening;
    int _notifyToken;
    NSURLSession *_session;
    NSMutableSet<NSString *> *_inFlight;
    NSString *_lastResult;
    BOOL _reportedWaitingForLogin;
    BOOL _reportedLogin;
}

+ (instancetype)sharedService {
    static CLSpotifyLyricsService *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[self alloc] initWithRequestTemplate:[CLSpotifyRequestTemplate sharedTemplate] sessionConfiguration:nil];
    });
    return shared;
}

- (instancetype)initWithRequestTemplate:(CLSpotifyRequestTemplate *)requestTemplate
                   sessionConfiguration:(NSURLSessionConfiguration *)configuration {
    self = [super init];
    if (!self) return nil;
    _requestTemplate = requestTemplate;
    _configuration = [configuration copy];
    _queue = dispatch_queue_create("com.andi.carly.spotify-service", DISPATCH_QUEUE_SERIAL);
    _inFlight = [NSMutableSet set];
    atomic_init(&_running, false);
    return self;
}

- (BOOL)isRunning {
    return atomic_load(&_running);
}

#pragma mark - Lifecycle

- (void)start {
    dispatch_async(_queue, ^{
        if (atomic_load(&self->_running)) return;
        atomic_store(&self->_running, true);

        NSURLSessionConfiguration *configuration =
            [self->_configuration copy] ?: [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.URLCache = nil;
        configuration.HTTPCookieStorage = nil;
        configuration.HTTPShouldSetCookies = NO;
        configuration.timeoutIntervalForRequest = 8.0;
        configuration.timeoutIntervalForResource = 15.0;
        NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
        delegateQueue.maxConcurrentOperationCount = 1;
        delegateQueue.underlyingQueue = self->_queue;   // completions run on the work queue
        self->_session = [NSURLSession sessionWithConfiguration:configuration delegate:nil delegateQueue:delegateQueue];

        __weak typeof(self) weakSelf = self;
        int token = 0;
        uint32_t status = notify_register_dispatch(CLSpotifyBridgeRequestNotification.UTF8String, &token,
                                                   self->_queue, ^(int unused) {
            [weakSelf processOnQueue];
        });
        self->_listening = (status == NOTIFY_STATUS_OK);
        self->_notifyToken = token;
        if (!self->_listening) CLLogInfo(@"[spotify] cannot listen for the host's requests (notify status %u)", status);

        [CLSpotifyBridge pruneEntriesOlderThan:kCLPruneAge];
        BOOL wrote = [self writeStatusOnQueue];
        CLLogInfo(@"[spotify] lyrics service started (bridge %@%@; Spotify login %@)", [CLSpotifyBridge directory],
                  wrote ? @"" : @", NOT writable", self.requestTemplate.hasAuthorization ? @"seen" : @"not seen yet");
        [self processOnQueue];
    });
}

- (void)stop {
    dispatch_async(_queue, ^{
        if (!atomic_load(&self->_running)) return;
        atomic_store(&self->_running, false);
        if (self->_listening) notify_cancel(self->_notifyToken);
        self->_listening = NO;
        [self->_session invalidateAndCancel];
        self->_session = nil;
        [self->_inFlight removeAllObjects];
        [CLSpotifyBridge removeStatus];
        CLLogInfo(@"[spotify] lyrics service stopped");
    });
}

- (void)requestTemplateDidChange {
    dispatch_async(_queue, ^{
        if (!atomic_load(&self->_running)) return;
        BOOL authorized = self.requestTemplate.hasAuthorization;
        if (authorized && !self->_reportedLogin) {
            CLLogInfo(@"[spotify] Spotify login seen (API host %@, Spotify's own lyrics request %@)",
                      self.requestTemplate.host ?: @"?", self.requestTemplate.hasLyricsRequestShape ? @"seen" : @"not seen yet");
        } else {
            CLLogDebug(@"[spotify] request template changed (authorized %d, host %@, lyrics shape %d)", authorized,
                       self.requestTemplate.host ?: @"?", self.requestTemplate.hasLyricsRequestShape);
        }
        self->_reportedLogin = authorized;
        [self writeStatusOnQueue];
        [self processOnQueue];
    });
}

- (void)processPendingRequests {
    dispatch_async(_queue, ^{ [self processOnQueue]; });
}

#pragma mark - Work (queue only)

- (BOOL)writeStatusOnQueue {
    CLSpotifyRequestTemplate *requestTemplate = self.requestTemplate;
    NSMutableDictionary *status = [NSMutableDictionary dictionaryWithCapacity:8];
    status[CLSpotifyBridgeStatusPID] = @(getpid());
    status[CLSpotifyBridgeStatusVersion] = @CL_VERSION;
    status[CLSpotifyBridgeStatusAuthorized] = @(requestTemplate.hasAuthorization);
    status[CLSpotifyBridgeStatusAuthorizedAt] = @(requestTemplate.authorizationSeenAt);
    status[CLSpotifyBridgeStatusLyricsShape] = @(requestTemplate.hasLyricsRequestShape);
    if (requestTemplate.host) status[CLSpotifyBridgeStatusHost] = requestTemplate.host;
    if (_lastResult) status[CLSpotifyBridgeStatusLastResult] = _lastResult;
    return [CLSpotifyBridge writeStatus:status];
}

- (void)processOnQueue {
    if (!atomic_load(&_running) || !_session) return;
    NSArray<NSString *> *trackIDs = [CLSpotifyBridge pendingRequestTrackIDs];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    for (NSString *trackID in trackIDs) {
        if ([_inFlight containsObject:trackID]) continue;
        NSDictionary *request = [CLSpotifyBridge requestForTrackID:trackID];
        id at = request[CLSpotifyBridgeRequestTime];
        if (!request || ![at isKindOfClass:[NSNumber class]] || now - [(NSNumber *)at doubleValue] > kCLRequestMaximumAge) {
            [CLSpotifyBridge removeRequestForTrackID:trackID];
            continue;
        }
        NSURLRequest *lyricsRequest = [self.requestTemplate lyricsRequestForTrackID:trackID];
        if (!lyricsRequest) {
            if (!_reportedWaitingForLogin) {
                CLLogInfo(@"[spotify] %@ waits: Spotify has not made an authorised API request yet", trackID);
            }
            _reportedWaitingForLogin = YES;
            continue;
        }
        _reportedWaitingForLogin = NO;
        [self fetchTrackID:trackID request:lyricsRequest info:request];
    }
}

- (void)fetchTrackID:(NSString *)trackID request:(NSURLRequest *)request info:(NSDictionary *)info {
    NSDate *started = [NSDate date];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task =
        [_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            [weakSelf finishTrackID:trackID request:request data:data response:response error:error started:started];
        }];
    if (!task) return;
    [_inFlight addObject:trackID];
    id title = info[CLSpotifyBridgeRequestTitle];
    CLLogDebug(@"[spotify] fetching %@ (\"%@\") from %@%@", trackID, [title isKindOfClass:[NSString class]] ? title : @"?",
               request.URL.host, self.requestTemplate.hasLyricsRequestShape ? @"" : @" in the web player's JSON shape");
    [task resume];
}

/// The data task's completion, on the work queue (the session's delegate queue runs there).
- (void)finishTrackID:(NSString *)trackID
              request:(NSURLRequest *)request
                 data:(NSData *)data
             response:(NSURLResponse *)response
                error:(NSError *)error
              started:(NSDate *)started {
    [_inFlight removeObject:trackID];
    if (!atomic_load(&_running)) return;   // stopped: -invalidateAndCancel ends every task with an error

    NSInteger http = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    CLSpotifyBridgeResponse *answer = nil;
    NSString *summary = nil;
    if (error) {
        summary = [NSString stringWithFormat:@"request failed: %@", error.localizedDescription ?: error.domain];
        answer = [CLSpotifyBridgeResponse errorWithMessage:summary httpStatus:0];
    } else if (http == 200) {
        CLLyrics *lyrics = [CLSpotifyColorLyricsDecoder lyricsFromResponseData:data source:kCLSpotifyLyricsSource];
        answer = [CLSpotifyBridgeResponse responseWithLyrics:lyrics httpStatus:http];
        if (answer) {
            summary = [NSString stringWithFormat:@"%@, %lu lines", lyrics.kind == CLLyricsKindSynced ? @"synced" : @"plain",
                       (unsigned long)lyrics.lines.count];
        } else if (data.length == 0) {
            summary = @"no lyrics (empty answer)";
            answer = [CLSpotifyBridgeResponse noLyricsWithHTTPStatus:http];
        } else {
            NSString *type = [(NSHTTPURLResponse *)response valueForHTTPHeaderField:@"Content-Type"] ?: @"no content type";
            summary = [NSString stringWithFormat:@"answer not readable (%lu bytes, %@)", (unsigned long)data.length, type];
            answer = [CLSpotifyBridgeResponse errorWithMessage:summary httpStatus:http];
        }
    } else if (http == 204 || http == 404) {
        summary = [NSString stringWithFormat:@"no lyrics (HTTP %ld)", (long)http];
        answer = [CLSpotifyBridgeResponse noLyricsWithHTTPStatus:http];
    } else if (http == 401) {
        [self.requestTemplate rejectAuthorizationOfRequest:request];
        summary = @"Spotify's API refused the login (HTTP 401); waiting for Spotify to refresh it";
        answer = [CLSpotifyBridgeResponse errorWithMessage:summary httpStatus:http];
    } else {
        summary = [NSString stringWithFormat:@"HTTP %ld", (long)http];
        answer = [CLSpotifyBridgeResponse errorWithMessage:summary httpStatus:http];
    }

    [CLSpotifyBridge writeResponse:answer forTrackID:trackID];
    [CLSpotifyBridge removeRequestForTrackID:trackID];
    [CLSpotifyBridge postNotification:CLSpotifyBridgeResponseNotification];
    _lastResult = [NSString stringWithFormat:@"%@: %@", trackID, summary];
    [self writeStatusOnQueue];
    CLLogInfo(@"[spotify] %@: %@ in %.2fs", trackID, summary, -[started timeIntervalSinceNow]);
}

@end
