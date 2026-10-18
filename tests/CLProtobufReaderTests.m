// Tests for CLProtobufReader (Tweak/Util/CLProtobufReader.m): cursor primitives, field
// enumeration, the numeric helpers, and — the whole reason this class exists — decoding a
// hand-built byte array that replicates Spotify's color-lyrics wire structure
// (docs/research/spotify-local-lyrics.md), including safety against truncated input.
#import "CLProtobufReaderTests.h"
#import "CLTestCase.h"
#import "CLTestFixtures.h"
#import "Util/CLProtobufReader.h"
#import <math.h>

#pragma mark - Cursor primitives

static void CLTestVarintRoundTrip(void) {
    uint64_t values[] = { 0, 1, 2, 127, 128, 129, 16383, 16384, 300,
                           (uint64_t)UINT32_MAX, (uint64_t)UINT32_MAX + 1, UINT64_MAX };
    for (size_t i = 0; i < sizeof(values) / sizeof(values[0]); i++) {
        CLTestProtoWriter *writer = [[CLTestProtoWriter alloc] init];
        [writer appendRawVarint:values[i]];
        CLProtobufReader *reader = [[CLProtobufReader alloc] initWithData:writer.data];
        uint64_t decoded = 0;
        BOOL ok = [reader readVarint:&decoded];
        CL_ASSERT_TRUE(ok);
        CL_ASSERT_EQ(decoded, values[i]);
        CL_ASSERT_TRUE(reader.isAtEnd);
    }
}

static void CLTestVarintTruncatedIsSafe(void) {
    // A continuation byte (top bit set) with nothing after it must fail, not hang or over-read.
    uint8_t bytes[] = { 0x80, 0x80, 0x80 };
    NSData *data = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    CLProtobufReader *reader = [[CLProtobufReader alloc] initWithData:data];
    uint64_t value = 0;
    CL_ASSERT_FALSE([reader readVarint:&value]);
    CL_ASSERT_EQ(reader.offset, (NSUInteger)0);   // cursor must not move on failure

    // More than ten continuation bytes is malformed by definition (over-long encoding).
    uint8_t tooLong[11];
    for (int i = 0; i < 11; i++) tooLong[i] = 0x80;
    NSData *tooLongData = [NSData dataWithBytes:tooLong length:sizeof(tooLong)];
    CLProtobufReader *reader2 = [[CLProtobufReader alloc] initWithData:tooLongData];
    CL_ASSERT_FALSE([reader2 readVarint:&value]);
}

static void CLTestFixedWidthRoundTrip(void) {
    CLTestProtoWriter *writer32 = [[CLTestProtoWriter alloc] init];
    [writer32 appendRawBytes:[NSData dataWithBytes:(uint8_t[]){ 0x01, 0x02, 0x03, 0x04 } length:4]];
    CLProtobufReader *reader32 = [[CLProtobufReader alloc] initWithData:writer32.data];
    uint32_t v32 = 0;
    CL_ASSERT_TRUE([reader32 readFixed32:&v32]);
    CL_ASSERT_EQ(v32, (unsigned long)0x04030201);   // little-endian

    NSData *shortData = [NSData dataWithBytes:(uint8_t[]){ 0x01, 0x02, 0x03 } length:3];
    CLProtobufReader *shortReader = [[CLProtobufReader alloc] initWithData:shortData];
    CL_ASSERT_FALSE([shortReader readFixed32:&v32]);

    CLTestProtoWriter *writer64 = [[CLTestProtoWriter alloc] init];
    uint8_t eight[8] = { 1, 2, 3, 4, 5, 6, 7, 8 };
    [writer64 appendRawBytes:[NSData dataWithBytes:eight length:8]];
    CLProtobufReader *reader64 = [[CLProtobufReader alloc] initWithData:writer64.data];
    uint64_t v64 = 0;
    CL_ASSERT_TRUE([reader64 readFixed64:&v64]);
    CL_ASSERT_EQ(v64, (unsigned long)0x0807060504030201ULL);
}

static void CLTestLengthDelimitedRoundTrip(void) {
    CLTestProtoWriter *writer = [[CLTestProtoWriter alloc] init];
    [writer appendRawVarint:0];   // a legitimately empty payload
    CLProtobufReader *emptyReader = [[CLProtobufReader alloc] initWithData:writer.data];
    NSData *empty = [emptyReader readLengthDelimited];
    CL_ASSERT_NOT_NIL(empty);
    CL_ASSERT_EQ(empty.length, (NSUInteger)0);

    NSString *payloadString = @"hello";
    CLTestProtoWriter *good = [[CLTestProtoWriter alloc] init];
    [good appendRawVarint:payloadString.length];
    [good appendRawBytes:[payloadString dataUsingEncoding:NSUTF8StringEncoding]];
    CLProtobufReader *goodReader = [[CLProtobufReader alloc] initWithData:good.data];
    NSData *decoded = [goodReader readLengthDelimited];
    CL_ASSERT_EQ([CLProtobufReader stringFromData:decoded], payloadString);
    CL_ASSERT_TRUE(goodReader.isAtEnd);

    // Declared length longer than what actually follows: nil, cursor left untouched.
    CLTestProtoWriter *oversized = [[CLTestProtoWriter alloc] init];
    [oversized appendRawVarint:100];
    [oversized appendRawBytes:[@"short" dataUsingEncoding:NSUTF8StringEncoding]];
    CLProtobufReader *oversizedReader = [[CLProtobufReader alloc] initWithData:oversized.data];
    CL_ASSERT_NIL([oversizedReader readLengthDelimited]);
    CL_ASSERT_EQ(oversizedReader.offset, (NSUInteger)0);
}

static void CLTestNilAndEmptyDataAreHandled(void) {
    CLProtobufReader *nilReader = [[CLProtobufReader alloc] initWithData:nil];
    CL_ASSERT_TRUE(nilReader.isAtEnd);
    CL_ASSERT_EQ(nilReader.remaining, (NSUInteger)0);
    uint64_t value = 0;
    CL_ASSERT_FALSE([nilReader readVarint:&value]);

    CL_ASSERT_FALSE([CLProtobufReader enumerateFieldsInData:nil usingBlock:^(uint32_t f,
                        CLProtobufWireType w, uint64_t v, NSData *d, BOOL *stop) {}]);
    CL_ASSERT_FALSE([CLProtobufReader enumerateFieldsInData:[NSData data] usingBlock:^(uint32_t f,
                        CLProtobufWireType w, uint64_t v, NSData *d, BOOL *stop) {}]);
}

#pragma mark - Field enumeration

static void CLTestEnumerateFieldsBasicMessage(void) {
    CLTestProtoWriter *writer = [[CLTestProtoWriter alloc] init];
    [writer appendVarintField:1 value:42];
    [writer appendLengthDelimitedField:2 string:@"hi"];
    [writer appendFixed32Field:3 value:0xAABBCCDD];
    [writer appendFixed64Field:4 value:0x1122334455667788ULL];

    NSMutableArray<NSNumber *> *seenFields = [NSMutableArray array];
    NSMutableArray<NSNumber *> *seenWireTypes = [NSMutableArray array];
    __block uint64_t varintValue = 0;
    __block NSString *stringValue = nil;
    __block uint32_t fixed32Value = 0;
    __block uint64_t fixed64Value = 0;

    BOOL ok = [CLProtobufReader enumerateFieldsInData:writer.data
        usingBlock:^(uint32_t fieldNumber, CLProtobufWireType wireType, uint64_t value,
                     NSData *data, BOOL *stop) {
        [seenFields addObject:@(fieldNumber)];
        [seenWireTypes addObject:@(wireType)];
        switch (fieldNumber) {
            case 1: varintValue = value; break;
            case 2: stringValue = [CLProtobufReader stringFromData:data]; break;
            case 3: fixed32Value = (uint32_t)value; break;
            case 4: fixed64Value = value; break;
        }
    }];

    CL_ASSERT_TRUE(ok);
    CL_ASSERT_EQ(seenFields.count, (NSUInteger)4);
    CL_ASSERT_EQ(seenFields[0].unsignedIntValue, (unsigned)1);
    CL_ASSERT_EQ(seenFields[1].unsignedIntValue, (unsigned)2);
    CL_ASSERT_EQ(seenFields[2].unsignedIntValue, (unsigned)3);
    CL_ASSERT_EQ(seenFields[3].unsignedIntValue, (unsigned)4);
    CL_ASSERT_EQ((long)seenWireTypes[0].integerValue, (long)CLProtobufWireTypeVarint);
    CL_ASSERT_EQ((long)seenWireTypes[1].integerValue, (long)CLProtobufWireTypeLengthDelimited);
    CL_ASSERT_EQ((long)seenWireTypes[2].integerValue, (long)CLProtobufWireTypeFixed32);
    CL_ASSERT_EQ((long)seenWireTypes[3].integerValue, (long)CLProtobufWireTypeFixed64);
    CL_ASSERT_EQ(varintValue, (unsigned long)42);
    CL_ASSERT_EQ(stringValue, @"hi");
    CL_ASSERT_EQ((unsigned long)fixed32Value, (unsigned long)0xAABBCCDD);
    CL_ASSERT_EQ(fixed64Value, (unsigned long)0x1122334455667788ULL);
}

static void CLTestEnumerateFieldsStopsEarly(void) {
    CLTestProtoWriter *writer = [[CLTestProtoWriter alloc] init];
    [writer appendVarintField:1 value:1];
    [writer appendVarintField:2 value:2];
    [writer appendVarintField:3 value:3];

    __block NSUInteger callCount = 0;
    BOOL ok = [CLProtobufReader enumerateFieldsInData:writer.data
        usingBlock:^(uint32_t fieldNumber, CLProtobufWireType wireType, uint64_t value,
                     NSData *data, BOOL *stop) {
        callCount++;
        if (fieldNumber == 1) *stop = YES;
    }];
    CL_ASSERT_TRUE(ok);   // stopping early is not malformed
    CL_ASSERT_EQ(callCount, (NSUInteger)1);
}

static void CLTestEnumerateFieldsRejectsMalformedInput(void) {
    // Field number 0 is never valid.
    CLTestProtoWriter *zeroField = [[CLTestProtoWriter alloc] init];
    [zeroField appendVarintField:1 value:7];   // one good field first
    [zeroField appendRawTag:0 wireType:CLProtobufWireTypeVarint];
    [zeroField appendRawVarint:99];
    __block NSUInteger goodCallCount = 0;
    BOOL ok = [CLProtobufReader enumerateFieldsInData:zeroField.data
        usingBlock:^(uint32_t f, CLProtobufWireType w, uint64_t v, NSData *d, BOOL *stop) {
        goodCallCount++;
    }];
    CL_ASSERT_FALSE(ok);
    CL_ASSERT_EQ(goodCallCount, (NSUInteger)1);   // the field before the damage was still delivered

    // Deprecated group wire types (3 and 4) are treated as malformed.
    CLTestProtoWriter *group = [[CLTestProtoWriter alloc] init];
    [group appendRawTag:1 wireType:3];
    CL_ASSERT_FALSE([CLProtobufReader enumerateFieldsInData:group.data
        usingBlock:^(uint32_t f, CLProtobufWireType w, uint64_t v, NSData *d, BOOL *stop) {}]);

    // Reserved wire types 6/7 are equally rejected.
    CLTestProtoWriter *reserved = [[CLTestProtoWriter alloc] init];
    [reserved appendRawTag:1 wireType:6];
    CL_ASSERT_FALSE([CLProtobufReader enumerateFieldsInData:reserved.data
        usingBlock:^(uint32_t f, CLProtobufWireType w, uint64_t v, NSData *d, BOOL *stop) {}]);

    // A truncated tag (mid-varint at end of buffer).
    NSData *truncatedTag = [NSData dataWithBytes:(uint8_t[]){ 0x80 } length:1];
    CL_ASSERT_FALSE([CLProtobufReader enumerateFieldsInData:truncatedTag
        usingBlock:^(uint32_t f, CLProtobufWireType w, uint64_t v, NSData *d, BOOL *stop) {}]);
}

#pragma mark - Numeric helpers

static void CLTestZigZagDecoding(void) {
    CL_ASSERT_EQ((long)[CLProtobufReader zigZagDecoded32:0], (long)0);
    CL_ASSERT_EQ((long)[CLProtobufReader zigZagDecoded32:1], (long)-1);
    CL_ASSERT_EQ((long)[CLProtobufReader zigZagDecoded32:2], (long)1);
    CL_ASSERT_EQ((long)[CLProtobufReader zigZagDecoded32:3], (long)-2);
    CL_ASSERT_EQ((long)[CLProtobufReader zigZagDecoded32:4], (long)2);

    CL_ASSERT_EQ((long)[CLProtobufReader zigZagDecoded64:0], (long)0);
    CL_ASSERT_EQ((long)[CLProtobufReader zigZagDecoded64:1], (long)-1);
    CL_ASSERT_EQ((long)[CLProtobufReader zigZagDecoded64:2], (long)1);
    CL_ASSERT_EQ((long)[CLProtobufReader zigZagDecoded64:3], (long)-2);
}

static void CLTestFixedFloatingPointReinterpretation(void) {
    CL_ASSERT_NEAR([CLProtobufReader floatFromFixed32:0x3F800000u], 1.0, 0.0000001);
    CL_ASSERT_NEAR([CLProtobufReader floatFromFixed32:0xBF800000u], -1.0, 0.0000001);
    CL_ASSERT_NEAR([CLProtobufReader floatFromFixed32:0x00000000u], 0.0, 0.0000001);

    CL_ASSERT_NEAR([CLProtobufReader doubleFromFixed64:0x3FF0000000000000ULL], 1.0, 1e-12);
    CL_ASSERT_NEAR([CLProtobufReader doubleFromFixed64:0xC000000000000000ULL], -2.0, 1e-12);
}

static void CLTestStringFromDataEdgeCases(void) {
    CL_ASSERT_NIL([CLProtobufReader stringFromData:nil]);
    CL_ASSERT_EQ([CLProtobufReader stringFromData:[NSData data]], @"");
    uint8_t invalidUTF8[] = { 0xFF, 0xFE };
    CL_ASSERT_NIL([CLProtobufReader stringFromData:[NSData dataWithBytes:invalidUTF8 length:2]]);
}

#pragma mark - The real payload: Spotify's color-lyrics structure

static void CLTestDecodesSpotifyColorLyricsShape(void) {
    NSData *fixture = CLTestSpotifyColorLyricsFixture(3);

    __block NSData *nestedLyricsMessage = nil;
    BOOL topLevelOK = [CLProtobufReader enumerateFieldsInData:fixture
        usingBlock:^(uint32_t fieldNumber, CLProtobufWireType wireType, uint64_t value,
                     NSData *data, BOOL *stop) {
        if (fieldNumber == 1 && wireType == CLProtobufWireTypeLengthDelimited) {
            nestedLyricsMessage = data;
        }
    }];
    CL_ASSERT_TRUE(topLevelOK);
    CL_ASSERT_NOT_NIL(nestedLyricsMessage);

    __block uint64_t syncType = 999;
    NSMutableArray<NSData *> *lineMessages = [NSMutableArray array];
    BOOL lyricsOK = [CLProtobufReader enumerateFieldsInData:nestedLyricsMessage
        usingBlock:^(uint32_t fieldNumber, CLProtobufWireType wireType, uint64_t value,
                     NSData *data, BOOL *stop) {
        if (fieldNumber == 1 && wireType == CLProtobufWireTypeVarint) {
            syncType = value;
        } else if (fieldNumber == 2 && wireType == CLProtobufWireTypeLengthDelimited) {
            [lineMessages addObject:data];
        }
    }];
    CL_ASSERT_TRUE(lyricsOK);
    CL_ASSERT_EQ(syncType, (unsigned long)1);            // LINE_SYNCED
    CL_ASSERT_EQ(lineMessages.count, (NSUInteger)4);     // 3 worded lines + Spotify's end marker

    for (NSUInteger i = 0; i < 3; i++) {
        __block uint64_t startMs = 0;
        __block NSString *words = nil;
        BOOL lineOK = [CLProtobufReader enumerateFieldsInData:lineMessages[i]
            usingBlock:^(uint32_t fieldNumber, CLProtobufWireType wireType, uint64_t value,
                         NSData *data, BOOL *stop) {
            if (fieldNumber == 1) startMs = value;
            else if (fieldNumber == 2) words = [CLProtobufReader stringFromData:data];
        }];
        CL_ASSERT_TRUE(lineOK);
        CL_ASSERT_EQ(startMs, (unsigned long)(1000 + i * 2500));
        CL_ASSERT_EQ(words, ([NSString stringWithFormat:@"Line number %lu", (unsigned long)(i + 1)]));
    }

    // The trailing end marker: a timestamp with no words field at all.
    __block BOOL endMarkerHasWords = NO;
    __block BOOL endMarkerHasTimestamp = NO;
    [CLProtobufReader enumerateFieldsInData:lineMessages[3]
        usingBlock:^(uint32_t fieldNumber, CLProtobufWireType wireType, uint64_t value,
                     NSData *data, BOOL *stop) {
        if (fieldNumber == 1) endMarkerHasTimestamp = YES;
        if (fieldNumber == 2) endMarkerHasWords = YES;
    }];
    CL_ASSERT_TRUE(endMarkerHasTimestamp);
    CL_ASSERT_FALSE(endMarkerHasWords);
}

static void CLTestTruncatedSpotifyFixtureNeverCrashes(void) {
    NSData *fullFixture = CLTestSpotifyColorLyricsFixture(5);
    NSUInteger fullLength = fullFixture.length;
    CL_ASSERT_TRUE(fullLength > 10);   // sanity: the fixture is non-trivial

    for (NSUInteger cut = 0; cut <= fullLength; cut++) {
        NSData *prefix = [fullFixture subdataWithRange:NSMakeRange(0, cut)];
        __block NSUInteger fieldsSeen = 0;
        BOOL ok = NO;
        @try {
            ok = [CLProtobufReader enumerateFieldsInData:prefix
                usingBlock:^(uint32_t f, CLProtobufWireType w, uint64_t v, NSData *d, BOOL *stop) {
                fieldsSeen++;
            }];
        } @catch (NSException *exception) {
            CL_ASSERT_TRUE(NO);   // the contract promises this code never raises
        }
        if (cut == fullLength) {
            CL_ASSERT_TRUE(ok);
        } else if (cut == 0) {
            CL_ASSERT_FALSE(ok);
        }
        // For every intermediate cut we only require "did not crash / did not raise"; whether it
        // reports ok or not depends on exactly where the cut lands, which is not interesting here.
        (void)fieldsSeen;
    }
}

void CLRunProtobufReaderTests(void) {
    CLTestBeginSuite("CLProtobufReader");
    CLTestVarintRoundTrip();
    CLTestVarintTruncatedIsSafe();
    CLTestFixedWidthRoundTrip();
    CLTestLengthDelimitedRoundTrip();
    CLTestNilAndEmptyDataAreHandled();
    CLTestEnumerateFieldsBasicMessage();
    CLTestEnumerateFieldsStopsEarly();
    CLTestEnumerateFieldsRejectsMalformedInput();
    CLTestZigZagDecoding();
    CLTestFixedFloatingPointReinterpretation();
    CLTestStringFromDataEdgeCases();
    CLTestDecodesSpotifyColorLyricsShape();
    CLTestTruncatedSpotifyFixtureNeverCrashes();
}
