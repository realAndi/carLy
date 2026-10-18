// Turns the resolved "Sources" preferences into a provider chain.
//
// This used to live as a static function inside Tweak.x, where nothing could reach it: a %ctor-
// installed Logos file is not part of the tests tool, so the rules below — the user's order,
// each provider's own enable flag, offline-only, unknown identifiers, duplicates — were only
// exercised by plugging a real phone into a real car. It is a plain class so that
// tests/CLProviderFactoryTests.m can assert on it instead.
//
// Split in two on purpose: resolving *which* providers should run is pure (strings in, strings
// out) and is where all the rules live; building them is a one-liner per identifier.
#import <Foundation/Foundation.h>
#import "Lyrics/CLLyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// The identifiers understood in `providerOrder`.
extern NSString *const CLProviderIdentifierEmbedded;       ///< "embedded" (0.8.0)
extern NSString *const CLProviderIdentifierAppleMusic;     ///< "apple-music" (0.8.0)
extern NSString *const CLProviderIdentifierSpotify;        ///< "spotify" (0.9.0)
extern NSString *const CLProviderIdentifierSpotifyCache;   ///< "spotify-cache"
extern NSString *const CLProviderIdentifierLRCLib;         ///< "lrclib"
extern NSString *const CLProviderIdentifierCustom;         ///< "custom"

@interface CLProviderFactory : NSObject

/// The default order when `providerOrder` is missing or empty: the song's own lyrics first
/// (embedded, then Apple Music's for Apple Music songs, then Spotify's for Spotify songs), then
/// Spotify's cache, then the community and custom sources.
@property (class, nonatomic, readonly) NSArray<NSString *> *defaultOrder;

/// Which providers should run, in order. Pure function of its arguments:
///   * entries are lowercased, and an identifier that appears twice is kept only the first time;
///   * an entry that is not a string, is empty, or is not a known identifier is skipped (the
///     unknown one is logged once per call at info level);
///   * a known identifier the order does not list does not run — except the ones added after the
///     Source Order page shipped ("embedded" and "apple-music" in 0.8.0, "spotify" in 0.9.0): an
///     older saved order cannot list them, so a missing one is inserted right before the first
///     listed source that +defaultOrder puts after it (at the end when there is none). For an
///     order saved by 0.8.x that puts "spotify" just before "spotify-cache", or before "lrclib"
///     when the user moved that up;
///   * a provider whose own enable flag is NO is skipped;
///   * `offlineOnly` drops everything that would touch the network, which leaves the on-disk
///     sources: embedded lyrics and the Spotify cache (PLAN.md §3.2). "spotify" is a network
///     source: Spotify fetches the lyrics from its API;
///   * an empty or nil `order` means +defaultOrder.
/// An empty result is legitimate and means "no source is available"; the chain treats that as a
/// plain miss.
+ (NSArray<NSString *> *)identifiersForOrder:(nullable NSArray *)order
                             embeddedEnabled:(BOOL)embeddedEnabled
                           appleMusicEnabled:(BOOL)appleMusicEnabled
                        spotifyLyricsEnabled:(BOOL)spotifyLyricsEnabled
                         spotifyCacheEnabled:(BOOL)spotifyCacheEnabled
                               lrclibEnabled:(BOOL)lrclibEnabled
                       customEndpointEnabled:(BOOL)customEndpointEnabled
                                 offlineOnly:(BOOL)offlineOnly;

/// Instantiates the providers named by `identifiers`, in that order. A custom endpoint whose URL
/// template is empty or not http(s) leaves its provider inert, and an inert provider is left out
/// entirely rather than put in the chain to delay every miss by one step.
+ (NSArray<id<CLLyricsProvider>> *)providersForIdentifiers:(nullable NSArray<NSString *> *)identifiers
                                         customEndpointURL:(nullable NSString *)customEndpointURL
                                    customEndpointHeader:(nullable NSString *)headerName
                              customEndpointHeaderValue:(nullable NSString *)headerValue;

@end

NS_ASSUME_NONNULL_END
