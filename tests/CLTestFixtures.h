// CLTestFixtures — hand-rolled protobuf wire-format ENCODER used only by the test tool to build
// byte fixtures. Deliberately independent of CLProtobufReader (the code under test): a bug shared
// between an encoder and its decoder would hide itself from every round-trip test, so this writer
// is written from the wire-format spec directly, not by "playing back" the reader's own helpers.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLTestProtoWriter : NSObject

/// Mutable little builder: append field after field, then take -data.
- (void)appendVarintField:(uint32_t)fieldNumber value:(uint64_t)value;
- (void)appendLengthDelimitedField:(uint32_t)fieldNumber bytes:(NSData *)bytes;
- (void)appendLengthDelimitedField:(uint32_t)fieldNumber string:(NSString *)string;
- (void)appendFixed32Field:(uint32_t)fieldNumber value:(uint32_t)value;
- (void)appendFixed64Field:(uint32_t)fieldNumber value:(uint64_t)value;
- (void)appendRawTag:(uint32_t)fieldNumber wireType:(NSUInteger)wireType;   // for malformed fixtures
- (void)appendRawVarint:(uint64_t)value;                                    // for malformed fixtures
- (void)appendRawBytes:(NSData *)bytes;                                     // for malformed fixtures

@property (nonatomic, readonly) NSData *data;

@end

/// Builds one LyricsLine message body: field 1 (start_time_ms, varint) + field 2 (words, string).
/// Pass `hasWords = NO` to build the Spotify "end of lyrics" marker line (timestamp only).
NSData *CLTestBuildLyricsLineMessage(uint64_t startTimeMilliseconds, NSString *_Nullable words, BOOL hasWords);

/// Builds a bare LyricsResponse message body: field 1 (sync_type, varint) + field 2* (lines, repeated).
NSData *CLTestBuildLyricsResponseMessage(uint64_t syncType, NSArray<NSData *> *lineMessages);

/// Wraps a LyricsResponse body as ColorLyricsResponse.lyrics (field 1, length-delimited).
NSData *CLTestBuildColorLyricsResponseMessage(NSData *lyricsResponseMessage);

/// A ready-made, realistic fixture matching docs/research/spotify-local-lyrics.md: a
/// ColorLyricsResponse wrapping a LINE_SYNCED LyricsResponse with `lineCount` worded lines
/// followed by Spotify's trailing empty-text end marker.
NSData *CLTestSpotifyColorLyricsFixture(NSUInteger lineCount);

/// A minimal LRCLIB /api/get JSON success body (as NSData, UTF-8 JSON) for a synced track.
NSData *CLTestLRCLibGetResponseFixture(void);

NS_ASSUME_NONNULL_END
