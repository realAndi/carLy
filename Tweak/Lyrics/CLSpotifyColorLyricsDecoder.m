#import "CLSpotifyColorLyricsDecoder.h"

#import "Util/CLLog.h"
#import "Util/CLProtobufReader.h"

#pragma mark - Wire layout (docs/research/spotify-local-lyrics.md)

// message ColorLyricsResponse { LyricsResponse lyrics = 1; Colors colors = 2; }
static const uint32_t kCLColorLyricsFieldLyrics = 1;
// message LyricsResponse { int32 sync_type = 1; repeated LyricsLine lines = 2; ... }
static const uint32_t kCLLyricsFieldSyncType = 1;
static const uint32_t kCLLyricsFieldLines = 2;
// message LyricsLine { int64 start_time_ms = 1; string words = 2; ... }
static const uint32_t kCLLineFieldStartTimeMilliseconds = 1;
static const uint32_t kCLLineFieldWords = 2;
// sync_type: 0 = UNSYNCED, 1 = LINE_SYNCED (the only value observed on this device), 2 =
// SYLLABLE_SYNCED (the web client's JSON names it; its lines still carry a start time each).
static const uint64_t kCLLyricsSyncTypeLineSynced = 1;
static const uint64_t kCLLyricsSyncTypeSyllableSynced = 2;
// A start time past this is a negative or garbage varint, not a timestamp.
static const NSTimeInterval kCLMaximumLineTime = 86400.0;

#pragma mark - Shared assembly

static CLLyricLine *CLLineWithMilliseconds(uint64_t milliseconds, BOOL hasStartTime, NSString *words) {
    if (!hasStartTime && !words) return nil;
    NSTimeInterval time = (NSTimeInterval)milliseconds / 1000.0;
    if (time < 0.0 || time > kCLMaximumLineTime) time = 0.0;
    return [CLLyricLine lineWithTime:time text:words ?: @""];
}

/// Lines (in any order) → lyrics. Interior blank lines are verse breaks and are kept; the trailing
/// end-of-lyrics marker is kept in `lines` but is not part of the text.
static CLLyrics *CLLyricsFromLines(NSMutableArray<CLLyricLine *> *lines, BOOL synced, NSString *source) {
    if (lines.count == 0) return nil;

    [lines sortUsingComparator:^NSComparisonResult(id lhs, id rhs) {
        NSTimeInterval left = [(CLLyricLine *)lhs time];
        NSTimeInterval right = [(CLLyricLine *)rhs time];
        if (left < right) return NSOrderedAscending;
        if (left > right) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithCapacity:lines.count];
    for (CLLyricLine *line in lines) [texts addObject:line.text ?: @""];
    NSCharacterSet *blank = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    while (texts.count > 0 && [[texts.lastObject stringByTrimmingCharactersInSet:blank] length] == 0) {
        [texts removeLastObject];
    }
    NSString *plainText = [texts componentsJoinedByString:@"\n"];
    if (plainText.length == 0) return nil;   // timings without a single word are not lyrics

    CLLyrics *lyrics = nil;
    if (synced) {
        lyrics = [CLLyrics syncedWithLines:lines source:source];
        if (lyrics && lyrics.plainText.length == 0) lyrics.plainText = plainText;
    } else {
        lyrics = [CLLyrics plainWithText:plainText source:source];
    }
    if (!lyrics) return nil;
    if (lyrics.fetchedAt <= 0) lyrics.fetchedAt = [[NSDate date] timeIntervalSince1970];
    return lyrics;
}

#pragma mark - Protobuf

/// Verified against this device's cache: the last entry of a LINE_SYNCED response carries only
/// start_time_ms and no words — it is the marker that says "stop showing the previous line".
/// It is kept, as an empty line, so the sync engine can blank the overlay at the right moment.
/// A message with neither field is not a line and is dropped.
static CLLyricLine *CLLineFromMessageData(NSData *data) {
    if (data.length == 0) return nil;
    __block uint64_t startMilliseconds = 0;
    __block BOOL hasStartTime = NO;
    __block NSString *words = nil;
    [CLProtobufReader enumerateFieldsInData:data
                                 usingBlock:^(uint32_t fieldNumber, CLProtobufWireType wireType,
                                              uint64_t value, NSData *payload, BOOL *stop) {
        if (fieldNumber == kCLLineFieldStartTimeMilliseconds && wireType == CLProtobufWireTypeVarint) {
            startMilliseconds = value;
            hasStartTime = YES;
        } else if (fieldNumber == kCLLineFieldWords && wireType == CLProtobufWireTypeLengthDelimited) {
            NSString *text = [CLProtobufReader stringFromData:payload];
            if (text) words = text;
        }
    }];
    return CLLineWithMilliseconds(startMilliseconds, hasStartTime, words);
}

/// Decodes a LyricsResponse. Lines that survived a truncated tail are kept on purpose: half a
/// lyric beats none, and the sync engine only ever reads forwards.
static CLLyrics *CLLyricsFromLyricsMessage(NSData *data, NSString *source) {
    if (data.length == 0) return nil;

    __block uint64_t syncType = 0;
    NSMutableArray<CLLyricLine *> *lines = [NSMutableArray array];
    BOOL clean = [CLProtobufReader enumerateFieldsInData:data
                                             usingBlock:^(uint32_t fieldNumber, CLProtobufWireType wireType,
                                                          uint64_t value, NSData *payload, BOOL *stop) {
        if (fieldNumber == kCLLyricsFieldSyncType && wireType == CLProtobufWireTypeVarint) {
            syncType = value;
        } else if (fieldNumber == kCLLyricsFieldLines && wireType == CLProtobufWireTypeLengthDelimited) {
            CLLyricLine *line = CLLineFromMessageData(payload);
            if (line) [lines addObject:line];
        }
    }];
    if (!clean) {
        CLLogDebug(@"[spotify] malformed lyrics message; keeping %lu decoded line(s)", (unsigned long)lines.count);
    }
    BOOL synced = syncType == kCLLyricsSyncTypeLineSynced || syncType == kCLLyricsSyncTypeSyllableSynced;
    return CLLyricsFromLines(lines, synced, source);
}

/// ColorLyricsResponse.lyrics (field 1, length-delimited). nil when the body is a bare
/// LyricsResponse — whose field 1 is a varint, so the two cannot be confused.
static NSData *CLNestedLyricsMessage(NSData *data) {
    __block NSData *nested = nil;
    [CLProtobufReader enumerateFieldsInData:data
                                 usingBlock:^(uint32_t fieldNumber, CLProtobufWireType wireType,
                                              uint64_t value, NSData *payload, BOOL *stop) {
        if (fieldNumber == kCLColorLyricsFieldLyrics && wireType == CLProtobufWireTypeLengthDelimited) {
            nested = payload;
            *stop = YES;
        }
    }];
    return nested;
}

#pragma mark - JSON

/// "4400" (the API sends int64 as strings) or 4400. NO when absent or not a non-negative number.
static BOOL CLJSONMilliseconds(id value, uint64_t *milliseconds) {
    if ([value isKindOfClass:[NSNumber class]]) {
        double number = [(NSNumber *)value doubleValue];
        if (!(number >= 0)) return NO;
        *milliseconds = (uint64_t)number;
        return YES;
    }
    if ([value isKindOfClass:[NSString class]]) {
        // Digits only: no sign, no spaces, short enough to fit.
        NSString *string = (NSString *)value;
        static NSCharacterSet *notDigits;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ notDigits = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]; });
        if (string.length == 0 || string.length > 18 || [string rangeOfCharacterFromSet:notDigits].location != NSNotFound) return NO;
        *milliseconds = (uint64_t)string.longLongValue;
        return YES;
    }
    return NO;
}

@implementation CLSpotifyColorLyricsDecoder

+ (CLLyrics *)lyricsFromResponseData:(NSData *)data source:(NSString *)source {
    if (data.length == 0) return nil;
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    NSUInteger index = 0;
    while (index < data.length && (bytes[index] == ' ' || bytes[index] == '\n' || bytes[index] == '\r' ||
                                   bytes[index] == '\t')) {
        index += 1;
    }
    // A protobuf body never starts with '{' (0x7B would be field 15, wire type 3, a deprecated
    // group start that neither message uses).
    if (index < data.length && bytes[index] == '{') {
        id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        return [self lyricsFromJSONObject:object source:source];
    }
    return [self lyricsFromProtobufData:data source:source];
}

+ (CLLyrics *)lyricsFromProtobufData:(NSData *)data source:(NSString *)source {
    if (data.length == 0) return nil;
    NSString *identifier = source.length > 0 ? source : @"spotify";
    CLLyrics *lyrics = nil;
    NSData *nested = CLNestedLyricsMessage(data);
    if (nested.length > 0) lyrics = CLLyricsFromLyricsMessage(nested, identifier);
    if (!lyrics) lyrics = CLLyricsFromLyricsMessage(data, identifier);
    return lyrics;
}

+ (CLLyrics *)lyricsFromJSONObject:(id)object source:(NSString *)source {
    if (![object isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *root = (NSDictionary *)object;
    NSDictionary *body = [root[@"lyrics"] isKindOfClass:[NSDictionary class]] ? root[@"lyrics"] : root;
    NSArray *rawLines = [body[@"lines"] isKindOfClass:[NSArray class]] ? body[@"lines"] : nil;
    if (rawLines.count == 0) return nil;

    NSString *syncType = [body[@"syncType"] isKindOfClass:[NSString class]] ? [body[@"syncType"] uppercaseString] : @"";
    BOOL synced = [syncType isEqualToString:@"LINE_SYNCED"] || [syncType isEqualToString:@"SYLLABLE_SYNCED"];

    NSMutableArray<CLLyricLine *> *lines = [NSMutableArray arrayWithCapacity:rawLines.count];
    for (id entry in rawLines) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *line = (NSDictionary *)entry;
        uint64_t milliseconds = 0;
        BOOL hasStartTime = CLJSONMilliseconds(line[@"startTimeMs"], &milliseconds);
        NSString *words = [line[@"words"] isKindOfClass:[NSString class]] ? line[@"words"] : nil;
        CLLyricLine *parsed = CLLineWithMilliseconds(milliseconds, hasStartTime, words);
        if (parsed) [lines addObject:parsed];
    }
    return CLLyricsFromLines(lines, synced, source.length > 0 ? source : @"spotify");
}

@end
