// Tests for CLLRCParser. Behaviour pinned down here matches the lyrics-core slice's HANDOFF.md
// note (offset direction/units, hundredths vs. hours variant, bracket-that-stays-in-text,
// nil-not-empty-array on no timed line) rather than being re-derived from scratch.
#import "CLLRCParserTests.h"
#import "CLTestCase.h"
#import "Lyrics/CLLRCParser.h"

static CLLyricLine *CLLine(NSArray<CLLyricLine *> *lines, NSUInteger index) {
    return index < lines.count ? lines[index] : nil;
}

static void CLTestLRCBasicTimestampFormats(void) {
    NSArray<CLLyricLine *> *lines;

    lines = [CLLRCParser parse:@"[00:05]Bare seconds"];
    CL_ASSERT_EQ(lines.count, (NSUInteger)1);
    CL_ASSERT_NEAR(CLLine(lines, 0).time, 5.0, 0.0005);
    CL_ASSERT_EQ(CLLine(lines, 0).text, @"Bare seconds");

    lines = [CLLRCParser parse:@"[00:05.5]Tenths"];
    CL_ASSERT_NEAR(CLLine(lines, 0).time, 5.5, 0.0005);

    lines = [CLLRCParser parse:@"[00:05.50]Hundredths dot"];
    CL_ASSERT_NEAR(CLLine(lines, 0).time, 5.5, 0.0005);

    lines = [CLLRCParser parse:@"[00:05.500]Milliseconds"];
    CL_ASSERT_NEAR(CLLine(lines, 0).time, 5.5, 0.0005);

    // The ':' hundredths variant: [mm:ss:xx] is NOT [hh:mm:ss] — it means seconds + hundredths.
    lines = [CLLRCParser parse:@"[01:02:03]Colon hundredths"];
    CL_ASSERT_EQ(lines.count, (NSUInteger)1);
    CL_ASSERT_NEAR(CLLine(lines, 0).time, 62.03, 0.0005);

    // [hh:mm:ss.xx] IS the four-component hours form.
    lines = [CLLRCParser parse:@"[01:02:03.04]Hours form"];
    CL_ASSERT_NEAR(CLLine(lines, 0).time, 3600.0 + 120.0 + 3.0 + 0.04, 0.0005);
}

static void CLTestLRCMultipleStampsPerLine(void) {
    NSArray<CLLyricLine *> *lines = [CLLRCParser parse:@"[00:01.00][00:02.00]Repeated line"];
    CL_ASSERT_EQ(lines.count, (NSUInteger)2);
    CL_ASSERT_NEAR(CLLine(lines, 0).time, 1.0, 0.0005);
    CL_ASSERT_NEAR(CLLine(lines, 1).time, 2.0, 0.0005);
    CL_ASSERT_EQ(CLLine(lines, 0).text, @"Repeated line");
    CL_ASSERT_EQ(CLLine(lines, 1).text, @"Repeated line");
}

static void CLTestLRCOffsetTag(void) {
    // Positive offset shifts lines EARLIER: effective = time - offset/1000, clamped at 0.
    NSArray<CLLyricLine *> *lines = [CLLRCParser parse:@"[offset:+500]\n[00:10.00]Hello"];
    CL_ASSERT_EQ(lines.count, (NSUInteger)1);
    CL_ASSERT_NEAR(CLLine(lines, 0).time, 9.5, 0.0005);

    // Negative offset shifts lines later.
    lines = [CLLRCParser parse:@"[offset:-300]\n[00:10.00]Hello"];
    CL_ASSERT_NEAR(CLLine(lines, 0).time, 10.3, 0.0005);

    // Clamped at 0, never negative.
    lines = [CLLRCParser parse:@"[offset:+5000]\n[00:00.10]Near start"];
    CL_ASSERT_NEAR(CLLine(lines, 0).time, 0.0, 0.0005);

    // The tag is honoured wherever it appears (after the lines too).
    lines = [CLLRCParser parse:@"[00:10.00]Hello\n[offset:+500]"];
    CL_ASSERT_NEAR(CLLine(lines, 0).time, 9.5, 0.0005);
}

static void CLTestLRCEmptyLinesKept(void) {
    NSArray<CLLyricLine *> *lines = [CLLRCParser parse:@"[00:01.00]First\n[00:02.00]\n[00:03.00]Third"];
    CL_ASSERT_EQ(lines.count, (NSUInteger)3);
    CL_ASSERT_EQ(CLLine(lines, 1).text, @"");
}

static void CLTestLRCSortingIsStableForEqualTimestamps(void) {
    NSArray<CLLyricLine *> *lines =
        [CLLRCParser parse:@"[00:10.00]B\n[00:05.00]A\n[00:10.00]C\n[00:05.00]A2"];
    CL_ASSERT_EQ(lines.count, (NSUInteger)4);
    CL_ASSERT_EQ(CLLine(lines, 0).text, @"A");
    CL_ASSERT_EQ(CLLine(lines, 1).text, @"A2");
    CL_ASSERT_EQ(CLLine(lines, 2).text, @"B");
    CL_ASSERT_EQ(CLLine(lines, 3).text, @"C");
}

static void CLTestLRCGarbageInputYieldsNil(void) {
    CL_ASSERT_NIL([CLLRCParser parse:@""]);
    CL_ASSERT_NIL([CLLRCParser parse:@"just some text\nwith no timestamps at all"]);
    CL_ASSERT_NIL([CLLRCParser parse:@"[ar:Some Artist]\n[ti:Some Title]\n[by:whoever]"]);

    // Route the nil/wrong-class values through a variable typed `id`: the header marks `lrc`
    // nonnull, and passing the `nil`/non-string literal directly would trip -Wnonnull under
    // -Wall -Werror. The parser is documented to guard with -isKindOfClass: at runtime regardless.
    id notAString = nil;
    CL_ASSERT_NIL([CLLRCParser parse:notAString]);
    notAString = @42;
    CL_ASSERT_NIL([CLLRCParser parse:notAString]);
}

static void CLTestLRCMetadataTagsAreSkipped(void) {
    NSArray<CLLyricLine *> *lines =
        [CLLRCParser parse:@"[ar:Some Artist]\n[ti:Some Title]\n[length:03:45]\n[00:01.00]Real line"];
    CL_ASSERT_EQ(lines.count, (NSUInteger)1);
    CL_ASSERT_EQ(CLLine(lines, 0).text, @"Real line");
}

static void CLTestLRCNonTimestampBracketStaysInText(void) {
    // Once we have at least one stamp on the line, a bracket that is not itself a timestamp is
    // lyric text, not another tag to consume — "[Chorus]" must survive.
    NSArray<CLLyricLine *> *lines = [CLLRCParser parse:@"[00:12.00][Chorus] x"];
    CL_ASSERT_EQ(lines.count, (NSUInteger)1);
    CL_ASSERT_EQ(CLLine(lines, 0).text, @"[Chorus] x");
}

static void CLTestLRCWordLevelTagsAreStripped(void) {
    NSArray<CLLyricLine *> *lines =
        [CLLRCParser parse:@"[00:01.00]<00:01.00>Hello <00:01.50>World"];
    CL_ASSERT_EQ(lines.count, (NSUInteger)1);
    CL_ASSERT_EQ(CLLine(lines, 0).text, @"Hello World");
}

static void CLTestLRCLineEndingsAllWork(void) {
    NSArray<CLLyricLine *> *lf = [CLLRCParser parse:@"[00:01.00]A\n[00:02.00]B"];
    NSArray<CLLyricLine *> *crlf = [CLLRCParser parse:@"[00:01.00]A\r\n[00:02.00]B"];
    NSArray<CLLyricLine *> *cr = [CLLRCParser parse:@"[00:01.00]A\r[00:02.00]B"];
    CL_ASSERT_EQ(lf.count, (NSUInteger)2);
    CL_ASSERT_EQ(crlf.count, (NSUInteger)2);
    CL_ASSERT_EQ(cr.count, (NSUInteger)2);
}

static void CLTestLRCByteOrderMarkIsStripped(void) {
    NSString *withBOM = [@"﻿" stringByAppendingString:@"[00:01.00]Hi"];
    NSArray<CLLyricLine *> *lines = [CLLRCParser parse:withBOM];
    CL_ASSERT_EQ(lines.count, (NSUInteger)1);
    CL_ASSERT_EQ(CLLine(lines, 0).text, @"Hi");
}

static void CLTestLRCRejectsImplausibleTimestamps(void) {
    // Minutes > 5999, seconds > 59 (two-digit field capped at 99 by the scanner but still an
    // implausible clock value is accepted only up to the documented bound), hours > 24.
    CL_ASSERT_NIL([CLLRCParser parse:@"[99:99:99.99]x"]);
    CL_ASSERT_NIL([CLLRCParser parse:@"[3.5]x"]);       // no ':' -> not a timestamp
    CL_ASSERT_NIL([CLLRCParser parse:@"[01:23.]x"]);    // trailing separator
    CL_ASSERT_NIL([CLLRCParser parse:@"[:01:23]x"]);    // leading separator
}

static void CLTestLRCPlainTextFromLines(void) {
    CL_ASSERT_EQ([CLLRCParser plainTextFromLines:nil], @"");
    CL_ASSERT_EQ([CLLRCParser plainTextFromLines:@[]], @"");

    NSArray<CLLyricLine *> *lines = [CLLRCParser parse:@"[00:01.00]First\n[00:02.00]\n[00:03.00]Third"];
    CL_ASSERT_EQ([CLLRCParser plainTextFromLines:lines], @"First\n\nThird");
}

void CLRunLRCParserTests(void) {
    CLTestBeginSuite("CLLRCParser");
    CLTestLRCBasicTimestampFormats();
    CLTestLRCMultipleStampsPerLine();
    CLTestLRCOffsetTag();
    CLTestLRCEmptyLinesKept();
    CLTestLRCSortingIsStableForEqualTimestamps();
    CLTestLRCGarbageInputYieldsNil();
    CLTestLRCMetadataTagsAreSkipped();
    CLTestLRCNonTimestampBracketStaysInText();
    CLTestLRCWordLevelTagsAreStripped();
    CLTestLRCLineEndingsAllWork();
    CLTestLRCByteOrderMarkIsStripped();
    CLTestLRCRejectsImplausibleTimestamps();
    CLTestLRCPlainTextFromLines();
}
