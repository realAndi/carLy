#import "CLTestFixtures.h"

typedef NS_ENUM(NSUInteger, CLTestWireType) {
    CLTestWireVarint = 0,
    CLTestWireFixed64 = 1,
    CLTestWireLengthDelimited = 2,
    CLTestWireFixed32 = 5,
};

@implementation CLTestProtoWriter {
    NSMutableData *_data;
}

- (instancetype)init {
    self = [super init];
    if (self) _data = [NSMutableData data];
    return self;
}

- (NSData *)data {
    return [_data copy];
}

- (void)appendRawBytes:(NSData *)bytes {
    if (bytes.length) [_data appendData:bytes];
}

/// Standard unsigned LEB128 varint, written independently of CLProtobufReader's decoder.
- (void)appendRawVarint:(uint64_t)value {
    uint8_t buffer[10];
    NSUInteger count = 0;
    do {
        uint8_t byte = value & 0x7F;
        value >>= 7;
        if (value != 0) byte |= 0x80;
        buffer[count++] = byte;
    } while (value != 0 && count < sizeof(buffer));
    [_data appendBytes:buffer length:count];
}

- (void)appendRawTag:(uint32_t)fieldNumber wireType:(NSUInteger)wireType {
    uint64_t tag = ((uint64_t)fieldNumber << 3) | (uint64_t)wireType;
    [self appendRawVarint:tag];
}

- (void)appendVarintField:(uint32_t)fieldNumber value:(uint64_t)value {
    [self appendRawTag:fieldNumber wireType:CLTestWireVarint];
    [self appendRawVarint:value];
}

- (void)appendLengthDelimitedField:(uint32_t)fieldNumber bytes:(NSData *)bytes {
    [self appendRawTag:fieldNumber wireType:CLTestWireLengthDelimited];
    [self appendRawVarint:bytes.length];
    [self appendRawBytes:bytes];
}

- (void)appendLengthDelimitedField:(uint32_t)fieldNumber string:(NSString *)string {
    NSData *bytes = [string dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    [self appendLengthDelimitedField:fieldNumber bytes:bytes];
}

- (void)appendFixed32Field:(uint32_t)fieldNumber value:(uint32_t)value {
    [self appendRawTag:fieldNumber wireType:CLTestWireFixed32];
    uint8_t buffer[4];
    for (NSUInteger i = 0; i < 4; i++) buffer[i] = (uint8_t)((value >> (8 * i)) & 0xFF);
    [_data appendBytes:buffer length:4];
}

- (void)appendFixed64Field:(uint32_t)fieldNumber value:(uint64_t)value {
    [self appendRawTag:fieldNumber wireType:CLTestWireFixed64];
    uint8_t buffer[8];
    for (NSUInteger i = 0; i < 8; i++) buffer[i] = (uint8_t)((value >> (8 * i)) & 0xFF);
    [_data appendBytes:buffer length:8];
}

@end

NSData *CLTestBuildLyricsLineMessage(uint64_t startTimeMilliseconds, NSString *words, BOOL hasWords) {
    CLTestProtoWriter *writer = [[CLTestProtoWriter alloc] init];
    [writer appendVarintField:1 value:startTimeMilliseconds];
    if (hasWords) [writer appendLengthDelimitedField:2 string:(words ?: @"")];
    return writer.data;
}

NSData *CLTestBuildLyricsResponseMessage(uint64_t syncType, NSArray<NSData *> *lineMessages) {
    CLTestProtoWriter *writer = [[CLTestProtoWriter alloc] init];
    [writer appendVarintField:1 value:syncType];
    for (NSData *line in lineMessages) {
        [writer appendLengthDelimitedField:2 bytes:line];
    }
    return writer.data;
}

NSData *CLTestBuildColorLyricsResponseMessage(NSData *lyricsResponseMessage) {
    CLTestProtoWriter *writer = [[CLTestProtoWriter alloc] init];
    [writer appendLengthDelimitedField:1 bytes:lyricsResponseMessage];
    return writer.data;
}

NSData *CLTestSpotifyColorLyricsFixture(NSUInteger lineCount) {
    NSMutableArray<NSData *> *lines = [NSMutableArray arrayWithCapacity:lineCount + 1];
    for (NSUInteger i = 0; i < lineCount; i++) {
        uint64_t ms = (uint64_t)(1000 + i * 2500);
        NSString *words = [NSString stringWithFormat:@"Line number %lu", (unsigned long)(i + 1)];
        [lines addObject:CLTestBuildLyricsLineMessage(ms, words, YES)];
    }
    // Spotify's trailing "stop showing the last line" marker: timestamp only, no words field.
    uint64_t endMs = (uint64_t)(1000 + lineCount * 2500);
    [lines addObject:CLTestBuildLyricsLineMessage(endMs, nil, NO)];

    NSData *lyricsMessage = CLTestBuildLyricsResponseMessage(1 /* LINE_SYNCED */, lines);
    return CLTestBuildColorLyricsResponseMessage(lyricsMessage);
}

NSData *CLTestLRCLibGetResponseFixture(void) {
    NSDictionary *object = @{
        @"id": @123456,
        @"trackName": @"Fixture Song",
        @"artistName": @"Fixture Artist",
        @"albumName": @"Fixture Album",
        @"duration": @201,
        @"instrumental": @NO,
        @"plainLyrics": @"line one\nline two\nline three",
        @"syncedLyrics": @"[00:01.00] line one\n[00:03.50] line two\n[00:06.00] line three",
    };
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL] ?: [NSData data];
}
