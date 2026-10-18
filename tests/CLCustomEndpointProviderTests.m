// Tests for CLCustomEndpointProvider (Tweak/Lyrics/CLCustomEndpointProvider.m). Two halves: the
// enabled/disabled state machine — which is what keeps this provider inert by default and safe to
// flip live from the prefs reload path — and the pure decoder -lyricsFromData:response: (exposed
// by the integrate wave at this slice's request), which is the whole of the response handling the
// header documents, exercised here with fixture bodies instead of a live endpoint.
#import "CLCustomEndpointProviderTests.h"
#import "CLTestCase.h"
#import "Lyrics/CLCustomEndpointProvider.h"

static NSData *CLTestBody(NSString *text) {
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

static void CLTestCustomEndpointConvenienceInitIsDisabled(void) {
    CLCustomEndpointProvider *provider = [[CLCustomEndpointProvider alloc] init];
    CL_ASSERT_FALSE(provider.isEnabled);
    CL_ASSERT_EQ(provider.identifier, @"custom");
    CL_ASSERT_NEAR(provider.timeout, 8.0, 0.0001);
    CL_ASSERT_NIL(provider.urlTemplate);
}

static void CLTestCustomEndpointDesignatedInitEnabledStates(void) {
    CLCustomEndpointProvider *httpsProvider =
        [[CLCustomEndpointProvider alloc] initWithURLTemplate:@"https://example.org/lyrics?a={artist}"
                                                    headerName:nil headerValue:nil];
    CL_ASSERT_TRUE(httpsProvider.isEnabled);

    CLCustomEndpointProvider *httpProvider =
        [[CLCustomEndpointProvider alloc] initWithURLTemplate:@"http://example.org/lyrics"
                                                    headerName:nil headerValue:nil];
    CL_ASSERT_TRUE(httpProvider.isEnabled);

    CLCustomEndpointProvider *emptyTemplate =
        [[CLCustomEndpointProvider alloc] initWithURLTemplate:@"" headerName:nil headerValue:nil];
    CL_ASSERT_FALSE(emptyTemplate.isEnabled);

    CLCustomEndpointProvider *nilTemplate =
        [[CLCustomEndpointProvider alloc] initWithURLTemplate:nil headerName:nil headerValue:nil];
    CL_ASSERT_FALSE(nilTemplate.isEnabled);

    CLCustomEndpointProvider *wrongScheme =
        [[CLCustomEndpointProvider alloc] initWithURLTemplate:@"ftp://example.org/lyrics"
                                                    headerName:nil headerValue:nil];
    CL_ASSERT_FALSE(wrongScheme.isEnabled);

    CLCustomEndpointProvider *justWhitespace =
        [[CLCustomEndpointProvider alloc] initWithURLTemplate:@"   " headerName:nil headerValue:nil];
    CL_ASSERT_FALSE(justWhitespace.isEnabled);
}

static void CLTestCustomEndpointIsLiveEditable(void) {
    CLCustomEndpointProvider *provider = [[CLCustomEndpointProvider alloc] init];
    CL_ASSERT_FALSE(provider.isEnabled);

    provider.urlTemplate = @"https://example.org/lyrics?a={artist}&t={title}";
    CL_ASSERT_TRUE(provider.isEnabled);

    provider.urlTemplate = nil;
    CL_ASSERT_FALSE(provider.isEnabled);

    provider.urlTemplate = @"not-a-url-at-all";
    CL_ASSERT_FALSE(provider.isEnabled);
}

static void CLTestCustomEndpointHeaderAndTimeoutRoundTrip(void) {
    CLCustomEndpointProvider *provider =
        [[CLCustomEndpointProvider alloc] initWithURLTemplate:@"https://example.org/x"
                                                    headerName:@"X-Api-Key" headerValue:@"secret-value"];
    CL_ASSERT_EQ(provider.headerName, @"X-Api-Key");
    CL_ASSERT_EQ(provider.headerValue, @"secret-value");

    provider.timeout = 2.5;
    CL_ASSERT_NEAR(provider.timeout, 2.5, 0.0001);

    provider.headerName = @"Authorization";
    provider.headerValue = @"Bearer abc";
    CL_ASSERT_EQ(provider.headerName, @"Authorization");
    CL_ASSERT_EQ(provider.headerValue, @"Bearer abc");
    CL_ASSERT_TRUE(provider.isEnabled);   // header changes never affect enablement
}


#pragma mark - Pure decoder (no network)

/// A JSON body: syncedLyrics wins, is parsed as LRC, and keeps the body's own plainLyrics.
static void CLTestCustomEndpointDecodesJSONSynced(void) {
    CLCustomEndpointProvider *provider = [[CLCustomEndpointProvider alloc] init];
    NSData *body = CLTestBody(@"{\"syncedLyrics\":\"[00:01.00]one\\n[00:04.25]two\","
                              @"\"plainLyrics\":\"one\\ntwo\"}");
    CLLyrics *lyrics = [provider lyricsFromData:body response:nil];
    CL_ASSERT_NOT_NIL(lyrics);
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.source, @"custom");
    CL_ASSERT_EQ((unsigned long)lyrics.lines.count, 2UL);
    CL_ASSERT_NEAR(lyrics.lines.lastObject.time, 4.25, 0.0005);
    CL_ASSERT_EQ(lyrics.plainText, @"one\ntwo");
}

/// The decoder works on a disabled provider too: decoding is independent of configuration.
static void CLTestCustomEndpointDecodesJSONInstrumentalAndPlain(void) {
    CLCustomEndpointProvider *provider = [[CLCustomEndpointProvider alloc] init];
    CL_ASSERT_FALSE(provider.isEnabled);

    CLLyrics *instrumental = [provider lyricsFromData:CLTestBody(@"{\"instrumental\":true}")
                                             response:nil];
    CL_ASSERT_NOT_NIL(instrumental);
    CL_ASSERT_EQ((long)instrumental.kind, (long)CLLyricsKindInstrumental);

    CLLyrics *plain = [provider lyricsFromData:CLTestBody(@"{\"plainLyrics\":\"a\\nb\"}")
                                      response:nil];
    CL_ASSERT_NOT_NIL(plain);
    CL_ASSERT_EQ((long)plain.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(plain.plainText, @"a\nb");
}

/// A JSON array answers from its first object, per the header.
static void CLTestCustomEndpointDecodesJSONArray(void) {
    CLCustomEndpointProvider *provider = [[CLCustomEndpointProvider alloc] init];
    CLLyrics *lyrics = [provider lyricsFromData:CLTestBody(@"[{\"plainLyrics\":\"from the array\"}]")
                                       response:nil];
    CL_ASSERT_NOT_NIL(lyrics);
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, @"from the array");
}

/// A body that is not JSON is taken as the lyrics themselves: LRC if it parses, plain text if not.
static void CLTestCustomEndpointDecodesRawBodies(void) {
    CLCustomEndpointProvider *provider = [[CLCustomEndpointProvider alloc] init];

    CLLyrics *lrc = [provider lyricsFromData:CLTestBody(@"[00:00.50]first\n[00:02.00]second")
                                    response:nil];
    CL_ASSERT_NOT_NIL(lrc);
    CL_ASSERT_EQ((long)lrc.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ((unsigned long)lrc.lines.count, 2UL);
    CL_ASSERT_EQ(lrc.plainText, @"first\nsecond");   // derived from the lines, none was supplied

    CLLyrics *text = [provider lyricsFromData:CLTestBody(@"just some words\non two lines")
                                     response:nil];
    CL_ASSERT_NOT_NIL(text);
    CL_ASSERT_EQ((long)text.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(text.plainText, @"just some words\non two lines");
}

/// Misses answer nil — never a fabricated "none", and never a guess at unfamiliar JSON.
static void CLTestCustomEndpointDecoderRejectsJunk(void) {
    CLCustomEndpointProvider *provider = [[CLCustomEndpointProvider alloc] init];
    CL_ASSERT_NIL([provider lyricsFromData:nil response:nil]);
    CL_ASSERT_NIL([provider lyricsFromData:[NSData data] response:nil]);
    CL_ASSERT_NIL([provider lyricsFromData:CLTestBody(@"   \n  ") response:nil]);
    CL_ASSERT_NIL([provider lyricsFromData:CLTestBody(@"{\"unrelated\":\"payload\"}") response:nil]);
    CL_ASSERT_NIL([provider lyricsFromData:CLTestBody(@"{\"instrumental\":false}") response:nil]);
    // A body that only *looks* like JSON falls through to the raw-text branch instead of failing.
    CLLyrics *broken = [provider lyricsFromData:CLTestBody(@"{not really json") response:nil];
    CL_ASSERT_NOT_NIL(broken);
    CL_ASSERT_EQ((long)broken.kind, (long)CLLyricsKindPlain);
}

void CLRunCustomEndpointProviderTests(void) {
    CLTestBeginSuite("CLCustomEndpointProvider");
    CLTestCustomEndpointConvenienceInitIsDisabled();
    CLTestCustomEndpointDesignatedInitEnabledStates();
    CLTestCustomEndpointIsLiveEditable();
    CLTestCustomEndpointHeaderAndTimeoutRoundTrip();
    CLTestCustomEndpointDecodesJSONSynced();
    CLTestCustomEndpointDecodesJSONInstrumentalAndPlain();
    CLTestCustomEndpointDecodesJSONArray();
    CLTestCustomEndpointDecodesRawBodies();
    CLTestCustomEndpointDecoderRejectsJunk();
}
