// Tests for CLLyricsController (Tweak/Core/CLLyricsController.m) — the piece that decides *when*
// to look lyrics up, which app may show them, and what happens to an answer that arrives after
// the song has already changed. Until the fix wave it had no automated coverage at all: it was
// excluded from this tool because it talks to CLNowPlayingSource, and CLNowPlayingSource talks to
// MediaRemote.
//
// -startDetached (the test seam CLLyricsController.h documents) is what makes this possible: the
// controller runs its whole pipeline without subscribing to the real now-playing source, so
// nothing here depends on — or disturbs — whatever is actually playing on this phone. Playback is
// fed in with -ingestPlaybackState:.
//
// Deliberately not exercised here: -seekToLineAtIndex:, which asks the *real* CLNowPlayingSource
// to seek and would move the user's own playback.
#import "CLLyricsControllerTests.h"
#import "CLTestCase.h"
#import "Core/CLLyricsController.h"
#import "Core/CLPlaybackState.h"
#import "Lyrics/CLLyricsCache.h"
#import "Lyrics/CLLyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Doubles

/// A provider that answers with plain lyrics whose text is the track title (so an assertion can
/// tell *which* request an answer belongs to), optionally after a delay.
@interface CLFakeControllerProvider : NSObject <CLLyricsProvider>
@property (nonatomic, readonly) NSString *identifier;
@property (nonatomic) NSTimeInterval delay;
@property (nonatomic) NSUInteger callCount;
@property (nonatomic, copy, nullable) NSString *lastRequestedTitle;
@end

@implementation CLFakeControllerProvider

- (NSString *)identifier { return @"fake"; }

- (void)fetchLyricsForTrack:(CLTrack *)track completion:(CLLyricsCompletion)completion {
    self.callCount++;
    self.lastRequestedTitle = track.title;
    CLLyrics *lyrics = [CLLyrics plainWithText:track.title source:self.identifier];
    if (self.delay > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.delay * NSEC_PER_SEC)),
                        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            completion(lyrics, nil);
        });
    } else {
        completion(lyrics, nil);
    }
}

@end

#pragma mark - Helpers

static NSUInteger sTitleCounter = 0;

/// A unique title per call: the controller writes every answer into CLLyricsCache, so reusing a
/// title across tests would let one test's stored result satisfy the next one's lookup.
static NSString *UniqueTitle(NSString *prefix) {
    return [NSString stringWithFormat:@"%@ %lu", prefix, (unsigned long)(++sTitleCounter)];
}

static CLPlaybackState *PlayingState(NSString *title, NSString *_Nullable bundleIdentifier,
                                      BOOL playing) {
    return [[CLPlaybackState alloc] initWithTitle:title
                                           artist:@"Test Artist"
                                            album:@"Test Album"
                                         duration:180.0
                                      elapsedTime:10.0
                                        timestamp:[NSDate date]
                                     playbackRate:playing ? 1.0 : 0.0
                                 bundleIdentifier:bundleIdentifier
                                contentIdentifier:nil
                                        isPlaying:playing
                                  isAdvertisement:NO
                                           origin:CLPlaybackStateOriginMediaRemote];
}

/// Fresh controller state for one test: stopped, reconfigured, started detached.
static CLFakeControllerProvider *ResetController(NSSet<NSString *> *_Nullable enabledApps,
                                                  NSTimeInterval providerDelay) {
    CLLyricsController *controller = CLLyricsController.sharedController;
    [controller stop];
    CLFakeControllerProvider *provider = [[CLFakeControllerProvider alloc] init];
    provider.delay = providerDelay;
    controller.providers = @[ provider ];
    controller.enabledBundleIdentifiers = enabledApps;
    [controller startDetached];
    CLTestWaitUntil(0.5, ^BOOL { return controller.isStarted; });
    return provider;
}

static BOOL WaitForStatus(CLLyricsControllerStatus status, NSTimeInterval timeout) {
    CLLyricsController *controller = CLLyricsController.sharedController;
    return CLTestWaitUntil(timeout, ^BOOL { return controller.status == status; });
}

#pragma mark - Tests

/// The happy path, and the thing every other test leans on: a playing track from an enabled app
/// resolves through the chain and is published.
static void TestResolvesForEnabledApp(void) {
    CLFakeControllerProvider *provider = ResetController([NSSet setWithObject:@"com.spotify.client"], 0);
    CLLyricsController *controller = CLLyricsController.sharedController;
    NSString *title = UniqueTitle(@"Enabled");

    [controller ingestPlaybackState:PlayingState(title, @"com.spotify.client", YES)];
    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusLoaded, 2.0));
    CL_ASSERT_EQ(controller.currentLyrics.plainText, title);
    CL_ASSERT_EQ(controller.currentLyrics.source, @"fake");
    CL_ASSERT_EQ(provider.callCount, (unsigned long)1);
}

/// enabledApps gating: another app's playback is refused outright, and it never reaches a provider.
static void TestDisabledAppIsNotResolved(void) {
    CLFakeControllerProvider *provider = ResetController([NSSet setWithObject:@"com.spotify.client"], 0);
    CLLyricsController *controller = CLLyricsController.sharedController;

    [controller ingestPlaybackState:PlayingState(UniqueTitle(@"Other"), @"com.apple.Music", YES)];
    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusDisabled, 2.0));
    CL_ASSERT_NIL(controller.currentLyrics);
    CL_ASSERT_EQ(provider.callCount, (unsigned long)0);
    CL_ASSERT_EQ(controller.currentLineIndex, (long)CLLyricsNoLine);

    // An unknown app (no bundle identifier at all) while a filter is set is refused too.
    [controller ingestPlaybackState:PlayingState(UniqueTitle(@"Unknown"), nil, YES)];
    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusDisabled, 2.0));
    CL_ASSERT_EQ(provider.callCount, (unsigned long)0);
}

/// "All apps" (a nil filter) and "no apps" (an empty set) are the two ends of the same switch.
static void TestAllAppsAndEmptySet(void) {
    ResetController(nil, 0);
    CLLyricsController *controller = CLLyricsController.sharedController;
    [controller ingestPlaybackState:PlayingState(UniqueTitle(@"AnyApp"), @"com.example.player", YES)];
    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusLoaded, 2.0));

    ResetController([NSSet set], 0);
    [controller ingestPlaybackState:PlayingState(UniqueTitle(@"NoApp"), @"com.spotify.client", YES)];
    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusDisabled, 2.0));
}

/// Turning an app off in Settings has to take effect at once, not at the next track change.
static void TestDisablingAnAppTearsDownImmediately(void) {
    ResetController([NSSet setWithObject:@"com.spotify.client"], 0);
    CLLyricsController *controller = CLLyricsController.sharedController;
    [controller ingestPlaybackState:PlayingState(UniqueTitle(@"StillPlaying"), @"com.spotify.client", YES)];
    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusLoaded, 2.0));

    controller.enabledBundleIdentifiers = [NSSet setWithObject:@"com.apple.Music"];
    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusDisabled, 2.0));
    CL_ASSERT_NIL(controller.currentLyrics);

    // ...and switching it back on picks the same track up again without one.
    controller.enabledBundleIdentifiers = [NSSet setWithObject:@"com.spotify.client"];
    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusLoaded, 2.0));
    CL_ASSERT_NOT_NIL(controller.currentLyrics);
}

/// The classic bug this guards: skip tracks fast and the *first* song's lyrics arrive last and
/// flash up over the second one. _resolveGeneration is what prevents it.
static void TestStaleCompletionIsDropped(void) {
    CLFakeControllerProvider *provider = ResetController([NSSet setWithObject:@"com.spotify.client"], 0.35);
    CLLyricsController *controller = CLLyricsController.sharedController;
    NSString *first = UniqueTitle(@"First");
    NSString *second = UniqueTitle(@"Second");

    [controller ingestPlaybackState:PlayingState(first, @"com.spotify.client", YES)];
    CL_ASSERT_EQ((long)controller.status, (long)CLLyricsControllerStatusLoading);
    // Wait until the chain has actually asked (the cache is consulted on its own queue first),
    // then skip, well before the fake provider's delay is up.
    CL_ASSERT_TRUE(CLTestWaitUntil(2.0, ^BOOL { return provider.callCount == 1; }));
    [controller ingestPlaybackState:PlayingState(second, @"com.spotify.client", YES)];
    CL_ASSERT_TRUE(CLTestWaitUntil(2.0, ^BOOL { return provider.callCount == 2; }));

    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusLoaded, 3.0));
    CL_ASSERT_EQ(controller.currentLyrics.plainText, second);

    // Keep pumping past the first request's delay: its completion must be dropped, not published.
    CLTestWaitUntil(0.6, ^BOOL { return NO; });
    CL_ASSERT_EQ(controller.currentLyrics.plainText, second);
    CL_ASSERT_EQ((long)controller.status, (long)CLLyricsControllerStatusLoaded);
}

/// Pausing is not a track change: the lyrics and the line stay exactly where they were.
static void TestPauseKeepsLyrics(void) {
    CLFakeControllerProvider *provider = ResetController([NSSet setWithObject:@"com.spotify.client"], 0);
    CLLyricsController *controller = CLLyricsController.sharedController;
    NSString *title = UniqueTitle(@"Paused");

    [controller ingestPlaybackState:PlayingState(title, @"com.spotify.client", YES)];
    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusLoaded, 2.0));
    NSUInteger callsAfterFirstResolve = provider.callCount;

    [controller ingestPlaybackState:PlayingState(title, @"com.spotify.client", NO)];   // rate 0
    CLTestWaitUntil(0.3, ^BOOL { return NO; });
    CL_ASSERT_EQ((long)controller.status, (long)CLLyricsControllerStatusLoaded);
    CL_ASSERT_EQ(controller.currentLyrics.plainText, title);
    CL_ASSERT_FALSE(controller.currentState.isPlaying);
    // Same song, so no second lookup: a pause must not re-run the provider chain.
    CL_ASSERT_EQ(provider.callCount, (unsigned long)callsAfterFirstResolve);

    // Resuming the same song does not re-resolve either.
    [controller ingestPlaybackState:PlayingState(title, @"com.spotify.client", YES)];
    CLTestWaitUntil(0.3, ^BOOL { return NO; });
    CL_ASSERT_EQ(provider.callCount, (unsigned long)callsAfterFirstResolve);
    CL_ASSERT_EQ(controller.currentLyrics.plainText, title);
}

/// Nothing playing, and an advertisement, are both "idle": no lookup, no stale lyrics left on screen.
static void TestIdleAndAdvertisement(void) {
    CLFakeControllerProvider *provider = ResetController([NSSet setWithObject:@"com.spotify.client"], 0);
    CLLyricsController *controller = CLLyricsController.sharedController;
    [controller ingestPlaybackState:PlayingState(UniqueTitle(@"BeforeAd"), @"com.spotify.client", YES)];
    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusLoaded, 2.0));
    NSUInteger callsBefore = provider.callCount;

    CLPlaybackState *advertisement =
        [[CLPlaybackState alloc] initWithTitle:@"Advertisement"
                                        artist:@"Spotify"
                                         album:nil
                                      duration:30.0
                                   elapsedTime:1.0
                                     timestamp:[NSDate date]
                                  playbackRate:1.0
                              bundleIdentifier:@"com.spotify.client"
                             contentIdentifier:nil
                                     isPlaying:YES
                               isAdvertisement:YES
                                        origin:CLPlaybackStateOriginMediaRemote];
    [controller ingestPlaybackState:advertisement];
    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusIdle, 2.0));
    CL_ASSERT_NIL(controller.currentLyrics);
    CL_ASSERT_EQ(provider.callCount, (unsigned long)callsBefore);

    [controller ingestPlaybackState:[CLPlaybackState emptyState]];
    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusIdle, 2.0));
    CL_ASSERT_EQ(provider.callCount, (unsigned long)callsBefore);
}

/// A controller that was never started ignores playback entirely (the tweak's "enabled = NO").
static void TestStoppedControllerIgnoresPlayback(void) {
    CLFakeControllerProvider *provider = ResetController([NSSet setWithObject:@"com.spotify.client"], 0);
    CLLyricsController *controller = CLLyricsController.sharedController;
    [controller stop];
    CLTestWaitUntil(0.3, ^BOOL { return !controller.isStarted; });
    CL_ASSERT_FALSE(controller.isStarted);

    [controller ingestPlaybackState:PlayingState(UniqueTitle(@"Stopped"), @"com.spotify.client", YES)];
    CLTestWaitUntil(0.3, ^BOOL { return NO; });
    CL_ASSERT_EQ(provider.callCount, (unsigned long)0);
    CL_ASSERT_NIL(controller.currentLyrics);
}

/// Synced lyrics drive the sync engine; the controller republishes its line index.
static void TestSyncedLyricsDriveTheLineIndex(void) {
    ResetController([NSSet setWithObject:@"com.spotify.client"], 0);
    CLLyricsController *controller = CLLyricsController.sharedController;

    // A provider that answers with real timed lines for this one test.
    NSArray<CLLyricLine *> *lines = @[
        [CLLyricLine lineWithTime:0.0 text:@"one"],
        [CLLyricLine lineWithTime:5.0 text:@"two"],
        [CLLyricLine lineWithTime:9.0 text:@"three"],
    ];
    CLLyrics *synced = [CLLyrics syncedWithLines:lines source:@"fake"];
    CLTrack *track = [[CLTrack alloc] init];
    track.title = UniqueTitle(@"Synced");
    track.artist = @"Test Artist";
    track.duration = 180.0;
    [CLLyricsCache.sharedCache storeLyrics:synced forTrack:track];

    // elapsedTime 10 s: the third line (t = 9) is the current one.
    CLPlaybackState *state = [[CLPlaybackState alloc] initWithTitle:track.title
                                                             artist:track.artist
                                                              album:nil
                                                           duration:180.0
                                                        elapsedTime:10.0
                                                          timestamp:[NSDate date]
                                                       playbackRate:1.0
                                                   bundleIdentifier:@"com.spotify.client"
                                                  contentIdentifier:nil
                                                          isPlaying:YES
                                                    isAdvertisement:NO
                                                             origin:CLPlaybackStateOriginMediaRemote];
    [controller ingestPlaybackState:state];
    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusLoaded, 2.0));
    CL_ASSERT_TRUE(controller.hasSyncedLyrics);
    CL_ASSERT_TRUE(CLTestWaitUntil(1.0, ^BOOL { return controller.currentLineIndex == 2; }));
    CL_ASSERT_EQ([controller lineAtIndex:2].text, @"three");
    CL_ASSERT_NIL([controller lineAtIndex:99]);
}

/// The active-display count decides whether the sync engine ticks at 10 Hz or at 1 Hz, and the
/// only thing keeping it honest is that every caller is balanced. Assert the arithmetic itself:
/// an unbalanced -displayDidResignActive must not drive it negative, because a negative count
/// would swallow the next -displayDidBecomeActive and leave the tick slow for the whole drive.
static void TestDisplayGatingCount(void) {
    CLLyricsController *controller = CLLyricsController.sharedController;
    NSInteger before = controller.activeDisplayCount;
    CL_ASSERT_EQ((long)before, (long)0);

    [controller displayDidBecomeActive];
    CL_ASSERT_EQ((long)controller.activeDisplayCount, (long)1);
    [controller displayDidBecomeActive];
    CL_ASSERT_EQ((long)controller.activeDisplayCount, (long)2);   // two overlapping customizers
    [controller displayDidResignActive];
    CL_ASSERT_EQ((long)controller.activeDisplayCount, (long)1);
    [controller displayDidResignActive];
    CL_ASSERT_EQ((long)controller.activeDisplayCount, (long)0);

    // Extra resigns are clamped, not counted.
    [controller displayDidResignActive];
    [controller displayDidResignActive];
    CL_ASSERT_EQ((long)controller.activeDisplayCount, (long)0);
    [controller displayDidBecomeActive];
    CL_ASSERT_EQ((long)controller.activeDisplayCount, (long)1);
    [controller displayDidResignActive];
    CL_ASSERT_EQ((long)controller.activeDisplayCount, (long)0);
}

/// A Spotify state for one content identifier, the shape MediaRemote delivers on a track change.
static CLPlaybackState *SpotifyStateWithDuration(NSString *title, NSString *artist, NSString *contentIdentifier,
                                                 NSTimeInterval duration) {
    return [[CLPlaybackState alloc] initWithTitle:title
                                           artist:artist
                                            album:@"Test Album"
                                         duration:duration
                                      elapsedTime:0.1
                                        timestamp:[NSDate date]
                                     playbackRate:1.0
                                 bundleIdentifier:@"com.spotify.client"
                                contentIdentifier:contentIdentifier
                                        isPlaying:YES
                                  isAdvertisement:NO
                                           origin:CLPlaybackStateOriginMediaRemote];
}

static CLPlaybackState *SpotifyState(NSString *title, NSString *artist, NSString *contentIdentifier) {
    return SpotifyStateWithDuration(title, artist, contentIdentifier, 160.0);
}

/// Seen on a real CarPlay session: on a track change Spotify published the new content identifier
/// with the *previous* song's title and artist, then the real ones a moment later under the same
/// identifier. The lookup has to wait for the burst to settle and use the final metadata, once.
static void TestTrackChangeBurstSettlesBeforeLookup(void) {
    CLFakeControllerProvider *provider = ResetController([NSSet setWithObject:@"com.spotify.client"], 0);
    CLLyricsController *controller = CLLyricsController.sharedController;
    NSString *stale = UniqueTitle(@"PreviousSong");
    NSString *real = UniqueTitle(@"RealSong");

    [controller ingestPlaybackState:SpotifyState(stale, @"Old Artist", @"spotify:track:burst#1")];
    CL_ASSERT_EQ((long)controller.status, (long)CLLyricsControllerStatusLoading);
    [controller ingestPlaybackState:SpotifyState(real, @"New Artist", @"spotify:track:burst#1")];

    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusLoaded, 2.0));
    CL_ASSERT_EQ(controller.currentLyrics.plainText, real);
    CL_ASSERT_EQ(provider.callCount, (unsigned long)1);
    CL_ASSERT_EQ(provider.lastRequestedTitle, real);
}

/// The same thing when the real title lands after the settle window: the lookup that already ran
/// on stale metadata is redone for the corrected title instead of being kept as "the same song".
static void TestLateMetadataUnderSameIdentifierIsLookedUpAgain(void) {
    CLFakeControllerProvider *provider = ResetController([NSSet setWithObject:@"com.spotify.client"], 0);
    CLLyricsController *controller = CLLyricsController.sharedController;
    NSString *stale = UniqueTitle(@"PreviousSong");
    NSString *real = UniqueTitle(@"RealSong");

    [controller ingestPlaybackState:SpotifyState(stale, @"Old Artist", @"spotify:track:late#1")];
    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusLoaded, 2.0));
    CL_ASSERT_EQ(provider.lastRequestedTitle, stale);

    [controller ingestPlaybackState:SpotifyState(real, @"New Artist", @"spotify:track:late#1")];
    CL_ASSERT_TRUE(CLTestWaitUntil(2.0, ^BOOL { return provider.callCount == 2; }));
    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusLoaded, 2.0));
    CL_ASSERT_EQ(controller.currentLyrics.plainText, real);

    // Plain progress updates for the corrected song must not look it up a third time.
    [controller ingestPlaybackState:SpotifyState(real, @"New Artist", @"spotify:track:late#1")];
    CLTestWaitUntil(0.5, ^BOOL { return NO; });
    CL_ASSERT_EQ(provider.callCount, (unsigned long)2);
}

/// Seen on every skip in a CarPlay simulator session: the next track's identifier and duration
/// arrive with the previous song's title and artist, and the real ones about a second later —
/// past the 300 ms settle. Nothing may be looked up for the stale title; the real one is looked up
/// as soon as it lands.
static void TestStaleTitleWaitsForTheRealOne(void) {
    CLFakeControllerProvider *provider = ResetController([NSSet setWithObject:@"com.spotify.client"], 0);
    CLLyricsController *controller = CLLyricsController.sharedController;
    NSString *first = UniqueTitle(@"FirstSong");
    NSString *second = UniqueTitle(@"SecondSong");

    [controller ingestPlaybackState:SpotifyState(first, @"First Artist", @"spotify:track:stale1#a")];
    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusLoaded, 2.0));
    CL_ASSERT_EQ(provider.callCount, (unsigned long)1);

    // Skip: new identifier and duration, old title and artist.
    [controller ingestPlaybackState:SpotifyStateWithDuration(first, @"First Artist", @"spotify:track:stale2#b", 201.0)];
    CL_ASSERT_EQ((long)controller.status, (long)CLLyricsControllerStatusLoading);
    CLTestWaitUntil(0.8, ^BOOL { return NO; });
    CL_ASSERT_EQ(provider.callCount, (unsigned long)1);          // still waiting, nothing wasted

    [controller ingestPlaybackState:SpotifyStateWithDuration(second, @"Second Artist", @"spotify:track:stale2#b", 201.0)];
    CL_ASSERT_TRUE(CLTestWaitUntil(0.6, ^BOOL { return provider.callCount == 2; }));
    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusLoaded, 2.0));
    CL_ASSERT_EQ(provider.lastRequestedTitle, second);
    CL_ASSERT_EQ(controller.currentLyrics.plainText, second);
}

/// A new track that really does share its predecessor's title (another version, a repeat) is not
/// stuck waiting: it is looked up once the stale-metadata wait runs out.
static void TestRepeatedTitleIsLookedUpAfterTheWait(void) {
    CLFakeControllerProvider *provider = ResetController([NSSet setWithObject:@"com.spotify.client"], 0);
    CLLyricsController *controller = CLLyricsController.sharedController;
    NSString *title = UniqueTitle(@"SameTitle");

    [controller ingestPlaybackState:SpotifyState(title, @"Same Artist", @"spotify:track:repeat1#a")];
    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusLoaded, 2.0));
    CL_ASSERT_EQ(provider.callCount, (unsigned long)1);

    // Another version: new identifier and length (so the cache cannot answer), same title and artist.
    [controller ingestPlaybackState:SpotifyStateWithDuration(title, @"Same Artist", @"spotify:track:repeat2#b", 245.0)];
    CLTestWaitUntil(0.8, ^BOOL { return NO; });
    CL_ASSERT_EQ(provider.callCount, (unsigned long)1);
    CL_ASSERT_TRUE(CLTestWaitUntil(2.0, ^BOOL { return provider.callCount == 2; }));
    CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusLoaded, 2.0));
    CL_ASSERT_EQ(controller.currentLyrics.plainText, title);
}

/// Answers synced lines at 5 s, 10.5 s and 30 s under whatever source it is told to report.
@interface CLFakeSourcedProvider : NSObject <CLLyricsProvider>
@property (nonatomic, copy) NSString *source;
@end

@implementation CLFakeSourcedProvider

- (NSString *)identifier { return self.source; }

- (void)fetchLyricsForTrack:(CLTrack *)track completion:(CLLyricsCompletion)completion {
    completion([CLLyrics syncedWithLines:@[ [CLLyricLine lineWithTime:5.0 text:@"a"],
                                            [CLLyricLine lineWithTime:10.5 text:@"b"],
                                            [CLLyricLine lineWithTime:30.0 text:@"c"] ]
                                  source:self.source], nil);
}

@end

/// 0.9.0: lyrics timed by the playing app's own service follow serviceOffset, everything else
/// follows offset — an offset tuned for LRCLIB must not delay Spotify's own lyrics.
static void TestServiceTimedLyricsUseTheirOwnOffset(void) {
    CL_ASSERT_TRUE([CLLyricsController isServiceTimedSource:@"spotify"]);
    CL_ASSERT_TRUE([CLLyricsController isServiceTimedSource:@"spotify-cache"]);
    CL_ASSERT_TRUE([CLLyricsController isServiceTimedSource:@"apple-music"]);
    CL_ASSERT_FALSE([CLLyricsController isServiceTimedSource:@"lrclib"]);
    CL_ASSERT_FALSE([CLLyricsController isServiceTimedSource:nil]);

    CLLyricsController *controller = CLLyricsController.sharedController;
    for (NSString *source in @[ @"lrclib", @"spotify" ]) {
        [controller stop];
        CLFakeSourcedProvider *provider = [[CLFakeSourcedProvider alloc] init];
        provider.source = source;
        controller.providers = @[ provider ];
        controller.enabledBundleIdentifiers = nil;
        controller.offset = 1.0;          // +1 s: at 10 s paused, line "b" (10.5 s) is current
        controller.serviceOffset = 0.0;   // none: at 10 s, line "a" (5 s) is current
        [controller startDetached];
        CLTestWaitUntil(0.5, ^BOOL { return controller.isStarted; });

        // Paused at 10 s, so the clock does not move while the test waits.
        [controller ingestPlaybackState:PlayingState(UniqueTitle(@"Offset"), @"com.spotify.client", NO)];
        CL_ASSERT_TRUE(WaitForStatus(CLLyricsControllerStatusLoaded, 2.0));
        BOOL service = [source isEqualToString:@"spotify"];
        CL_ASSERT_TRUE(CLTestWaitUntil(1.0, ^BOOL { return controller.currentLineIndex == (service ? 0 : 1); }));
        CL_ASSERT_EQ(controller.currentLineIndex, service ? 0L : 1L);

        // Changing the other offset leaves the line alone; changing its own moves it at once.
        if (service) {
            controller.offset = 0.0;
            CLTestWaitUntil(0.2, ^BOOL { return NO; });
            CL_ASSERT_EQ(controller.currentLineIndex, 0L);
            controller.serviceOffset = 1.0;
            CL_ASSERT_TRUE(CLTestWaitUntil(1.0, ^BOOL { return controller.currentLineIndex == 1; }));
        }
    }
    controller.offset = 0.0;
    controller.serviceOffset = 0.0;
}

void CLRunLyricsControllerTests(void) {
    CLTestBeginSuite("CLLyricsController");
    TestResolvesForEnabledApp();
    TestDisabledAppIsNotResolved();
    TestAllAppsAndEmptySet();
    TestDisablingAnAppTearsDownImmediately();
    TestStaleCompletionIsDropped();
    TestTrackChangeBurstSettlesBeforeLookup();
    TestLateMetadataUnderSameIdentifierIsLookedUpAgain();
    TestStaleTitleWaitsForTheRealOne();
    TestRepeatedTitleIsLookedUpAfterTheWait();
    TestPauseKeepsLyrics();
    TestIdleAndAdvertisement();
    TestStoppedControllerIgnoresPlayback();
    TestSyncedLyricsDriveTheLineIndex();
    TestDisplayGatingCount();
    TestServiceTimedLyricsUseTheirOwnOffset();
    // Leave the shared controller stopped: its sync engine schedules a 10 Hz main-queue timer
    // while "playing", and later suites pump the run loop.
    [CLLyricsController.sharedController stop];
    CLTestWaitUntil(0.2, ^BOOL { return NO; });
}

NS_ASSUME_NONNULL_END
