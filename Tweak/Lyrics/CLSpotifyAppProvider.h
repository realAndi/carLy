// Spotify's own lyrics for Spotify tracks, fetched by carLy inside Spotify with Spotify's own
// login (0.9.0). The host side of CLSpotifyBridge: it writes a request for the track's Spotify id,
// posts the request notification and waits for CLSpotifyLyricsService's answer (notification, plus
// a 0.25 s poll in case the notification is lost).
//
// How long it waits depends on status.json:
//   * no status, or the pid in it is gone → no carLy in Spotify (Spotify not restarted since
//     the install, the tweak disabled there): answers at once with CLSpotifyAppProviderErrorNotRunning;
//   * a live Spotify that has not seen its own login yet → `unauthorizedTimeout` (default 3 s);
//   * otherwise → `timeout` (default 6 s).
// Answers: Spotify's lyrics → them (source "spotify"); "Spotify has none" → (nil, nil), a clean miss;
// anything else (an error over there, the wait running out, the bridge unwritable) → (nil, error),
// which keeps the chain's all-miss result out of the negative cache.
//
// A track without a Spotify id (anything not from Spotify) is an immediate (nil, nil) without touching
// the disk. Completion is called exactly once, on a private queue.
#import "CLLyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const CLSpotifyAppProviderErrorDomain;

typedef NS_ENUM(NSInteger, CLSpotifyAppProviderError) {
    CLSpotifyAppProviderErrorNotRunning = 1,   ///< no live carLy in Spotify
    CLSpotifyAppProviderErrorBridge,           ///< the request could not be written
    CLSpotifyAppProviderErrorTimedOut,         ///< Spotify did not answer in time
    CLSpotifyAppProviderErrorSpotify,          ///< Spotify answered with an error (message in the description)
};

@interface CLSpotifyAppProvider : NSObject <CLLyricsProvider>

/// "spotify".
@property (nonatomic, readonly) NSString *identifier;
/// Seconds to wait for a Spotify that has its login. Default 6.
@property (nonatomic) NSTimeInterval timeout;
/// Seconds to wait for a Spotify that has not seen its login yet. Default 3.
@property (nonatomic) NSTimeInterval unauthorizedTimeout;

- (void)fetchLyricsForTrack:(CLTrack *)track completion:(CLLyricsCompletion)completion;

@end

NS_ASSUME_NONNULL_END
