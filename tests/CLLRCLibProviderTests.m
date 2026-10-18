// Tests for CLLRCLibProvider (Tweak/Lyrics/CLLRCLibProvider.m).
//
// The header now exposes the two pure decoders (-lyricsFromEntry: and
// -lyricsFromSearchResults:duration:, added by the integrate wave at this slice's request), so the
// whole "instrumental / syncedLyrics / plainLyrics / nothing" branching is pinned down here with
// fixtures. Anything that actually talks to lrclib.net still only runs with --network, and even
// then is lenient about the *result* (a rate limit or catalog miss is not this provider's bug)
// while still requiring that the request completes, exactly once, without hanging or crashing.
#import "CLLRCLibProviderTests.h"
#import "CLTestCase.h"
#import "CLTestFixtures.h"
#import "Lyrics/CLLRCLibProvider.h"

static void CLTestLRCLibDefaults(void) {
    CLLRCLibProvider *provider = [[CLLRCLibProvider alloc] init];
    CL_ASSERT_EQ(provider.identifier, @"lrclib");
    CL_ASSERT_NEAR(provider.timeout, 8.0, 0.0001);
    CL_ASSERT_NEAR(provider.durationTolerance, 3.0, 0.0001);
}

static void CLTestLRCLibPropertiesAreSettable(void) {
    CLLRCLibProvider *provider = [[CLLRCLibProvider alloc] init];
    provider.timeout = 3.5;
    provider.durationTolerance = 1.0;
    CL_ASSERT_NEAR(provider.timeout, 3.5, 0.0001);
    CL_ASSERT_NEAR(provider.durationTolerance, 1.0, 0.0001);
}


#pragma mark - Pure decoders (no network)

/// The /api/get fixture: synced lyrics win, and the entry's own plainLyrics is kept alongside.
static void CLTestLRCLibDecodesGetFixture(void) {
    CLLRCLibProvider *provider = [[CLLRCLibProvider alloc] init];
    id object = [NSJSONSerialization JSONObjectWithData:CLTestLRCLibGetResponseFixture()
                                                options:0 error:NULL];
    CL_ASSERT_NOT_NIL(object);

    CLLyrics *lyrics = [provider lyricsFromEntry:object];
    CL_ASSERT_NOT_NIL(lyrics);
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.source, @"lrclib");
    CL_ASSERT_EQ((unsigned long)lyrics.lines.count, 3UL);
    CL_ASSERT_NEAR(lyrics.lines.firstObject.time, 1.0, 0.0005);
    CL_ASSERT_EQ(lyrics.lines.firstObject.text, @"line one");
    // plainLyrics from the response, not re-derived from the timestamps.
    CL_ASSERT_EQ(lyrics.plainText, @"line one\nline two\nline three");
}

static void CLTestLRCLibDecodesInstrumental(void) {
    CLLRCLibProvider *provider = [[CLLRCLibProvider alloc] init];
    CLLyrics *lyrics = [provider lyricsFromEntry:@{ @"instrumental": @YES }];
    CL_ASSERT_NOT_NIL(lyrics);
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindInstrumental);
    CL_ASSERT_EQ(lyrics.source, @"lrclib");
    CL_ASSERT_EQ((unsigned long)lyrics.lines.count, 0UL);
    CL_ASSERT_TRUE(lyrics.fetchedAt > 0);
}

static void CLTestLRCLibDecodesPlainOnly(void) {
    CLLRCLibProvider *provider = [[CLLRCLibProvider alloc] init];
    CLLyrics *lyrics = [provider lyricsFromEntry:@{ @"plainLyrics": @"just\nwords" }];
    CL_ASSERT_NOT_NIL(lyrics);
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, @"just\nwords");
    CL_ASSERT_EQ((unsigned long)lyrics.lines.count, 0UL);
}

/// syncedLyrics that carry no timestamp at all must not become an empty synced result: the entry
/// falls through to instrumental, then to plainLyrics, then to a miss.
static void CLTestLRCLibUnparseableSyncedFallsThrough(void) {
    CLLRCLibProvider *provider = [[CLLRCLibProvider alloc] init];

    CLLyrics *toPlain = [provider lyricsFromEntry:@{ @"syncedLyrics": @"no timestamps here",
                                                     @"plainLyrics": @"the words" }];
    CL_ASSERT_NOT_NIL(toPlain);
    CL_ASSERT_EQ((long)toPlain.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(toPlain.plainText, @"the words");

    CLLyrics *toInstrumental = [provider lyricsFromEntry:@{ @"syncedLyrics": @"no timestamps here",
                                                            @"instrumental": @YES }];
    CL_ASSERT_NOT_NIL(toInstrumental);
    CL_ASSERT_EQ((long)toInstrumental.kind, (long)CLLyricsKindInstrumental);
}

/// Everything that is not a usable entry answers nil — never a fabricated "none", because the
/// chain (not a provider) owns the miss.
static void CLTestLRCLibDecoderRejectsJunk(void) {
    CLLRCLibProvider *provider = [[CLLRCLibProvider alloc] init];
    CL_ASSERT_NIL([provider lyricsFromEntry:nil]);
    CL_ASSERT_NIL([provider lyricsFromEntry:@"a string, not an object"]);
    CL_ASSERT_NIL([provider lyricsFromEntry:@[]]);
    CL_ASSERT_NIL(([provider lyricsFromEntry:@{}]));
    CL_ASSERT_NIL(([provider lyricsFromEntry:@{ @"instrumental": @NO }]));
    CL_ASSERT_NIL(([provider lyricsFromEntry:@{ @"plainLyrics": @"   " }]));
    CL_ASSERT_NIL(([provider lyricsFromEntry:@{ @"syncedLyrics": @123, @"plainLyrics": @456 }]));
}

static NSDictionary *CLTestLRCLibCandidate(NSString *synced, NSString *plain, double duration) {
    NSMutableDictionary *candidate = [NSMutableDictionary dictionary];
    candidate[@"duration"] = @(duration);
    if (synced) candidate[@"syncedLyrics"] = synced;
    if (plain) candidate[@"plainLyrics"] = plain;
    return candidate;
}

/// /api/search: synced beats plain, the closest duration inside the tolerance wins, and a
/// candidate outside the tolerance is not used at all.
static void CLTestLRCLibPicksBestSearchResult(void) {
    CLLRCLibProvider *provider = [[CLLRCLibProvider alloc] init];
    NSString *near = @"[00:02.00] near";
    NSString *far = @"[00:02.00] far";

    NSArray *results = @[ CLTestLRCLibCandidate(far, nil, 205),      // 5 s off -> outside tolerance
                          CLTestLRCLibCandidate(nil, @"plain", 200), // exact, but only plain
                          CLTestLRCLibCandidate(near, nil, 202) ];   // 2 s off -> the winner
    CLLyrics *chosen = [provider lyricsFromSearchResults:results duration:200];
    CL_ASSERT_NOT_NIL(chosen);
    CL_ASSERT_EQ((long)chosen.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(chosen.lines.firstObject.text, @"near");

    // Tighten the tolerance and the synced candidate drops out; the exact-duration plain one wins.
    provider.durationTolerance = 1.0;
    CLLyrics *tightened = [provider lyricsFromSearchResults:results duration:200];
    CL_ASSERT_NOT_NIL(tightened);
    CL_ASSERT_EQ((long)tightened.kind, (long)CLLyricsKindPlain);

    // Nothing within tolerance at all -> nil, not the closest miss.
    CL_ASSERT_NIL([provider lyricsFromSearchResults:results duration:400]);
    CL_ASSERT_NIL([provider lyricsFromSearchResults:@[] duration:200]);
    CL_ASSERT_NIL([provider lyricsFromSearchResults:nil duration:200]);
}

/// Unknown duration: no candidate can be verified, so LRCLIB's own relevance order decides.
static void CLTestLRCLibSearchWithUnknownDuration(void) {
    CLLRCLibProvider *provider = [[CLLRCLibProvider alloc] init];
    NSArray *results = @[ CLTestLRCLibCandidate(@"[00:01.00] first", nil, 0),
                          CLTestLRCLibCandidate(@"[00:01.00] second", nil, 0) ];
    CLLyrics *chosen = [provider lyricsFromSearchResults:results duration:0];
    CL_ASSERT_NOT_NIL(chosen);
    CL_ASSERT_EQ(chosen.lines.firstObject.text, @"first");
}

static void CLTestLRCLibLiveLookup(void) {
    CLLRCLibProvider *provider = [[CLLRCLibProvider alloc] init];
    provider.timeout = 10.0;

    CLTrack *track = [[CLTrack alloc] init];
    track.title = @"Bohemian Rhapsody";
    track.artist = @"Queen";
    track.album = @"A Night At The Opera";
    track.duration = 354;

    __block BOOL delivered = NO;
    __block CLLyrics *result = nil;
    __block NSError *resultError = nil;
    [provider fetchLyricsForTrack:track completion:^(CLLyrics *lyrics, NSError *error) {
        result = lyrics;
        resultError = error;
        delivered = YES;
    }];

    BOOL completedInTime = CLTestWaitUntil(15.0, ^BOOL{ return delivered; });
    CL_ASSERT_TRUE(completedInTime);   // must always call back, network conditions notwithstanding
    if (!completedInTime) return;

    if (resultError) {
        // lrclib.net rate-limits aggressively under bursty use (see lyrics-core's HANDOFF.md
        // note); a transient HTTP error here is a live-network fact, not a defect in this test.
        printf("  (network) lrclib returned an error, treating as inconclusive: %s\n",
               resultError.localizedDescription.UTF8String ?: "?");
        return;
    }
    CL_ASSERT_NOT_NIL(result);
    if (result.kind != CLLyricsKindNone) {
        CL_ASSERT_EQ(result.source, @"lrclib");
        printf("  (network) lrclib kind=%ld lines=%lu\n", (long)result.kind,
               (unsigned long)result.lines.count);
    } else {
        printf("  (network) lrclib had no match for the fixture track (catalog miss)\n");
    }
}

void CLRunLRCLibProviderTests(BOOL networkEnabled) {
    CLTestBeginSuite("CLLRCLibProvider");
    CLTestLRCLibDefaults();
    CLTestLRCLibPropertiesAreSettable();
    CLTestLRCLibDecodesGetFixture();
    CLTestLRCLibDecodesInstrumental();
    CLTestLRCLibDecodesPlainOnly();
    CLTestLRCLibUnparseableSyncedFallsThrough();
    CLTestLRCLibDecoderRejectsJunk();
    CLTestLRCLibPicksBestSearchResult();
    CLTestLRCLibSearchWithUnknownDuration();
    if (networkEnabled) {
        CLTestLRCLibLiveLookup();
    } else {
        printf("  (skipped live lookup; pass --network to exercise it)\n");
    }
}
