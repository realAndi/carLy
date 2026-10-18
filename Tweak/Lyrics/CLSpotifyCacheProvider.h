// Lyrics straight out of Spotify's own on-disk caches — Spotify-exact, offline, no keys, no
// network, no Spotify hook. Coverage is opportunistic (Spotify only caches a track's lyrics once
// its Now Playing View has shown them on this phone), so this provider goes *first* in the chain
// and LRCLIB stays the fallback. Format and evidence: docs/research/spotify-local-lyrics.md.
//
// Sources, in order:
//   1. Library/Caches/com.spotify.client/nsurlcache/Cache.db — cached `color-lyrics/v2/track/<id>`
//      response bodies (protobuf), inline or spilled into nsurlcache/fsCachedData.
//   2. Library/Application Support/lyrics_offline.sqlite3 — lyrics of downloaded tracks.
//
// Spotify's databases are in WAL mode and are being written by Spotify while we read, so we never
// open them: each database (plus its -wal and -shm) is copied into
// <NSCachesDirectory>/carLy/spotify/ and only the copy is opened, read-only. The copy is
// skipped while the source's size and mtime are unchanged.
#import "CLLyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface CLSpotifyCacheProvider : NSObject <CLLyricsProvider>

/// "spotify-cache".
@property (nonatomic, readonly) NSString *identifier;

/// All work happens on a private serial queue; the completion is delivered on that queue, except
/// for the "this is not a Spotify track" rejection, which answers synchronously without touching
/// the disk. Never blocks the caller, never throws, answers exactly once.
- (void)fetchLyricsForTrack:(CLTrack *)track completion:(CLLyricsCompletion)completion;

/// Decodes a raw `color-lyrics` protobuf body (a ColorLyricsResponse, or a bare LyricsResponse as
/// stored by lyrics_offline.sqlite3). nil when the body carries no usable lines. Pure function —
/// exposed so the tests/ tool can exercise the decoder with a fixture and no car attached.
+ (nullable CLLyrics *)lyricsFromResponseData:(nullable NSData *)data source:(NSString *)source;

/// Deletes the working copies of Spotify's databases (<NSCachesDirectory>/carLy/spotify).
/// For the "clear cache" maintenance action; the next fetch simply copies again.
+ (void)clearDatabaseCopies;

@end

NS_ASSUME_NONNULL_END
