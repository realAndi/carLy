// Tests for the Apple Music side of 0.8.0: CLMusicItemInfo, CLMusicItemRegistry, and the two
// providers that read it (CLAppleMusicProvider, CLEmbeddedLyricsProvider), each driven through
// its test seam — a private registry, a scripted TTML fetch, a fake library and a fake file
// reader — so nothing here needs the Music app, MediaPlayer, a network or a car.
#import "CLMusicSourcesTests.h"
#import "CLTestCase.h"
#import "Core/CLMusicItemInfo.h"
#import "Core/CLMusicItemRegistry.h"
#import "Lyrics/CLAppleMusicProvider.h"
#import "Lyrics/CLEmbeddedLyricsProvider.h"

static NSString *const kMusic = @"com.apple.Music";

static CLTrack *MakeTrack(NSString *title, NSString *artist, NSTimeInterval duration, NSString *bundle) {
    CLTrack *track = [[CLTrack alloc] init];
    track.title = title;
    track.artist = artist;
    track.duration = duration;
    track.bundleIdentifier = bundle;
    return track;
}

static CLMusicItemInfo *MakeInfo(NSString *title, long long store, long long subscription, long long lyricsID,
                                 CLMusicLyricsAvailability availability, unsigned long long pid) {
    return [[CLMusicItemInfo alloc] initWithTitle:title
                                           artist:@"Artist"
                                         duration:200
                                  storeIdentifier:store
                           subscriptionIdentifier:subscription
                                 lyricsIdentifier:lyricsID
                               lyricsAvailability:availability
                              libraryPersistentID:pid];
}

/// Calls a provider and waits for its single answer.
static BOOL Fetch(id<CLLyricsProvider> provider, CLTrack *track, CLLyrics *__autoreleasing *outLyrics,
                  NSError *__autoreleasing *outError, NSUInteger *outCalls) {
    __block NSUInteger calls = 0;
    __block CLLyrics *result = nil;
    __block NSError *resultError = nil;
    [provider fetchLyricsForTrack:track completion:^(CLLyrics *lyrics, NSError *error) {
        result = lyrics;
        resultError = error;
        calls++;
    }];
    BOOL answered = CLTestWaitUntil(3.0, ^BOOL{ return calls > 0; });
    CLTestWaitUntil(0.05, ^BOOL{ return NO; });   // a second, wrong call would land here
    if (outLyrics) *outLyrics = result;
    if (outError) *outError = resultError;
    if (outCalls) *outCalls = calls;
    return answered;
}

#pragma mark - CLMusicItemInfo

static void TestItemInfo(void) {
    CLMusicItemInfo *info = MakeInfo(@"  Song ", 111, 222, 333, CLMusicLyricsAvailabilityAvailable, 0xFEDCBA9876543210ULL);
    CL_ASSERT_EQ(info.title, @"Song");
    CL_ASSERT_EQ(info.preferredLyricsIdentifier, 333LL);   // lyricsAdamID first, like MPStoreLyricsRequest
    CL_ASSERT_EQ(MakeInfo(@"S", 111, 222, 0, 0, 0).preferredLyricsIdentifier, 222LL);
    CL_ASSERT_EQ(MakeInfo(@"S", 111, 0, 0, 0, 0).preferredLyricsIdentifier, 111LL);
    CL_ASSERT_EQ(MakeInfo(@"S", 0, 0, 0, 0, 0).preferredLyricsIdentifier, 0LL);
    CL_ASSERT_EQ(MakeInfo(@"S", -5, -6, -7, 0, 0).preferredLyricsIdentifier, 0LL);

    // A real library pid survives; legacyUniqueIdentifier's store-id fallback does not.
    CL_ASSERT_EQ(info.libraryPersistentID, 0xFEDCBA9876543210ULL);
    CL_ASSERT_EQ(MakeInfo(@"S", 111, 222, 0, 0, 222).libraryPersistentID, 0ULL);
    CL_ASSERT_EQ(MakeInfo(@"S", 111, 222, 0, 0, 111).libraryPersistentID, 0ULL);

    CL_ASSERT_TRUE([info describesTrack:MakeTrack(@"song", @"ARTIST", 201.5, kMusic)]);
    CL_ASSERT_TRUE([info describesTrack:MakeTrack(@"Song", @"Artist", 0, kMusic)]);   // duration unknown
    CL_ASSERT_FALSE([info describesTrack:MakeTrack(@"Song", @"Artist", 205, kMusic)]);
    CL_ASSERT_FALSE([info describesTrack:MakeTrack(@"Other", @"Artist", 200, kMusic)]);
    CL_ASSERT_FALSE([info describesTrack:MakeTrack(@"Song", @"Someone", 200, kMusic)]);
    CL_ASSERT_FALSE([info describesTrack:nil]);
    CL_ASSERT_FALSE([MakeInfo(nil, 1, 1, 1, 0, 0) describesTrack:MakeTrack(@"", @"Artist", 200, kMusic)]);

    CL_ASSERT_TRUE([info isEquivalentToInfo:MakeInfo(@"Song", 111, 222, 333, CLMusicLyricsAvailabilityAvailable,
                                                     0xFEDCBA9876543210ULL)]);
    CL_ASSERT_FALSE([info isEquivalentToInfo:MakeInfo(@"Song", 111, 222, 333, CLMusicLyricsAvailabilityNone,
                                                      0xFEDCBA9876543210ULL)]);
}

#pragma mark - CLMusicItemRegistry

static void TestRegistry(void) {
    CLMusicItemRegistry *registry = [[CLMusicItemRegistry alloc] init];
    CLTrack *track = MakeTrack(@"Song", @"Artist", 200, kMusic);
    CL_ASSERT_NIL([registry infoForTrack:track]);

    CL_ASSERT_TRUE([registry recordInfo:MakeInfo(@"Song", 1, 0, 0, 0, 0)]);
    CL_ASSERT_FALSE([registry recordInfo:MakeInfo(@"Song", 1, 0, 0, 0, 0)]);   // nothing changed
    CL_ASSERT_TRUE([registry recordInfo:MakeInfo(@"Song", 1, 0, 9, CLMusicLyricsAvailabilityAvailable, 0)]);
    CL_ASSERT_EQ([registry infoForTrack:track].lyricsIdentifier, 9LL);          // replaced, not duplicated
    CL_ASSERT_FALSE([registry recordInfo:MakeInfo(nil, 1, 0, 0, 0, 0)]);        // untitled items are ignored

    for (int i = 0; i < 12; i++) {
        [registry recordInfo:MakeInfo([NSString stringWithFormat:@"Filler %d", i], i + 10, 0, 0, 0, 0)];
    }
    CL_ASSERT_NIL([registry infoForTrack:track]);                              // only the newest eight
    CL_ASSERT_NOT_NIL([registry infoForTrack:MakeTrack(@"Filler 11", @"Artist", 200, kMusic)]);

    // Not live: no waiting, the answer is immediate.
    dispatch_queue_t queue = dispatch_queue_create("registry-test", DISPATCH_QUEUE_SERIAL);
    __block BOOL answered = NO;
    __block CLMusicItemInfo *found = (CLMusicItemInfo *)@"sentinel";
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    [registry infoForTrack:track waitingUpTo:2.0 queue:queue completion:^(CLMusicItemInfo *info) {
        found = info; answered = YES;
    }];
    CL_ASSERT_TRUE(CLTestWaitUntil(1.0, ^BOOL{ return answered; }));
    CL_ASSERT_NIL(found);
    CL_ASSERT_TRUE(CFAbsoluteTimeGetCurrent() - start < 0.5);

    // Live: an item recorded while waiting is picked up.
    registry.live = YES;
    answered = NO;
    [registry infoForTrack:track waitingUpTo:2.0 queue:queue completion:^(CLMusicItemInfo *info) {
        found = info; answered = YES;
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
        [registry recordInfo:MakeInfo(@"Song", 77, 0, 0, 0, 0)];
    });
    CL_ASSERT_TRUE(CLTestWaitUntil(2.5, ^BOOL{ return answered; }));
    CL_ASSERT_EQ(found.storeIdentifier, 77LL);

    // Live, never recorded: nil after the timeout.
    answered = NO;
    start = CFAbsoluteTimeGetCurrent();
    [registry infoForTrack:MakeTrack(@"Nobody", @"Artist", 200, kMusic) waitingUpTo:0.6 queue:queue
                completion:^(CLMusicItemInfo *info) { found = info; answered = YES; }];
    CL_ASSERT_TRUE(CLTestWaitUntil(2.0, ^BOOL{ return answered; }));
    CL_ASSERT_NIL(found);
    CL_ASSERT_TRUE(CFAbsoluteTimeGetCurrent() - start >= 0.5);
}

#pragma mark - CLAppleMusicProvider

static NSString *const kWordTTML =
    @"<tt xmlns=\"http://www.w3.org/ns/ttml\" xmlns:itunes=\"http://music.apple.com/lyric-ttml-internal\" "
    @"itunes:timing=\"Line\"><body><div>"
    @"<p begin=\"1.5\" end=\"3\">First line</p><p begin=\"4\" end=\"6\">Second line</p>"
    @"</div></body></tt>";

static void TestAppleMusicProvider(void) {
    CLMusicItemRegistry *registry = [[CLMusicItemRegistry alloc] init];
    __block NSMutableArray<NSNumber *> *requested = [NSMutableArray array];
    __block NSString *ttmlToReturn = kWordTTML;
    __block NSError *errorToReturn = nil;
    CLAppleMusicProvider *provider = [[CLAppleMusicProvider alloc]
        initWithRegistry:registry
                   fetch:^(long long adamID, void (^completion)(NSString *, NSError *)) {
                       @synchronized (requested) { [requested addObject:@(adamID)]; }
                       NSString *ttml = ttmlToReturn;
                       NSError *error = errorToReturn;
                       dispatch_async(dispatch_get_global_queue(0, 0), ^{ completion(ttml, error); });
                   }
            itemWaitTime:0.4];
    CL_ASSERT_EQ(provider.identifier, @"apple-music");

    CLLyrics *lyrics = nil;
    NSError *error = nil;
    NSUInteger calls = 0;

    // Another app's track: an immediate miss.
    CL_ASSERT_TRUE(Fetch(provider, MakeTrack(@"Song", @"Artist", 200, @"com.spotify.client"), &lyrics, &error, &calls));
    CL_ASSERT_NIL(lyrics);
    CL_ASSERT_NIL(error);
    CL_ASSERT_EQ(calls, (NSUInteger)1);

    CLTrack *track = MakeTrack(@"Song", @"Artist", 200, kMusic);
    // Registry not live (no Music hook, e.g. in CarPlayTemplateUIHost): a miss, not an error.
    CL_ASSERT_TRUE(Fetch(provider, track, &lyrics, &error, &calls));
    CL_ASSERT_NIL(lyrics);
    CL_ASSERT_NIL(error);

    // Live but the song was never reported: an error, so it is not negative-cached.
    registry.live = YES;
    CL_ASSERT_TRUE(Fetch(provider, track, &lyrics, &error, &calls));
    CL_ASSERT_NIL(lyrics);
    CL_ASSERT_NOT_NIL(error);
    CL_ASSERT_EQ(requested.count, (NSUInteger)0);

    // Apple says no lyrics: a miss without a request.
    [registry recordInfo:MakeInfo(@"Song", 11, 22, 33, CLMusicLyricsAvailabilityNone, 0)];
    CL_ASSERT_TRUE(Fetch(provider, track, &lyrics, &error, &calls));
    CL_ASSERT_NIL(lyrics);
    CL_ASSERT_NIL(error);
    CL_ASSERT_EQ(requested.count, (NSUInteger)0);

    // A local file (no store ids): a miss without a request.
    [registry recordInfo:MakeInfo(@"Song", 0, 0, 0, CLMusicLyricsAvailabilityUnknown, 12345)];
    CL_ASSERT_TRUE(Fetch(provider, track, &lyrics, &error, &calls));
    CL_ASSERT_NIL(lyrics);
    CL_ASSERT_EQ(requested.count, (NSUInteger)0);

    // Catalog song: asks for the lyrics adam id and parses the TTML.
    [registry recordInfo:MakeInfo(@"Song", 11, 22, 33, CLMusicLyricsAvailabilityAvailable, 0)];
    CL_ASSERT_TRUE(Fetch(provider, track, &lyrics, &error, &calls));
    CL_ASSERT_EQ(calls, (NSUInteger)1);
    CL_ASSERT_EQ(requested.lastObject, @33);
    CL_ASSERT_NIL(error);
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)2);
    CL_ASSERT_NEAR(lyrics.lines.firstObject.time, 1.5, 0.001);
    CL_ASSERT_EQ(lyrics.lines.firstObject.text, @"First line");
    CL_ASSERT_EQ(lyrics.source, @"apple-music");

    // Unknown availability still asks (older content items may not carry the flag).
    [registry recordInfo:MakeInfo(@"Song", 11, 22, 0, CLMusicLyricsAvailabilityUnknown, 0)];
    CL_ASSERT_TRUE(Fetch(provider, track, &lyrics, &error, &calls));
    CL_ASSERT_EQ(requested.lastObject, @22);
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);

    // A failed request is an error, never a miss.
    errorToReturn = [NSError errorWithDomain:@"CLTest" code:500 userInfo:nil];
    ttmlToReturn = nil;
    CL_ASSERT_TRUE(Fetch(provider, track, &lyrics, &error, &calls));
    CL_ASSERT_NIL(lyrics);
    CL_ASSERT_EQ((long)error.code, (long)500);

    // Unparseable TTML: a miss.
    errorToReturn = nil;
    ttmlToReturn = @"<html>not lyrics</html>";
    CL_ASSERT_TRUE(Fetch(provider, track, &lyrics, &error, &calls));
    CL_ASSERT_NIL(lyrics);
    CL_ASSERT_NIL(error);
}

#pragma mark - CLEmbeddedLyricsProvider

/// A minimal ID3v2.3 tag holding one USLT frame with `text` (ISO-8859-1), then a few fake MPEG bytes.
static NSData *ID3WithUSLT(NSString *text) {
    NSMutableData *frameBody = [NSMutableData data];
    uint8_t header[] = { 0x00, 'e', 'n', 'g', 0x00 };   // encoding 0, "eng", empty descriptor
    [frameBody appendBytes:header length:sizeof(header)];
    [frameBody appendData:[text dataUsingEncoding:NSISOLatin1StringEncoding]];

    NSMutableData *frame = [NSMutableData dataWithBytes:"USLT" length:4];
    uint32_t size = CFSwapInt32HostToBig((uint32_t)frameBody.length);
    [frame appendBytes:&size length:4];
    uint8_t flags[2] = { 0, 0 };
    [frame appendBytes:flags length:2];
    [frame appendData:frameBody];

    NSMutableData *tag = [NSMutableData dataWithBytes:"ID3\x03\x00\x00" length:6];
    uint32_t tagSize = (uint32_t)frame.length;
    uint8_t synchsafe[4] = { (tagSize >> 21) & 0x7F, (tagSize >> 14) & 0x7F, (tagSize >> 7) & 0x7F, tagSize & 0x7F };
    [tag appendBytes:synchsafe length:4];
    [tag appendData:frame];
    uint8_t mpeg[] = { 0xFF, 0xFB, 0x90, 0x64, 0x00, 0x00, 0x00, 0x00 };
    [tag appendBytes:mpeg length:sizeof(mpeg)];
    return tag;
}

static void TestEmbeddedProvider(void) {
    CLMusicItemRegistry *registry = [[CLMusicItemRegistry alloc] init];
    registry.live = YES;
    __block CLMusicLibraryItem *libraryItem = nil;
    __block unsigned long long askedFor = 0;
    NSMutableDictionary<NSString *, NSData *> *files = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *reads = [NSMutableArray array];
    CLEmbeddedLyricsProvider *provider = [[CLEmbeddedLyricsProvider alloc]
        initWithRegistry:registry
                  lookup:^CLMusicLibraryItem *(unsigned long long persistentID) {
                      askedFor = persistentID;
                      return libraryItem;
                  }
              fileReader:^NSData *(NSString *path) {
                  @synchronized (reads) { [reads addObject:path.lastPathComponent]; }
                  return files[path];
              }
            itemWaitTime:0.3];
    CL_ASSERT_EQ(provider.identifier, @"embedded");

    CLLyrics *lyrics = nil;
    NSError *error = nil;
    NSUInteger calls = 0;
    CLTrack *track = MakeTrack(@"Song", @"Artist", 200, kMusic);

    CL_ASSERT_TRUE(Fetch(provider, MakeTrack(@"Song", @"Artist", 200, @"com.spotify.client"), &lyrics, &error, &calls));
    CL_ASSERT_NIL(lyrics);
    CL_ASSERT_NIL(error);

    // Never reported while live: an error (not cached).
    CL_ASSERT_TRUE(Fetch(provider, track, &lyrics, &error, &calls));
    CL_ASSERT_NOT_NIL(error);

    // A catalog song with no library pid: a miss without a lookup.
    [registry recordInfo:MakeInfo(@"Song", 11, 22, 0, CLMusicLyricsAvailabilityAvailable, 0)];
    CL_ASSERT_TRUE(Fetch(provider, track, &lyrics, &error, &calls));
    CL_ASSERT_NIL(lyrics);
    CL_ASSERT_NIL(error);
    CL_ASSERT_EQ(askedFor, 0ULL);

    // A library item with a different title: ignored.
    [registry recordInfo:MakeInfo(@"Song", 0, 0, 0, CLMusicLyricsAvailabilityUnknown, 4242)];
    libraryItem = [[CLMusicLibraryItem alloc] initWithTitle:@"Another Song" duration:200
                                                     lyrics:@"[00:01.00]Nope\n[00:02.00]Nope" filePath:nil];
    CL_ASSERT_TRUE(Fetch(provider, track, &lyrics, &error, &calls));
    CL_ASSERT_EQ(askedFor, 4242ULL);
    CL_ASSERT_NIL(lyrics);

    // LRC in the library's lyrics text: synced, and no file is read.
    libraryItem = [[CLMusicLibraryItem alloc] initWithTitle:@"song" duration:200
                                                     lyrics:@"[00:01.00]One\n[00:02.50]Two\n[00:04.00]Three"
                                                   filePath:@"/music/F00/ABCD.mp3"];
    [reads removeAllObjects];
    CL_ASSERT_TRUE(Fetch(provider, track, &lyrics, &error, &calls));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)3);
    CL_ASSERT_NEAR(lyrics.lines[1].time, 2.5, 0.001);
    CL_ASSERT_EQ(lyrics.source, @"embedded");
    CL_ASSERT_EQ(reads.count, (NSUInteger)0);

    // Plain text in the database, LRC in the file's USLT: the file wins.
    libraryItem = [[CLMusicLibraryItem alloc] initWithTitle:@"Song" duration:200
                                                     lyrics:@"Just words\nNo timing"
                                                   filePath:@"/music/F00/ABCD.mp3"];
    files[@"/music/F00/ABCD.mp3"] = ID3WithUSLT(@"[00:03.00]Tagged one\n[00:05.00]Tagged two");
    CL_ASSERT_TRUE(Fetch(provider, track, &lyrics, &error, &calls));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.firstObject.text, @"Tagged one");

    // Plain everywhere but a sidecar .lrc next to the file: the sidecar wins.
    files[@"/music/F00/ABCD.mp3"] = ID3WithUSLT(@"Tagged but plain");
    files[@"/music/F00/ABCD.lrc"] = [@"[ar:Artist]\n[00:07.00]Sidecar line\n[00:09.00]Another" dataUsingEncoding:NSUTF8StringEncoding];
    CL_ASSERT_TRUE(Fetch(provider, track, &lyrics, &error, &calls));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.firstObject.text, @"Sidecar line");

    // Nothing synced anywhere: the database's plain text.
    [files removeObjectForKey:@"/music/F00/ABCD.lrc"];
    CL_ASSERT_TRUE(Fetch(provider, track, &lyrics, &error, &calls));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_TRUE([lyrics.plainText containsString:@"Just words"]);

    // No database text, a plain tag: the tag's text.
    libraryItem = [[CLMusicLibraryItem alloc] initWithTitle:@"Song" duration:200 lyrics:nil
                                                   filePath:@"/music/F00/ABCD.mp3"];
    CL_ASSERT_TRUE(Fetch(provider, track, &lyrics, &error, &calls));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_TRUE([lyrics.plainText containsString:@"Tagged but plain"]);

    // Nothing at all: a miss.
    libraryItem = [[CLMusicLibraryItem alloc] initWithTitle:@"Song" duration:200 lyrics:@"   " filePath:nil];
    CL_ASSERT_TRUE(Fetch(provider, track, &lyrics, &error, &calls));
    CL_ASSERT_NIL(lyrics);
    CL_ASSERT_NIL(error);
    CL_ASSERT_EQ(calls, (NSUInteger)1);
}

void CLRunMusicSourcesTests(void) {
    CLTestBeginSuite("Apple Music sources (registry, apple-music, embedded)");
    TestItemInfo();
    TestRegistry();
    TestAppleMusicProvider();
    TestEmbeddedProvider();
}
