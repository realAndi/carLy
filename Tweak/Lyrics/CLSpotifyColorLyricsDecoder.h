// Decodes Spotify's own lyrics: the body of `color-lyrics/v2/track/<id>`, in either of the two
// shapes Spotify serves it. Pure functions, no I/O, safe on any thread.
//
//   * protobuf (what the iOS app asks for and what lands in its NSURLCache; the wire layout and the
//     evidence are in docs/research/spotify-local-lyrics.md):
//       ColorLyricsResponse { LyricsResponse lyrics = 1; Colors colors = 2; }
//       LyricsResponse      { int32 sync_type = 1; repeated LyricsLine lines = 2; ... }
//       LyricsLine          { int64 start_time_ms = 1; string words = 2; ... }
//     lyrics_offline.sqlite3 stores a bare LyricsResponse, which decodes too.
//   * JSON (what the web player asks for with `format=json`; the API answers in it when the request
//     says so, and the decoder takes it so a change of `Accept` on Spotify's side cannot blank the
//     lyrics):
//       { "lyrics": { "syncType": "LINE_SYNCED", "lines": [ { "startTimeMs": "4400",
//         "words": "..." }, ... ] }, "colors": { ... } }
//
// Both shapes follow the same rules: a LINE_SYNCED (or SYLLABLE_SYNCED) answer becomes synced lyrics
// and keeps Spotify's trailing wordless end marker as an empty line (it is the cue to blank the last
// line); anything else is plain text; timings without a single word are not lyrics.
#import "CLLyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface CLSpotifyColorLyricsDecoder : NSObject

/// JSON when the first non-blank byte is '{', protobuf otherwise. nil when the body carries no usable
/// lines. `source` becomes the lyrics' source identifier.
+ (nullable CLLyrics *)lyricsFromResponseData:(nullable NSData *)data source:(NSString *)source;

/// The protobuf shape only (a ColorLyricsResponse, or a bare LyricsResponse).
+ (nullable CLLyrics *)lyricsFromProtobufData:(nullable NSData *)data source:(NSString *)source;

/// The JSON shape only, already parsed: the whole response object, or just its "lyrics" object.
+ (nullable CLLyrics *)lyricsFromJSONObject:(nullable id)object source:(NSString *)source;

@end

NS_ASSUME_NONNULL_END
