// Tests for CLSpotifyColorLyricsDecoder (Tweak/Lyrics/CLSpotifyColorLyricsDecoder.m): the two shapes
// Spotify serves `color-lyrics/v2/track/<id>` in. The protobuf fixtures come from CLTestFixtures
// (independent of CLProtobufReader); the JSON ones are written out by hand in the web player's shape.
#import "CLSpotifyColorLyricsDecoderTests.h"
#import "CLTestCase.h"
#import "CLTestFixtures.h"
#import "Lyrics/CLSpotifyColorLyricsDecoder.h"

static NSData *CLJSONData(id object) {
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL] ?: [NSData data];
}

static void TestJSONLineSynced(void) {
    // int64 as strings, as the API sends them, and the wordless end marker at the end.
    NSData *body = CLJSONData(@{
        @"lyrics": @{
            @"syncType": @"LINE_SYNCED",
            @"lines": @[ @{ @"startTimeMs": @"4400", @"words": @"Maybe I should close my eyes", @"syllables": @[] },
                         @{ @"startTimeMs": @"960", @"words": @"First line" },
                         @{ @"startTimeMs": @"9000", @"words": @"" } ],
            @"provider": @"MusixMatch",
        },
        @"colors": @{ @"background": @-9013642, @"text": @-16777216 },
        @"hasVocalRemoval": @NO,
    });
    CLLyrics *lyrics = [CLSpotifyColorLyricsDecoder lyricsFromResponseData:body source:@"spotify"];
    CL_ASSERT_NOT_NIL(lyrics);
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.source, @"spotify");
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)3);
    // Sorted by time; the end marker is kept as an empty line but is not part of the text.
    CL_ASSERT_EQ(lyrics.lines[0].text, @"First line");
    CL_ASSERT_NEAR(lyrics.lines[0].time, 0.96, 0.0005);
    CL_ASSERT_EQ(lyrics.lines[2].text, @"");
    CL_ASSERT_NEAR(lyrics.lines[2].time, 9.0, 0.0005);
    CL_ASSERT_EQ(lyrics.plainText, @"First line\nMaybe I should close my eyes");
}

static void TestJSONVariants(void) {
    // Numbers instead of strings, syllable-synced, and the "lyrics" object on its own.
    NSDictionary *bare = @{ @"syncType": @"SYLLABLE_SYNCED",
                            @"lines": @[ @{ @"startTimeMs": @1500, @"words": @"one" },
                                         @{ @"startTimeMs": @3000, @"words": @"two" } ] };
    CLLyrics *lyrics = [CLSpotifyColorLyricsDecoder lyricsFromJSONObject:bare source:@"spotify"];
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)2);
    CL_ASSERT_NEAR(lyrics.lines[1].time, 3.0, 0.0005);

    // Unsynced: plain text, no timed lines.
    NSData *unsynced = CLJSONData(@{ @"lyrics": @{ @"syncType": @"UNSYNCED",
                                                   @"lines": @[ @{ @"startTimeMs": @"0", @"words": @"a" },
                                                                @{ @"startTimeMs": @"0", @"words": @"b" } ] } });
    CLLyrics *plain = [CLSpotifyColorLyricsDecoder lyricsFromResponseData:unsynced source:@"spotify"];
    CL_ASSERT_EQ((long)plain.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(plain.plainText, @"a\nb");
    CL_ASSERT_EQ(plain.lines.count, (NSUInteger)0);

    // Leading whitespace still reads as JSON.
    NSMutableData *padded = [NSMutableData dataWithData:[@"  \n" dataUsingEncoding:NSUTF8StringEncoding]];
    [padded appendData:unsynced];
    CL_ASSERT_EQ((long)[CLSpotifyColorLyricsDecoder lyricsFromResponseData:padded source:@"spotify"].kind,
                 (long)CLLyricsKindPlain);
}

static void TestJSONRejects(void) {
    CL_ASSERT_NIL([CLSpotifyColorLyricsDecoder lyricsFromJSONObject:nil source:@"spotify"]);
    CL_ASSERT_NIL([CLSpotifyColorLyricsDecoder lyricsFromJSONObject:@[] source:@"spotify"]);
    CL_ASSERT_NIL([CLSpotifyColorLyricsDecoder lyricsFromJSONObject:@{ @"lyrics": @{ @"lines": @[] } } source:@"spotify"]);
    // Timings without a single word are not lyrics.
    CL_ASSERT_NIL(([CLSpotifyColorLyricsDecoder lyricsFromJSONObject:@{ @"syncType": @"LINE_SYNCED",
                                                                       @"lines": @[ @{ @"startTimeMs": @"100", @"words": @"" } ] }
                                                             source:@"spotify"]));
    // Junk entries and junk times are skipped, never trusted.
    CLLyrics *lyrics = [CLSpotifyColorLyricsDecoder lyricsFromJSONObject:@{
        @"syncType": @"LINE_SYNCED",
        @"lines": @[ @"nope", @{ @"startTimeMs": @"12abc", @"words": @"kept at zero" }, @{ @"startTimeMs": @"-5" },
                     @{ @"startTimeMs": @"2000", @"words": @"two" } ] } source:@"spotify"];
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)2);
    CL_ASSERT_EQ(lyrics.lines[0].text, @"kept at zero");
    CL_ASSERT_NEAR(lyrics.lines[0].time, 0.0, 0.0005);
    // Not JSON at all, behind a '{'.
    CL_ASSERT_NIL([CLSpotifyColorLyricsDecoder lyricsFromResponseData:[@"{not json" dataUsingEncoding:NSUTF8StringEncoding]
                                                               source:@"spotify"]);
    CL_ASSERT_NIL([CLSpotifyColorLyricsDecoder lyricsFromResponseData:nil source:@"spotify"]);
}

static void TestProtobufThroughTheDecoder(void) {
    CLLyrics *lyrics = [CLSpotifyColorLyricsDecoder lyricsFromResponseData:CLTestSpotifyColorLyricsFixture(3) source:@"spotify"];
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.source, @"spotify");
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)4);
    CL_ASSERT_EQ(lyrics.plainText, @"Line number 1\nLine number 2\nLine number 3");

    // sync_type 2 (SYLLABLE_SYNCED) is timed too.
    NSData *line0 = CLTestBuildLyricsLineMessage(500, @"syllable line", YES);
    NSData *syllable = CLTestBuildColorLyricsResponseMessage(CLTestBuildLyricsResponseMessage(2, @[ line0 ]));
    CL_ASSERT_EQ((long)[CLSpotifyColorLyricsDecoder lyricsFromProtobufData:syllable source:@"spotify"].kind,
                 (long)CLLyricsKindSynced);
}

void CLRunSpotifyColorLyricsDecoderTests(void) {
    CLTestBeginSuite("CLSpotifyColorLyricsDecoder");
    TestJSONLineSynced();
    TestJSONVariants();
    TestJSONRejects();
    TestProtobufThroughTheDecoder();
}
