// CLLRCParser — LRC (and "enhanced LRC") text -> sorted CLLyricLine array. Pure Foundation, no
// network, no UIKit: exercised by the on-device test tool without a car.
//
// Accepted timestamp shapes, one or several per line:
//   [mm:ss] [mm:ss.x] [mm:ss.xx] [mm:ss.xxx] [mm:ss:xx] (the ':' hundredths variant)
//   [hh:mm:ss.xx] is accepted as well; the first separator must be ':'.
// Metadata tags ([ar:], [ti:], [al:], [by:], [length:], ...) are skipped. [offset:<±ms>] is
// applied to every line: per the LRC convention a positive offset makes the lyrics appear
// *earlier*, so the effective time is (timestamp - offset/1000), clamped at 0. The tag is
// honoured wherever it appears in the file.
// Lines whose text is empty are kept — they mark instrumental gaps and the sync engine needs
// them to blank the overlay. Word-level "<mm:ss.xx>" tags inside the text are stripped.
// CRLF, CR and LF line endings all work.
#import "CLLyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface CLLRCParser : NSObject
/// Parsed lines sorted ascending by time (stable for equal timestamps). nil when the input is
/// not a string, is empty, or contains no timed line at all.
+ (nullable NSArray<CLLyricLine *> *)parse:(NSString *)lrc;
/// Convenience for keeping a plain-text copy of synced lyrics (one line per entry, blanks kept).
+ (NSString *)plainTextFromLines:(nullable NSArray<CLLyricLine *> *)lines;
@end

NS_ASSUME_NONNULL_END
