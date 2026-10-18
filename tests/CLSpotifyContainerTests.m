// Tests for CLSpotifyContainer (Tweak/Util/CLSpotifyContainer.m). Locating Spotify's real
// container is inherently environment-dependent (Phase 0 in PLAN.md — whether the host sandbox
// even permits the walk), so this suite only pins down the one pure, deterministic entry point
// (+isPathReadable:) and the "resolved once, remembered" contract of the path accessors, without
// asserting whether Spotify's container happens to be readable from *this* process (a bare CLI
// tool is not CarPlayTemplateUIHost, so that answer would not mean anything here anyway).
#import "CLSpotifyContainerTests.h"
#import "CLTestCase.h"
#import "Util/CLSpotifyContainer.h"

static void CLTestIsPathReadable(void) {
    CL_ASSERT_FALSE([CLSpotifyContainer isPathReadable:nil]);
    CL_ASSERT_FALSE([CLSpotifyContainer isPathReadable:@""]);
    CL_ASSERT_FALSE([CLSpotifyContainer isPathReadable:@"/this/path/almost-certainly/does-not-exist-42"]);

    NSString *tempFile = [NSTemporaryDirectory() stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"cltests-%@.txt", [NSUUID UUID].UUIDString]];
    NSError *error = nil;
    BOOL wrote = [@"probe" writeToFile:tempFile atomically:YES encoding:NSUTF8StringEncoding error:&error];
    CL_ASSERT_TRUE(wrote);
    if (wrote) {
        CL_ASSERT_TRUE([CLSpotifyContainer isPathReadable:tempFile]);
        [[NSFileManager defaultManager] removeItemAtPath:tempFile error:NULL];
        CL_ASSERT_FALSE([CLSpotifyContainer isPathReadable:tempFile]);   // gone now
    }
}

static void CLTestPathAccessorsAreStableAcrossCalls(void) {
    // "Resolved at most once per process (success *and* failure are remembered)": whatever the
    // first call returns, a second call must return the same thing (same nil-ness, and if
    // non-nil, the identical string) — this is what makes it safe to call from a hot path.
    NSString *first = [CLSpotifyContainer dataContainerPath];
    NSString *second = [CLSpotifyContainer dataContainerPath];
    CL_ASSERT_EQ((first == nil), (second == nil));
    if (first) CL_ASSERT_EQ(first, second);

    NSString *cacheFirst = [CLSpotifyContainer cacheDatabasePath];
    NSString *cacheSecond = [CLSpotifyContainer cacheDatabasePath];
    CL_ASSERT_EQ((cacheFirst == nil), (cacheSecond == nil));

    NSString *fsFirst = [CLSpotifyContainer fsCachedDataDirectory];
    NSString *fsSecond = [CLSpotifyContainer fsCachedDataDirectory];
    CL_ASSERT_EQ((fsFirst == nil), (fsSecond == nil));

    NSString *offlineFirst = [CLSpotifyContainer offlineLyricsDatabasePath];
    NSString *offlineSecond = [CLSpotifyContainer offlineLyricsDatabasePath];
    CL_ASSERT_EQ((offlineFirst == nil), (offlineSecond == nil));

    // Every derived path lives under the container path, when there is one at all.
    if (first && cacheFirst) CL_ASSERT_TRUE([cacheFirst hasPrefix:first]);
    if (first && fsFirst) CL_ASSERT_TRUE([fsFirst hasPrefix:first]);
    if (first && offlineFirst) CL_ASSERT_TRUE([offlineFirst hasPrefix:first]);

    printf("  (info) Spotify container from this process: %s\n", first ? "found" : "not found (expected outside the host process)");
}

void CLRunSpotifyContainerTests(void) {
    CLTestBeginSuite("CLSpotifyContainer");
    CLTestIsPathReadable();
    CLTestPathAccessorsAreStableAcrossCalls();
}
