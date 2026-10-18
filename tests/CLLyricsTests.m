// Tests for CLLyrics: factories and the dictionaryRepresentation <-> lyricsWithDictionary:
// round trip that CLLyricsCache persists to disk (Tweak/Lyrics/CLLyricsTypes.m).
#import "CLLyricsTests.h"
#import "CLTestCase.h"
#import "Lyrics/CLLyricsTypes.h"

static NSArray<CLLyricLine *> *CLMakeLines(void) {
    return @[
        [CLLyricLine lineWithTime:1.5 text:@"First line"],
        [CLLyricLine lineWithTime:4.0 text:@""],              // instrumental gap, kept
        [CLLyricLine lineWithTime:7.25 text:@"Third line"],
    ];
}

static void CLTestLyricsFactories(void) {
    CLLyrics *none = [CLLyrics noneFromSource:@"unit-test"];
    CL_ASSERT_EQ((long)none.kind, (long)CLLyricsKindNone);
    CL_ASSERT_EQ(none.source, @"unit-test");
    CL_ASSERT_TRUE(none.fetchedAt > 0);

    CLLyrics *synced = [CLLyrics syncedWithLines:CLMakeLines() source:@"unit-test"];
    CL_ASSERT_EQ((long)synced.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(synced.lines.count, (NSUInteger)3);

    // Non-CLLyricLine garbage in the array is dropped; an all-garbage array collapses to none.
    CLLyrics *garbageOnly = [CLLyrics syncedWithLines:(NSArray *)@[ @"not a line", @42 ] source:@"x"];
    CL_ASSERT_EQ((long)garbageOnly.kind, (long)CLLyricsKindNone);

    CLLyrics *emptySynced = [CLLyrics syncedWithLines:@[] source:@"unit-test"];
    CL_ASSERT_EQ((long)emptySynced.kind, (long)CLLyricsKindNone);   // nothing to show == no lyrics

    CLLyrics *plain = [CLLyrics plainWithText:@"Some words" source:@"unit-test"];
    CL_ASSERT_EQ((long)plain.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(plain.plainText, @"Some words");

    CLLyrics *whitespaceOnly = [CLLyrics plainWithText:@"   \n\t  " source:@"unit-test"];
    CL_ASSERT_EQ((long)whitespaceOnly.kind, (long)CLLyricsKindNone);

    NSString *notActuallyAString = nil;
    CLLyrics *nilText = [CLLyrics plainWithText:notActuallyAString source:@"unit-test"];
    CL_ASSERT_EQ((long)nilText.kind, (long)CLLyricsKindNone);
}

static void CLTestLyricsDictionaryIsValidJSON(void) {
    CLLyrics *synced = [CLLyrics syncedWithLines:CLMakeLines() source:@"unit-test"];
    NSDictionary *dict = [synced dictionaryRepresentation];
    CL_ASSERT_TRUE([NSJSONSerialization isValidJSONObject:dict]);
    CL_ASSERT_NOT_NIL([NSJSONSerialization dataWithJSONObject:dict options:0 error:NULL]);
}

static void CLTestLyricsRoundTripSynced(void) {
    CLLyrics *original = [CLLyrics syncedWithLines:CLMakeLines() source:@"lrclib"];
    NSDictionary *dict = [original dictionaryRepresentation];
    CLLyrics *decoded = [CLLyrics lyricsWithDictionary:dict];

    CL_ASSERT_NOT_NIL(decoded);
    CL_ASSERT_EQ((long)decoded.kind, (long)original.kind);
    CL_ASSERT_EQ(decoded.source, original.source);
    CL_ASSERT_NEAR(decoded.fetchedAt, original.fetchedAt, 0.001);
    CL_ASSERT_EQ(decoded.lines.count, original.lines.count);
    for (NSUInteger i = 0; i < original.lines.count; i++) {
        CL_ASSERT_NEAR(decoded.lines[i].time, original.lines[i].time, 0.0005);
        CL_ASSERT_EQ(decoded.lines[i].text, original.lines[i].text);
    }
    CL_ASSERT_NIL(decoded.plainText);   // never set on this one
}

static void CLTestLyricsRoundTripSyncedWithPlainText(void) {
    CLLyrics *original = [CLLyrics syncedWithLines:CLMakeLines() source:@"spotify-cache"];
    original.plainText = @"First line\n\nThird line";
    NSDictionary *dict = [original dictionaryRepresentation];
    CLLyrics *decoded = [CLLyrics lyricsWithDictionary:dict];
    CL_ASSERT_EQ(decoded.plainText, original.plainText);
    CL_ASSERT_EQ((long)decoded.kind, (long)CLLyricsKindSynced);
}

static void CLTestLyricsRoundTripPlainAndNone(void) {
    CLLyrics *plain = [CLLyrics plainWithText:@"Just text, no timing" source:@"custom"];
    CLLyrics *decodedPlain = [CLLyrics lyricsWithDictionary:[plain dictionaryRepresentation]];
    CL_ASSERT_EQ((long)decodedPlain.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(decodedPlain.plainText, @"Just text, no timing");
    CL_ASSERT_EQ(decodedPlain.lines.count, (NSUInteger)0);

    CLLyrics *none = [CLLyrics noneFromSource:@"chain"];
    CLLyrics *decodedNone = [CLLyrics lyricsWithDictionary:[none dictionaryRepresentation]];
    CL_ASSERT_EQ((long)decodedNone.kind, (long)CLLyricsKindNone);
    CL_ASSERT_EQ(decodedNone.source, @"chain");
}

static void CLTestLyricsDecodingIsDefensive(void) {
    NSDictionary *notADictionary = nil;
    CL_ASSERT_NIL([CLLyrics lyricsWithDictionary:notADictionary]);
    NSDictionary *actuallyAnArray = (NSDictionary *)@[ @1, @2 ];   // wrong class entirely
    CL_ASSERT_NIL([CLLyrics lyricsWithDictionary:actuallyAnArray]);
    CL_ASSERT_NIL([CLLyrics lyricsWithDictionary:@{ @"lines": @[] }]);            // no "kind"
    CL_ASSERT_NIL([CLLyrics lyricsWithDictionary:@{ @"kind": @"synced" }]);       // "kind" not a number
    CL_ASSERT_NIL([CLLyrics lyricsWithDictionary:@{ @"kind": @99 }]);             // out of range

    // A "synced" record whose lines did not survive decoding is not usable as synced: it degrades
    // to plain (if there is text) or none.
    CLLyrics *degradesToPlain = [CLLyrics lyricsWithDictionary:@{
        @"kind": @(CLLyricsKindSynced), @"plainText": @"leftover text", @"lines": @[]
    }];
    CL_ASSERT_EQ((long)degradesToPlain.kind, (long)CLLyricsKindPlain);

    CLLyrics *degradesToNone = [CLLyrics lyricsWithDictionary:@{
        @"kind": @(CLLyricsKindSynced), @"lines": @[]
    }];
    CL_ASSERT_EQ((long)degradesToNone.kind, (long)CLLyricsKindNone);

    // Malformed line entries are skipped individually rather than failing the whole decode.
    CLLyrics *partial = [CLLyrics lyricsWithDictionary:@{
        @"kind": @(CLLyricsKindSynced),
        @"lines": @[
            @{ @"t": @1.0, @"text": @"good" },
            @{ @"t": @"not a number", @"text": @"bad t" },
            @"not even a dictionary",
            @{ @"text": @"missing t entirely" },
            @{ @"t": @2.0 },   // missing text -> defaults to ""
        ],
    }];
    CL_ASSERT_EQ(partial.lines.count, (NSUInteger)2);
    CL_ASSERT_EQ(partial.lines[0].text, @"good");
    CL_ASSERT_EQ(partial.lines[1].text, @"");
    CL_ASSERT_NEAR(partial.lines[1].time, 2.0, 0.0005);

    // A source given as NSNull or a non-string falls back to the empty string, never crashes.
    CLLyrics *badSource = [CLLyrics lyricsWithDictionary:@{
        @"kind": @(CLLyricsKindNone), @"source": [NSNull null]
    }];
    CL_ASSERT_NOT_NIL(badSource);
    CL_ASSERT_EQ(badSource.source, @"");
}

/// +instrumentalFromSource: (added to the contract in the integrate wave): a positive result with
/// no lines, distinct from a "none" so the UI can say "instrumental", and it survives the cache
/// round trip like any other kind.
static void CLTestLyricsInstrumentalFactory(void) {
    CLLyrics *instrumental = [CLLyrics instrumentalFromSource:@"unit-test"];
    CL_ASSERT_EQ((long)instrumental.kind, (long)CLLyricsKindInstrumental);
    CL_ASSERT_EQ(instrumental.source, @"unit-test");
    CL_ASSERT_EQ((unsigned long)instrumental.lines.count, 0UL);
    CL_ASSERT_NIL(instrumental.plainText);
    CL_ASSERT_TRUE(instrumental.fetchedAt > 0);

    CLLyrics *restored = [CLLyrics lyricsWithDictionary:instrumental.dictionaryRepresentation];
    CL_ASSERT_NOT_NIL(restored);
    CL_ASSERT_EQ((long)restored.kind, (long)CLLyricsKindInstrumental);
    CL_ASSERT_EQ(restored.source, @"unit-test");
    CL_ASSERT_NEAR(restored.fetchedAt, instrumental.fetchedAt, 0.0005);
}

void CLRunLyricsTests(void) {
    CLTestBeginSuite("CLLyrics");
    CLTestLyricsFactories();
    CLTestLyricsInstrumentalFactory();
    CLTestLyricsDictionaryIsValidJSON();
    CLTestLyricsRoundTripSynced();
    CLTestLyricsRoundTripSyncedWithPlainText();
    CLTestLyricsRoundTripPlainAndNone();
    CLTestLyricsDecodingIsDefensive();
}
