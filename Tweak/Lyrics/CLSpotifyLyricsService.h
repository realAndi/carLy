// carLy's one job inside Spotify (0.9.0): answer the CarPlay host's lyrics requests with
// Spotify's own lyrics.
//
//   host: requests/<id>.json + spotify.request notification   (CLSpotifyAppProvider)
//   here: GET color-lyrics/v2/track/<id> with Spotify's own login (CLSpotifyRequestTemplate)
//         → responses/<id>.json + spotify.response notification
//
// A request waits here while Spotify has not made an authorised API request yet (the host gives up
// on its own after a few seconds, and status.json tells it not to wait long). Answers:
//   200 with lines    → lyrics (synced or plain), decoded by CLSpotifyColorLyricsDecoder
//   200 empty, 204, 404 → "Spotify has no lyrics for this track"
//   401               → error, and the token is dropped until Spotify uses a fresh one
//   anything else, a transport failure, an undecodable body → error (the host never caches those)
//
// Nothing here runs unless the host asks: no polling, no fetching ahead. Our own NSURLSession is
// ephemeral (no cache, no cookies) and our requests are tagged so the hook does not learn from them.
// Foundation only; every method is safe on any thread; the work happens on one private serial queue.
#import <Foundation/Foundation.h>

@class CLSpotifyRequestTemplate;

NS_ASSUME_NONNULL_BEGIN

@interface CLSpotifyLyricsService : NSObject

/// The service the tweak runs in Spotify, on +[CLSpotifyRequestTemplate sharedTemplate].
+ (instancetype)sharedService;

/// Test seam: a service on its own template and, optionally, its own session configuration (e.g.
/// one whose protocolClasses serve canned answers). nil = an ephemeral configuration.
- (instancetype)initWithRequestTemplate:(CLSpotifyRequestTemplate *)requestTemplate
                   sessionConfiguration:(nullable NSURLSessionConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) CLSpotifyRequestTemplate *requestTemplate;

/// Starts listening for the host's requests, writes status.json and answers anything already
/// waiting. Idempotent.
- (void)start;
/// Stops listening, cancels fetches in flight and removes status.json, so the host stops asking.
- (void)stop;
@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// The template learnt something (first token, a refreshed one, another host): refresh status.json
/// and answer requests that were waiting for a login.
- (void)requestTemplateDidChange;

/// Answers whatever is in requests/ now (what the request notification triggers).
- (void)processPendingRequests;

@end

NS_ASSUME_NONNULL_END
