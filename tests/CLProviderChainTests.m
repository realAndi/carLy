// Tests for CLProviderChain (Tweak/Lyrics/CLProviderChain.m): ordering, the "first error on an
// all-miss" behaviour the lyrics-core slice's HANDOFF.md note calls out, and cancellation.
//
// The chain always delivers its completion via dispatch_async on the main queue (even for the
// synchronous "nothing to resolve" shortcut), so every test here waits with CLTestWaitUntil
// rather than assuming synchronous delivery.
#import "CLProviderChainTests.h"
#import "CLTestCase.h"
#import "Lyrics/CLProviderChain.h"

NS_ASSUME_NONNULL_BEGIN

/// A tiny scriptable CLLyricsProvider double: returns a fixed (lyrics, error) pair, optionally
/// after a delay on a background queue, and records how many times it was asked.
@interface CLFakeChainProvider : NSObject <CLLyricsProvider>
- (instancetype)initWithIdentifier:(NSString *)identifier
                             lyrics:(nullable CLLyrics *)lyrics
                              error:(nullable NSError *)error
                              delay:(NSTimeInterval)delay;
@property (nonatomic, readonly) NSString *identifier;
@property (nonatomic) NSUInteger callCount;
@property (nonatomic, copy, nullable) dispatch_block_t onFetchCalled;
@end

@implementation CLFakeChainProvider {
    CLLyrics *_lyrics;
    NSError *_error;
    NSTimeInterval _delay;
}

- (instancetype)initWithIdentifier:(NSString *)identifier
                             lyrics:(nullable CLLyrics *)lyrics
                              error:(nullable NSError *)error
                              delay:(NSTimeInterval)delay {
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _lyrics = lyrics;
        _error = error;
        _delay = delay;
    }
    return self;
}

- (void)fetchLyricsForTrack:(CLTrack *)track completion:(CLLyricsCompletion)completion {
    self.callCount++;
    if (self.onFetchCalled) self.onFetchCalled();
    CLLyrics *lyrics = _lyrics;
    NSError *error = _error;
    if (_delay > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_delay * NSEC_PER_SEC)),
                        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            completion(lyrics, error);
        });
    } else {
        completion(lyrics, error);
    }
}

@end

NS_ASSUME_NONNULL_END

static CLTrack *CLMakeChainTestTrack(void) {
    CLTrack *track = [[CLTrack alloc] init];
    track.title = @"Chain Test Song";
    track.artist = @"Chain Test Artist";
    track.duration = 200;
    return track;
}

static void CLTestChainTriesProvidersInOrderAndStopsOnHit(void) {
    NSMutableArray<NSString *> *callOrder = [NSMutableArray array];

    CLFakeChainProvider *miss = [[CLFakeChainProvider alloc] initWithIdentifier:@"fake-miss"
                                                                          lyrics:nil error:nil delay:0.05];
    miss.onFetchCalled = ^{ [callOrder addObject:@"fake-miss"]; };

    CLLyrics *hitLyrics = [CLLyrics plainWithText:@"found it" source:@""];   // empty source on purpose
    CLFakeChainProvider *hit = [[CLFakeChainProvider alloc] initWithIdentifier:@"fake-hit"
                                                                         lyrics:hitLyrics error:nil delay:0];
    hit.onFetchCalled = ^{ [callOrder addObject:@"fake-hit"]; };

    CLProviderChain *chain = [[CLProviderChain alloc] initWithProviders:@[ miss, hit ]];
    __block BOOL delivered = NO;
    __block CLLyrics *result = nil;
    __block NSError *resultError = nil;
    [chain resolveLyricsForTrack:CLMakeChainTestTrack() completion:^(CLLyrics *lyrics, NSError *error) {
        result = lyrics;
        resultError = error;
        delivered = YES;
    }];

    CL_ASSERT_TRUE(CLTestWaitUntil(2.0, ^BOOL{ return delivered; }));
    CL_ASSERT_EQ(miss.callCount, (NSUInteger)1);
    CL_ASSERT_EQ(hit.callCount, (NSUInteger)1);
    CL_ASSERT_EQ(callOrder.count, (NSUInteger)2);
    CL_ASSERT_EQ(callOrder[0], @"fake-miss");    // strictly sequential, never both at once
    CL_ASSERT_EQ(callOrder[1], @"fake-hit");
    CL_ASSERT_NOT_NIL(result);
    CL_ASSERT_EQ((long)result.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(result.plainText, @"found it");
    CL_ASSERT_EQ(result.source, @"fake-hit");    // chain fills in the identifier when source is empty
    CL_ASSERT_NIL(resultError);
}

static void CLTestChainAllMissCarriesFirstError(void) {
    NSError *firstError = [NSError errorWithDomain:@"CLTest" code:503 userInfo:nil];
    NSError *secondError = [NSError errorWithDomain:@"CLTest" code:429 userInfo:nil];
    CLFakeChainProvider *p1 = [[CLFakeChainProvider alloc] initWithIdentifier:@"p1" lyrics:nil
                                                                         error:firstError delay:0];
    CLFakeChainProvider *p2 = [[CLFakeChainProvider alloc] initWithIdentifier:@"p2" lyrics:nil
                                                                         error:secondError delay:0];
    CLProviderChain *chain = [[CLProviderChain alloc] initWithProviders:@[ p1, p2 ]];

    __block BOOL delivered = NO;
    __block CLLyrics *result = nil;
    __block NSError *resultError = nil;
    [chain resolveLyricsForTrack:CLMakeChainTestTrack() completion:^(CLLyrics *lyrics, NSError *error) {
        result = lyrics; resultError = error; delivered = YES;
    }];

    CL_ASSERT_TRUE(CLTestWaitUntil(2.0, ^BOOL{ return delivered; }));
    CL_ASSERT_EQ((long)result.kind, (long)CLLyricsKindNone);
    CL_ASSERT_EQ(result.source, @"chain");
    CL_ASSERT_NOT_NIL(resultError);
    CL_ASSERT_EQ((long)resultError.code, (long)503);   // the FIRST error seen, not the last
}

static void CLTestChainAllMissWithoutErrorsReportsNilError(void) {
    CLFakeChainProvider *p1 = [[CLFakeChainProvider alloc] initWithIdentifier:@"p1" lyrics:nil error:nil delay:0];
    CLFakeChainProvider *p2 = [[CLFakeChainProvider alloc] initWithIdentifier:@"p2" lyrics:nil error:nil delay:0];
    CLProviderChain *chain = [[CLProviderChain alloc] initWithProviders:@[ p1, p2 ]];

    __block BOOL delivered = NO;
    __block CLLyrics *result = nil;
    __block NSError *resultError = nil;
    [chain resolveLyricsForTrack:CLMakeChainTestTrack() completion:^(CLLyrics *lyrics, NSError *error) {
        result = lyrics; resultError = error; delivered = YES;
    }];

    CL_ASSERT_TRUE(CLTestWaitUntil(2.0, ^BOOL{ return delivered; }));
    CL_ASSERT_EQ((long)result.kind, (long)CLLyricsKindNone);
    CL_ASSERT_NIL(resultError);   // a real (non-transient) miss must NOT carry an error
}

static void CLTestChainCancelPreventsCompletion(void) {
    CLFakeChainProvider *slow = [[CLFakeChainProvider alloc] initWithIdentifier:@"slow"
        lyrics:[CLLyrics plainWithText:@"too late" source:@"slow"] error:nil delay:0.3];
    CLProviderChain *chain = [[CLProviderChain alloc] initWithProviders:@[ slow ]];

    __block BOOL delivered = NO;
    id token = [chain resolveLyricsForTrack:CLMakeChainTestTrack()
                                  completion:^(CLLyrics *lyrics, NSError *error) { delivered = YES; }];
    [chain cancel:token];

    // Wait comfortably past the provider's own delay: the completion must never fire.
    CLTestWaitUntil(0.5, ^BOOL{ return delivered; });
    CL_ASSERT_FALSE(delivered);
}

static void CLTestChainEmptyTrackShortCircuitsWithoutCallingProviders(void) {
    CLFakeChainProvider *shouldNeverRun = [[CLFakeChainProvider alloc] initWithIdentifier:@"never"
        lyrics:[CLLyrics plainWithText:@"nope" source:@"never"] error:nil delay:0];
    CLProviderChain *chain = [[CLProviderChain alloc] initWithProviders:@[ shouldNeverRun ]];

    CLTrack *emptyTrack = [[CLTrack alloc] init];   // no title, no artist
    __block BOOL delivered = NO;
    __block CLLyrics *result = nil;
    [chain resolveLyricsForTrack:emptyTrack completion:^(CLLyrics *lyrics, NSError *error) {
        result = lyrics; delivered = YES;
    }];

    CL_ASSERT_TRUE(CLTestWaitUntil(1.0, ^BOOL{ return delivered; }));
    CL_ASSERT_EQ((long)result.kind, (long)CLLyricsKindNone);
    CL_ASSERT_EQ(shouldNeverRun.callCount, (NSUInteger)0);
}

static void CLTestChainSanitizesProviderList(void) {
    CLFakeChainProvider *real = [[CLFakeChainProvider alloc] initWithIdentifier:@"real" lyrics:nil
                                                                           error:nil delay:0];
    NSObject *doesNotConform = [[NSObject alloc] init];
    NSArray *mixed = @[ [NSNull null], doesNotConform, real ];
    CLProviderChain *chain = [[CLProviderChain alloc] initWithProviders:mixed];
    CL_ASSERT_EQ(chain.providers.count, (NSUInteger)1);
    CL_ASSERT_TRUE(chain.providers.firstObject == real);

    // Re-assigning through the setter sanitizes too.
    chain.providers = @[ [NSNull null] ];
    CL_ASSERT_EQ(chain.providers.count, (NSUInteger)0);
}

/// Runs `providers` and waits for the answer.
static void CLResolveWithChain(NSArray *providers, CLLyrics *_Nullable __autoreleasing *outLyrics,
                               NSError *_Nullable __autoreleasing *outError) {
    CLProviderChain *chain = [[CLProviderChain alloc] initWithProviders:providers];
    __block BOOL delivered = NO;
    __block CLLyrics *result = nil;
    __block NSError *resultError = nil;
    [chain resolveLyricsForTrack:CLMakeChainTestTrack() completion:^(CLLyrics *lyrics, NSError *error) {
        result = lyrics; resultError = error; delivered = YES;
    }];
    CL_ASSERT_TRUE(CLTestWaitUntil(2.0, ^BOOL{ return delivered; }));
    if (outLyrics) *outLyrics = result;
    if (outError) *outError = resultError;
}

/// 0.8.0: plain text is held while later providers are asked; synced lines win.
static void CLTestChainPrefersSyncedOverPlain(void) {
    CLLyrics *plain = [CLLyrics plainWithText:@"plain words" source:@"first"];
    CLLyrics *synced = [CLLyrics syncedWithLines:@[ [CLLyricLine lineWithTime:1 text:@"timed"] ]
                                          source:@"second"];
    CLFakeChainProvider *p1 = [[CLFakeChainProvider alloc] initWithIdentifier:@"first" lyrics:plain
                                                                         error:nil delay:0];
    CLFakeChainProvider *p2 = [[CLFakeChainProvider alloc] initWithIdentifier:@"second" lyrics:synced
                                                                         error:nil delay:0.02];
    CLFakeChainProvider *p3 = [[CLFakeChainProvider alloc] initWithIdentifier:@"third" lyrics:plain
                                                                         error:nil delay:0];
    CLLyrics *result = nil;
    NSError *error = nil;
    CLResolveWithChain(@[ p1, p2, p3 ], &result, &error);
    CL_ASSERT_EQ((long)result.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(result.source, @"second");
    CL_ASSERT_NIL(error);
    CL_ASSERT_EQ(p3.callCount, (NSUInteger)0);   // synced stops the chain

    // Nobody has synced lines: the first plain text, no error.
    CLFakeChainProvider *miss = [[CLFakeChainProvider alloc] initWithIdentifier:@"miss" lyrics:nil
                                                                           error:nil delay:0];
    CLFakeChainProvider *laterPlain = [[CLFakeChainProvider alloc]
        initWithIdentifier:@"later" lyrics:[CLLyrics plainWithText:@"later words" source:@"later"]
                     error:nil delay:0];
    CLFakeChainProvider *firstPlain = [[CLFakeChainProvider alloc] initWithIdentifier:@"first" lyrics:plain
                                                                                error:nil delay:0];
    CLResolveWithChain(@[ firstPlain, miss, laterPlain ], &result, &error);
    CL_ASSERT_EQ((long)result.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(result.plainText, @"plain words");
    CL_ASSERT_NIL(error);
    CL_ASSERT_EQ(laterPlain.callCount, (NSUInteger)1);

    // A later provider failed: the plain text still shows, with that error so it is not cached.
    CLFakeChainProvider *failing = [[CLFakeChainProvider alloc]
        initWithIdentifier:@"failing" lyrics:nil error:[NSError errorWithDomain:@"CLTest" code:503 userInfo:nil]
                     delay:0];
    CLFakeChainProvider *plainAgain = [[CLFakeChainProvider alloc] initWithIdentifier:@"first" lyrics:plain
                                                                                error:nil delay:0];
    CLResolveWithChain(@[ plainAgain, failing ], &result, &error);
    CL_ASSERT_EQ((long)result.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ((long)error.code, (long)503);

    // Instrumental is as definitive as synced.
    CLFakeChainProvider *instrumental = [[CLFakeChainProvider alloc]
        initWithIdentifier:@"instr" lyrics:[CLLyrics instrumentalFromSource:@"instr"] error:nil delay:0];
    CLFakeChainProvider *never = [[CLFakeChainProvider alloc] initWithIdentifier:@"never" lyrics:synced
                                                                           error:nil delay:0];
    CLResolveWithChain(@[ instrumental, never ], &result, &error);
    CL_ASSERT_EQ((long)result.kind, (long)CLLyricsKindInstrumental);
    CL_ASSERT_EQ(never.callCount, (NSUInteger)0);

    // ...unless an earlier source already had words: then the instrumental is ignored.
    CLFakeChainProvider *words = [[CLFakeChainProvider alloc] initWithIdentifier:@"words" lyrics:plain
                                                                           error:nil delay:0];
    CLFakeChainProvider *laterInstrumental = [[CLFakeChainProvider alloc]
        initWithIdentifier:@"instr2" lyrics:[CLLyrics instrumentalFromSource:@"instr2"] error:nil delay:0];
    CLFakeChainProvider *afterThat = [[CLFakeChainProvider alloc] initWithIdentifier:@"after" lyrics:synced
                                                                               error:nil delay:0];
    CLResolveWithChain(@[ words, laterInstrumental ], &result, &error);
    CL_ASSERT_EQ((long)result.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(result.plainText, @"plain words");
    CLResolveWithChain(@[ words, laterInstrumental, afterThat ], &result, &error);
    CL_ASSERT_EQ((long)result.kind, (long)CLLyricsKindSynced);
}

void CLRunProviderChainTests(void) {
    CLTestBeginSuite("CLProviderChain");
    CLTestChainTriesProvidersInOrderAndStopsOnHit();
    CLTestChainAllMissCarriesFirstError();
    CLTestChainAllMissWithoutErrorsReportsNilError();
    CLTestChainCancelPreventsCompletion();
    CLTestChainEmptyTrackShortCircuitsWithoutCallingProviders();
    CLTestChainSanitizesProviderList();
    CLTestChainPrefersSyncedOverPlain();
}
