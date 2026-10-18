// Tests for CLLyricsCache (Tweak/Lyrics/CLLyricsCache.m).
//
// CLLyricsCache is a hard singleton (+sharedCache), but its storage root is overridable with the
// CARLY_CACHE_DIR environment variable (added by the integrate wave at this slice's request),
// and tests/run.sh points it at a fresh scratch directory per run. So this suite gets real
// isolation: it cannot touch this user's own <NSCachesDirectory>/carLy/lyrics, and two runs
// cannot collide. Running the binary directly, without run.sh, simply falls back to the default
// path — which is still safe, because a bare Theos "tool" executable has no app sandbox container
// and its NSCachesDirectory is this process's own home, never CarPlayTemplateUIHost's. Every
// track here also carries a random per-run marker, and the suite calls -clear as its last step,
// so neither mode accumulates files.
#import "CLLyricsCacheTests.h"
#import "CLTestCase.h"
#import "Lyrics/CLLyricsCache.h"

static CLTrack *CLMakeCacheTestTrack(NSString *marker, NSString *titleSuffix) {
    CLTrack *track = [[CLTrack alloc] init];
    track.title = [NSString stringWithFormat:@"CLTests Fixture %@ %@", marker, titleSuffix];
    track.artist = @"CLTests Fixture Artist";
    track.duration = 180;
    return track;
}

/// Mirrors the path formula documented in CLLyricsCache.h — including the CARLY_CACHE_DIR
/// override — so the test can look at the file CLLyricsCache itself would have written,
/// independently of any of the class's own accessors.
static NSString *CLExpectedCachePathForTrack(CLTrack *track) {
    NSString *root = NSProcessInfo.processInfo.environment[@"CARLY_CACHE_DIR"];
    if (![root hasPrefix:@"/"] || root.length <= 1) {
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        root = [caches stringByAppendingPathComponent:@"carLy"];
    }
    NSString *directory = [root stringByAppendingPathComponent:@"lyrics"];
    return [directory stringByAppendingPathComponent:
            [track.cacheKey stringByAppendingPathExtension:@"json"]];
}

static void CLTestCacheStoreThenImmediateRead(NSString *marker) {
    CLLyricsCache *cache = [CLLyricsCache sharedCache];
    CLTrack *track = CLMakeCacheTestTrack(marker, @"StoreRead");
    CLLyrics *synced = [CLLyrics syncedWithLines:@[
        [CLLyricLine lineWithTime:1.0 text:@"a"],
        [CLLyricLine lineWithTime:2.0 text:@"b"],
    ] source:@"unit-test"];

    CL_ASSERT_NIL([cache lyricsForTrack:track]);   // nothing stored yet
    [cache storeLyrics:synced forTrack:track];
    CLLyrics *readBack = [cache lyricsForTrack:track];
    CL_ASSERT_NOT_NIL(readBack);
    CL_ASSERT_EQ((long)readBack.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(readBack.lines.count, (NSUInteger)2);
    CL_ASSERT_EQ(readBack.source, @"unit-test");
}

static void CLTestCacheNegativeEntryFreshIsKept(NSString *marker) {
    CLLyricsCache *cache = [CLLyricsCache sharedCache];
    NSTimeInterval savedTTL = cache.negativeTTL;
    cache.negativeTTL = 24 * 60 * 60;

    CLTrack *track = CLMakeCacheTestTrack(marker, @"NegativeFresh");
    CLLyrics *none = [CLLyrics noneFromSource:@"chain"];   // fetchedAt stamped to "now" already
    [cache storeLyrics:none forTrack:track];

    CLLyrics *readBack = [cache lyricsForTrack:track];
    CL_ASSERT_NOT_NIL(readBack);
    CL_ASSERT_EQ((long)readBack.kind, (long)CLLyricsKindNone);

    cache.negativeTTL = savedTTL;
}

static void CLTestCacheNegativeEntryExpiresAfterTTL(NSString *marker) {
    CLLyricsCache *cache = [CLLyricsCache sharedCache];
    NSTimeInterval savedTTL = cache.negativeTTL;
    cache.negativeTTL = 60;   // 1 minute, so "25 hours old" is unambiguously expired

    CLTrack *track = CLMakeCacheTestTrack(marker, @"NegativeExpired");
    CLLyrics *stale = [CLLyrics noneFromSource:@"chain"];
    stale.fetchedAt = [NSDate date].timeIntervalSince1970 - (25 * 60 * 60);   // 25h old
    [cache storeLyrics:stale forTrack:track];

    CL_ASSERT_NIL([cache lyricsForTrack:track]);   // expired negative -> treated as a miss

    cache.negativeTTL = savedTTL;
}

static void CLTestCacheNegativeTTLZeroDisablesNegativeCaching(NSString *marker) {
    CLLyricsCache *cache = [CLLyricsCache sharedCache];
    NSTimeInterval savedTTL = cache.negativeTTL;
    cache.negativeTTL = 0;   // "0 disables negative caching" per the header

    CLTrack *track = CLMakeCacheTestTrack(marker, @"NegativeZeroTTL");
    CLLyrics *freshNone = [CLLyrics noneFromSource:@"chain"];
    [cache storeLyrics:freshNone forTrack:track];
    CL_ASSERT_NIL([cache lyricsForTrack:track]);   // even a brand new negative is "expired"

    cache.negativeTTL = savedTTL;
}

static void CLTestCachePositiveEntriesNeverExpire(NSString *marker) {
    CLLyricsCache *cache = [CLLyricsCache sharedCache];
    NSTimeInterval savedTTL = cache.negativeTTL;
    cache.negativeTTL = 1;   // as aggressive as possible

    CLTrack *track = CLMakeCacheTestTrack(marker, @"PositiveNeverExpires");
    CLLyrics *plain = [CLLyrics plainWithText:@"some lyrics" source:@"unit-test"];
    plain.fetchedAt = [NSDate date].timeIntervalSince1970 - (365 * 24 * 60 * 60);   // a year old
    [cache storeLyrics:plain forTrack:track];
    CL_ASSERT_NOT_NIL([cache lyricsForTrack:track]);   // only kind == None ever expires

    cache.negativeTTL = savedTTL;
}

static void CLTestCacheWritesReadableJSONToDisk(NSString *marker) {
    CLLyricsCache *cache = [CLLyricsCache sharedCache];
    CLTrack *track = CLMakeCacheTestTrack(marker, @"DiskFormat");
    CLLyrics *synced = [CLLyrics syncedWithLines:@[
        [CLLyricLine lineWithTime:3.25 text:@"line text"],
    ] source:@"unit-test"];
    [cache storeLyrics:synced forTrack:track];

    NSString *expectedPath = CLExpectedCachePathForTrack(track);
    BOOL appeared = CLTestWaitUntil(2.0, ^BOOL{
        return [[NSFileManager defaultManager] fileExistsAtPath:expectedPath];
    });
    CL_ASSERT_TRUE(appeared);

    NSData *raw = [NSData dataWithContentsOfFile:expectedPath];
    CL_ASSERT_NOT_NIL(raw);
    id json = [NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL];
    CL_ASSERT_TRUE([json isKindOfClass:[NSDictionary class]]);
    NSDictionary *dict = json;
    CL_ASSERT_EQ(((NSNumber *)dict[@"kind"]).longValue, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(dict[@"source"], @"unit-test");
    CL_ASSERT_TRUE([dict[@"lines"] isKindOfClass:[NSArray class]]);
    CL_ASSERT_EQ(((NSArray *)dict[@"lines"]).count, (NSUInteger)1);
}

static void CLTestCacheDiskEntryCountAndClear(NSString *marker) {
    CLLyricsCache *cache = [CLLyricsCache sharedCache];
    CLTrack *track = CLMakeCacheTestTrack(marker, @"DiskCount");
    [cache storeLyrics:[CLLyrics plainWithText:@"x" source:@"unit-test"] forTrack:track];

    NSString *expectedPath = CLExpectedCachePathForTrack(track);
    CL_ASSERT_TRUE(CLTestWaitUntil(2.0, ^BOOL{
        return [[NSFileManager defaultManager] fileExistsAtPath:expectedPath];
    }));
    CL_ASSERT_TRUE([cache diskEntryCount] >= 1);

    [cache clear];
    CL_ASSERT_EQ([cache diskEntryCount], (NSUInteger)0);
    CL_ASSERT_NIL([cache lyricsForTrack:track]);
    CL_ASSERT_FALSE([[NSFileManager defaultManager] fileExistsAtPath:expectedPath]);
}

void CLRunLyricsCacheTests(void) {
    CLTestBeginSuite("CLLyricsCache");
    NSString *marker = [[NSUUID UUID] UUIDString];

    CLTestCacheStoreThenImmediateRead(marker);
    CLTestCacheNegativeEntryFreshIsKept(marker);
    CLTestCacheNegativeEntryExpiresAfterTTL(marker);
    CLTestCacheNegativeTTLZeroDisablesNegativeCaching(marker);
    CLTestCachePositiveEntriesNeverExpire(marker);
    CLTestCacheWritesReadableJSONToDisk(marker);
    // Runs last: -clear wipes every entry this process's cache directory holds, including the
    // ones the tests above just created (which is the point — see the file header comment).
    CLTestCacheDiskEntryCountAndClear(marker);
}
