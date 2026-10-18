// Tests for CLTTMLParser (Apple Music's lyrics TTML -> CLLyrics). Fixtures follow the shapes in
// docs/research/apple-music-lyrics.md: Apple sends the document on one line with a space text node
// between word spans and none between the syllables of a word; the pretty-printed variant covers
// hand-written or re-serialised documents.
#import "CLTTMLParserTests.h"
#import "CLTestCase.h"
#import "Lyrics/CLTTMLParser.h"
#import <math.h>

static NSString *const kCLTTMLTestNamespaces =
    @"xmlns='http://www.w3.org/ns/ttml' xmlns:itunes='http://music.apple.com/lyric-ttml-internal' "
    @"xmlns:ttm='http://www.w3.org/ns/ttml#metadata'";

/// A <tt> document whose <body> holds `body`, with itunes:timing when `timing` is non-nil.
static NSString *CLTTMLTestDocument(NSString *timing, NSString *body) {
    NSString *timingAttribute = timing ? [NSString stringWithFormat:@" itunes:timing='%@'", timing] : @"";
    return [NSString stringWithFormat:@"<tt %@%@ xml:lang='en'><head><metadata/></head><body>%@</body></tt>",
            kCLTTMLTestNamespaces, timingAttribute, body];
}

static CLLyrics *CLTTMLTestParse(NSString *ttml) {
    return [CLTTMLParser lyricsFromTTML:ttml source:@"apple-music"];
}

static CLLyricLine *CLTTMLTestLine(CLLyrics *lyrics, NSUInteger index) {
    return index < lyrics.lines.count ? lyrics.lines[index] : nil;
}

/// What the syllable-lyrics endpoint returns, trimmed to four lines: agents and iTunesMetadata
/// (a translation and a songwriter, both of which must stay out of the lyrics) in <head>,
/// syllables, words, a background-vocal group, two <div>s with a 7.5 s break between them, and a
/// clock value with minutes.
static NSString *CLTTMLTestAppleWordSample(void) {
    return
    @"<tt xmlns=\"http://www.w3.org/ns/ttml\" xmlns:itunes=\"http://music.apple.com/lyric-ttml-internal\" "
     "xmlns:ttm=\"http://www.w3.org/ns/ttml#metadata\" itunes:timing=\"Word\" xml:lang=\"en\">"
    "<head><metadata><ttm:agent type=\"person\" xml:id=\"v1\"/><ttm:agent type=\"person\" xml:id=\"v2\"/>"
    "<iTunesMetadata xmlns=\"http://music.apple.com/lyric-ttml-internal\" leadingSilence=\"0.360\">"
    "<translations><translation type=\"replacement\" xml:lang=\"de\">"
    "<text for=\"L1\"><span>Reißt die Mauern ein</span></text></translation></translations>"
    "<songwriters><songwriter>Jane Writer</songwriter></songwriters></iTunesMetadata></metadata></head>"
    "<body dur=\"3:25.100\">"
    "<div begin=\"10.018\" end=\"17.500\" itunes:songPart=\"Verse\">"
    "<p begin=\"10.018\" end=\"12.244\" itunes:key=\"L1\" ttm:agent=\"v1\">"
    "<span begin=\"10.018\" end=\"10.290\">Break</span> <span begin=\"10.290\" end=\"10.512\">down</span> "
    "<span begin=\"10.512\" end=\"10.700\">the</span> <span begin=\"10.700\" end=\"12.244\">walls</span></p>"
    "<p begin=\"12.500\" end=\"17.500\" itunes:key=\"L2\" ttm:agent=\"v1\">"
    "<span begin=\"12.500\" end=\"12.800\">It&apos;s</span> <span begin=\"12.800\" end=\"13.100\">a</span> "
    "<span begin=\"13.100\" end=\"13.400\">Won</span><span begin=\"13.400\" end=\"13.700\">der</span>"
    "<span begin=\"13.700\" end=\"14.200\">ful</span> <span begin=\"14.200\" end=\"15.000\">night</span>"
    "<span ttm:role=\"x-bg\"><span begin=\"15.500\" end=\"16.000\">(ooh</span> "
    "<span begin=\"16.000\" end=\"17.500\">yeah)</span></span></p>"
    "</div>"
    "<div begin=\"25.000\" end=\"1:02.345\" itunes:songPart=\"Chorus\">"
    "<p begin=\"25.000\" end=\"28.000\" itunes:key=\"L3\" ttm:agent=\"v2\">"
    "<span begin=\"25.000\" end=\"25.600\">Sing</span> <span begin=\"25.600\" end=\"26.000\">it</span> "
    "<span begin=\"26.000\" end=\"28.000\">loud</span></p>"
    "<p begin=\"28.100\" end=\"1:02.345\" itunes:key=\"L4\" ttm:agent=\"v2\">"
    "<span begin=\"28.100\" end=\"30.000\">Every</span><span begin=\"30.000\" end=\"31.000\">body</span> "
    "<span begin=\"31.000\" end=\"1:02.345\">now</span></p>"
    "</div></body></tt>";
}

#pragma mark - Clock values

static void CLTestTTMLClockValues(void) {
    CL_ASSERT_NEAR([CLTTMLParser timeFromClockValue:@"10.018"], 10.018, 1e-9);
    CL_ASSERT_NEAR([CLTTMLParser timeFromClockValue:@"1:02.345"], 62.345, 1e-9);
    CL_ASSERT_NEAR([CLTTMLParser timeFromClockValue:@"01:02:03.456"], 3723.456, 1e-9);
    CL_ASSERT_NEAR([CLTTMLParser timeFromClockValue:@"12.3s"], 12.3, 1e-9);
    CL_ASSERT_NEAR([CLTTMLParser timeFromClockValue:@"450ms"], 0.45, 1e-9);
    CL_ASSERT_NEAR([CLTTMLParser timeFromClockValue:@"1.5m"], 90.0, 1e-9);
    CL_ASSERT_NEAR([CLTTMLParser timeFromClockValue:@"0.5h"], 1800.0, 1e-9);

    CL_ASSERT_NEAR([CLTTMLParser timeFromClockValue:@"0"], 0.0, 1e-9);
    CL_ASSERT_NEAR([CLTTMLParser timeFromClockValue:@"0.000"], 0.0, 1e-9);
    CL_ASSERT_NEAR([CLTTMLParser timeFromClockValue:@"7s"], 7.0, 1e-9);
    CL_ASSERT_NEAR([CLTTMLParser timeFromClockValue:@"2h"], 7200.0, 1e-9);
    CL_ASSERT_NEAR([CLTTMLParser timeFromClockValue:@"1:02"], 62.0, 1e-9);
    CL_ASSERT_NEAR([CLTTMLParser timeFromClockValue:@"01:02:03"], 3723.0, 1e-9);
    CL_ASSERT_NEAR([CLTTMLParser timeFromClockValue:@"3:25.100"], 205.1, 1e-9);
    CL_ASSERT_NEAR([CLTTMLParser timeFromClockValue:@" 10.5\n"], 10.5, 1e-9);
    // Digits past the ninth fraction digit are accepted and ignored.
    CL_ASSERT_NEAR([CLTTMLParser timeFromClockValue:@"10.0180000001"], 10.018, 1e-9);
}

static void CLTestTTMLClockGarbage(void) {
    NSArray<NSString *> *garbage = @[
        @"", @"   ", @"abc", @"-1", @"-0:01", @"+1", @"1:", @":5", @"1::2", @"1.2.3", @"5.", @".5",
        @"10x", @"10 s", @"1:02:03:04", @"12f", @"100t", @"1e3", @"inf", @"nan", @"1:2.5.6",
        @"1.5:30", @"1:02s", @"10.018ms5", @"１０",
        @"123456789012345678901234567890123",
    ];
    for (NSString *value in garbage) {
        NSString *label = [NSString stringWithFormat:@"isnan(timeFromClockValue:@\"%@\")", value];
        CLTestRecordResult(isnan([CLTTMLParser timeFromClockValue:value]) ? YES : NO,
                           label.UTF8String, __FILE__, __LINE__);
    }
    CL_ASSERT_TRUE(isnan([CLTTMLParser timeFromClockValue:nil]));
    id notAString = @42;
    CL_ASSERT_TRUE(isnan([CLTTMLParser timeFromClockValue:notAString]));
}

#pragma mark - Synced documents

static void CLTestTTMLAppleWordSample(void) {
    CLLyrics *lyrics = CLTTMLTestParse(CLTTMLTestAppleWordSample());
    CL_ASSERT_NOT_NIL(lyrics);
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.source, @"apple-music");
    CL_ASSERT_TRUE(lyrics.fetchedAt > 0);

    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)5);
    CL_ASSERT_NEAR(CLTTMLTestLine(lyrics, 0).time, 10.018, 0.0005);
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 0).text, @"Break down the walls");
    // Syllables join, words get one space, the x-bg group follows after a space.
    CL_ASSERT_NEAR(CLTTMLTestLine(lyrics, 1).time, 12.5, 0.0005);
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 1).text, @"It's a Wonderful night (ooh yeah)");
    // 7.5 s between the verse's last end and the chorus: a blank line at 17.5.
    CL_ASSERT_NEAR(CLTTMLTestLine(lyrics, 2).time, 17.5, 0.0005);
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 2).text, @"");
    CL_ASSERT_NEAR(CLTTMLTestLine(lyrics, 3).time, 25.0, 0.0005);
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 3).text, @"Sing it loud");
    // 0.1 s gap: no blank line; nothing after the last line.
    CL_ASSERT_NEAR(CLTTMLTestLine(lyrics, 4).time, 28.1, 0.0005);
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 4).text, @"Everybody now");

    // plainText follows the <div>s, not the gaps.
    CL_ASSERT_EQ(lyrics.plainText,
                 @"Break down the walls\nIt's a Wonderful night (ooh yeah)\n\nSing it loud\nEverybody now");
    CL_ASSERT_TRUE([lyrics.plainText rangeOfString:@"Mauern"].location == NSNotFound);
    CL_ASSERT_TRUE([lyrics.plainText rangeOfString:@"Jane"].location == NSNotFound);
}

static void CLTestTTMLPrettyPrinted(void) {
    NSString *ttml =
    @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
     "<tt xmlns=\"http://www.w3.org/ns/ttml\"\n"
     "    xmlns:itunes=\"http://music.apple.com/lyric-ttml-internal\"\n"
     "    xmlns:ttm=\"http://www.w3.org/ns/ttml#metadata\" itunes:timing=\"Word\">\n"
     "  <head>\n    <metadata>\n      <ttm:agent type=\"person\" xml:id=\"v1\"/>\n    </metadata>\n  </head>\n"
     "  <body>\n"
     "    <div>\n"
     "      <p begin=\"1.000\" end=\"3.000\">\n"
     "        <span begin=\"1.000\" end=\"1.500\">Hello</span>\n"
     "        <span begin=\"1.500\" end=\"2.000\">world</span>\n"
     "        <span ttm:role=\"x-bg\">\n"
     "          <span begin=\"2.000\" end=\"3.000\">(hi)</span>\n"
     "        </span>\n"
     "      </p>\n"
     "      <p begin=\"3.500\" end=\"5.000\">\n"
     "        Plain\n\t\t  text   inside\n"
     "        a p\n"
     "      </p>\n"
     "    </div>\n"
     "  </body>\n"
     "</tt>\n";
    CLLyrics *lyrics = CLTTMLTestParse(ttml);
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)2);
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 0).text, @"Hello world (hi)");
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 1).text, @"Plain text inside a p");
    CL_ASSERT_NEAR(CLTTMLTestLine(lyrics, 1).time, 3.5, 0.0005);
    CL_ASSERT_EQ(lyrics.plainText, @"Hello world (hi)\nPlain text inside a p");
}

static void CLTestTTMLLineTimed(void) {
    CLLyrics *lyrics = CLTTMLTestParse(CLTTMLTestDocument(@"Line",
        @"<div><p begin='00:05.100' end='00:07.000'>First line</p>"
        @"<p begin='00:07.500' end='00:09.000'>Second line</p></div>"));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)2);
    CL_ASSERT_NEAR(CLTTMLTestLine(lyrics, 0).time, 5.1, 0.0005);
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 0).text, @"First line");
    CL_ASSERT_NEAR(CLTTMLTestLine(lyrics, 1).time, 7.5, 0.0005);
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 1).text, @"Second line");
}

static void CLTestTTMLNoTimingAttributeButTimed(void) {
    CLLyrics *lyrics = CLTTMLTestParse(CLTTMLTestDocument(nil,
        @"<div><p begin='1.5' end='2.5'>One</p><p begin='3' end='4'>Two</p></div>"));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)2);
    CL_ASSERT_NEAR(CLTTMLTestLine(lyrics, 0).time, 1.5, 0.0005);
    CL_ASSERT_NEAR(CLTTMLTestLine(lyrics, 1).time, 3.0, 0.0005);
}

static void CLTestTTMLParagraphTimedBySpans(void) {
    CLLyrics *lyrics = CLTTMLTestParse(CLTTMLTestDocument(@"Word",
        @"<div>"
        @"<p><span begin='4.200' end='4.800'>No</span> <span begin='4.800' end='6.000'>begin</span></p>"
        @"<p begin='12.000' end='13.000'>Next</p>"
        // Background group first in the document but later in time: the line starts at the
        // earliest span, and the main text after the group is kept apart from it.
        @"<p><span ttm:role='x-bg'><span begin='20.500' end='21.000'>(bg)</span></span>"
        @"<span begin='20.000' end='20.400'>main</span></p>"
        @"<p>No time at all</p>"
        @"</div>"));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)5);
    CL_ASSERT_NEAR(CLTTMLTestLine(lyrics, 0).time, 4.2, 0.0005);
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 0).text, @"No begin");
    // The <p> had no `end`: its last span's end (6.0) opens the 6 s break.
    CL_ASSERT_NEAR(CLTTMLTestLine(lyrics, 1).time, 6.0, 0.0005);
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 1).text, @"");
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 2).text, @"Next");
    CL_ASSERT_NEAR(CLTTMLTestLine(lyrics, 3).time, 13.0, 0.0005);
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 3).text, @"");
    CL_ASSERT_NEAR(CLTTMLTestLine(lyrics, 4).time, 20.0, 0.0005);
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 4).text, @"(bg) main");
    // The untimed <p> is not a line, but it is still part of the text.
    CL_ASSERT_EQ(lyrics.plainText, @"No begin\nNext\n(bg) main\nNo time at all");
}

static void CLTestTTMLGapBlankLines(void) {
    CLLyrics *lyrics = CLTTMLTestParse(CLTTMLTestDocument(@"Line",
        @"<div>"
        @"<p begin='1.018' end='3.056'>A</p>"
        // Exactly 5 s after A's end (8.056 - 3.056 is 4.999999999999999 in double): blank at 3.056.
        @"<p begin='8.056' end='9.000'>B</p>"
        @"<p begin='12.000' end='13.000'>C</p>"   // 3 s: none
        @"<p begin='17.999' end='19.000'>D</p>"   // 4.999 s: none
        @"<p begin='31.000'>E</p>"                // 12 s after D: blank at 19
        @"<p begin='60.000' end='61.000'>F</p>"   // E has no end: none; F is last: none
        @"</div>"));
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)8);
    NSArray<NSString *> *texts = @[ @"A", @"", @"B", @"C", @"D", @"", @"E", @"F" ];
    double times[] = { 1.018, 3.056, 8.056, 12.0, 17.999, 19.0, 31.0, 60.0 };
    for (NSUInteger i = 0; i < texts.count && i < lyrics.lines.count; i++) {
        CL_ASSERT_EQ(lyrics.lines[i].text, texts[i]);
        CL_ASSERT_NEAR(lyrics.lines[i].time, times[i], 0.0005);
    }

    // Overlapping lines (a duet): the short line ends at 13 but the long one runs to 30, so the
    // 7 s "gap" before 20 is not a break; the real one starts at 30.
    lyrics = CLTTMLTestParse(CLTTMLTestDocument(@"Line",
        @"<div><p begin='10' end='30'>Long</p><p begin='12' end='13'>Short</p>"
        @"<p begin='20' end='21'>Next</p><p begin='40' end='41'>Last</p></div>"));
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)5);
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 2).text, @"Next");
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 3).text, @"");
    CL_ASSERT_NEAR(CLTTMLTestLine(lyrics, 3).time, 30.0, 0.0005);
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 4).text, @"Last");

    // An `end` before its `begin` is not trusted.
    lyrics = CLTTMLTestParse(CLTTMLTestDocument(@"Line",
        @"<div><p begin='10' end='5'>Backwards</p><p begin='20' end='21'>After</p></div>"));
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)2);
}

static void CLTestTTMLSortingIsStable(void) {
    CLLyrics *lyrics = CLTTMLTestParse(CLTTMLTestDocument(@"Line",
        @"<div><p begin='9'>C</p><p begin='3'>A</p><p begin='9'>D</p><p begin='3'>B</p></div>"));
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)4);
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 0).text, @"A");
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 1).text, @"B");
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 2).text, @"C");
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 3).text, @"D");
    CL_ASSERT_EQ(lyrics.plainText, @"C\nA\nD\nB");   // document order
}

static void CLTestTTMLTextDetails(void) {
    CLLyrics *lyrics = CLTTMLTestParse(CLTTMLTestDocument(@"Line",
        @"<div>"
        @"<p begin='1'>Rock &amp; Roll &apos;n&apos; &quot;more&quot; &lt;3 caf&#233; &#x266A;</p>"
        @"<p begin='2'>Line<br/>break</p>"
        @"<p begin='3'><![CDATA[Rock & <Roll>]]></p>"
        @"<p begin='4'><span begin='4'>Hey</span> <span ttm:role='x-bg'>(hey)</span></p>"
        @"</div>"));
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)4);
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 0).text, @"Rock & Roll 'n' \"more\" <3 café ♪");
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 1).text, @"Line break");
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 2).text, @"Rock & <Roll>");
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 3).text, @"Hey (hey)");   // no doubled space
}

static void CLTestTTMLDocumentShapes(void) {
    // TTML under a prefix instead of the default namespace.
    CLLyrics *lyrics = CLTTMLTestParse(
        @"<tt:tt xmlns:tt='http://www.w3.org/ns/ttml' xmlns:itunes='http://music.apple.com/lyric-ttml-internal' "
        @"itunes:timing='Line'><tt:body><tt:div><tt:p begin='1' end='2'>Prefixed</tt:p></tt:div></tt:body></tt:tt>");
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 0).text, @"Prefixed");

    // <body dur> and <div begin> do not move the lines (Apple's times are absolute).
    lyrics = CLTTMLTestParse(
        [NSString stringWithFormat:@"<tt %@ itunes:timing='Line'><body dur='3:00.000'>"
         @"<div begin='100.000' end='200.000'><p begin='1.000' end='2.000'>A</p></div></body></tt>",
         kCLTTMLTestNamespaces]);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)1);
    CL_ASSERT_NEAR(CLTTMLTestLine(lyrics, 0).time, 1.0, 0.0005);

    // BOM, leading whitespace and a declaration naming another encoding are dropped.
    lyrics = CLTTMLTestParse([@"﻿\n  <?xml version='1.0' encoding='UTF-16'?>\n"
                              stringByAppendingString:CLTTMLTestDocument(@"Line", @"<div><p begin='1'>Hi</p></div>")]);
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 0).text, @"Hi");

    // Prefixes used without their xmlns declarations still read (libxml2 only warns).
    lyrics = CLTTMLTestParse(@"<tt itunes:timing='None'><body><div><p begin='1'>Hi "
                             @"<span ttm:role='x-bg'>(there)</span></p></div></body></tt>");
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, @"Hi (there)");

    // A <p> straight in <body>, between <div>s, is a stanza of its own.
    lyrics = CLTTMLTestParse(CLTTMLTestDocument(nil, @"<div><p>A</p></div><p>B</p><div><p>C</p></div>"));
    CL_ASSERT_EQ(lyrics.plainText, @"A\n\nB\n\nC");
}

static void CLTestTTMLLargeDocument(void) {
    NSMutableString *body = [NSMutableString stringWithString:@"<div>"];
    for (NSUInteger i = 0; i < 500; i++) {
        if (i > 0 && i % 50 == 0) [body appendString:@"</div><div>"];
        double begin = 1.0 + (double)i * 3.0;
        [body appendFormat:@"<p begin='%.3f' end='%.3f'><span begin='%.3f' end='%.3f'>Li</span>"
                           @"<span begin='%.3f' end='%.3f'>ne</span> <span begin='%.3f' end='%.3f'>%lu</span></p>",
                           begin, begin + 2.5, begin, begin + 0.5, begin + 0.5, begin + 1.0,
                           begin + 1.0, begin + 2.5, (unsigned long)i];
    }
    [body appendString:@"</div>"];

    NSDate *start = [NSDate date];
    CLLyrics *lyrics = CLTTMLTestParse(CLTTMLTestDocument(@"Word", body));
    NSTimeInterval elapsed = -[start timeIntervalSinceNow];
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)500);   // 0.5 s gaps: no blank lines
    CL_ASSERT_NEAR(CLTTMLTestLine(lyrics, 0).time, 1.0, 0.0005);
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 0).text, @"Line 0");
    CL_ASSERT_NEAR(CLTTMLTestLine(lyrics, 499).time, 1498.0, 0.0005);
    CL_ASSERT_EQ(CLTTMLTestLine(lyrics, 499).text, @"Line 499");
    // Ten stanzas: 500 rows plus 9 separators.
    CL_ASSERT_EQ([lyrics.plainText componentsSeparatedByString:@"\n"].count, (NSUInteger)509);
    CL_ASSERT_TRUE(elapsed < 5.0);
}

#pragma mark - Unsynced documents

static void CLTestTTMLTranscript(void) {
    // itunes:timing="None" wins over the zero times Apple leaves on transcripts.
    CLLyrics *lyrics = CLTTMLTestParse(CLTTMLTestDocument(@"None",
        @"<div><p begin='0' end='0'>Verse one, line one</p><p begin='0.000' end='0.000'>Verse one, line two</p></div>"
        @"<div><p begin='0'><span>Cho</span><span>rus</span> <span>line</span></p></div>"));
    CL_ASSERT_NOT_NIL(lyrics);
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)0);
    CL_ASSERT_EQ(lyrics.source, @"apple-music");
    CL_ASSERT_EQ(lyrics.plainText, @"Verse one, line one\nVerse one, line two\n\nChorus line");

    lyrics = CLTTMLTestParse(CLTTMLTestDocument(@"none", @"<div><p begin='5'>Lowercase</p></div>"));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
}

static void CLTestTTMLNothingTimed(void) {
    CLLyrics *lyrics = CLTTMLTestParse(CLTTMLTestDocument(nil,
        @"<div><p>One</p><p>Two</p></div><div><p>Three</p></div>"));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, @"One\nTwo\n\nThree");

    // Claimed line timing but no parseable time anywhere.
    lyrics = CLTTMLTestParse(CLTTMLTestDocument(@"Line", @"<div><p begin='soon'>One</p></div>"));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, @"One");

    // The only timed <p> is empty: the words that are there are still shown.
    lyrics = CLTTMLTestParse(CLTTMLTestDocument(@"Line", @"<div><p begin='1'>   </p><p>Untimed words</p></div>"));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, @"Untimed words");
}

#pragma mark - Rejected input

static void CLTestTTMLRejectsGarbage(void) {
    CL_ASSERT_NIL([CLTTMLParser lyricsFromTTML:nil source:@"apple-music"]);
    CL_ASSERT_NIL(CLTTMLTestParse(@""));
    CL_ASSERT_NIL(CLTTMLTestParse(@"   \n\t"));
    id notAString = @42;
    CL_ASSERT_NIL(CLTTMLTestParse(notAString));
    CL_ASSERT_NIL(CLTTMLTestParse(@"just some lyrics"));
    CL_ASSERT_NIL(CLTTMLTestParse(@"{\"data\":[]}"));

    // Malformed, truncated, trailing junk, an unterminated declaration.
    CL_ASSERT_NIL(CLTTMLTestParse(@"<tt><body><div><p begin='1'>Oops</div></body></tt>"));
    NSString *sample = CLTTMLTestAppleWordSample();
    CL_ASSERT_NIL(CLTTMLTestParse([sample substringToIndex:sample.length / 2]));
    CL_ASSERT_NIL(CLTTMLTestParse([sample stringByAppendingString:@"<tt/>"]));
    CL_ASSERT_NIL(CLTTMLTestParse(@"<?xml version='1.0'"));

    // Not TTML.
    CL_ASSERT_NIL(CLTTMLTestParse(@"<html><body><p begin='1'>Hi</p></body></html>"));
    CL_ASSERT_NIL(CLTTMLTestParse(@"<ttx><body><div><p begin='1'>Hi</p></div></body></ttx>"));

    // TTML without lyric text.
    CL_ASSERT_NIL(CLTTMLTestParse(CLTTMLTestDocument(@"Word", @"")));
    CL_ASSERT_NIL(CLTTMLTestParse(CLTTMLTestDocument(@"Line",
        @"<div><p begin='1'>   </p><p begin='2'><span begin='2'> </span></p></div>")));
    CL_ASSERT_NIL(CLTTMLTestParse(
        [NSString stringWithFormat:@"<tt %@><head><metadata><ttm:title>Title</ttm:title></metadata></head>"
         @"<body/></tt>", kCLTTMLTestNamespaces]));
}

static void CLTestTTMLRefusesEntities(void) {
    // Entity expansion ("billion laughs") and an external entity: refused before parsing.
    NSString *laughs =
        @"<?xml version='1.0'?><!DOCTYPE tt [<!ENTITY a 'haha'>"
        @"<!ENTITY b '&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;'><!ENTITY c '&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;'>"
        @"<!ENTITY d '&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;'><!ENTITY e '&d;&d;&d;&d;&d;&d;&d;&d;&d;&d;'>]>"
        @"<tt><body><div><p begin='1'>&e;</p></div></body></tt>";
    CL_ASSERT_NIL(CLTTMLTestParse(laughs));

    NSString *external =
        @"<!DOCTYPE tt [<!ENTITY xxe SYSTEM 'file:///etc/passwd'>]>"
        @"<tt><body><div><p begin='1'>&xxe;</p></div></body></tt>";
    CL_ASSERT_NIL(CLTTMLTestParse(external));
}

void CLRunTTMLParserTests(void) {
    CLTestBeginSuite("CLTTMLParser");
    CLTestTTMLClockValues();
    CLTestTTMLClockGarbage();
    CLTestTTMLAppleWordSample();
    CLTestTTMLPrettyPrinted();
    CLTestTTMLLineTimed();
    CLTestTTMLNoTimingAttributeButTimed();
    CLTestTTMLParagraphTimedBySpans();
    CLTestTTMLGapBlankLines();
    CLTestTTMLSortingIsStable();
    CLTestTTMLTextDetails();
    CLTestTTMLDocumentShapes();
    CLTestTTMLLargeDocument();
    CLTestTTMLTranscript();
    CLTestTTMLNothingTimed();
    CLTestTTMLRejectsGarbage();
    CLTestTTMLRefusesEntities();
}
