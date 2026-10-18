// What carLy, inside Spotify, has learnt about how Spotify talks to its own API (0.9.0).
//
// Spotify signs every request to its API hosts (<region>-spclient.spotify.com, spclient.wg.spotify.com)
// with `Authorization: Bearer <token>` and a `client-token`, both minted and refreshed by Spotify's
// own login code. Rather than reimplement any of that, the NSURLSessionTask hook
// (Hooks/SpotifyAppHooks.x) shows every such request to this class, which keeps the newest headers
// in memory and replays them on one request of our own: GET
// https://<that host>/color-lyrics/v2/track/<id>, the request Spotify's lyrics screen makes
// (docs/research/spotify-local-lyrics.md). Once Spotify's own lyrics request has been seen, its
// host, query and headers are copied exactly (protobuf, like the app); until then the headers of any
// authorised request go to the same path with the web player's well-known shape,
// `?format=json&vocalRemoval=false&market=from_token` and `Accept: application/json`.
// CLSpotifyColorLyricsDecoder reads either answer.
//
// The headers live only in this object's memory, inside Spotify's process: they are never written to
// disk, never logged and never handed to the bridge. Thread-safe; -observeRequest: is cheap for any
// request that is not an authorised API request, because it runs on every task Spotify resumes.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// NSURLProtocol property our own lyrics requests carry, so the hook does not learn from them.
extern NSString *const CLSpotifyOwnRequestProperty;

@interface CLSpotifyRequestTemplate : NSObject

+ (instancetype)sharedTemplate;
/// A fresh, unshared template (tests).
- (instancetype)init;

/// *.spclient.spotify.com, spclient.wg.spotify.com and the like: a host containing "spclient" under
/// spotify.com. Case-insensitive.
+ (BOOL)isSpotifyAPIHost:(nullable NSString *)host;

/// Learns from one of Spotify's outgoing requests. Ignores anything that is not an https request to
/// an API host with a Bearer authorisation, our own requests, and a token the API has refused.
/// Returns YES when what we would send changed: a first or a new token, another host, Spotify's own
/// lyrics request seen for the first time.
- (BOOL)observeRequest:(nullable NSURLRequest *)request;

@property (nonatomic, readonly) BOOL hasAuthorization;
/// The host our lyrics request goes to (nil before the first authorised request).
@property (nonatomic, readonly, copy, nullable) NSString *host;
/// Unix time the current token was last seen on one of Spotify's requests; 0 without one.
@property (nonatomic, readonly) NSTimeInterval authorizationSeenAt;
/// YES once Spotify's own color-lyrics request has been seen (and is what we copy).
@property (nonatomic, readonly) BOOL hasLyricsRequestShape;

/// GET color-lyrics/v2/track/<trackID> with Spotify's headers, or nil without a token or with an
/// invalid track id (1–64 base-62 characters).
- (nullable NSURLRequest *)lyricsRequestForTrackID:(NSString *)trackID;

/// The API refused the token `request` carried (401): forget it, and ignore it if an older request of
/// Spotify's still carries it. The next fresh token Spotify uses replaces it.
- (void)rejectAuthorizationOfRequest:(nullable NSURLRequest *)request;

@end

NS_ASSUME_NONNULL_END
