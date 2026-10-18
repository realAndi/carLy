// CLLRCLibProvider — lyrics from https://lrclib.net. Free, no account, no API key, no token;
// the only etiquette requirement is the Lrclib-Client header, which this provider always sends.
//
// Lookup strategy for a track (stops at the first usable answer):
//   1. GET /api/get?track_name&artist_name&album_name&duration   (album only when known)
//   2. GET /api/get?track_name&artist_name&duration              (on 404, or when 1 had no album)
//   3. GET /api/search?track_name&artist_name                    (on 404, or when duration == 0)
//      -> the candidate with syncedLyrics whose duration is closest to ours, within 3 s.
// Answers: instrumental -> CLLyricsKindInstrumental, syncedLyrics -> parsed synced lyrics (with
// plainText kept alongside), plainLyrics only -> plain, nothing -> (nil, nil). Transport failures
// and unexpected HTTP statuses -> (nil, error). Completion is called exactly once, off the main
// thread (NSURLSession's delegate queue).
#import "CLLyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const CLLRCLibErrorDomain;   // code == HTTP status for unexpected statuses

@interface CLLRCLibProvider : NSObject <CLLyricsProvider>
/// Per-request timeout in seconds. Default 8.
@property (nonatomic) NSTimeInterval timeout;
/// Seconds a /api/search candidate may differ from the track duration. Default 3.
@property (nonatomic) NSTimeInterval durationTolerance;

/// Pure decoders: parsed JSON in, CLLyrics out. No network, no disk, no state beyond `identifier`
/// and `durationTolerance`, safe on any thread. They are the whole of this provider's response
/// handling, exposed so the "instrumental / syncedLyrics / plainLyrics / nothing" branching can be
/// pinned down with fixtures instead of a live server (tests/CLLRCLibProviderTests.m).
/// `entry` is one /api/get object; `results` is a /api/search array, from which the synced
/// candidate closest to `duration` within `durationTolerance` wins (any synced one when duration
/// is 0). nil means "this response carries no usable lyrics".
- (nullable CLLyrics *)lyricsFromEntry:(nullable id)entry;
- (nullable CLLyrics *)lyricsFromSearchResults:(nullable NSArray *)results
                                      duration:(NSTimeInterval)duration;
@end

NS_ASSUME_NONNULL_END
