// CLTTMLParser — Apple Music lyrics TTML (the `ttml` string Apple's `syllable-lyrics` endpoint
// returns) -> CLLyrics. Pure Foundation (NSXMLParser), no UIKit, no private API, no network: tests/
// feeds it fixtures. Format notes and a sample: docs/research/apple-music-lyrics.md.
//
// Synced documents (itunes:timing="Word" or "Line", or no itunes:timing but timed <p>s):
//   * one CLLyricLine per <p>, at the <p>'s `begin` (or its earliest span `begin`, when the <p>
//     has none); a <p> with no usable time is dropped;
//   * the line text is every text node inside the <p>, nested spans included, in document order:
//     adjacent syllable spans join with no space, the whitespace between word spans becomes one
//     space, runs of whitespace collapse, the result is trimmed; <br/> reads as a space;
//   * background vocals (spans with ttm:role="x-bg", and everything inside them) stay in the line,
//     separated from the text on either side by a space;
//   * where the next line begins at least kCLTTMLGapForBlankLine seconds after the latest `end` of
//     every line so far (a <p>'s `end`, else its latest span `end`; in a duet a long line can
//     outlast a shorter one), an empty line is inserted at that `end` (instrumental break), the
//     way LRC files mark one and CLLRCParser keeps it;
//   * lines sorted ascending by time, stable for equal times; lines with empty text dropped;
//   * `plainText` is the document's own stanza text (one row per <p>, a blank row between <div>s).
//   A synced document whose timed lines are all empty falls back to its untimed text as plain.
// Unsynced documents (itunes:timing="None", or nothing timed at all): plain lyrics, one line per
// <p>, a blank line between <div>s (stanzas), trimmed.
// nil for nil/empty input, XML that does not parse, a root element other than <tt>, a document
// with no lyric text, any <!DOCTYPE>/<!ENTITY> (NSXMLParser still expands internal entities), or
// more than 8M UTF-16 units. A leading BOM and <?xml …?> declaration are stripped first.
// itunes:timing is read from <tt> only, ignoring case; <div>/<body> times and every `dur` are
// ignored; frame and tick clock values ("12f", "100t") are unparseable.
#import "CLLyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// Minimum silence (seconds, from one line's `end` to the next line's `begin`) that gets an empty
/// line inserted.
extern const NSTimeInterval kCLTTMLGapForBlankLine;   // 5.0

@interface CLTTMLParser : NSObject

+ (nullable CLLyrics *)lyricsFromTTML:(nullable NSString *)ttml source:(NSString *)source;

/// TTML clock value -> seconds: "10.018", "1:02.345", "01:02:03.456", "12.3s", "450ms", "1.5m",
/// "0.5h". NAN for nil, empty, negative or unparseable input.
+ (NSTimeInterval)timeFromClockValue:(nullable NSString *)value;

@end

NS_ASSUME_NONNULL_END
