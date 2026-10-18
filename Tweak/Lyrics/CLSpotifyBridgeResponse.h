// One answer carLy-in-Spotify hands back to carLy-in-the-host through CLSpotifyBridge
// (0.9.0): Spotify's lyrics for a track, "Spotify has none", or "could not ask Spotify". A value
// type with a JSON round trip; no I/O.
//
// On disk (responses/<trackID>.json):
//   { "v": 1, "status": "lyrics" | "none" | "error", "lyrics": <CLLyrics dictionaryRepresentation>,
//     "message": <string>, "http": <HTTP status, 0 when no request was made>, "at": <unix seconds> }
#import "CLLyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CLSpotifyBridgeResponseStatus) {
    CLSpotifyBridgeResponseStatusLyrics = 1,   ///< `lyrics` is set (synced or plain)
    CLSpotifyBridgeResponseStatusNoLyrics,     ///< Spotify answered and has no lyrics for the track
    CLSpotifyBridgeResponseStatusError,        ///< no answer worth caching: no login yet, 401, 5xx, offline
};

@interface CLSpotifyBridgeResponse : NSObject

@property (nonatomic, readonly) CLSpotifyBridgeResponseStatus status;
@property (nonatomic, readonly, nullable) CLLyrics *lyrics;
/// Why, for the log (errors only). Never contains a header, a token or lyrics text.
@property (nonatomic, readonly, copy, nullable) NSString *message;
@property (nonatomic, readonly) NSInteger httpStatus;
@property (nonatomic, readonly) NSTimeInterval respondedAt;

/// nil when `lyrics` is nil or of kind none: there is nothing to hand over.
+ (nullable instancetype)responseWithLyrics:(nullable CLLyrics *)lyrics httpStatus:(NSInteger)httpStatus;
+ (instancetype)noLyricsWithHTTPStatus:(NSInteger)httpStatus;
+ (instancetype)errorWithMessage:(nullable NSString *)message httpStatus:(NSInteger)httpStatus;

- (NSDictionary *)dictionaryRepresentation;
/// Defensive: an unknown version, an unknown status or a "lyrics" status without decodable lyrics
/// all yield nil.
+ (nullable instancetype)responseWithDictionary:(nullable NSDictionary *)dictionary;

@end

NS_ASSUME_NONNULL_END
