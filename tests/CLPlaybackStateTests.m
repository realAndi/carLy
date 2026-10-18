// Tests for CLPlaybackState, focused on -elapsedNow's interpolation (Tweak/Core/CLPlaybackState.m)
// plus the handful of derived properties and derivation methods the sync engine and controller
// depend on.
#import "CLPlaybackStateTests.h"
#import "CLTestCase.h"
#import "Core/CLPlaybackState.h"

static CLPlaybackState *CLMakeState(NSTimeInterval elapsed, NSDate *timestamp, double rate,
                                     BOOL isPlaying, NSTimeInterval duration) {
    return [[CLPlaybackState alloc] initWithTitle:@"Title"
                                            artist:@"Artist"
                                             album:@"Album"
                                          duration:duration
                                       elapsedTime:elapsed
                                         timestamp:timestamp
                                      playbackRate:rate
                                  bundleIdentifier:@"com.spotify.client"
                                 contentIdentifier:@"spotify:track:abc#uuid-1"
                                         isPlaying:isPlaying
                                   isAdvertisement:NO
                                            origin:CLPlaybackStateOriginMediaRemote];
}

static void CLTestElapsedNowWhilePaused(void) {
    // rate == 0 and not playing -> effectiveRate 0 -> no extrapolation regardless of how old the
    // timestamp is.
    NSDate *longAgo = [NSDate dateWithTimeIntervalSinceNow:-3600];
    CLPlaybackState *paused = CLMakeState(42.0, longAgo, 0.0, NO, 0);
    CL_ASSERT_NEAR(paused.elapsedNow, 42.0, 0.0005);
}

static void CLTestElapsedNowWhilePlaying(void) {
    NSDate *fiveSecondsAgo = [NSDate dateWithTimeIntervalSinceNow:-5.0];
    CLPlaybackState *playing = CLMakeState(10.0, fiveSecondsAgo, 1.0, YES, 0);
    // Allow generous slack for scheduling jitter between building `fiveSecondsAgo` and reading
    // elapsedNow (still on the order of microseconds in practice).
    CL_ASSERT_NEAR(playing.elapsedNow, 15.0, 0.5);
}

static void CLTestElapsedNowClampsToDuration(void) {
    NSDate *tenSecondsAgo = [NSDate dateWithTimeIntervalSinceNow:-10.0];
    CLPlaybackState *nearEnd = CLMakeState(19.0, tenSecondsAgo, 1.0, YES, 20.0);
    CL_ASSERT_NEAR(nearEnd.elapsedNow, 20.0, 0.0005);   // 19 + 10 = 29, clamped to duration 20
}

static void CLTestElapsedNowFloorsAtZeroForFutureTimestamp(void) {
    // A future timestamp (clock skew) must never produce negative "age"; age is clamped to 0, so
    // elapsedNow is exactly elapsedTime regardless of the (irrelevant, since age*rate == 0) rate.
    NSDate *future = [NSDate dateWithTimeIntervalSinceNow:100.0];
    CLPlaybackState *skewed = CLMakeState(5.0, future, 1.0, YES, 0);
    CL_ASSERT_NEAR(skewed.elapsedNow, 5.0, 0.0005);
}

static void CLTestEffectiveRateFallback(void) {
    // Some clients report rate 0 while genuinely playing; effectiveRate falls back to 1.
    NSDate *twoSecondsAgo = [NSDate dateWithTimeIntervalSinceNow:-2.0];
    CLPlaybackState *zeroRateButPlaying = CLMakeState(0.0, twoSecondsAgo, 0.0, YES, 0);
    CL_ASSERT_NEAR(zeroRateButPlaying.effectiveRate, 1.0, 0.0005);
    CL_ASSERT_NEAR(zeroRateButPlaying.elapsedNow, 2.0, 0.5);

    CLPlaybackState *zeroRateNotPlaying = CLMakeState(0.0, twoSecondsAgo, 0.0, NO, 0);
    CL_ASSERT_NEAR(zeroRateNotPlaying.effectiveRate, 0.0, 0.0005);
}

static void CLTestHasTrackInfoAndEmptyState(void) {
    CL_ASSERT_FALSE(CLPlaybackState.emptyState.hasTrackInfo);
    CL_ASSERT_TRUE(CLMakeState(0, nil, 0, NO, 0).hasTrackInfo);
    CL_ASSERT_NIL(CLPlaybackState.emptyState.track);
    CL_ASSERT_NOT_NIL(CLMakeState(0, nil, 0, NO, 0).track);
}

static void CLTestContentIdentityStripsPlaySuffix(void) {
    CLPlaybackState *state = CLMakeState(0, nil, 0, NO, 0);
    CL_ASSERT_EQ(state.contentIdentity, @"spotify:track:abc");
}

static void CLTestIsSameSongAsPrefersContentIdentity(void) {
    CLPlaybackState *a = CLMakeState(0, nil, 0, NO, 0);          // spotify:track:abc#uuid-1
    CLPlaybackState *sameContentDifferentTitle =
        [[CLPlaybackState alloc] initWithTitle:@"Totally Different"
                                         artist:@"Someone Else"
                                          album:nil
                                       duration:0
                                    elapsedTime:0
                                      timestamp:nil
                                   playbackRate:0
                               bundleIdentifier:@"com.spotify.client"
                              contentIdentifier:@"spotify:track:abc#uuid-2"
                                      isPlaying:NO
                                isAdvertisement:NO
                                         origin:CLPlaybackStateOriginMediaRemote];
    CL_ASSERT_TRUE([a isSameSongAs:sameContentDifferentTitle]);   // same base identity wins

    CLPlaybackState *noContentIdentifier =
        [[CLPlaybackState alloc] initWithTitle:@"Title"
                                         artist:@"Artist"
                                          album:nil
                                       duration:0
                                    elapsedTime:0
                                      timestamp:nil
                                   playbackRate:0
                               bundleIdentifier:nil
                              contentIdentifier:nil
                                      isPlaying:NO
                                isAdvertisement:NO
                                         origin:CLPlaybackStateOriginExternal];
    CL_ASSERT_TRUE([a isSameSongAs:noContentIdentifier]);   // falls back to title/artist match
    CL_ASSERT_FALSE([CLPlaybackState.emptyState isSameSongAs:noContentIdentifier]);   // no title at all
}

static void CLTestStateByFillingGapsFrom(void) {
    CLPlaybackState *sparse =
        [CLPlaybackState stateWithTitle:@"Title" artist:@"Artist" album:nil duration:0
                        bundleIdentifier:nil contentIdentifier:nil
                                  origin:CLPlaybackStateOriginMediaRemote];
    CLPlaybackState *rich =
        [CLPlaybackState stateWithTitle:@"Title" artist:@"Artist" album:@"Album" duration:200
                        bundleIdentifier:@"com.spotify.client"
                       contentIdentifier:@"spotify:track:abc#uuid"
                                  origin:CLPlaybackStateOriginExternal];
    CLPlaybackState *filled = [sparse stateByFillingGapsFrom:rich];
    CL_ASSERT_EQ(filled.album, @"Album");
    CL_ASSERT_EQ(filled.bundleIdentifier, @"com.spotify.client");
    CL_ASSERT_EQ(filled.contentIdentifier, @"spotify:track:abc#uuid");
    CL_ASSERT_NEAR(filled.duration, 200.0, 0.0005);

    // A state that already knows everything is returned unchanged (by reference).
    CLPlaybackState *unchanged = [rich stateByFillingGapsFrom:sparse];
    CL_ASSERT_TRUE(unchanged == rich);
}

static void CLTestStateByUpdatingElapsedTime(void) {
    CLPlaybackState *original = CLMakeState(0, nil, 0, NO, 0);
    NSDate *now = [NSDate date];
    CLPlaybackState *updated = [original stateByUpdatingElapsedTime:33.0 timestamp:now
                                                        playbackRate:1.0 isPlaying:YES];
    CL_ASSERT_NEAR(updated.elapsedTime, 33.0, 0.0005);
    CL_ASSERT_TRUE(updated.isPlaying);
    CL_ASSERT_EQ(updated.title, original.title);   // metadata carried over unchanged
}

static void CLTestStateBySettingBundleIdentifier(void) {
    CLPlaybackState *original = CLMakeState(0, nil, 0, NO, 0);
    CLPlaybackState *same = [original stateBySettingBundleIdentifier:@"com.spotify.client"];
    CL_ASSERT_TRUE(same == original);   // no-op returns self

    CLPlaybackState *changed = [original stateBySettingBundleIdentifier:@"com.apple.Music"];
    CL_ASSERT_EQ(changed.bundleIdentifier, @"com.apple.Music");
    CL_ASSERT_EQ(changed.title, original.title);
}

void CLRunPlaybackStateTests(void) {
    CLTestBeginSuite("CLPlaybackState");
    CLTestElapsedNowWhilePaused();
    CLTestElapsedNowWhilePlaying();
    CLTestElapsedNowClampsToDuration();
    CLTestElapsedNowFloorsAtZeroForFutureTimestamp();
    CLTestEffectiveRateFallback();
    CLTestHasTrackInfoAndEmptyState();
    CLTestContentIdentityStripsPlaySuffix();
    CLTestIsSameSongAsPrefersContentIdentity();
    CLTestStateByFillingGapsFrom();
    CLTestStateByUpdatingElapsedTime();
    CLTestStateBySettingBundleIdentifier();
}
