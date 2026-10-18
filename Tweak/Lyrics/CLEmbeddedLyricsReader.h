// CLEmbeddedLyricsReader — lyrics stored with the song itself: in the audio file's tags, or in a
// sidecar .lrc file next to it. Pure Foundation, no AVFoundation, no network, no UIKit: every
// format below is read by hand from the bytes, so tests/ can feed it fixtures without a car.
//
// Tags read (research: docs/research/embedded-lyrics.md):
//   ID3v2.2 / 2.3 / 2.4 — USLT/ULT (unsynced text), SYLT/SLT (synced, millisecond stamps only),
//     TXXX/TXX whose description names lyrics. Found at the start of MP3, AAC (ADTS) and FLAC
//     files, and in the "id3 " chunk of WAV and the "ID3 " chunk of AIFF.
//   MP4 (M4A, ALAC, M4B) — moov/udta/meta/ilst "©lyr", and iTunes free-form "----" atoms whose name
//     is a lyrics field.
//   FLAC — VORBIS_COMMENT fields LYRICS, UNSYNCEDLYRICS, SYNCEDLYRICS (and their spellings).
//   Ogg Vorbis / Opus — the same Vorbis comment fields.
// Text that holds LRC timestamps (many taggers store synced lyrics as LRC in USLT or LYRICS)
// becomes synced lyrics; anything else becomes plain lyrics. When a file holds several
// candidates, the first synced one wins, else the first plain one.
//
// Every length read from the file is checked against the bytes actually present, and the work per
// file is capped; a truncated or hostile file yields nil or whatever complete tags precede the
// damage, never a crash or an out-of-bounds read.
#import "CLLyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface CLEmbeddedLyricsReader : NSObject

/// Lyrics from the tags of a whole audio file (pass memory-mapped data for large files; only the
/// tag bytes are touched). nil when the format is not recognised or it carries no lyrics.
+ (nullable CLLyrics *)lyricsFromAudioData:(nullable NSData *)data source:(NSString *)source;

/// Lyrics text as a tag or a .lrc file stores it: LRC timestamps -> synced, otherwise plain
/// (with stray LRC header tags such as "[ar:...]" dropped). nil when nothing is left.
+ (nullable CLLyrics *)lyricsFromText:(nullable NSString *)text source:(NSString *)source;

/// Decodes a sidecar text file: UTF-8 (with or without BOM), UTF-16 with BOM, and anything else
/// as Windows-1252. nil for empty data; @"" for a bare BOM.
+ (nullable NSString *)stringFromTextData:(nullable NSData *)data;

@end

NS_ASSUME_NONNULL_END
