// Tests for CLSpotifyCacheProvider's pure decoder, +lyricsFromResponseData:source: (Tweak/Lyrics/
// CLSpotifyCacheProvider.m) — exactly the entry point its own HANDOFF.md note calls out for
// fixture-driven testing without a car, a Spotify install, or sqlite. Fixtures are built by
// CLTestFixtures, independently of CLProtobufReader.
#import "CLSpotifyCacheProviderTests.h"
#import "CLTestCase.h"
#import "CLTestFixtures.h"
#import "Lyrics/CLSpotifyCacheProvider.h"

static void CLTestSpotifyDecodeWrappedLineSynced(void) {
    NSData *fixture = CLTestSpotifyColorLyricsFixture(3);
    CLLyrics *lyrics = [CLSpotifyCacheProvider lyricsFromResponseData:fixture source:@"spotify-cache"];

    CL_ASSERT_NOT_NIL(lyrics);
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.source, @"spotify-cache");
    // 3 worded lines + Spotify's trailing empty-text end marker, all kept in -lines.
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)4);
    CL_ASSERT_EQ(lyrics.lines[0].text, @"Line number 1");
    CL_ASSERT_EQ(lyrics.lines[3].text, @"");
    CL_ASSERT_NEAR(lyrics.lines[3].time, (1000.0 + 3 * 2500.0) / 1000.0, 0.0005);

    // The end marker must never leak into plainText.
    CL_ASSERT_EQ(lyrics.plainText, @"Line number 1\nLine number 2\nLine number 3");
    CL_ASSERT_FALSE([lyrics.plainText hasSuffix:@"\n"]);
}

static void CLTestSpotifyDecodeBareLyricsResponse(void) {
    // The same content, but as a bare LyricsResponse (no ColorLyricsResponse wrapper) — this is
    // what lyrics_offline.sqlite3's entity_data is documented to look like.
    NSData *line0 = CLTestBuildLyricsLineMessage(4400, @"Maybe I should close my eyes", YES);
    NSData *line1 = CLTestBuildLyricsLineMessage(7200, @"...", YES);
    NSData *bare = CLTestBuildLyricsResponseMessage(1, @[ line0, line1 ]);

    CLLyrics *lyrics = [CLSpotifyCacheProvider lyricsFromResponseData:bare source:@"spotify-cache"];
    CL_ASSERT_NOT_NIL(lyrics);
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)2);
    CL_ASSERT_EQ(lyrics.lines[0].text, @"Maybe I should close my eyes");
}

static void CLTestSpotifyDecodeUnsyncedIsPlain(void) {
    NSData *line0 = CLTestBuildLyricsLineMessage(0, @"unsynced words one", YES);
    NSData *line1 = CLTestBuildLyricsLineMessage(0, @"unsynced words two", YES);
    NSData *unsynced = CLTestBuildColorLyricsResponseMessage(
        CLTestBuildLyricsResponseMessage(0 /* UNSYNCED */, @[ line0, line1 ]));

    CLLyrics *lyrics = [CLSpotifyCacheProvider lyricsFromResponseData:unsynced source:@"spotify-cache"];
    CL_ASSERT_NOT_NIL(lyrics);
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, @"unsynced words one\nunsynced words two");
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)0);   // plain lyrics carry no timed lines
}

static void CLTestSpotifyDecodeRejectsEmptyOrWordlessInput(void) {
    CL_ASSERT_NIL([CLSpotifyCacheProvider lyricsFromResponseData:nil source:@"spotify-cache"]);
    CL_ASSERT_NIL([CLSpotifyCacheProvider lyricsFromResponseData:[NSData data] source:@"spotify-cache"]);

    // Only the wordless end marker, no real lyrics at all: timings without a single word.
    NSData *onlyMarker = CLTestBuildColorLyricsResponseMessage(
        CLTestBuildLyricsResponseMessage(1, @[ CLTestBuildLyricsLineMessage(500, nil, NO) ]));
    CL_ASSERT_NIL([CLSpotifyCacheProvider lyricsFromResponseData:onlyMarker source:@"spotify-cache"]);

    // Random bytes that are not a valid protobuf message at all.
    uint8_t garbage[] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    NSData *garbageData = [NSData dataWithBytes:garbage length:sizeof(garbage)];
    CL_ASSERT_NIL([CLSpotifyCacheProvider lyricsFromResponseData:garbageData source:@"spotify-cache"]);
}

static void CLTestSpotifyDecodeTruncationNeverCrashes(void) {
    NSData *fullFixture = CLTestSpotifyColorLyricsFixture(6);
    NSUInteger fullLength = fullFixture.length;
    // Every prefix length, not just a stride sample, plus the untouched full buffer explicitly —
    // this is cheap (a few hundred bytes) and a stride could otherwise skip the exact length.
    for (NSUInteger cut = 0; cut <= fullLength; cut++) {
        NSData *prefix = [fullFixture subdataWithRange:NSMakeRange(0, cut)];
        @try {
            CLLyrics *lyrics = [CLSpotifyCacheProvider lyricsFromResponseData:prefix source:@"x"];
            // No specific outcome is required for a truncated buffer, only that decoding a
            // partial one never produces something claiming to be synced with zero lines.
            if (lyrics && lyrics.kind == CLLyricsKindSynced) {
                CL_ASSERT_TRUE(lyrics.lines.count > 0);
            }
        } @catch (NSException *exception) {
            CL_ASSERT_TRUE(NO);   // must never throw, per the class's own contract
        }
    }
    // And the untouched fixture must still decode cleanly at the end.
    CL_ASSERT_NOT_NIL([CLSpotifyCacheProvider lyricsFromResponseData:fullFixture source:@"x"]);
}

static void CLTestSpotifyIdentifier(void) {
    CLSpotifyCacheProvider *provider = [[CLSpotifyCacheProvider alloc] init];
    CL_ASSERT_EQ(provider.identifier, @"spotify-cache");
}

static void CLTestSpotifyNonSpotifyTrackMissesSynchronouslyWithoutTouchingDisk(void) {
    CLSpotifyCacheProvider *provider = [[CLSpotifyCacheProvider alloc] init];
    CLTrack *notSpotify = [[CLTrack alloc] init];
    notSpotify.title = @"Some Song";
    notSpotify.artist = @"Some Artist";
    notSpotify.contentIdentifier = @"com.apple.music:1234";   // not a spotify: id

    __block BOOL delivered = NO;
    __block CLLyrics *result = nil;
    __block NSError *resultError = nil;
    [provider fetchLyricsForTrack:notSpotify completion:^(CLLyrics *lyrics, NSError *error) {
        result = lyrics;
        resultError = error;
        delivered = YES;
    }];
    // Documented to answer synchronously for this case, but wait defensively regardless.
    CL_ASSERT_TRUE(CLTestWaitUntil(1.0, ^BOOL{ return delivered; }));
    CL_ASSERT_NIL(result);
    CL_ASSERT_NIL(resultError);
}

void CLRunSpotifyCacheProviderTests(void) {
    CLTestBeginSuite("CLSpotifyCacheProvider");
    CLTestSpotifyIdentifier();
    CLTestSpotifyDecodeWrappedLineSynced();
    CLTestSpotifyDecodeBareLyricsResponse();
    CLTestSpotifyDecodeUnsyncedIsPlain();
    CLTestSpotifyDecodeRejectsEmptyOrWordlessInput();
    CLTestSpotifyDecodeTruncationNeverCrashes();
    CLTestSpotifyNonSpotifyTrackMissesSynchronouslyWithoutTouchingDisk();
}

void CLRunSpotifyCacheProviderLiveLookup(NSString *spotifyTrackID) {
    CLTestBeginSuite("CLSpotifyCacheProvider (--spotify, exploratory)");
    CLSpotifyCacheProvider *provider = [[CLSpotifyCacheProvider alloc] init];
    CLTrack *track = [[CLTrack alloc] init];
    track.title = @"(unknown, looked up by id)";
    track.artist = @"(unknown)";
    track.contentIdentifier = [NSString stringWithFormat:@"spotify:track:%@#cltests", spotifyTrackID];

    __block BOOL delivered = NO;
    [provider fetchLyricsForTrack:track completion:^(CLLyrics *lyrics, NSError *error) {
        if (lyrics) {
            printf("  spotify-cache HIT for %s: kind=%ld lines=%lu source=%s\n",
                   spotifyTrackID.UTF8String, (long)lyrics.kind, (unsigned long)lyrics.lines.count,
                   lyrics.source.UTF8String);
            if (lyrics.plainText.length) {
                printf("  --- plainText ---\n%s\n-----------------\n", lyrics.plainText.UTF8String);
            }
        } else {
            printf("  spotify-cache MISS for %s (not cached, container unreadable, or not found)\n",
                   spotifyTrackID.UTF8String);
        }
        delivered = YES;
    }];
    CLTestWaitUntil(10.0, ^BOOL{ return delivered; });
    if (!delivered) printf("  spotify-cache lookup did not complete within 10s\n");
}
