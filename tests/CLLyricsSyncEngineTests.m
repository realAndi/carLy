// Tests for CLLyricsSyncEngine (Tweak/Sync/CLLyricsSyncEngine.m). Every setter here documents
// that it runs synchronously when already on the main thread (CLSyncRunOnMain), which is exactly
// where this single-threaded test binary's main() runs, so no run-loop pumping is needed and the
// timer never starts (it only runs while a *playing* state is fed in, which these tests avoid
// except where they explicitly want a single, synchronous reevaluation).
#import "CLLyricsSyncEngineTests.h"
#import "CLTestCase.h"
#import "Sync/CLLyricsSyncEngine.h"
#import "Core/CLPlaybackState.h"
#import <math.h>

static NSArray<CLLyricLine *> *CLMakeSyncLines(void) {
    // Deliberately includes a duplicate timestamp (indices 1 and 2) to pin down which one the
    // binary search in -lineIndexForElapsed: reports as current.
    return @[
        [CLLyricLine lineWithTime:1.0 text:@"one"],
        [CLLyricLine lineWithTime:2.0 text:@"two-a"],
        [CLLyricLine lineWithTime:2.0 text:@"two-b"],
        [CLLyricLine lineWithTime:5.0 text:@"five"],
    ];
}

static void CLTestLineIndexForElapsedBoundaries(void) {
    CLLyricsSyncEngine *engine = [[CLLyricsSyncEngine alloc] init];
    engine.lines = CLMakeSyncLines();

    CL_ASSERT_EQ((long)[engine lineIndexForElapsed:0.5], (long)CLLyricsNoLine);   // before first
    CL_ASSERT_EQ((long)[engine lineIndexForElapsed:1.0], (long)0);                // exact hit
    CL_ASSERT_EQ((long)[engine lineIndexForElapsed:2.0], (long)2);                // exact hit, duplicate -> last
    CL_ASSERT_EQ((long)[engine lineIndexForElapsed:3.5], (long)2);                // between
    CL_ASSERT_EQ((long)[engine lineIndexForElapsed:100.0], (long)3);              // after last
}

static void CLTestLineIndexForElapsedWithOffset(void) {
    CLLyricsSyncEngine *engine = [[CLLyricsSyncEngine alloc] init];
    engine.lines = CLMakeSyncLines();

    // Positive offset shows lines earlier: effective = elapsed + offset.
    engine.offset = 1.0;
    CL_ASSERT_EQ((long)[engine lineIndexForElapsed:0.0], (long)0);    // 0+1 == first line's time
    CL_ASSERT_EQ((long)[engine lineIndexForElapsed:0.5], (long)0);    // 0.5+1 = 1.5, still line 0

    engine.offset = -1.0;
    CL_ASSERT_EQ((long)[engine lineIndexForElapsed:2.0], (long)0);    // 2-1 = 1, only line 0 qualifies
    CL_ASSERT_EQ((long)[engine lineIndexForElapsed:3.0], (long)2);    // 3-1 = 2, duplicate -> last

    // Offset is clamped to +-30s.
    engine.offset = 1000.0;
    CL_ASSERT_NEAR(engine.offset, 30.0, 0.0005);
    engine.offset = -1000.0;
    CL_ASSERT_NEAR(engine.offset, -30.0, 0.0005);
}

static void CLTestLineIndexForElapsedEdgeCases(void) {
    CLLyricsSyncEngine *engine = [[CLLyricsSyncEngine alloc] init];

    // No lines at all -> always CLLyricsNoLine.
    CL_ASSERT_EQ((long)[engine lineIndexForElapsed:5.0], (long)CLLyricsNoLine);

    engine.lines = CLMakeSyncLines();
    CL_ASSERT_EQ((long)[engine lineIndexForElapsed:(NSTimeInterval)NAN], (long)CLLyricsNoLine);

    // Lines fed in out of order are sorted before use, stably for equal timestamps.
    CLLyricsSyncEngine *unordered = [[CLLyricsSyncEngine alloc] init];
    unordered.lines = @[
        [CLLyricLine lineWithTime:5.0 text:@"five"],
        [CLLyricLine lineWithTime:1.0 text:@"one"],
        [CLLyricLine lineWithTime:2.0 text:@"two"],
    ];
    CL_ASSERT_EQ(unordered.lines[0].text, @"one");
    CL_ASSERT_EQ(unordered.lines[1].text, @"two");
    CL_ASSERT_EQ(unordered.lines[2].text, @"five");
}

static void CLTestPlaybackTimeForLineAtIndex(void) {
    CLLyricsSyncEngine *engine = [[CLLyricsSyncEngine alloc] init];
    engine.lines = CLMakeSyncLines();

    CL_ASSERT_NEAR([engine playbackTimeForLineAtIndex:0], 1.0, 0.0005);
    CL_ASSERT_NEAR([engine playbackTimeForLineAtIndex:3], 5.0, 0.0005);
    CL_ASSERT_EQ((long)[engine playbackTimeForLineAtIndex:-1], (long)-1);
    CL_ASSERT_EQ((long)[engine playbackTimeForLineAtIndex:99], (long)-1);

    engine.offset = 1.0;   // seeking must compensate the offset so the same line comes up again
    CL_ASSERT_NEAR([engine playbackTimeForLineAtIndex:0], 0.0, 0.0005);   // 1 - 1 = 0
    engine.offset = -1.0;
    CL_ASSERT_NEAR([engine playbackTimeForLineAtIndex:0], 2.0, 0.0005);  // 1 - (-1) = 2
}

static CLPlaybackState *CLMakePausedState(NSTimeInterval elapsed, NSTimeInterval duration) {
    return [[CLPlaybackState alloc] initWithTitle:@"T" artist:@"A" album:nil duration:duration
                                       elapsedTime:elapsed timestamp:[NSDate date] playbackRate:0
                                  bundleIdentifier:nil contentIdentifier:nil isPlaying:NO
                                   isAdvertisement:NO origin:CLPlaybackStateOriginMediaRemote];
}

static void CLTestUpdateWithPlaybackStateDrivesCurrentLineAndProgress(void) {
    CLLyricsSyncEngine *engine = [[CLLyricsSyncEngine alloc] init];
    engine.lines = @[
        [CLLyricLine lineWithTime:0.0 text:@"start"],
        [CLLyricLine lineWithTime:10.0 text:@"middle"],
        [CLLyricLine lineWithTime:20.0 text:@"end"],
    ];
    CL_ASSERT_FALSE(engine.running);   // paused states never start the tick timer

    [engine updateWithPlaybackState:CLMakePausedState(5.0, 0)];
    CL_ASSERT_EQ((long)engine.currentLineIndex, (long)0);
    CL_ASSERT_NEAR(engine.progressWithinCurrentLine, 0.5, 0.0005);   // (5-0)/(10-0)
    CL_ASSERT_FALSE(engine.running);

    // Past the last line with an unknown track duration: falls back to finalLineDuration (5s).
    [engine updateWithPlaybackState:CLMakePausedState(22.0, 0)];
    CL_ASSERT_EQ((long)engine.currentLineIndex, (long)2);
    CL_ASSERT_NEAR(engine.progressWithinCurrentLine, 0.4, 0.0005);   // (22-20)/((20+5)-20)

    // -stop resets to "no line" and forgets the playback state.
    [engine stop];
    CL_ASSERT_EQ((long)engine.currentLineIndex, (long)CLLyricsNoLine);
    CL_ASSERT_NIL(engine.playbackState);
}

static void CLTestOnLineChangedFiresOnlyOnActualChange(void) {
    CLLyricsSyncEngine *engine = [[CLLyricsSyncEngine alloc] init];
    // Deliberately no line at time 0: with no playback state yet, -setLines: reevaluates at an
    // effective elapsed of 0, and a first line AT time 0 would make that assignment itself the
    // real "NoLine -> 0" transition before onLineChanged is even installed below, which would
    // make the "first callback" checks below fail for a reason that has nothing to do with what
    // this test is actually pinning down.
    engine.lines = @[
        [CLLyricLine lineWithTime:5.0 text:@"a"],
        [CLLyricLine lineWithTime:10.0 text:@"b"],
    ];
    __block NSInteger callCount = 0;
    __block NSInteger lastIndex = CLLyricsNoLine;
    engine.onLineChanged = ^(NSInteger index) {
        callCount++;
        lastIndex = index;
    };

    [engine updateWithPlaybackState:CLMakePausedState(6.0, 0)];   // -> line 0, first callback
    CL_ASSERT_EQ((long)callCount, (long)1);
    CL_ASSERT_EQ((long)lastIndex, (long)0);

    [engine updateWithPlaybackState:CLMakePausedState(7.0, 0)];   // still line 0: no callback
    CL_ASSERT_EQ((long)callCount, (long)1);

    [engine updateWithPlaybackState:CLMakePausedState(11.0, 0)];  // -> line 1
    CL_ASSERT_EQ((long)callCount, (long)2);
    CL_ASSERT_EQ((long)lastIndex, (long)1);
}

void CLRunLyricsSyncEngineTests(void) {
    CLTestBeginSuite("CLLyricsSyncEngine");
    CLTestLineIndexForElapsedBoundaries();
    CLTestLineIndexForElapsedWithOffset();
    CLTestLineIndexForElapsedEdgeCases();
    CLTestPlaybackTimeForLineAtIndex();
    CLTestUpdateWithPlaybackStateDrivesCurrentLineAndProgress();
    CLTestOnLineChangedFiresOnlyOnActualChange();
}
