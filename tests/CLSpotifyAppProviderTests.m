// Tests for the Spotify lyrics round trip (0.9.0): CLSpotifyAppProvider, the host side, against
//   1. a hand-played Spotify side (files written by the test), for the provider's own rules: who is
//      answering, how long it waits, what each answer turns into;
//   2. the real CLSpotifyLyricsService on a fresh CLSpotifyRequestTemplate, with an NSURLProtocol
//      standing in for Spotify's API — everything the phone does except the hook and Spotify itself.
// Both sides run in this one process through the scratch bridge directory tests/main.m sets up.
#import "CLSpotifyAppProviderTests.h"
#import "CLTestCase.h"
#import "CLTestFixtures.h"
#import "Lyrics/CLSpotifyAppProvider.h"
#import "Lyrics/CLSpotifyBridge.h"
#import "Lyrics/CLSpotifyBridgeResponse.h"
#import "Lyrics/CLSpotifyLyricsService.h"
#import "Lyrics/CLSpotifyRequestTemplate.h"

#import <unistd.h>

#pragma mark - A stand-in for Spotify's API

/// trackID → @[ HTTP status, body, content type ]. Anything else is a 404.
static NSMutableDictionary<NSString *, NSArray *> *gCannedAnswers;
static NSURLRequest *gLastAPIRequest;
static NSUInteger gAPIRequestCount;

@interface CLTestSpotifyAPIProtocol : NSURLProtocol
@end

@implementation CLTestSpotifyAPIProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return [CLSpotifyRequestTemplate isSpotifyAPIHost:request.URL.host];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSString *trackID = self.request.URL.lastPathComponent;
    NSArray *answer = nil;
    @synchronized([CLTestSpotifyAPIProtocol class]) {
        answer = gCannedAnswers[trackID];
        gLastAPIRequest = self.request;
        gAPIRequestCount += 1;
    }
    NSInteger status = answer.count > 0 ? [answer[0] integerValue] : 404;
    NSData *body = answer.count > 1 ? answer[1] : [NSData data];
    NSString *type = answer.count > 2 ? answer[2] : @"application/protobuf";
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                              statusCode:status
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{ @"Content-Type": type }];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (body.length > 0) [self.client URLProtocol:self didLoadData:body];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
}

@end

#pragma mark - Helpers

static CLTrack *CLSpotifyTrack(NSString *trackID) {
    CLTrack *track = [[CLTrack alloc] init];
    track.title = @"Sweet Lies";
    track.artist = @"Qendresa";
    track.duration = 221.772;
    track.bundleIdentifier = @"com.spotify.client";
    track.contentIdentifier = [NSString stringWithFormat:@"spotify:track:%@#3D9A0F6E-0000-4000-8000-000000000000", trackID];
    return track;
}

typedef struct {
    BOOL done;
    NSTimeInterval elapsed;
} CLFetchOutcome;

/// Fetches and pumps the run loop until the completion runs (or `limit` passes).
static CLFetchOutcome CLFetch(CLSpotifyAppProvider *provider, CLTrack *track, NSTimeInterval limit,
                              CLLyrics *__strong *lyricsOut, NSError *__strong *errorOut) {
    __block BOOL done = NO;
    __block CLLyrics *lyrics = nil;
    __block NSError *error = nil;
    NSDate *start = [NSDate date];
    [provider fetchLyricsForTrack:track completion:^(CLLyrics *result, NSError *failure) {
        lyrics = result;
        error = failure;
        done = YES;
    }];
    CLTestWaitUntil(limit, ^BOOL { return done; });
    if (lyricsOut) *lyricsOut = lyrics;
    if (errorOut) *errorOut = error;
    return (CLFetchOutcome){ .done = done, .elapsed = -[start timeIntervalSinceNow] };
}

static void CLWriteLiveStatus(BOOL authorized) {
    [CLSpotifyBridge writeStatus:@{ CLSpotifyBridgeStatusPID: @(getpid()),
                                    CLSpotifyBridgeStatusAuthorized: @(authorized),
                                    CLSpotifyBridgeStatusVersion: @"test" }];
}

/// Plays Spotify once: waits for the request for `trackID`, then writes `response` and notifies.
static void CLAnswerInBackground(NSString *trackID, CLSpotifyBridgeResponse *response) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (int i = 0; i < 200 && ![CLSpotifyBridge requestForTrackID:trackID]; i++) usleep(10 * 1000);
        [CLSpotifyBridge writeResponse:response forTrackID:trackID];
        [CLSpotifyBridge removeRequestForTrackID:trackID];
        [CLSpotifyBridge postNotification:CLSpotifyBridgeResponseNotification];
    });
}

static CLLyrics *CLTwoLines(void) {
    return [CLLyrics syncedWithLines:@[ [CLLyricLine lineWithTime:1 text:@"one"], [CLLyricLine lineWithTime:2 text:@"two"] ]
                              source:@"spotify"];
}

#pragma mark - 1. The provider's rules

static void TestNotASpotifyTrack(void) {
    CLSpotifyAppProvider *provider = [[CLSpotifyAppProvider alloc] init];
    CL_ASSERT_EQ(provider.identifier, @"spotify");
    CLTrack *track = CLSpotifyTrack(@"TrackAAAAAAAAAAAAAAAAA");
    track.contentIdentifier = @"com.apple.Music:12345";
    __block BOOL called = NO;
    __block BOOL miss = NO;
    [provider fetchLyricsForTrack:track completion:^(CLLyrics *lyrics, NSError *error) {
        called = YES;
        miss = lyrics == nil && error == nil;
    }];
    CL_ASSERT_TRUE(called);   // synchronously, without touching the disk
    CL_ASSERT_TRUE(miss);
}

static void TestNobodyAnswering(void) {
    CLSpotifyAppProvider *provider = [[CLSpotifyAppProvider alloc] init];
    NSString *trackID = @"TrackBBBBBBBBBBBBBBBBB";

    [CLSpotifyBridge removeStatus];
    CLLyrics *lyrics = nil;
    NSError *error = nil;
    CLFetchOutcome outcome = CLFetch(provider, CLSpotifyTrack(trackID), 2.0, &lyrics, &error);
    CL_ASSERT_TRUE(outcome.done);
    CL_ASSERT_TRUE(outcome.elapsed < 1.0);
    CL_ASSERT_NIL(lyrics);
    CL_ASSERT_EQ(error.code, (long)CLSpotifyAppProviderErrorNotRunning);
    CL_ASSERT_NIL([CLSpotifyBridge requestForTrackID:trackID]);   // nobody to ask, so nothing asked

    // A status left behind by a Spotify that is gone counts as nobody.
    [CLSpotifyBridge writeStatus:@{ CLSpotifyBridgeStatusPID: @(99999999), CLSpotifyBridgeStatusAuthorized: @YES }];
    outcome = CLFetch(provider, CLSpotifyTrack(trackID), 2.0, &lyrics, &error);
    CL_ASSERT_TRUE(outcome.done);
    CL_ASSERT_EQ(error.code, (long)CLSpotifyAppProviderErrorNotRunning);
    [CLSpotifyBridge removeStatus];
}

static void TestTimeout(void) {
    CLSpotifyAppProvider *provider = [[CLSpotifyAppProvider alloc] init];
    provider.timeout = 5.0;
    provider.unauthorizedTimeout = 0.5;   // a live Spotify without its login waits the short one
    NSString *trackID = @"TrackCCCCCCCCCCCCCCCCC";
    CLWriteLiveStatus(NO);

    CLLyrics *lyrics = nil;
    NSError *error = nil;
    CLFetchOutcome outcome = CLFetch(provider, CLSpotifyTrack(trackID), 4.0, &lyrics, &error);
    CL_ASSERT_TRUE(outcome.done);
    CL_ASSERT_TRUE(outcome.elapsed >= 0.45 && outcome.elapsed < 2.0);
    CL_ASSERT_NIL(lyrics);
    CL_ASSERT_EQ(error.domain, CLSpotifyAppProviderErrorDomain);
    CL_ASSERT_EQ(error.code, (long)CLSpotifyAppProviderErrorTimedOut);
    CL_ASSERT_NIL([CLSpotifyBridge requestForTrackID:trackID]);   // withdrawn
    [CLSpotifyBridge removeStatus];
}

static void TestAnswers(void) {
    CLSpotifyAppProvider *provider = [[CLSpotifyAppProvider alloc] init];
    CLWriteLiveStatus(YES);
    CLLyrics *lyrics = nil;
    NSError *error = nil;

    NSString *withLyrics = @"TrackDDDDDDDDDDDDDDDDD";
    CLAnswerInBackground(withLyrics, [CLSpotifyBridgeResponse responseWithLyrics:CLTwoLines() httpStatus:200]);
    CLFetchOutcome outcome = CLFetch(provider, CLSpotifyTrack(withLyrics), 5.0, &lyrics, &error);
    CL_ASSERT_TRUE(outcome.done);
    CL_ASSERT_NIL(error);
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)2);
    CL_ASSERT_EQ(lyrics.source, @"spotify");
    CL_ASSERT_NIL([CLSpotifyBridge responseForTrackID:withLyrics]);   // consumed

    NSString *without = @"TrackEEEEEEEEEEEEEEEEE";
    CLAnswerInBackground(without, [CLSpotifyBridgeResponse noLyricsWithHTTPStatus:404]);
    outcome = CLFetch(provider, CLSpotifyTrack(without), 5.0, &lyrics, &error);
    CL_ASSERT_TRUE(outcome.done);
    CL_ASSERT_NIL(lyrics);
    CL_ASSERT_NIL(error);   // a clean miss: the chain may cache it

    NSString *failing = @"TrackFFFFFFFFFFFFFFFFF";
    CLAnswerInBackground(failing, [CLSpotifyBridgeResponse errorWithMessage:@"HTTP 503" httpStatus:503]);
    outcome = CLFetch(provider, CLSpotifyTrack(failing), 5.0, &lyrics, &error);
    CL_ASSERT_TRUE(outcome.done);
    CL_ASSERT_NIL(lyrics);
    CL_ASSERT_EQ(error.code, (long)CLSpotifyAppProviderErrorSpotify);
    CL_ASSERT_EQ(error.localizedDescription, @"HTTP 503");

    // A leftover answer to an older question is never read: the provider clears it before asking.
    NSString *stale = @"TrackGGGGGGGGGGGGGGGGG";
    [CLSpotifyBridge writeResponse:[CLSpotifyBridgeResponse errorWithMessage:@"old" httpStatus:500] forTrackID:stale];
    CLAnswerInBackground(stale, [CLSpotifyBridgeResponse responseWithLyrics:CLTwoLines() httpStatus:200]);
    outcome = CLFetch(provider, CLSpotifyTrack(stale), 5.0, &lyrics, &error);
    CL_ASSERT_NIL(error);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)2);

    // Two lookups of the same track at once both get the one answer.
    NSString *twice = @"TrackHHHHHHHHHHHHHHHHH";
    __block int answered = 0;
    CLTrack *track = CLSpotifyTrack(twice);
    for (int i = 0; i < 2; i++) {
        [provider fetchLyricsForTrack:track completion:^(CLLyrics *result, NSError *failure) {
            if (result.lines.count == 2) {
                @synchronized([CLTestSpotifyAPIProtocol class]) { answered += 1; }
            }
        }];
    }
    CLAnswerInBackground(twice, [CLSpotifyBridgeResponse responseWithLyrics:CLTwoLines() httpStatus:200]);
    CL_ASSERT_TRUE(CLTestWaitUntil(5.0, ^BOOL { @synchronized([CLTestSpotifyAPIProtocol class]) { return answered == 2; } }));
    [CLSpotifyBridge removeStatus];
}

#pragma mark - 2. The whole round trip, with the real service

static NSURLRequest *CLAuthorisedSpotifyRequest(NSString *token) {
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gew1-spclient.spotify.com/metadata/4/track/abc"]];
    [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"client-token-1" forHTTPHeaderField:@"client-token"];
    [request setValue:@"iOS" forHTTPHeaderField:@"App-Platform"];
    return request;
}

static void TestRoundTripThroughTheService(void) {
    NSString *synced = @"RoundTripSynced0000000";
    NSString *json = @"RoundTripJSON000000000";
    NSString *missing = @"RoundTripMissing000000";
    NSString *refused = @"RoundTripRefused000000";
    NSData *jsonBody = [NSJSONSerialization dataWithJSONObject:@{ @"lyrics": @{ @"syncType": @"LINE_SYNCED",
        @"lines": @[ @{ @"startTimeMs": @"1000", @"words": @"json one" }, @{ @"startTimeMs": @"3000", @"words": @"json two" } ] } }
                                                       options:0 error:NULL];
    @synchronized([CLTestSpotifyAPIProtocol class]) {
        gCannedAnswers = [@{ synced: @[ @200, CLTestSpotifyColorLyricsFixture(3), @"application/protobuf" ],
                             json: @[ @200, jsonBody, @"application/json" ],
                             missing: @[ @404 ],
                             refused: @[ @401 ] } mutableCopy];
        gAPIRequestCount = 0;
    }

    CLSpotifyRequestTemplate *template = [[CLSpotifyRequestTemplate alloc] init];
    CL_ASSERT_TRUE([template observeRequest:CLAuthorisedSpotifyRequest(@"token-1")]);
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.protocolClasses = @[ [CLTestSpotifyAPIProtocol class] ];
    CLSpotifyLyricsService *service = [[CLSpotifyLyricsService alloc] initWithRequestTemplate:template
                                                                         sessionConfiguration:configuration];
    [service start];
    CL_ASSERT_TRUE(CLTestWaitUntil(3.0, ^BOOL { return [[CLSpotifyBridge status][CLSpotifyBridgeStatusPID] intValue] == getpid(); }));
    CL_ASSERT_TRUE([[CLSpotifyBridge status][CLSpotifyBridgeStatusAuthorized] boolValue]);
    CL_ASSERT_TRUE(service.running);

    CLSpotifyAppProvider *provider = [[CLSpotifyAppProvider alloc] init];
    CLLyrics *lyrics = nil;
    NSError *error = nil;

    // Protobuf, the app's own shape.
    CLFetchOutcome outcome = CLFetch(provider, CLSpotifyTrack(synced), 6.0, &lyrics, &error);
    CL_ASSERT_TRUE(outcome.done);
    CL_ASSERT_NIL(error);
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)4);
    CL_ASSERT_EQ(lyrics.source, @"spotify");
    NSURLRequest *sent = nil;
    @synchronized([CLTestSpotifyAPIProtocol class]) { sent = gLastAPIRequest; }
    CL_ASSERT_EQ([sent valueForHTTPHeaderField:@"Authorization"], @"Bearer token-1");
    CL_ASSERT_EQ(sent.URL.path, ([@"/color-lyrics/v2/track/" stringByAppendingString:synced]));
    CL_ASSERT_NIL([CLSpotifyBridge requestForTrackID:synced]);   // answered and cleared
    CL_ASSERT_NIL([CLSpotifyBridge responseForTrackID:synced]);  // read and cleared

    // JSON, the web player's shape.
    outcome = CLFetch(provider, CLSpotifyTrack(json), 6.0, &lyrics, &error);
    CL_ASSERT_NIL(error);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)2);
    CL_ASSERT_EQ(lyrics.lines[1].text, @"json two");

    // 404: Spotify has none — a clean miss.
    outcome = CLFetch(provider, CLSpotifyTrack(missing), 6.0, &lyrics, &error);
    CL_ASSERT_TRUE(outcome.done);
    CL_ASSERT_NIL(lyrics);
    CL_ASSERT_NIL(error);

    // 401: an error, and the token is dropped.
    outcome = CLFetch(provider, CLSpotifyTrack(refused), 6.0, &lyrics, &error);
    CL_ASSERT_TRUE(outcome.done);
    CL_ASSERT_EQ(error.code, (long)CLSpotifyAppProviderErrorSpotify);
    CL_ASSERT_FALSE(template.hasAuthorization);
    CL_ASSERT_TRUE(CLTestWaitUntil(2.0, ^BOOL { return ![[CLSpotifyBridge status][CLSpotifyBridgeStatusAuthorized] boolValue]; }));

    // Without a login the request waits in Spotify; a fresh token answers it while the host still waits.
    provider.unauthorizedTimeout = 4.0;
    __block BOOL done = NO;
    __block CLLyrics *late = nil;
    [provider fetchLyricsForTrack:CLSpotifyTrack(synced) completion:^(CLLyrics *result, NSError *failure) {
        late = result;
        done = YES;
    }];
    CLTestWaitUntil(0.5, ^BOOL { return NO; });
    CL_ASSERT_FALSE(done);
    CL_ASSERT_TRUE([template observeRequest:CLAuthorisedSpotifyRequest(@"token-2")]);
    [service requestTemplateDidChange];
    CL_ASSERT_TRUE(CLTestWaitUntil(4.0, ^BOOL { return done; }));
    CL_ASSERT_EQ(late.lines.count, (NSUInteger)4);
    @synchronized([CLTestSpotifyAPIProtocol class]) { sent = gLastAPIRequest; }
    CL_ASSERT_EQ([sent valueForHTTPHeaderField:@"Authorization"], @"Bearer token-2");

    // Stopping takes the status away, so the host stops asking at once.
    [service stop];
    CL_ASSERT_TRUE(CLTestWaitUntil(2.0, ^BOOL { return [CLSpotifyBridge status] == nil; }));
    CL_ASSERT_FALSE(service.running);
    outcome = CLFetch(provider, CLSpotifyTrack(synced), 2.0, &lyrics, &error);
    CL_ASSERT_EQ(error.code, (long)CLSpotifyAppProviderErrorNotRunning);
}

void CLRunSpotifyAppProviderTests(void) {
    CLTestBeginSuite("CLSpotifyAppProvider + CLSpotifyLyricsService");
    CL_ASSERT_FALSE([[CLSpotifyBridge directory] hasPrefix:@"/var/jb/"]);
    TestNotASpotifyTrack();
    TestNobodyAnswering();
    TestTimeout();
    TestAnswers();
    TestRoundTripThroughTheService();
}
