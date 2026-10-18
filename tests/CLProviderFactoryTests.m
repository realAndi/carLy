// Tests for CLProviderFactory (Tweak/Lyrics/CLProviderFactory.m) — the rules that turn the
// "Sources" preferences into a provider chain.
//
// This logic used to be a static function inside Tweak.x, which nothing but a real car could
// reach; the fix wave moved it out precisely so the table below could exist. Everything here is
// pure: no network, no disk, no preferences.
#import "CLProviderFactoryTests.h"
#import "CLTestCase.h"
#import "Lyrics/CLProviderFactory.h"
#import "Lyrics/CLSpotifyAppProvider.h"

NS_ASSUME_NONNULL_BEGIN

/// The pre-0.8.0 sources only: embedded, Apple Music and Spotify switched off, so the older tables
/// below read exactly as they did. TestMusicSources and TestSpotifySource cover the newer ones.
static NSArray<NSString *> *Identifiers(NSArray *_Nullable order, BOOL spotify, BOOL lrclib,
                                        BOOL custom, BOOL offline) {
    return [CLProviderFactory identifiersForOrder:order
                                  embeddedEnabled:NO
                                appleMusicEnabled:NO
                             spotifyLyricsEnabled:NO
                              spotifyCacheEnabled:spotify
                                    lrclibEnabled:lrclib
                            customEndpointEnabled:custom
                                      offlineOnly:offline];
}

static NSArray<NSString *> *IdentifiersOfProviders(NSArray<id<CLLyricsProvider>> *providers) {
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:providers.count];
    for (id<CLLyricsProvider> provider in providers) {
        [names addObject:provider.identifier ?: NSStringFromClass([provider class])];
    }
    return names;
}

static void TestDefaultOrder(void) {
    // Nothing configured: on-disk first, then the network, in the documented order.
    CL_ASSERT_EQ(Identifiers(nil, YES, YES, YES, NO),
                 (@[ @"spotify-cache", @"lrclib", @"custom" ]));
    CL_ASSERT_EQ(Identifiers(@[], YES, YES, YES, NO),
                 (@[ @"spotify-cache", @"lrclib", @"custom" ]));
    CL_ASSERT_EQ(CLProviderFactory.defaultOrder,
                 (@[ @"embedded", @"apple-music", @"spotify", @"spotify-cache", @"lrclib", @"custom" ]));
    // A non-array value (a hand-edited plist) is the same as "not configured".
    CL_ASSERT_EQ(Identifiers((NSArray *)@"lrclib", YES, YES, YES, NO),
                 (@[ @"spotify-cache", @"lrclib", @"custom" ]));
}

static void TestOrderIsHonoured(void) {
    CL_ASSERT_EQ(Identifiers((@[ @"lrclib", @"spotify-cache" ]), YES, YES, YES, NO),
                 (@[ @"lrclib", @"spotify-cache" ]));
    // An identifier the user never listed simply does not run.
    CL_ASSERT_EQ(Identifiers((@[ @"custom" ]), YES, YES, YES, NO), (@[ @"custom" ]));
    // Case does not matter; the resolved list is always lowercase.
    CL_ASSERT_EQ(Identifiers((@[ @"LRCLib", @"Spotify-Cache" ]), YES, YES, YES, NO),
                 (@[ @"lrclib", @"spotify-cache" ]));
}

static void TestDedupeAndJunk(void) {
    // A duplicate keeps its first position and is not run twice.
    CL_ASSERT_EQ(Identifiers((@[ @"lrclib", @"lrclib", @"spotify-cache", @"LRCLIB" ]),
                             YES, YES, YES, NO),
                 (@[ @"lrclib", @"spotify-cache" ]));
    // Unknown identifiers, empty strings and non-strings are skipped, not fatal.
    CL_ASSERT_EQ(Identifiers((@[ @"musixmatch", @"", @(7), [NSNull null], @"lrclib" ]),
                             YES, YES, YES, NO),
                 (@[ @"lrclib" ]));
    // Everything unknown: an empty chain, which the controller reports as a plain miss.
    CL_ASSERT_EQ(Identifiers((@[ @"genius", @"musixmatch" ]), YES, YES, YES, NO).count,
                 (unsigned long)0);
}

static void TestEnableFlags(void) {
    CL_ASSERT_EQ(Identifiers(nil, NO, YES, YES, NO), (@[ @"lrclib", @"custom" ]));
    CL_ASSERT_EQ(Identifiers(nil, YES, NO, YES, NO), (@[ @"spotify-cache", @"custom" ]));
    CL_ASSERT_EQ(Identifiers(nil, YES, YES, NO, NO), (@[ @"spotify-cache", @"lrclib" ]));
    CL_ASSERT_EQ(Identifiers(nil, NO, NO, NO, NO).count, (unsigned long)0);
    // A disabled provider stays disabled even when the user put it first.
    CL_ASSERT_EQ(Identifiers((@[ @"lrclib", @"spotify-cache" ]), YES, NO, YES, NO),
                 (@[ @"spotify-cache" ]));
}

static void TestOfflineOnly(void) {
    // offlineOnly drops both network providers and keeps the on-disk one (PLAN.md §3.2).
    CL_ASSERT_EQ(Identifiers(nil, YES, YES, YES, YES), (@[ @"spotify-cache" ]));
    CL_ASSERT_EQ(Identifiers((@[ @"custom", @"lrclib" ]), YES, YES, YES, YES).count,
                 (unsigned long)0);
    // offlineOnly does not resurrect a provider the user switched off.
    CL_ASSERT_EQ(Identifiers(nil, NO, YES, YES, YES).count, (unsigned long)0);
}

static void TestProviderInstantiation(void) {
    NSArray<id<CLLyricsProvider>> *providers =
        [CLProviderFactory providersForIdentifiers:(@[ @"spotify-cache", @"lrclib" ])
                                 customEndpointURL:@""
                              customEndpointHeader:@""
                        customEndpointHeaderValue:@""];
    CL_ASSERT_EQ(IdentifiersOfProviders(providers), (@[ @"spotify-cache", @"lrclib" ]));

    // A custom endpoint with no URL is inert and must not take a slot in the chain: leaving it in
    // would delay every miss by one provider that can never answer.
    NSArray<id<CLLyricsProvider>> *inert =
        [CLProviderFactory providersForIdentifiers:(@[ @"custom", @"lrclib" ])
                                 customEndpointURL:@""
                              customEndpointHeader:@""
                        customEndpointHeaderValue:@""];
    CL_ASSERT_EQ(IdentifiersOfProviders(inert), (@[ @"lrclib" ]));

    // A non-http template is inert too.
    NSArray<id<CLLyricsProvider>> *badScheme =
        [CLProviderFactory providersForIdentifiers:(@[ @"custom" ])
                                 customEndpointURL:@"file:///etc/passwd"
                              customEndpointHeader:@""
                        customEndpointHeaderValue:@""];
    CL_ASSERT_EQ(badScheme.count, (unsigned long)0);

    // A usable template is kept, in the position the user asked for.
    NSArray<id<CLLyricsProvider>> *usable =
        [CLProviderFactory providersForIdentifiers:(@[ @"custom", @"spotify-cache" ])
                                 customEndpointURL:@"https://example.invalid/{artist}/{title}"
                              customEndpointHeader:@"X-Token"
                        customEndpointHeaderValue:@"secret"];
    CL_ASSERT_EQ(IdentifiersOfProviders(usable), (@[ @"custom", @"spotify-cache" ]));

    // Nil and junk in, empty out — never a crash and never a half-built chain.
    CL_ASSERT_EQ([CLProviderFactory providersForIdentifiers:nil
                                          customEndpointURL:nil
                                       customEndpointHeader:nil
                                 customEndpointHeaderValue:nil].count, (unsigned long)0);
    NSArray<NSString *> *junk = (NSArray<NSString *> *)[NSArray arrayWithObjects:@"nope", @(3), nil];
    CL_ASSERT_EQ([CLProviderFactory providersForIdentifiers:junk
                                          customEndpointURL:nil
                                       customEndpointHeader:nil
                                 customEndpointHeaderValue:nil].count, (unsigned long)0);
}

static NSArray<NSString *> *AllIdentifiers(NSArray *_Nullable order, BOOL embedded, BOOL appleMusic,
                                           BOOL offline) {
    return [CLProviderFactory identifiersForOrder:order
                                  embeddedEnabled:embedded
                                appleMusicEnabled:appleMusic
                             spotifyLyricsEnabled:NO
                              spotifyCacheEnabled:YES
                                    lrclibEnabled:YES
                            customEndpointEnabled:YES
                                      offlineOnly:offline];
}

/// 0.8.0's embedded lyrics and Apple Music lyrics.
static void TestMusicSources(void) {
    // Nothing configured: the song's own lyrics first.
    CL_ASSERT_EQ(AllIdentifiers(nil, YES, YES, NO),
                 (@[ @"embedded", @"apple-music", @"spotify-cache", @"lrclib", @"custom" ]));
    // An order saved by an older version cannot list them: they go in front, in default order.
    CL_ASSERT_EQ(AllIdentifiers((@[ @"lrclib", @"spotify-cache", @"custom" ]), YES, YES, NO),
                 (@[ @"embedded", @"apple-music", @"lrclib", @"spotify-cache", @"custom" ]));
    // One of them already placed by the user stays where it is; only the missing one is added.
    CL_ASSERT_EQ(AllIdentifiers((@[ @"lrclib", @"apple-music", @"spotify-cache" ]), YES, YES, NO),
                 (@[ @"embedded", @"lrclib", @"apple-music", @"spotify-cache" ]));
    CL_ASSERT_EQ(AllIdentifiers((@[ @"LRCLIB", @"Embedded", @"apple-music" ]), YES, YES, NO),
                 (@[ @"lrclib", @"embedded", @"apple-music" ]));
    // Their own switches.
    CL_ASSERT_EQ(AllIdentifiers(nil, NO, YES, NO),
                 (@[ @"apple-music", @"spotify-cache", @"lrclib", @"custom" ]));
    CL_ASSERT_EQ(AllIdentifiers(nil, YES, NO, NO),
                 (@[ @"embedded", @"spotify-cache", @"lrclib", @"custom" ]));
    // offlineOnly keeps embedded (the song file) and drops Apple Music (the network).
    CL_ASSERT_EQ(AllIdentifiers(nil, YES, YES, YES), (@[ @"embedded", @"spotify-cache" ]));
    // Built in that order.
    NSArray<id<CLLyricsProvider>> *providers =
        [CLProviderFactory providersForIdentifiers:AllIdentifiers(nil, YES, YES, NO)
                                 customEndpointURL:@""
                              customEndpointHeader:@""
                        customEndpointHeaderValue:@""];
    CL_ASSERT_EQ(IdentifiersOfProviders(providers),
                 (@[ @"embedded", @"apple-music", @"spotify-cache", @"lrclib" ]));
}

static NSArray<NSString *> *SpotifyIdentifiers(NSArray *_Nullable order, BOOL spotifyLyrics, BOOL offline) {
    return [CLProviderFactory identifiersForOrder:order
                                  embeddedEnabled:YES
                                appleMusicEnabled:YES
                             spotifyLyricsEnabled:spotifyLyrics
                              spotifyCacheEnabled:YES
                                    lrclibEnabled:YES
                            customEndpointEnabled:YES
                                      offlineOnly:offline];
}

/// 0.9.0's Spotify lyrics (fetched by carLy inside Spotify).
static void TestSpotifySource(void) {
    // Nothing configured: right after Apple Music, ahead of the cache and LRCLIB.
    CL_ASSERT_EQ(SpotifyIdentifiers(nil, YES, NO),
                 (@[ @"embedded", @"apple-music", @"spotify", @"spotify-cache", @"lrclib", @"custom" ]));
    // An order saved by 0.8.x's Source Order page lists the other five: it goes before the cache.
    CL_ASSERT_EQ(SpotifyIdentifiers((@[ @"embedded", @"apple-music", @"spotify-cache", @"lrclib", @"custom" ]), YES, NO),
                 (@[ @"embedded", @"apple-music", @"spotify", @"spotify-cache", @"lrclib", @"custom" ]));
    // LRCLIB moved to the top: Spotify still runs before it.
    CL_ASSERT_EQ(SpotifyIdentifiers((@[ @"lrclib", @"embedded", @"apple-music", @"spotify-cache", @"custom" ]), YES, NO),
                 (@[ @"spotify", @"lrclib", @"embedded", @"apple-music", @"spotify-cache", @"custom" ]));
    // Several sources missing at once each land before the first listed one ranked after them.
    CL_ASSERT_EQ(SpotifyIdentifiers((@[ @"custom" ]), YES, NO),
                 (@[ @"embedded", @"apple-music", @"spotify", @"custom" ]));
    // Placed by the user: stays where it is.
    CL_ASSERT_EQ(SpotifyIdentifiers((@[ @"lrclib", @"spotify" ]), YES, NO),
                 (@[ @"embedded", @"apple-music", @"lrclib", @"spotify" ]));
    CL_ASSERT_EQ(SpotifyIdentifiers((@[ @"Spotify", @"lrclib" ]), YES, NO),
                 (@[ @"embedded", @"apple-music", @"spotify", @"lrclib" ]));
    // Its own switch; and Offline Only drops it (Spotify fetches it from its API).
    CL_ASSERT_EQ(SpotifyIdentifiers(nil, NO, NO),
                 (@[ @"embedded", @"apple-music", @"spotify-cache", @"lrclib", @"custom" ]));
    CL_ASSERT_EQ(SpotifyIdentifiers(nil, YES, YES), (@[ @"embedded", @"spotify-cache" ]));
    // Built as the bridge provider.
    NSArray<id<CLLyricsProvider>> *providers =
        [CLProviderFactory providersForIdentifiers:(@[ @"spotify", @"lrclib" ])
                                 customEndpointURL:@""
                              customEndpointHeader:@""
                        customEndpointHeaderValue:@""];
    CL_ASSERT_EQ(IdentifiersOfProviders(providers), (@[ @"spotify", @"lrclib" ]));
    CL_ASSERT_TRUE(providers.count > 0 && [providers[0] isKindOfClass:[CLSpotifyAppProvider class]]);
}

/// The whole point of the split: what the preferences say end to end, identifiers -> providers.
static void TestEndToEnd(void) {
    NSArray<NSString *> *identifiers = Identifiers((@[ @"custom", @"lrclib", @"spotify-cache" ]),
                                                   YES, YES, YES, NO);
    NSArray<id<CLLyricsProvider>> *providers =
        [CLProviderFactory providersForIdentifiers:identifiers
                                 customEndpointURL:@"https://example.invalid/{title}"
                              customEndpointHeader:@""
                        customEndpointHeaderValue:@""];
    CL_ASSERT_EQ(IdentifiersOfProviders(providers), (@[ @"custom", @"lrclib", @"spotify-cache" ]));

    NSArray<id<CLLyricsProvider>> *offline =
        [CLProviderFactory providersForIdentifiers:Identifiers(nil, YES, YES, YES, YES)
                                 customEndpointURL:@"https://example.invalid/{title}"
                              customEndpointHeader:@""
                        customEndpointHeaderValue:@""];
    CL_ASSERT_EQ(IdentifiersOfProviders(offline), (@[ @"spotify-cache" ]));
}

void CLRunProviderFactoryTests(void) {
    CLTestBeginSuite("CLProviderFactory");
    TestDefaultOrder();
    TestOrderIsHonoured();
    TestDedupeAndJunk();
    TestEnableFlags();
    TestOfflineOnly();
    TestProviderInstantiation();
    TestMusicSources();
    TestSpotifySource();
    TestEndToEnd();
}

NS_ASSUME_NONNULL_END
