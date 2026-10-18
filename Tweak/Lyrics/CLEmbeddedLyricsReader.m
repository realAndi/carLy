// CLEmbeddedLyricsReader.m — see CLEmbeddedLyricsReader.h for what is read. Hand-rolled readers over
// the raw bytes, in the defensive style of Util/CLProtobufReader.m:
//   * offsets are size_t values that never exceed the length of the buffer they index. A length
//     read from the file is compared with the bytes left (`length - offset`) before it is added to
//     an offset, so offset arithmetic cannot overflow and nothing is read out of bounds;
//   * the only recursion is the MP4 atom walk, capped at kCLMaxAtomDepth;
//   * one work budget (kCLMaxSteps) is shared by every ID3 frame, MP4 atom, RIFF/AIFF chunk, FLAC
//     block, Ogg page, Vorbis comment and SYLT entry, and the scan stops at the first synced
//     candidate (nothing later in the file can beat it);
//   * only tag bytes are touched: MP4 skips `mdat` by its header, Ogg stops after the comment
//     packet, ID3 reads the tag and nothing after it. Whole-tag unsynchronisation (ID3v2.2/2.3)
//     copies at most kCLMaxUnsyncBytes; a single lyrics value larger than kCLMaxTextBytes is
//     ignored.
//
// Decisions worth knowing:
//   Synced or plain (+lyricsFromText:source:) — "content lines" are the non-blank lines that are
//     not LRC header tags; a line is "timed" when it starts with an LRC timestamp. The text is
//     synced when it has a timed line and either every content line is timed, or at least two are
//     and they make up at least half of the content lines. A plain lyric with one stray "[00:00]"
//     stays plain (stamp and all); a one-line LRC is still synced. A synced text whose lines are
//     all empty is nil.
//   LRC header lines dropped from plain text: a line that is exactly one "[key:value]" tag whose
//     key is a known LRC tag (ar ti al au by re ve la id key lang tool length offset language, any
//     case) or any other all-lowercase ASCII word. "[Chorus: Artist]" section labels stay.
//   Lyrics field names (TXXX description, MP4 "----" name, Vorbis key), case-insensitive: LYRICS,
//     UNSYNCEDLYRICS, SYNCEDLYRICS, their spellings with a space or '_' ("UNSYNCED LYRICS"), and
//     LYRICS-<lang> / LYRICS:<lang> / LYRICS_<lang> with a 2-3 letter <lang>.
//   SYLT — only millisecond stamps (format 2) and content types 0-2 (other, lyrics, transcription)
//     are read. By default each entry is one line: text trimmed, line breaks inside it joined with
//     a space, empty entries kept as blank gap lines. When the frame is word/syllable-timed — some
//     but fewer than half of the visible entries contain a line break, and visible entries average
//     at most kCLSYLTWordAverageChars characters — the entries are concatenated and cut into lines
//     at the line breaks; each line takes the time of its first visible entry, and an entry that
//     is empty or only a line break becomes a blank gap line at its time. Lines are sorted by time
//     (stable). A SYLT whose stamps are all equal carries no timing and is read as plain text.
//   ID3v2.4 frame sizes: synchsafe, except that a size with a high bit set can only be a plain
//     (2.3-style) size, and when both readings are possible and differ the plain one is used only
//     if the synchsafe one does not end on a frame boundary and the plain one does (iTunes wrote
//     2.4 tags with 2.3 sizes).
//   UTF-16 without a BOM (ID3 encoding 1) takes the byte order of the frame's last BOM, else
//     little-endian. Single-byte text (ID3 encoding 0, text files that are not UTF) is decoded as
//     Windows-1252, falling back to ISO-8859-1 for the five bytes 1252 leaves undefined; invalid
//     UTF-8 falls back the same way.
//
// Not read: ID3v2 tags appended at the end of a file, Lyrics3, APE tags, compressed or encrypted
// ID3 frames, SYLT with MPEG-frame stamps, QuickTime `keys`-indexed metadata, `udta/meta` inside a
// `trak`, Ogg Speex/Theora comments, Matroska/WebM, RF64 and W64.
#import "CLEmbeddedLyricsReader.h"
#import "CLLRCParser.h"
#import <string.h>

static const NSUInteger kCLMaxSteps = 65536;
static const NSUInteger kCLMaxAtomDepth = 8;
static const NSUInteger kCLMaxID3Tags = 4;               // stacked ID3v2 tags at the start of a file
static const NSUInteger kCLMaxSYLTEntries = 20000;
static const NSUInteger kCLMaxOggPages = 8192;
static const NSUInteger kCLSYLTWordAverageChars = 12;
static const size_t kCLMaxUnsyncBytes = 16u << 20;
static const size_t kCLMaxTextBytes = 4u << 20;
static const size_t kCLMaxOggPacketBytes = 16u << 20;
static const size_t kCLMaxFieldNameBytes = 256;

#define CLFourCC(a, b, c, d) \
    (((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | ((uint32_t)(c) << 8) | (uint32_t)(d))

static const uint32_t kCLAtomMoov = CLFourCC('m', 'o', 'o', 'v');
static const uint32_t kCLAtomUdta = CLFourCC('u', 'd', 't', 'a');
static const uint32_t kCLAtomMeta = CLFourCC('m', 'e', 't', 'a');
static const uint32_t kCLAtomIlst = CLFourCC('i', 'l', 's', 't');
static const uint32_t kCLAtomLyrics = CLFourCC(0xA9, 'l', 'y', 'r');
static const uint32_t kCLAtomFreeform = CLFourCC('-', '-', '-', '-');
static const uint32_t kCLAtomName = CLFourCC('n', 'a', 'm', 'e');
static const uint32_t kCLAtomData = CLFourCC('d', 'a', 't', 'a');

#pragma mark - Bytes

static inline uint32_t CLReadBE24(const uint8_t *p) {
    return ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8) | (uint32_t)p[2];
}

static inline uint32_t CLReadBE32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static inline uint64_t CLReadBE64(const uint8_t *p) {
    return ((uint64_t)CLReadBE32(p) << 32) | (uint64_t)CLReadBE32(p + 4);
}

static inline uint32_t CLReadLE32(const uint8_t *p) {
    return ((uint32_t)p[3] << 24) | ((uint32_t)p[2] << 16) | ((uint32_t)p[1] << 8) | (uint32_t)p[0];
}

static inline BOOL CLIsSynchsafe(const uint8_t *p) {
    return ((p[0] | p[1] | p[2] | p[3]) & 0x80) == 0;
}

static inline uint32_t CLReadSynchsafe32(const uint8_t *p) {
    return ((uint32_t)(p[0] & 0x7F) << 21) | ((uint32_t)(p[1] & 0x7F) << 14) |
           ((uint32_t)(p[2] & 0x7F) << 7) | (uint32_t)(p[3] & 0x7F);
}

#pragma mark - Text

/// Windows-1252 (a superset of ISO-8859-1's printable range), else ISO-8859-1, which accepts every
/// byte. Never nil.
static NSString *CLStringFromSingleByte(const uint8_t *bytes, size_t length) {
    if (length == 0) return @"";
    NSString *string = [[NSString alloc] initWithBytes:bytes length:length
                                              encoding:NSWindowsCP1252StringEncoding];
    if (!string) {
        string = [[NSString alloc] initWithBytes:bytes length:length encoding:NSISOLatin1StringEncoding];
    }
    return string ?: @"";
}

/// UTF-8 with an optional BOM; invalid UTF-8 is read as single-byte text. Never nil.
static NSString *CLStringFromUTF8(const uint8_t *bytes, size_t length) {
    if (length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
        bytes += 3;
        length -= 3;
    }
    if (length == 0) return @"";
    NSString *string = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    return string ?: CLStringFromSingleByte(bytes, length);
}

/// UTF-16 code units in the given byte order, no BOM handling. An odd trailing byte is dropped and
/// unpaired surrogates are kept as they are, so this only fails when memory does.
static NSString *CLStringFromUTF16Units(const uint8_t *bytes, size_t length, BOOL bigEndian) {
    size_t count = length / 2;
    if (count == 0) return @"";
    unichar *units = malloc(count * sizeof(unichar));
    if (!units) return nil;
    for (size_t i = 0; i < count; i++) {
        uint8_t first = bytes[2 * i];
        uint8_t second = bytes[2 * i + 1];
        units[i] = bigEndian ? (unichar)((first << 8) | second) : (unichar)((second << 8) | first);
    }
    NSString *string = [NSString stringWithCharacters:units length:count];
    free(units);
    return string;
}

/// Reads a UTF-16 BOM at the start of `bytes` into `*bigEndian`; NO (and `*bigEndian` untouched)
/// when there is none.
static BOOL CLReadUTF16BOM(const uint8_t *bytes, size_t length, BOOL *bigEndian) {
    if (length < 2) return NO;
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) { *bigEndian = NO; return YES; }
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) { *bigEndian = YES; return YES; }
    return NO;
}

/// UTF-16 with an optional BOM. `*bigEndian` is the byte order assumed without one, and is updated
/// when a BOM is found.
static NSString *CLStringFromUTF16(const uint8_t *bytes, size_t length, BOOL *bigEndian) {
    if (CLReadUTF16BOM(bytes, length, bigEndian)) {
        bytes += 2;
        length -= 2;
    }
    return CLStringFromUTF16Units(bytes, length, *bigEndian);
}

/// YES for a tag field name that holds lyrics (see the file comment for the list).
static BOOL CLIsLyricsFieldName(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return NO;
    static NSSet<NSString *> *names = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithObjects:@"LYRICS", @"UNSYNCEDLYRICS", @"UNSYNCED LYRICS",
                 @"UNSYNCED_LYRICS", @"SYNCEDLYRICS", @"SYNCED LYRICS", @"SYNCED_LYRICS", nil];
    });
    NSString *key = [[name stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if ([names containsObject:key]) return YES;

    NSUInteger length = key.length;
    if (length < 9 || length > 10 || ![key hasPrefix:@"LYRICS"]) return NO;
    unichar separator = [key characterAtIndex:6];
    if (separator != '-' && separator != ':' && separator != '_') return NO;
    for (NSUInteger i = 7; i < length; i++) {
        unichar c = [key characterAtIndex:i];
        if (c < 'A' || c > 'Z') return NO;
    }
    return YES;
}

#pragma mark - Text -> lyrics

/// "[ar:Artist]"-style LRC header line (trimmed input); see the file comment.
static BOOL CLIsLRCHeaderLine(NSString *line) {
    NSUInteger length = line.length;
    if (length < 4 || [line characterAtIndex:0] != '[' || [line characterAtIndex:length - 1] != ']') {
        return NO;
    }
    if ([line rangeOfString:@"]"].location != length - 1) return NO;   // one tag filling the line
    NSUInteger colon = [line rangeOfString:@":"].location;
    if (colon == NSNotFound || colon < 3 || colon > 17) return NO;     // key of 2...16 letters

    NSString *key = [line substringWithRange:NSMakeRange(1, colon - 1)];
    BOOL lowercase = YES;
    for (NSUInteger i = 0; i < key.length; i++) {
        unichar c = [key characterAtIndex:i];
        if (c >= 'a' && c <= 'z') continue;
        if (c >= 'A' && c <= 'Z') { lowercase = NO; continue; }
        return NO;
    }
    if (lowercase) return YES;

    static NSSet<NSString *> *known = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        known = [NSSet setWithObjects:@"ar", @"ti", @"al", @"au", @"by", @"re", @"ve", @"la", @"id",
                 @"key", @"lang", @"tool", @"length", @"offset", @"language", nil];
    });
    return [known containsObject:key.lowercaseString];
}

static CLLyrics *CLLyricsFromText(NSString *text, NSString *source) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return nil;
    NSString *src = [source isKindOfClass:[NSString class]] ? source : @"";
    if ([text hasPrefix:@"﻿"]) text = [text substringFromIndex:1];

    NSString *normalized = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
                            stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSCharacterSet *blank = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *rawLines =
        [normalized componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    NSMutableArray<NSString *> *kept = [NSMutableArray arrayWithCapacity:rawLines.count];
    NSUInteger contentLines = 0;
    NSUInteger timedLines = 0;
    for (NSString *raw in rawLines) {
        @autoreleasepool {
            NSString *trimmed = [raw stringByTrimmingCharactersInSet:blank];
            if (trimmed.length == 0) {
                [kept addObject:@""];
                continue;
            }
            if (CLIsLRCHeaderLine(trimmed)) continue;
            contentLines++;
            if ([trimmed hasPrefix:@"["] && [CLLRCParser parse:trimmed].count > 0) timedLines++;
            [kept addObject:raw];
        }
    }

    BOOL synced = timedLines > 0 &&
                  (timedLines == contentLines || (timedLines >= 2 && timedLines * 2 >= contentLines));
    if (synced) {
        NSArray<CLLyricLine *> *lines = [CLLRCParser parse:normalized];
        BOOL visible = NO;
        for (CLLyricLine *line in lines) {
            if ([line.text stringByTrimmingCharactersInSet:blank].length > 0) { visible = YES; break; }
        }
        if (!visible) return nil;
        CLLyrics *lyrics = [CLLyrics syncedWithLines:lines source:src];
        lyrics.plainText = [CLLRCParser plainTextFromLines:lines];
        return lyrics;
    }

    NSString *plain = [[kept componentsJoinedByString:@"\n"] stringByTrimmingCharactersInSet:blank];
    if (plain.length == 0) return nil;
    return [CLLyrics plainWithText:plain source:src];
}

#pragma mark - Scan state

typedef struct {
    __unsafe_unretained NSString *source;
    __unsafe_unretained NSMutableArray<CLLyrics *> *candidates;
    NSUInteger stepsLeft;
    BOOL foundSynced;
} CLScan;

/// Spends one unit of the work budget. NO once it is spent or a synced candidate has been found,
/// which ends every walk.
static BOOL CLScanStep(CLScan *scan) {
    if (scan->foundSynced || scan->stepsLeft == 0) return NO;
    scan->stepsLeft--;
    return YES;
}

static void CLScanAddLyrics(CLScan *scan, CLLyrics *lyrics) {
    if (!lyrics || lyrics.kind == CLLyricsKindNone) return;
    [scan->candidates addObject:lyrics];
    if (lyrics.kind == CLLyricsKindSynced) scan->foundSynced = YES;
}

static void CLScanAddText(CLScan *scan, NSString *text) {
    if (text.length == 0) return;
    CLScanAddLyrics(scan, CLLyricsFromText(text, scan->source));
}

#pragma mark - Vorbis comments (FLAC, Ogg Vorbis, Opus)

/// vendor length (LE32), vendor, count (LE32), then count x [LE32 length, "KEY=value"].
static void CLReadVorbisComment(const uint8_t *bytes, size_t length, CLScan *scan) {
    if (length < 4) return;
    uint64_t vendorLength = CLReadLE32(bytes);
    if (vendorLength > length - 4) return;
    size_t offset = 4 + (size_t)vendorLength;
    if (length - offset < 4) return;
    uint32_t count = CLReadLE32(bytes + offset);
    offset += 4;

    for (uint32_t i = 0; i < count && CLScanStep(scan); i++) {
        if (length - offset < 4) return;
        uint64_t commentLength = CLReadLE32(bytes + offset);
        offset += 4;
        if (commentLength > length - offset) return;
        const uint8_t *comment = bytes + offset;
        const uint8_t *equals = commentLength > 0 ? memchr(comment, '=', (size_t)commentLength) : NULL;
        if (equals) {
            size_t keyLength = (size_t)(equals - comment);
            size_t valueLength = (size_t)commentLength - keyLength - 1;
            if (keyLength > 0 && keyLength <= kCLMaxFieldNameBytes && valueLength <= kCLMaxTextBytes) {
                NSString *key = [[NSString alloc] initWithBytes:comment length:keyLength
                                                       encoding:NSASCIIStringEncoding];
                if (CLIsLyricsFieldName(key)) CLScanAddText(scan, CLStringFromUTF8(equals + 1, valueLength));
            }
        }
        offset += (size_t)commentLength;
    }
}

#pragma mark - FLAC

/// `bytes` starts at "fLaC". Metadata blocks: 1 byte (last flag, 7-bit type), BE24 length.
static void CLReadFLAC(const uint8_t *bytes, size_t length, CLScan *scan) {
    if (length < 4) return;
    size_t offset = 4;
    while (length - offset >= 4 && CLScanStep(scan)) {
        uint8_t header = bytes[offset];
        uint8_t type = header & 0x7F;
        size_t blockLength = CLReadBE24(bytes + offset + 1);
        size_t start = offset + 4;
        size_t available = length - start;
        if (type == 127) return;                                   // invalid block type
        if (type == 4) CLReadVorbisComment(bytes + start, MIN(blockLength, available), scan);
        if ((header & 0x80) || blockLength >= available) return;   // last block, or file ends here
        offset = start + blockLength;
    }
}

#pragma mark - ID3v2

typedef NS_ENUM(NSInteger, CLID3FrameKind) {
    CLID3FrameKindOther = 0,
    CLID3FrameKindUSLT,
    CLID3FrameKindSYLT,
    CLID3FrameKindTXXX,
};

static BOOL CLID3IsFrameID(const uint8_t *bytes, size_t length) {
    for (size_t i = 0; i < length; i++) {
        uint8_t c = bytes[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))) return NO;
    }
    return YES;
}

static CLID3FrameKind CLID3KindOfFrame(const uint8_t *frameID, uint8_t major) {
    if (major == 2) {
        if (memcmp(frameID, "ULT", 3) == 0) return CLID3FrameKindUSLT;
        if (memcmp(frameID, "SLT", 3) == 0) return CLID3FrameKindSYLT;
        if (memcmp(frameID, "TXX", 3) == 0) return CLID3FrameKindTXXX;
        return CLID3FrameKindOther;
    }
    if (memcmp(frameID, "USLT", 4) == 0) return CLID3FrameKindUSLT;
    if (memcmp(frameID, "SYLT", 4) == 0) return CLID3FrameKindSYLT;
    if (memcmp(frameID, "TXXX", 4) == 0) return CLID3FrameKindTXXX;
    return CLID3FrameKindOther;
}

/// Reverses unsynchronisation (0xFF 0x00 -> 0xFF). nil only when memory fails.
static NSData *CLID3RemoveUnsynchronisation(const uint8_t *bytes, size_t length) {
    NSMutableData *output = [NSMutableData dataWithLength:length];
    if (!output) return nil;
    if (length == 0) return output;
    uint8_t *destination = output.mutableBytes;
    size_t written = 0;
    for (size_t i = 0; i < length; i++) {
        destination[written++] = bytes[i];
        if (bytes[i] == 0xFF && i + 1 < length && bytes[i + 1] == 0x00) i++;
    }
    output.length = written;
    return output;
}

static BOOL CLID3IsWideEncoding(uint8_t encoding) {
    return encoding == 1 || encoding == 2;
}

/// Splits a terminated string off the front of `bytes`: the text length before the terminator and
/// the offset just past it (both == length when the string is unterminated). Encodings 1 and 2 end
/// with two zero bytes on an even offset, the others with one zero byte.
static void CLID3SplitString(const uint8_t *bytes, size_t length, uint8_t encoding,
                             size_t *outTextLength, size_t *outNext) {
    if (CLID3IsWideEncoding(encoding)) {
        for (size_t i = 0; length - i >= 2; i += 2) {
            if (bytes[i] == 0 && bytes[i + 1] == 0) {
                *outTextLength = i;
                *outNext = i + 2;
                return;
            }
        }
    } else if (length > 0) {
        const uint8_t *zero = memchr(bytes, 0, length);
        if (zero) {
            *outTextLength = (size_t)(zero - bytes);
            *outNext = *outTextLength + 1;
            return;
        }
    }
    *outTextLength = length;
    *outNext = length;
}

/// `*bigEndian` is the UTF-16 byte order to assume without a BOM (encoding 1 only).
static NSString *CLID3DecodeString(const uint8_t *bytes, size_t length, uint8_t encoding, BOOL *bigEndian) {
    switch (encoding) {
        case 0: return CLStringFromSingleByte(bytes, length);
        case 1: return CLStringFromUTF16(bytes, length, bigEndian);
        case 2: { BOOL big = YES; return CLStringFromUTF16(bytes, length, &big); }
        case 3: return CLStringFromUTF8(bytes, length);
        default: return nil;
    }
}

/// The value that follows a terminated descriptor, cut at its own terminator.
static NSString *CLID3ValueAfter(const uint8_t *bytes, size_t length, size_t offset, uint8_t encoding,
                                 BOOL *bigEndian) {
    size_t valueLength = 0;
    size_t ignored = 0;
    CLID3SplitString(bytes + offset, length - offset, encoding, &valueLength, &ignored);
    if (valueLength > kCLMaxTextBytes) return nil;
    return CLID3DecodeString(bytes + offset, valueLength, encoding, bigEndian);
}

/// USLT / ULT: encoding, language[3], terminated descriptor, text.
static void CLID3ReadUSLT(const uint8_t *payload, size_t size, CLScan *scan) {
    if (size < 4 || payload[0] > 3) return;
    uint8_t encoding = payload[0];
    const uint8_t *rest = payload + 4;
    size_t restLength = size - 4;
    size_t descriptorLength = 0;
    size_t next = 0;
    CLID3SplitString(rest, restLength, encoding, &descriptorLength, &next);
    BOOL bigEndian = NO;
    if (encoding == 1) CLReadUTF16BOM(rest, descriptorLength, &bigEndian);
    CLScanAddText(scan, CLID3ValueAfter(rest, restLength, next, encoding, &bigEndian));
}

/// TXXX / TXX: encoding, terminated description, value.
static void CLID3ReadTXXX(const uint8_t *payload, size_t size, CLScan *scan) {
    if (size < 1 || payload[0] > 3) return;
    uint8_t encoding = payload[0];
    const uint8_t *rest = payload + 1;
    size_t restLength = size - 1;
    size_t descriptionLength = 0;
    size_t next = 0;
    CLID3SplitString(rest, restLength, encoding, &descriptionLength, &next);
    if (descriptionLength > kCLMaxFieldNameBytes) return;
    BOOL bigEndian = NO;
    if (!CLIsLyricsFieldName(CLID3DecodeString(rest, descriptionLength, encoding, &bigEndian))) return;
    CLScanAddText(scan, CLID3ValueAfter(rest, restLength, next, encoding, &bigEndian));
}

static void CLAppendSYLTLine(NSMutableArray<CLLyricLine *> *lines, NSString *text, NSTimeInterval time) {
    if (!text) return;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [lines addObject:[CLLyricLine lineWithTime:time text:trimmed]];
}

/// "a\n b" -> "a b": one display line from an entry that holds several.
static NSString *CLJoinedLineParts(NSString *text) {
    NSCharacterSet *blank = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:blank];
        if (trimmed.length) [parts addObject:trimmed];
    }
    return [parts componentsJoinedByString:@" "];
}

/// SYLT entries (raw text, frame order) -> display lines; see the file comment for the rules.
static NSArray<CLLyricLine *> *CLLinesFromSYLTEntries(NSArray<CLLyricLine *> *entries) {
    NSCharacterSet *blank = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSCharacterSet *breaks = [NSCharacterSet newlineCharacterSet];
    NSUInteger visible = 0;
    NSUInteger visibleCharacters = 0;
    NSUInteger breakEntries = 0;
    for (CLLyricLine *entry in entries) {
        NSUInteger characters = [entry.text stringByTrimmingCharactersInSet:blank].length;
        if (characters == 0) continue;
        visible++;
        visibleCharacters += characters;
        if ([entry.text rangeOfCharacterFromSet:breaks].location != NSNotFound) breakEntries++;
    }
    if (visible == 0) return nil;
    BOOL wordTimed = breakEntries > 0 && breakEntries * 2 < visible &&
                     visibleCharacters <= visible * kCLSYLTWordAverageChars;

    NSMutableArray<CLLyricLine *> *lines = [NSMutableArray arrayWithCapacity:entries.count];
    if (!wordTimed) {
        for (CLLyricLine *entry in entries) {
            NSString *text = [entry.text stringByTrimmingCharactersInSet:blank];
            if ([text rangeOfCharacterFromSet:breaks].location != NSNotFound) text = CLJoinedLineParts(text);
            [lines addObject:[CLLyricLine lineWithTime:entry.time text:text]];
        }
    } else {
        NSMutableString *current = nil;
        NSTimeInterval currentTime = 0;
        for (CLLyricLine *entry in entries) {
            NSString *raw = entry.text;
            if ([raw stringByTrimmingCharactersInSet:blank].length == 0) {
                BOOL gap = raw.length == 0 || [raw rangeOfCharacterFromSet:breaks].location != NSNotFound;
                if (!gap) {                     // a spacer between two words
                    [current appendString:raw];
                    continue;
                }
                CLAppendSYLTLine(lines, current, currentTime);
                current = nil;
                if (lines.count == 0 || lines.lastObject.text.length > 0) {
                    [lines addObject:[CLLyricLine lineWithTime:entry.time text:@""]];
                }
                continue;
            }
            NSArray<NSString *> *parts = [raw componentsSeparatedByCharactersInSet:breaks];
            for (NSUInteger i = 0; i < parts.count; i++) {
                if (i > 0) {
                    CLAppendSYLTLine(lines, current, currentTime);
                    current = nil;
                }
                NSString *part = parts[i];
                if (!current) {
                    if ([part stringByTrimmingCharactersInSet:blank].length == 0) continue;
                    current = [NSMutableString string];
                    currentTime = entry.time;
                }
                [current appendString:part];
            }
        }
        CLAppendSYLTLine(lines, current, currentTime);
    }

    [lines sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(CLLyricLine *a, CLLyricLine *b) {
        if (a.time < b.time) return NSOrderedAscending;
        if (a.time > b.time) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return lines;
}

/// SYLT / SLT: encoding, language[3], timestamp format, content type, terminated descriptor, then
/// [terminated text, BE32 time] entries.
static void CLID3ReadSYLT(const uint8_t *payload, size_t size, CLScan *scan) {
    if (size < 6 || payload[0] > 3) return;
    uint8_t encoding = payload[0];
    if (payload[4] != 2) return;   // 2 = milliseconds; 1 = MPEG frames would need the audio
    if (payload[5] > 2) return;    // 0 other, 1 lyrics, 2 transcription; 3+ are events, chords, URLs
    const uint8_t *rest = payload + 6;
    size_t restLength = size - 6;
    size_t textLength = 0;
    size_t next = 0;
    CLID3SplitString(rest, restLength, encoding, &textLength, &next);
    BOOL bigEndian = NO;
    if (encoding == 1) CLReadUTF16BOM(rest, textLength, &bigEndian);

    NSMutableArray<CLLyricLine *> *entries = [NSMutableArray array];
    size_t offset = next;
    while (offset < restLength && entries.count < kCLMaxSYLTEntries && CLScanStep(scan)) {
        size_t remaining = restLength - offset;
        CLID3SplitString(rest + offset, remaining, encoding, &textLength, &next);
        if (remaining - next < 4) break;   // unterminated, or no room for the time stamp
        uint32_t milliseconds = CLReadBE32(rest + offset + next);
        NSString *text = CLID3DecodeString(rest + offset, textLength, encoding, &bigEndian) ?: @"";
        [entries addObject:[CLLyricLine lineWithTime:milliseconds / 1000.0 text:text]];
        offset += next + 4;
    }

    NSArray<CLLyricLine *> *lines = CLLinesFromSYLTEntries(entries);
    if (lines.count == 0) return;
    NSString *plain = [CLLRCParser plainTextFromLines:lines];
    if (lines.count > 1 && lines.firstObject.time == lines.lastObject.time) {
        CLScanAddLyrics(scan, [CLLyrics plainWithText:plain source:scan->source]);   // no real timing
        return;
    }
    CLLyrics *lyrics = [CLLyrics syncedWithLines:lines source:scan->source];
    lyrics.plainText = plain;
    CLScanAddLyrics(scan, lyrics);
}

static void CLID3ReadFrame(CLID3FrameKind kind, uint8_t major, uint16_t flags, BOOL tagUnsynchronised,
                           const uint8_t *payload, size_t size, CLScan *scan) {
    NSData *resynchronised NS_VALID_UNTIL_END_OF_SCOPE = nil;
    if (major == 3) {
        if (flags & 0x00C0) return;                                  // compressed or encrypted
        if (flags & 0x0020) {                                        // grouping identity byte
            if (size < 1) return;
            payload += 1;
            size -= 1;
        }
    } else if (major == 4) {
        if (flags & 0x000C) return;                                  // compressed or encrypted
        if (flags & 0x0040) {                                        // grouping identity byte
            if (size < 1) return;
            payload += 1;
            size -= 1;
        }
        if (flags & 0x0001) {                                        // data length indicator
            if (size < 4) return;
            payload += 4;
            size -= 4;
        }
        if ((flags & 0x0002) || tagUnsynchronised) {
            resynchronised = CLID3RemoveUnsynchronisation(payload, size);
            if (!resynchronised) return;
            payload = resynchronised.bytes;
            size = resynchronised.length;
        }
    }
    switch (kind) {
        case CLID3FrameKindUSLT: CLID3ReadUSLT(payload, size, scan); break;
        case CLID3FrameKindSYLT: CLID3ReadSYLT(payload, size, scan); break;
        case CLID3FrameKindTXXX: CLID3ReadTXXX(payload, size, scan); break;
        case CLID3FrameKindOther: break;
    }
}

/// YES when `end` is a place a v2.4 frame may end: the end of the tag, padding, or the next frame.
static BOOL CLID3v24EndsOnBoundary(const uint8_t *body, size_t bodyLength, uint64_t end) {
    if (end > bodyLength) return NO;
    if (end == bodyLength) return YES;
    if (body[end] == 0) return YES;
    return bodyLength - (size_t)end >= 10 && CLID3IsFrameID(body + end, 4);
}

/// The size of the v2.4 frame at `frameOffset` (whose 10-byte header is known to fit); see the file
/// comment for the synchsafe/plain rule.
static uint64_t CLID3v24FrameSize(const uint8_t *body, size_t bodyLength, size_t frameOffset) {
    const uint8_t *sizeBytes = body + frameOffset + 4;
    uint64_t plain = CLReadBE32(sizeBytes);
    if (!CLIsSynchsafe(sizeBytes)) return plain;
    uint64_t synchsafe = CLReadSynchsafe32(sizeBytes);
    if (synchsafe == plain) return synchsafe;
    if (CLID3v24EndsOnBoundary(body, bodyLength, frameOffset + 10 + synchsafe)) return synchsafe;
    if (CLID3v24EndsOnBoundary(body, bodyLength, frameOffset + 10 + plain)) return plain;
    return synchsafe;
}

/// Reads the ID3v2 tag at the start of `bytes`. Returns the bytes the tag occupies according to its
/// header (more than `length` for a truncated file), or 0 when `bytes` does not start with a tag.
static uint64_t CLReadID3Tag(const uint8_t *bytes, size_t length, CLScan *scan) {
    if (length < 10 || memcmp(bytes, "ID3", 3) != 0) return 0;
    uint8_t major = bytes[3];
    uint8_t flags = bytes[5];
    if (major < 2 || major > 4 || bytes[4] == 0xFF || !CLIsSynchsafe(bytes + 6)) return 0;
    uint64_t declared = CLReadSynchsafe32(bytes + 6);
    uint64_t tagSize = 10 + declared + ((major == 4 && (flags & 0x10)) ? 10 : 0);
    if (major == 2 && (flags & 0x40)) return tagSize;   // 2.2 "compression" was never defined: skip

    const uint8_t *body = bytes + 10;
    size_t bodyLength = (size_t)MIN(declared, (uint64_t)(length - 10));
    BOOL unsynchronised = (flags & 0x80) != 0;
    NSData *resynchronised NS_VALID_UNTIL_END_OF_SCOPE = nil;
    if (unsynchronised && major < 4) {                  // 2.2/2.3: the whole tag after the header
        resynchronised = CLID3RemoveUnsynchronisation(body, MIN(bodyLength, kCLMaxUnsyncBytes));
        if (!resynchronised) return tagSize;
        body = resynchronised.bytes;
        bodyLength = resynchronised.length;
    }

    size_t offset = 0;
    if (major >= 3 && (flags & 0x40)) {                 // extended header
        if (bodyLength < 4) return tagSize;
        uint64_t extended;
        if (major == 3) {
            extended = (uint64_t)CLReadBE32(body) + 4;  // 2.3: the size excludes its own 4 bytes
        } else {
            if (!CLIsSynchsafe(body)) return tagSize;
            extended = CLReadSynchsafe32(body);         // 2.4: synchsafe, includes itself
        }
        if (extended < 6 || extended > bodyLength) return tagSize;
        offset = (size_t)extended;
    }

    size_t idLength = major == 2 ? 3 : 4;
    size_t headerSize = major == 2 ? 6 : 10;
    while (bodyLength - offset >= headerSize && CLScanStep(scan)) {
        const uint8_t *frame = body + offset;
        if (frame[0] == 0) break;                       // padding
        if (!CLID3IsFrameID(frame, idLength)) break;
        uint64_t frameSize;
        uint16_t frameFlags = 0;
        if (major == 2) {
            frameSize = CLReadBE24(frame + 3);
        } else {
            frameSize = major == 3 ? CLReadBE32(frame + 4) : CLID3v24FrameSize(body, bodyLength, offset);
            frameFlags = (uint16_t)((frame[8] << 8) | frame[9]);
        }
        if (frameSize > bodyLength - offset - headerSize) break;   // truncated or corrupt
        CLID3FrameKind kind = CLID3KindOfFrame(frame, major);
        if (kind != CLID3FrameKindOther) {
            CLID3ReadFrame(kind, major, frameFlags, unsynchronised && major == 4,
                           frame + headerSize, (size_t)frameSize, scan);
        }
        offset += headerSize + (size_t)frameSize;
    }
    return tagSize;
}

/// One or more ID3v2 tags at the start of the file (MP3, ADTS AAC), then FLAC when "fLaC" follows.
static void CLReadLeadingID3(const uint8_t *bytes, size_t length, CLScan *scan) {
    size_t offset = 0;
    for (NSUInteger i = 0; i < kCLMaxID3Tags && !scan->foundSynced; i++) {
        uint64_t tagSize = CLReadID3Tag(bytes + offset, length - offset, scan);
        if (tagSize == 0) break;
        if (tagSize > length - offset) return;   // truncated: nothing follows the tag
        offset += (size_t)tagSize;
    }
    if (length - offset >= 4 && memcmp(bytes + offset, "fLaC", 4) == 0) {
        CLReadFLAC(bytes + offset, length - offset, scan);
    }
}

#pragma mark - RIFF (WAV) / IFF (AIFF)

static BOOL CLIsID3ChunkID(const uint8_t *chunkID) {
    return (chunkID[0] == 'i' || chunkID[0] == 'I') && (chunkID[1] == 'd' || chunkID[1] == 'D') &&
           chunkID[2] == '3' && chunkID[3] == ' ';
}

/// Chunks after the 12-byte RIFF/FORM header: ID[4], size (LE for RIFF, BE for FORM), data padded
/// to an even length. The "id3 " / "ID3 " chunk holds a whole ID3v2 tag.
static void CLReadChunks(const uint8_t *bytes, size_t length, BOOL littleEndian, CLScan *scan) {
    if (length < 12) return;
    size_t offset = 12;
    while (length - offset >= 8 && CLScanStep(scan)) {
        const uint8_t *chunk = bytes + offset;
        uint64_t size = littleEndian ? CLReadLE32(chunk + 4) : CLReadBE32(chunk + 4);
        size_t start = offset + 8;
        size_t available = length - start;
        if (CLIsID3ChunkID(chunk)) {
            (void)CLReadID3Tag(bytes + start, (size_t)MIN(size, (uint64_t)available), scan);
        }
        uint64_t padded = size + (size & 1);
        if (padded >= available) return;         // the last chunk, or a truncated one
        offset = start + (size_t)padded;
    }
}

#pragma mark - MP4

typedef struct {
    uint32_t type;
    size_t payload;     // first byte after the header
    size_t end;         // one past the last byte, clamped to the parent
    BOOL truncated;     // the atom claims more bytes than its parent holds
} CLMP4Atom;

/// The atom header at `offset` inside a parent that ends at `end`. NO when no complete header fits
/// or the size is impossible. Size 1 = 64-bit size after the type, size 0 = to the end of the parent.
static BOOL CLMP4ReadAtom(const uint8_t *bytes, size_t offset, size_t end, CLMP4Atom *atom) {
    if (offset > end || end - offset < 8) return NO;
    uint64_t size = CLReadBE32(bytes + offset);
    size_t header = 8;
    if (size == 1) {
        if (end - offset < 16) return NO;
        size = CLReadBE64(bytes + offset + 8);
        header = 16;
    } else if (size == 0) {
        size = end - offset;
    }
    if (size < header) return NO;
    atom->type = CLReadBE32(bytes + offset + 4);
    atom->payload = offset + header;
    atom->truncated = size > end - offset;
    atom->end = atom->truncated ? end : offset + (size_t)size;
    return YES;
}

static BOOL CLMP4IsContainer(uint32_t type) {
    return type == kCLAtomMoov || type == kCLAtomUdta || type == kCLAtomMeta || type == kCLAtomIlst;
}

/// ISO `meta` is a full atom (version + flags before its children), QuickTime's is not. It is bare
/// when its first 4 bytes already read as the size of a plausible child atom.
static BOOL CLMP4MetaIsBare(const uint8_t *bytes, size_t payload, size_t end) {
    if (end - payload < 8) return NO;
    uint32_t size = CLReadBE32(bytes + payload);
    if (size < 8 || size > end - payload) return NO;
    for (size_t i = 4; i < 8; i++) {
        uint8_t c = bytes[payload + i];
        if (c < 0x20 || c > 0x7E) return NO;
    }
    return YES;
}

/// An `ilst` item: "©lyr" (data children) or "----" (mean, name, data children).
static void CLMP4ReadItem(const uint8_t *bytes, CLMP4Atom item, CLScan *scan) {
    BOOL freeform = item.type == kCLAtomFreeform;
    NSString *name = nil;
    NSString *text = nil;
    size_t offset = item.payload;
    CLMP4Atom child;
    while (CLMP4ReadAtom(bytes, offset, item.end, &child) && CLScanStep(scan)) {
        const uint8_t *payload = bytes + child.payload;
        size_t length = child.end - child.payload;
        if (child.type == kCLAtomName && length >= 4 && length - 4 <= kCLMaxFieldNameBytes) {
            name = CLStringFromUTF8(payload + 4, length - 4);          // after version + flags
        } else if (child.type == kCLAtomData && !text && length >= 8 && length - 8 <= kCLMaxTextBytes) {
            uint32_t dataType = CLReadBE32(payload) & 0x00FFFFFF;      // then a 4-byte locale
            if (dataType == 0 || dataType == 1) text = CLStringFromUTF8(payload + 8, length - 8);
            else if (dataType == 2) text = CLStringFromUTF16Units(payload + 8, length - 8, YES);
        }
        if (child.truncated) break;
        offset = child.end;
    }
    if (text && (!freeform || CLIsLyricsFieldName(name))) CLScanAddText(scan, text);
}

/// Walks the atoms in [start, end), descending into moov/udta/meta/ilst only; `mdat` and every
/// other atom is skipped by its header.
static void CLMP4ReadAtoms(const uint8_t *bytes, size_t start, size_t end, uint32_t parent,
                           NSUInteger depth, CLScan *scan) {
    if (depth > kCLMaxAtomDepth) return;
    size_t offset = start;
    CLMP4Atom atom;
    while (CLMP4ReadAtom(bytes, offset, end, &atom) && CLScanStep(scan)) {
        if (parent == kCLAtomIlst) {
            if (atom.type == kCLAtomLyrics || atom.type == kCLAtomFreeform) CLMP4ReadItem(bytes, atom, scan);
        } else if (CLMP4IsContainer(atom.type)) {
            size_t children = atom.payload;
            if (atom.type == kCLAtomMeta && !CLMP4MetaIsBare(bytes, children, atom.end)) {
                children = atom.end - children >= 4 ? children + 4 : atom.end;
            }
            CLMP4ReadAtoms(bytes, children, atom.end, atom.type, depth + 1, scan);
        }
        if (atom.truncated) return;
        offset = atom.end;
    }
}

static BOOL CLLooksLikeMP4(const uint8_t *bytes, size_t length) {
    if (length < 8) return NO;
    uint32_t type = CLReadBE32(bytes + 4);
    return type == CLFourCC('f', 't', 'y', 'p') || type == kCLAtomMoov ||
           type == CLFourCC('m', 'd', 'a', 't') || type == CLFourCC('f', 'r', 'e', 'e') ||
           type == CLFourCC('s', 'k', 'i', 'p') || type == CLFourCC('w', 'i', 'd', 'e');
}

#pragma mark - Ogg

/// The second packet of an Ogg stream: Vorbis "\x03vorbis", Opus "OpusTags", or (Ogg FLAC, whose
/// first packet starts "\x7FFLAC") a native VORBIS_COMMENT metadata block.
static void CLReadOggCommentPacket(const uint8_t *head, size_t headLength, const uint8_t *packet,
                                   size_t length, CLScan *scan) {
    if (length >= 7 && memcmp(packet, "\x03" "vorbis", 7) == 0) {
        CLReadVorbisComment(packet + 7, length - 7, scan);
    } else if (length >= 8 && memcmp(packet, "OpusTags", 8) == 0) {
        CLReadVorbisComment(packet + 8, length - 8, scan);
    } else if (headLength >= 5 && memcmp(head, "\x7F" "FLAC", 5) == 0 && length >= 4 &&
               (packet[0] & 0x7F) == 4) {
        CLReadVorbisComment(packet + 4, MIN((size_t)CLReadBE24(packet + 1), length - 4), scan);
    }
}

/// Pages: "OggS", version 0, header type, granule[8], serial (LE32), sequence, CRC, segment count,
/// segment table, body. Reassembles the first two packets of the first page's logical stream
/// (a lacing value below 255 ends a packet, so packets span pages) and reads the comment packet.
static void CLReadOgg(const uint8_t *bytes, size_t length, CLScan *scan) {
    size_t offset = 0;
    uint32_t serial = 0;
    BOOL haveSerial = NO;
    NSUInteger packetIndex = 0;
    uint8_t head[8] = {0};
    size_t headLength = 0;
    NSMutableData *comment NS_VALID_UNTIL_END_OF_SCOPE = [NSMutableData data];

    for (NSUInteger pages = 0; pages < kCLMaxOggPages && CLScanStep(scan); pages++) {
        if (length - offset < 27) return;
        const uint8_t *page = bytes + offset;
        if (memcmp(page, "OggS", 4) != 0 || page[4] != 0) return;
        size_t segments = page[26];
        if (length - offset - 27 < segments) return;
        const uint8_t *lacing = page + 27;
        size_t bodyLength = 0;
        for (size_t i = 0; i < segments; i++) bodyLength += lacing[i];
        size_t body = offset + 27 + segments;
        if (length - body < bodyLength) return;        // truncated page

        uint32_t pageSerial = CLReadLE32(page + 14);
        if (!haveSerial) {
            serial = pageSerial;
            haveSerial = YES;
        }
        if (pageSerial == serial) {
            size_t cursor = body;
            for (size_t i = 0; i < segments; i++) {
                size_t lace = lacing[i];
                if (packetIndex == 0) {
                    size_t take = MIN(lace, sizeof(head) - headLength);
                    if (take > 0) memcpy(head + headLength, bytes + cursor, take);
                    headLength += take;
                } else {
                    if (lace > kCLMaxOggPacketBytes - comment.length) return;
                    [comment appendBytes:bytes + cursor length:lace];
                }
                cursor += lace;
                if (lace < 255 && ++packetIndex == 2) {
                    CLReadOggCommentPacket(head, headLength, comment.bytes, comment.length, scan);
                    return;
                }
            }
        }
        offset = body + bodyLength;
    }
}

#pragma mark - CLEmbeddedLyricsReader

@implementation CLEmbeddedLyricsReader

+ (CLLyrics *)lyricsFromAudioData:(NSData *)data source:(NSString *)source {
    if (![data isKindOfClass:[NSData class]] || data.length < 8) return nil;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    size_t length = data.length;
    if (!bytes) return nil;

    NSString *src = [source isKindOfClass:[NSString class]] ? source : @"";
    NSMutableArray<CLLyrics *> *candidates = [NSMutableArray array];
    @autoreleasepool {
        CLScan scan = { src, candidates, kCLMaxSteps, NO };
        if (memcmp(bytes, "ID3", 3) == 0) {
            CLReadLeadingID3(bytes, length, &scan);
        } else if (memcmp(bytes, "fLaC", 4) == 0) {
            CLReadFLAC(bytes, length, &scan);
        } else if (memcmp(bytes, "OggS", 4) == 0) {
            CLReadOgg(bytes, length, &scan);
        } else if (length >= 12 && memcmp(bytes, "RIFF", 4) == 0 && memcmp(bytes + 8, "WAVE", 4) == 0) {
            CLReadChunks(bytes, length, YES, &scan);
        } else if (length >= 12 && memcmp(bytes, "FORM", 4) == 0 &&
                   (memcmp(bytes + 8, "AIFF", 4) == 0 || memcmp(bytes + 8, "AIFC", 4) == 0)) {
            CLReadChunks(bytes, length, NO, &scan);
        } else if (CLLooksLikeMP4(bytes, length)) {
            CLMP4ReadAtoms(bytes, 0, length, 0, 0, &scan);
        }
    }

    CLLyrics *plain = nil;
    for (CLLyrics *candidate in candidates) {
        if (candidate.kind == CLLyricsKindSynced) return candidate;
        if (!plain && candidate.kind == CLLyricsKindPlain) plain = candidate;
    }
    return plain;
}

+ (CLLyrics *)lyricsFromText:(NSString *)text source:(NSString *)source {
    return CLLyricsFromText(text, source);
}

+ (NSString *)stringFromTextData:(NSData *)data {
    if (![data isKindOfClass:[NSData class]] || data.length == 0) return nil;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    size_t length = data.length;
    if (!bytes) return nil;
    BOOL bigEndian = NO;
    if (CLReadUTF16BOM(bytes, length, &bigEndian)) return CLStringFromUTF16(bytes, length, &bigEndian);
    return CLStringFromUTF8(bytes, length);
}

@end
