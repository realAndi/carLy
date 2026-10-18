// Tests for CLSpotifyBridge and CLSpotifyBridgeResponse (Tweak/Lyrics/): the files carLy in the
// CarPlay host and carLy in Spotify exchange. tests/main.m points CARLY_SPOTIFY_BRIDGE_DIR at
// a scratch directory before any suite runs, so nothing here touches the phone's live bridge.
#import "CLSpotifyBridgeTests.h"
#import "CLTestCase.h"
#import "Lyrics/CLSpotifyBridge.h"
#import "Lyrics/CLSpotifyBridgeResponse.h"

#import <sys/stat.h>
#import <utime.h>

static CLLyrics *CLBridgeTestLyrics(void) {
    return [CLLyrics syncedWithLines:@[ [CLLyricLine lineWithTime:1.0 text:@"one"],
                                        [CLLyricLine lineWithTime:2.5 text:@"two"],
                                        [CLLyricLine lineWithTime:4.0 text:@""] ]
                              source:@"spotify"];
}

static void TestTrackIDValidation(void) {
    CL_ASSERT_TRUE([CLSpotifyBridge isValidTrackID:@"2K6Nk2bR9xPE39EY9mARVa"]);
    CL_ASSERT_FALSE([CLSpotifyBridge isValidTrackID:nil]);
    CL_ASSERT_FALSE([CLSpotifyBridge isValidTrackID:@""]);
    CL_ASSERT_FALSE([CLSpotifyBridge isValidTrackID:@"../status"]);
    CL_ASSERT_FALSE([CLSpotifyBridge isValidTrackID:@"abc.json"]);
    CL_ASSERT_FALSE([CLSpotifyBridge isValidTrackID:@"a/b"]);
    CL_ASSERT_FALSE([CLSpotifyBridge isValidTrackID:@"%_"]);
    CL_ASSERT_FALSE([CLSpotifyBridge isValidTrackID:[@"" stringByPaddingToLength:65 withString:@"a" startingAtIndex:0]]);
    // Nothing is written for an invalid id.
    CL_ASSERT_FALSE([CLSpotifyBridge writeRequestForTrackID:@"../evil" info:nil]);
    CL_ASSERT_FALSE([CLSpotifyBridge writeResponse:[CLSpotifyBridgeResponse noLyricsWithHTTPStatus:404] forTrackID:@"../evil"]);
}

static void TestResponseRoundTrip(void) {
    CLSpotifyBridgeResponse *lyrics = [CLSpotifyBridgeResponse responseWithLyrics:CLBridgeTestLyrics() httpStatus:200];
    CLSpotifyBridgeResponse *decoded = [CLSpotifyBridgeResponse responseWithDictionary:[lyrics dictionaryRepresentation]];
    CL_ASSERT_EQ((long)decoded.status, (long)CLSpotifyBridgeResponseStatusLyrics);
    CL_ASSERT_EQ(decoded.httpStatus, 200L);
    CL_ASSERT_EQ((long)decoded.lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(decoded.lyrics.lines.count, (NSUInteger)3);
    CL_ASSERT_EQ(decoded.lyrics.source, @"spotify");
    CL_ASSERT_TRUE(decoded.respondedAt > 0);

    CLSpotifyBridgeResponse *none = [CLSpotifyBridgeResponse responseWithDictionary:
                                     [[CLSpotifyBridgeResponse noLyricsWithHTTPStatus:404] dictionaryRepresentation]];
    CL_ASSERT_EQ((long)none.status, (long)CLSpotifyBridgeResponseStatusNoLyrics);
    CL_ASSERT_NIL(none.lyrics);

    CLSpotifyBridgeResponse *error = [CLSpotifyBridgeResponse responseWithDictionary:
                                      [[CLSpotifyBridgeResponse errorWithMessage:@"HTTP 503" httpStatus:503] dictionaryRepresentation]];
    CL_ASSERT_EQ((long)error.status, (long)CLSpotifyBridgeResponseStatusError);
    CL_ASSERT_EQ(error.message, @"HTTP 503");

    // Nothing to hand over is not a "lyrics" answer.
    CL_ASSERT_NIL([CLSpotifyBridgeResponse responseWithLyrics:nil httpStatus:200]);
    CL_ASSERT_NIL([CLSpotifyBridgeResponse responseWithLyrics:[CLLyrics noneFromSource:@"spotify"] httpStatus:200]);
    // Defensive decoding.
    CL_ASSERT_NIL([CLSpotifyBridgeResponse responseWithDictionary:nil]);
    CL_ASSERT_NIL(([CLSpotifyBridgeResponse responseWithDictionary:@{ @"v": @2, @"status": @"none" }]));
    CL_ASSERT_NIL(([CLSpotifyBridgeResponse responseWithDictionary:@{ @"v": @1, @"status": @"maybe" }]));
    CL_ASSERT_NIL(([CLSpotifyBridgeResponse responseWithDictionary:@{ @"v": @1, @"status": @"lyrics" }]));
    CL_ASSERT_NIL(([CLSpotifyBridgeResponse responseWithDictionary:@{ @"v": @1, @"status": @"lyrics", @"lyrics": @"x" }]));
}

static void TestRequestsAndResponsesOnDisk(void) {
    NSString *first = @"TrackAAAAAAAAAAAAAAAAA";
    NSString *second = @"TrackBBBBBBBBBBBBBBBBB";
    CL_ASSERT_TRUE([CLSpotifyBridge writeRequestForTrackID:first info:@{ CLSpotifyBridgeRequestTitle: @"Sweet Lies" }]);
    // Make the first one clearly older, so the order does not depend on the file system's clock grain.
    NSString *firstPath = [[[CLSpotifyBridge directory] stringByAppendingPathComponent:@"requests"]
                           stringByAppendingPathComponent:[first stringByAppendingPathExtension:@"json"]];
    struct utimbuf times = { .actime = time(NULL) - 10, .modtime = time(NULL) - 10 };
    utime(firstPath.fileSystemRepresentation, &times);
    CL_ASSERT_TRUE([CLSpotifyBridge writeRequestForTrackID:second info:nil]);

    NSArray<NSString *> *pending = [CLSpotifyBridge pendingRequestTrackIDs];
    CL_ASSERT_EQ(pending, (@[ first, second ]));
    NSDictionary *request = [CLSpotifyBridge requestForTrackID:first];
    CL_ASSERT_EQ(request[CLSpotifyBridgeRequestTitle], @"Sweet Lies");
    CL_ASSERT_TRUE([request[CLSpotifyBridgeRequestTime] doubleValue] > 0);
    CL_ASSERT_EQ(request[@"v"], @1);

    // A stray file that is not "<id>.json" is never listed.
    NSString *stray = [[[CLSpotifyBridge directory] stringByAppendingPathComponent:@"requests"] stringByAppendingPathComponent:@".tmp.1234"];
    [[NSData data] writeToFile:stray atomically:NO];
    CL_ASSERT_EQ([CLSpotifyBridge pendingRequestTrackIDs].count, (NSUInteger)2);
    [[NSFileManager defaultManager] removeItemAtPath:stray error:NULL];

    [CLSpotifyBridge removeRequestForTrackID:first];
    CL_ASSERT_EQ([CLSpotifyBridge pendingRequestTrackIDs], (@[ second ]));
    CL_ASSERT_NIL([CLSpotifyBridge requestForTrackID:first]);

    CLSpotifyBridgeResponse *answer = [CLSpotifyBridgeResponse responseWithLyrics:CLBridgeTestLyrics() httpStatus:200];
    CL_ASSERT_TRUE([CLSpotifyBridge writeResponse:answer forTrackID:second]);
    CLSpotifyBridgeResponse *read = [CLSpotifyBridge responseForTrackID:second];
    CL_ASSERT_EQ((long)read.status, (long)CLSpotifyBridgeResponseStatusLyrics);
    CL_ASSERT_EQ(read.lyrics.lines.count, (NSUInteger)3);
    CL_ASSERT_NIL([CLSpotifyBridge responseForTrackID:first]);

    // Housekeeping: everything older than the cut-off goes, newer stays.
    [CLSpotifyBridge pruneEntriesOlderThan:3600];
    CL_ASSERT_NOT_NIL([CLSpotifyBridge responseForTrackID:second]);
    CL_ASSERT_EQ([CLSpotifyBridge pendingRequestTrackIDs].count, (NSUInteger)1);
    usleep(50 * 1000);
    [CLSpotifyBridge pruneEntriesOlderThan:0];   // older than now: everything
    CL_ASSERT_NIL([CLSpotifyBridge responseForTrackID:second]);
    CL_ASSERT_EQ([CLSpotifyBridge pendingRequestTrackIDs].count, (NSUInteger)0);
}

static void TestStatus(void) {
    [CLSpotifyBridge removeStatus];
    CL_ASSERT_NIL([CLSpotifyBridge status]);
    CL_ASSERT_TRUE(([CLSpotifyBridge writeStatus:@{ CLSpotifyBridgeStatusPID: @(getpid()),
                                                   CLSpotifyBridgeStatusAuthorized: @YES,
                                                   CLSpotifyBridgeStatusHost: @"gew1-spclient.spotify.com" }]));
    NSDictionary *status = [CLSpotifyBridge status];
    CL_ASSERT_EQ(status[CLSpotifyBridgeStatusPID], @(getpid()));
    CL_ASSERT_EQ(status[CLSpotifyBridgeStatusHost], @"gew1-spclient.spotify.com");
    CL_ASSERT_TRUE([status[CLSpotifyBridgeStatusUpdatedAt] doubleValue] > 0);
    [CLSpotifyBridge removeStatus];
    CL_ASSERT_NIL([CLSpotifyBridge status]);
}

void CLRunSpotifyBridgeTests(void) {
    CLTestBeginSuite("CLSpotifyBridge");
    // Never the phone's live bridge (tests/main.m sets the override first).
    CL_ASSERT_FALSE([[CLSpotifyBridge directory] hasPrefix:@"/var/jb/"]);
    TestTrackIDValidation();
    TestResponseRoundTrip();
    TestRequestsAndResponsesOnDisk();
    TestStatus();
}
