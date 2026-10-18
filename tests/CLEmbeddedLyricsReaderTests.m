// Tests for CLEmbeddedLyricsReader (Tweak/Lyrics/CLEmbeddedLyricsReader.m). Every fixture is built
// byte by byte below from the format specs (ID3v2.2/2.3/2.4, MP4 atoms, FLAC metadata blocks, Ogg
// pages, RIFF/AIFF chunks), never from the reader's own helpers. Besides the happy paths, every
// fixture is fed truncated at every length and with every length field corrupted; those inputs
// come from exact-size heap buffers, so an out-of-bounds read trips AddressSanitizer when the
// suite is built with -fsanitize=address.
#import "CLEmbeddedLyricsReaderTests.h"
#import "CLTestCase.h"
#import "Lyrics/CLEmbeddedLyricsReader.h"
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

static NSString *const kCLTestSource = @"embedded";

#pragma mark - Byte builders

static void CLPut8(NSMutableData *data, uint8_t value) {
    [data appendBytes:&value length:1];
}

static void CLPutBE16(NSMutableData *data, uint16_t value) {
    CLPut8(data, (uint8_t)(value >> 8));
    CLPut8(data, (uint8_t)value);
}

static void CLPutBE24(NSMutableData *data, uint32_t value) {
    CLPut8(data, (uint8_t)(value >> 16));
    CLPut8(data, (uint8_t)(value >> 8));
    CLPut8(data, (uint8_t)value);
}

static void CLPutBE32(NSMutableData *data, uint32_t value) {
    CLPutBE16(data, (uint16_t)(value >> 16));
    CLPutBE16(data, (uint16_t)value);
}

static void CLPutBE64(NSMutableData *data, uint64_t value) {
    CLPutBE32(data, (uint32_t)(value >> 32));
    CLPutBE32(data, (uint32_t)value);
}

static void CLPutLE16(NSMutableData *data, uint16_t value) {
    CLPut8(data, (uint8_t)value);
    CLPut8(data, (uint8_t)(value >> 8));
}

static void CLPutLE32(NSMutableData *data, uint32_t value) {
    CLPutLE16(data, (uint16_t)value);
    CLPutLE16(data, (uint16_t)(value >> 16));
}

static void CLPutSynchsafe(NSMutableData *data, uint32_t value) {
    CLPut8(data, (uint8_t)((value >> 21) & 0x7F));
    CLPut8(data, (uint8_t)((value >> 14) & 0x7F));
    CLPut8(data, (uint8_t)((value >> 7) & 0x7F));
    CLPut8(data, (uint8_t)(value & 0x7F));
}

/// A C string without its terminating NUL ("\xA9lyr" and friends included).
static void CLPutASCII(NSMutableData *data, const char *string) {
    [data appendBytes:string length:strlen(string)];
}

static void CLPutZeros(NSMutableData *data, NSUInteger count) {
    [data increaseLengthBy:count];
}

static NSData *CLJoin(NSArray<NSData *> *parts) {
    NSMutableData *data = [NSMutableData data];
    for (NSData *part in parts) [data appendData:part];
    return data;
}

/// Exact-size malloc'd copy, so AddressSanitizer sees any read past `length`.
static NSData *CLExactCopy(const uint8_t *bytes, size_t length) {
    if (length == 0) return [NSData data];
    uint8_t *buffer = malloc(length);
    if (!buffer) return [NSData data];
    memcpy(buffer, bytes, length);
    return [NSData dataWithBytesNoCopy:buffer length:length freeWhenDone:YES];
}

static CLLyrics *CLRead(NSData *data) {
    return [CLEmbeddedLyricsReader lyricsFromAudioData:CLExactCopy(data.bytes, data.length)
                                                source:kCLTestSource];
}

static CLLyricLine *CLLineAt(CLLyrics *lyrics, NSUInteger index) {
    return index < lyrics.lines.count ? lyrics.lines[index] : nil;
}

#pragma mark - ID3 builders

typedef NS_ENUM(NSInteger, CLTestForm) {
    CLTestFormLatin1,          // encoding 0
    CLTestFormUTF16LE,         // encoding 1, BOM FF FE on every string
    CLTestFormUTF16BE,         // encoding 1, BOM FE FF on every string
    CLTestFormUTF16BEBare,     // encoding 2 (big-endian, no BOM)
    CLTestFormUTF8,            // encoding 3
};

static uint8_t CLEncodingByte(CLTestForm form) {
    switch (form) {
        case CLTestFormLatin1: return 0;
        case CLTestFormUTF16LE: return 1;
        case CLTestFormUTF16BE: return 1;
        case CLTestFormUTF16BEBare: return 2;
        case CLTestFormUTF8: return 3;
    }
    return 0;
}

static void CLPutText(NSMutableData *data, NSString *text, CLTestForm form, BOOL terminated) {
    switch (form) {
        case CLTestFormLatin1:
            [data appendData:[text dataUsingEncoding:NSISOLatin1StringEncoding]];
            if (terminated) CLPut8(data, 0);
            break;
        case CLTestFormUTF16LE:
            CLPut8(data, 0xFF);
            CLPut8(data, 0xFE);
            [data appendData:[text dataUsingEncoding:NSUTF16LittleEndianStringEncoding]];
            if (terminated) CLPutZeros(data, 2);
            break;
        case CLTestFormUTF16BE:
            CLPut8(data, 0xFE);
            CLPut8(data, 0xFF);
            [data appendData:[text dataUsingEncoding:NSUTF16BigEndianStringEncoding]];
            if (terminated) CLPutZeros(data, 2);
            break;
        case CLTestFormUTF16BEBare:
            [data appendData:[text dataUsingEncoding:NSUTF16BigEndianStringEncoding]];
            if (terminated) CLPutZeros(data, 2);
            break;
        case CLTestFormUTF8:
            [data appendData:[text dataUsingEncoding:NSUTF8StringEncoding]];
            if (terminated) CLPut8(data, 0);
            break;
    }
}

/// A frame header (3-byte id + BE24 for 2.2, 4-byte id + BE32 + flags for 2.3, synchsafe for 2.4)
/// followed by `payload`.
static NSData *CLID3Frame(uint8_t major, const char *frameID, uint16_t flags, NSData *payload) {
    NSMutableData *frame = [NSMutableData data];
    CLPutASCII(frame, frameID);
    uint32_t size = (uint32_t)payload.length;
    if (major == 2) CLPutBE24(frame, size);
    else if (major == 3) CLPutBE32(frame, size);
    else CLPutSynchsafe(frame, size);
    if (major >= 3) CLPutBE16(frame, flags);
    [frame appendData:payload];
    return frame;
}

static NSData *CLID3TagWithBody(uint8_t major, uint8_t flags, NSData *body) {
    NSMutableData *tag = [NSMutableData data];
    CLPutASCII(tag, "ID3");
    CLPut8(tag, major);
    CLPut8(tag, 0);
    CLPut8(tag, flags);
    CLPutSynchsafe(tag, (uint32_t)body.length);
    [tag appendData:body];
    return tag;
}

static NSData *CLID3Tag(uint8_t major, NSArray<NSData *> *frames, NSUInteger padding) {
    NSMutableData *body = [CLJoin(frames) mutableCopy];
    CLPutZeros(body, padding);
    return CLID3TagWithBody(major, 0, body);
}

/// T??? text frame payload (Latin-1).
static NSData *CLTextPayload(NSString *text) {
    NSMutableData *payload = [NSMutableData data];
    CLPut8(payload, 0);
    CLPutText(payload, text, CLTestFormLatin1, NO);
    return payload;
}

static NSData *CLUSLTPayload(NSString *text, CLTestForm form) {
    NSMutableData *payload = [NSMutableData data];
    CLPut8(payload, CLEncodingByte(form));
    CLPutASCII(payload, "eng");
    CLPutText(payload, @"desc", form, YES);
    CLPutText(payload, text, form, NO);
    return payload;
}

static NSData *CLTXXXPayload(NSString *description, NSString *value, CLTestForm form) {
    NSMutableData *payload = [NSMutableData data];
    CLPut8(payload, CLEncodingByte(form));
    CLPutText(payload, description, form, YES);
    CLPutText(payload, value, form, NO);
    return payload;
}

/// SYLT: `entries` alternates NSString text and NSNumber milliseconds. The descriptor is written in
/// `descriptorForm` (which also gives the encoding byte), the entries in `entryForm`.
static NSData *CLSYLTPayloadForms(uint8_t stampFormat, CLTestForm descriptorForm, CLTestForm entryForm,
                                  NSArray *entries) {
    NSMutableData *payload = [NSMutableData data];
    CLPut8(payload, CLEncodingByte(descriptorForm));
    CLPutASCII(payload, "eng");
    CLPut8(payload, stampFormat);
    CLPut8(payload, 1);                             // content type: lyrics
    CLPutText(payload, @"", descriptorForm, YES);
    for (NSUInteger i = 0; i + 1 < entries.count; i += 2) {
        CLPutText(payload, entries[i], entryForm, YES);
        CLPutBE32(payload, [entries[i + 1] unsignedIntValue]);
    }
    return payload;
}

static NSData *CLSYLTPayload(uint8_t stampFormat, CLTestForm form, NSArray *entries) {
    return CLSYLTPayloadForms(stampFormat, form, form, entries);
}

/// Unsynchronisation as a writer applies it: a zero byte after every 0xFF.
static NSData *CLUnsynchronised(NSData *data) {
    NSMutableData *output = [NSMutableData data];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        CLPut8(output, bytes[i]);
        if (bytes[i] == 0xFF) CLPut8(output, 0);
    }
    return output;
}

/// A few bytes of fake MPEG audio after the tag, as in a real file.
static NSData *CLWithAudio(NSData *tag) {
    NSMutableData *file = [tag mutableCopy];
    const uint8_t frameHeader[] = { 0xFF, 0xFB, 0x90, 0x64, 0x00, 0x00, 0x00, 0x00 };
    [file appendBytes:frameHeader length:sizeof(frameHeader)];
    CLPutZeros(file, 24);
    return file;
}

#pragma mark - MP4 builders

static NSData *CLAtom(const char *type, NSData *payload) {
    NSMutableData *atom = [NSMutableData data];
    CLPutBE32(atom, (uint32_t)(8 + payload.length));
    CLPutASCII(atom, type);
    [atom appendData:payload];
    return atom;
}

static NSData *CLLargeAtom(const char *type, NSData *payload) {
    NSMutableData *atom = [NSMutableData data];
    CLPutBE32(atom, 1);
    CLPutASCII(atom, type);
    CLPutBE64(atom, 16 + (uint64_t)payload.length);
    [atom appendData:payload];
    return atom;
}

/// Version + flags, then `rest`.
static NSData *CLFullPayload(NSData *rest) {
    NSMutableData *payload = [NSMutableData data];
    CLPutZeros(payload, 4);
    [payload appendData:rest];
    return payload;
}

static NSData *CLDataAtom(NSString *text) {
    NSMutableData *payload = [NSMutableData data];
    CLPutBE32(payload, 1);                          // type: UTF-8
    CLPutBE32(payload, 0);                          // locale
    [payload appendData:[text dataUsingEncoding:NSUTF8StringEncoding]];
    return CLAtom("data", payload);
}

static NSData *CLItem(const char *type, NSString *text) {
    return CLAtom(type, CLDataAtom(text));
}

static NSData *CLFreeformItem(NSString *name, NSString *text) {
    NSMutableData *mean = [NSMutableData data];
    CLPutASCII(mean, "com.apple.iTunes");
    return CLAtom("----", CLJoin(@[ CLAtom("mean", CLFullPayload(mean)),
                                    CLAtom("name", CLFullPayload([name dataUsingEncoding:NSUTF8StringEncoding])),
                                    CLDataAtom(text) ]));
}

typedef NS_OPTIONS(NSUInteger, CLMP4Options) {
    CLMP4OptionBareMeta = 1 << 0,       // QuickTime-style meta without version/flags
    CLMP4OptionLargeMoov = 1 << 1,      // moov written with a 64-bit size
};

static NSData *CLMP4File(NSArray<NSData *> *items, CLMP4Options options, NSData *beforeMoov) {
    NSMutableData *ftyp = [NSMutableData data];
    CLPutASCII(ftyp, "M4A ");
    CLPutBE32(ftyp, 0);
    CLPutASCII(ftyp, "M4A mp42isom");

    NSMutableData *hdlr = [NSMutableData data];
    CLPutZeros(hdlr, 8);                            // version/flags, pre_defined
    CLPutASCII(hdlr, "mdirappl");
    CLPutZeros(hdlr, 9);
    NSData *metaChildren = CLJoin(@[ CLAtom("hdlr", hdlr), CLAtom("ilst", CLJoin(items)) ]);
    NSData *meta = CLAtom("meta", (options & CLMP4OptionBareMeta) ? metaChildren : CLFullPayload(metaChildren));

    NSMutableData *mvhd = [NSMutableData data];
    CLPutZeros(mvhd, 100);
    NSData *moovPayload = CLJoin(@[ CLAtom("mvhd", mvhd), CLAtom("udta", meta) ]);
    NSData *moov = (options & CLMP4OptionLargeMoov) ? CLLargeAtom("moov", moovPayload)
                                                    : CLAtom("moov", moovPayload);
    return CLJoin(@[ CLAtom("ftyp", ftyp), beforeMoov ?: [NSData data], moov ]);
}

#pragma mark - FLAC / Vorbis comment builders

static NSData *CLVorbisCommentBody(NSArray<NSString *> *comments) {
    NSMutableData *body = [NSMutableData data];
    NSData *vendor = [@"reference libFLAC 1.4.3 20230623" dataUsingEncoding:NSUTF8StringEncoding];
    CLPutLE32(body, (uint32_t)vendor.length);
    [body appendData:vendor];
    CLPutLE32(body, (uint32_t)comments.count);
    for (NSString *comment in comments) {
        NSData *bytes = [comment dataUsingEncoding:NSUTF8StringEncoding];
        CLPutLE32(body, (uint32_t)bytes.length);
        [body appendData:bytes];
    }
    return body;
}

static void CLPutFLACBlock(NSMutableData *data, uint8_t type, BOOL last, NSData *payload) {
    CLPut8(data, (uint8_t)((last ? 0x80 : 0) | type));
    CLPutBE24(data, (uint32_t)payload.length);
    [data appendData:payload];
}

static NSData *CLFLACFile(NSData *prefix, NSArray<NSString *> *comments) {
    NSMutableData *file = [(prefix ?: [NSData data]) mutableCopy];
    CLPutASCII(file, "fLaC");
    NSMutableData *streamInfo = [NSMutableData data];
    CLPutZeros(streamInfo, 34);
    CLPutFLACBlock(file, 0, NO, streamInfo);
    CLPutFLACBlock(file, 4, NO, CLVorbisCommentBody(comments));
    NSMutableData *padding = [NSMutableData data];
    CLPutZeros(padding, 16);
    CLPutFLACBlock(file, 1, YES, padding);
    const uint8_t frameSync[] = { 0xFF, 0xF8, 0x69, 0x08, 0x00, 0x00 };
    [file appendBytes:frameSync length:sizeof(frameSync)];
    return file;
}

#pragma mark - Ogg builders

static void CLPutOggPage(NSMutableData *out, uint32_t serial, uint32_t sequence, uint8_t headerType,
                         NSData *lacing, NSData *body) {
    CLPutASCII(out, "OggS");
    CLPut8(out, 0);
    CLPut8(out, headerType);
    CLPutZeros(out, 8);                             // granule position
    CLPutLE32(out, serial);
    CLPutLE32(out, sequence);
    CLPutLE32(out, 0);                              // CRC (not checked by the reader)
    CLPut8(out, (uint8_t)lacing.length);
    [out appendData:lacing];
    [out appendData:body];
}

/// packets[0] alone on a beginning-of-stream page; the others laced into pages of at most
/// `maxSegments` segments. With `foreignPage`, a page of a second logical stream (carrying its own
/// lyrics) sits right after the first of those pages.
static NSData *CLOggFile(NSArray<NSData *> *packets, NSUInteger maxSegments, BOOL foreignPage) {
    NSMutableData *out = [NSMutableData data];
    uint32_t serial = 0x1234ABCD;
    uint32_t sequence = 0;
    NSMutableData *lacing = [NSMutableData data];
    CLPut8(lacing, (uint8_t)packets[0].length);
    CLPutOggPage(out, serial, sequence++, 0x02, lacing, packets[0]);

    NSMutableData *laces = [NSMutableData data];
    NSMutableData *stream = [NSMutableData data];
    for (NSUInteger p = 1; p < packets.count; p++) {
        [stream appendData:packets[p]];
        size_t remaining = packets[p].length;
        while (YES) {
            size_t lace = MIN((size_t)255, remaining);
            CLPut8(laces, (uint8_t)lace);
            remaining -= lace;
            if (lace < 255) break;
        }
    }

    const uint8_t *laceBytes = laces.bytes;
    size_t segment = 0;
    size_t streamOffset = 0;
    BOOL continued = NO;
    NSUInteger pages = 0;
    while (segment < laces.length) {
        size_t count = MIN((size_t)maxSegments, laces.length - segment);
        size_t bodyLength = 0;
        for (size_t i = 0; i < count; i++) bodyLength += laceBytes[segment + i];
        CLPutOggPage(out, serial, sequence++, continued ? 0x01 : 0x00,
                     [laces subdataWithRange:NSMakeRange(segment, count)],
                     [stream subdataWithRange:NSMakeRange(streamOffset, bodyLength)]);
        continued = laceBytes[segment + count - 1] == 255;
        segment += count;
        streamOffset += bodyLength;
        if (foreignPage && ++pages == 1) {
            NSMutableData *junk = [NSMutableData data];
            CLPutASCII(junk, "\x03" "vorbis");
            [junk appendData:CLVorbisCommentBody(@[ @"LYRICS=[00:01.00]Wrong stream\n[00:02.00]Wrong" ])];
            NSMutableData *junkLacing = [NSMutableData data];
            CLPut8(junkLacing, (uint8_t)junk.length);
            CLPutOggPage(out, 0x0F0F0F0F, 0, 0x02, junkLacing, junk);
        }
    }
    return out;
}

static NSData *CLVorbisIdentification(void) {
    NSMutableData *packet = [NSMutableData data];
    CLPutASCII(packet, "\x01" "vorbis");
    CLPutLE32(packet, 0);                           // version
    CLPut8(packet, 2);                              // channels
    CLPutLE32(packet, 44100);
    CLPutLE32(packet, 0);
    CLPutLE32(packet, 128000);
    CLPutLE32(packet, 0);
    CLPut8(packet, 0xB8);                           // block sizes
    CLPut8(packet, 1);                              // framing
    return packet;
}

static NSData *CLVorbisCommentPacket(NSArray<NSString *> *comments) {
    NSMutableData *packet = [NSMutableData data];
    CLPutASCII(packet, "\x03" "vorbis");
    [packet appendData:CLVorbisCommentBody(comments)];
    CLPut8(packet, 1);                              // framing bit
    return packet;
}

static NSData *CLVorbisSetup(void) {
    NSMutableData *packet = [NSMutableData data];
    CLPutASCII(packet, "\x05" "vorbis");
    for (int i = 0; i < 40; i++) CLPut8(packet, 0x42);
    return packet;
}

static NSData *CLOpusHead(void) {
    NSMutableData *packet = [NSMutableData data];
    CLPutASCII(packet, "OpusHead");
    CLPut8(packet, 1);
    CLPut8(packet, 2);
    CLPutLE16(packet, 312);
    CLPutLE32(packet, 48000);
    CLPutLE16(packet, 0);
    CLPut8(packet, 0);
    return packet;
}

static NSData *CLOpusTags(NSArray<NSString *> *comments) {
    NSMutableData *packet = [NSMutableData data];
    CLPutASCII(packet, "OpusTags");
    [packet appendData:CLVorbisCommentBody(comments)];
    return packet;
}

#pragma mark - WAV / AIFF builders

static NSData *CLWAVFile(NSData *tag, const char *chunkID) {
    NSMutableData *chunks = [NSMutableData data];
    CLPutASCII(chunks, "fmt ");
    CLPutLE32(chunks, 16);
    CLPutLE16(chunks, 1);
    CLPutLE16(chunks, 2);
    CLPutLE32(chunks, 44100);
    CLPutLE32(chunks, 176400);
    CLPutLE16(chunks, 4);
    CLPutLE16(chunks, 16);
    CLPutASCII(chunks, "data");
    CLPutLE32(chunks, 3);                           // odd: one pad byte follows
    CLPutZeros(chunks, 4);
    CLPutASCII(chunks, chunkID);
    CLPutLE32(chunks, (uint32_t)tag.length);
    [chunks appendData:tag];
    if (tag.length & 1) CLPut8(chunks, 0);

    NSMutableData *file = [NSMutableData data];
    CLPutASCII(file, "RIFF");
    CLPutLE32(file, (uint32_t)(4 + chunks.length));
    CLPutASCII(file, "WAVE");
    [file appendData:chunks];
    return file;
}

static NSData *CLAIFFFile(NSData *tag) {
    NSMutableData *chunks = [NSMutableData data];
    CLPutASCII(chunks, "COMM");
    CLPutBE32(chunks, 18);
    CLPutZeros(chunks, 18);
    CLPutASCII(chunks, "SSND");
    CLPutBE32(chunks, 9);                           // odd: one pad byte follows
    CLPutZeros(chunks, 10);
    CLPutASCII(chunks, "ID3 ");
    CLPutBE32(chunks, (uint32_t)tag.length);
    [chunks appendData:tag];
    if (tag.length & 1) CLPut8(chunks, 0);

    NSMutableData *file = [NSMutableData data];
    CLPutASCII(file, "FORM");
    CLPutBE32(file, (uint32_t)(4 + chunks.length));
    CLPutASCII(file, "AIFF");
    [file appendData:chunks];
    return file;
}

#pragma mark - Fixtures shared by the tests and the robustness sweeps

static NSString *const kCLLRCText = @"[ar:Artist]\n[ti:Title]\n[00:01.00]First\n[00:03.50]Second\n";

static NSData *CLFixtureID3v23UTF16(void) {
    return CLWithAudio(CLID3Tag(3, @[ CLID3Frame(3, "TIT2", 0, CLTextPayload(@"Title")),
                                      CLID3Frame(3, "USLT", 0, CLUSLTPayload(@"Grüße 🎵\nZweite Zeile",
                                                                             CLTestFormUTF16LE)) ],
                                32));
}

/// A long Latin-1 lyric so frame sizes pass 127 (synchsafe and plain readings differ) and hold 0xFF.
static NSString *CLLongLatin1Lyric(NSUInteger length) {
    NSMutableString *text = [@"ÿ first line\nsecond ÿ line\n" mutableCopy];
    while (text.length < length) [text appendString:@"la "];
    return [[text substringToIndex:length - 1] stringByAppendingString:@"!"];   // trimmed text ends here
}

/// ID3v2.4, USLT with frame-level unsynchronisation and a data length indicator, then TIT2.
static NSData *CLFixtureID3v24Unsync(NSString *text) {
    NSData *payload = CLUSLTPayload(text, CLTestFormLatin1);
    NSMutableData *framed = [NSMutableData data];
    CLPutSynchsafe(framed, (uint32_t)payload.length);        // data length indicator
    [framed appendData:CLUnsynchronised(payload)];
    return CLWithAudio(CLID3Tag(4, @[ CLID3Frame(4, "USLT", 0x0003, framed),
                                      CLID3Frame(4, "TIT2", 0, CLTextPayload(@"Title")) ],
                                8));
}

/// ID3v2.3 with whole-tag unsynchronisation; the USLT payload is exactly 255 bytes, so even its
/// frame size (00 00 00 FF) is unsynchronised.
static NSData *CLFixtureID3v23TagUnsync(NSString *text) {
    NSData *body = CLJoin(@[ CLID3Frame(3, "USLT", 0, CLUSLTPayload(text, CLTestFormLatin1)),
                             CLID3Frame(3, "TIT2", 0, CLTextPayload(@"Title")) ]);
    NSMutableData *padded = [body mutableCopy];
    CLPutZeros(padded, 8);
    return CLWithAudio(CLID3TagWithBody(3, 0x80, CLUnsynchronised(padded)));
}

static NSArray *CLSYLTLineEntries(void) {
    return @[ @"\nFirst line", @1000, @"\nSecond line", @2500, @"", @4000, @"\nThird ", @6000 ];
}

static NSData *CLFixtureSYLT(void) {
    return CLWithAudio(CLID3Tag(3, @[ CLID3Frame(3, "USLT", 0, CLUSLTPayload(@"Plain first", CLTestFormLatin1)),
                                      CLID3Frame(3, "SYLT", 0, CLSYLTPayload(2, CLTestFormUTF8, CLSYLTLineEntries())) ],
                                16));
}

static NSArray *CLSYLTWordEntries(void) {
    return @[ @"\nHello", @1000, @" big", @1200, @" world", @1400,
              @"\nSecond", @3000, @" line", @3300, @" here", @3600,
              @"\n", @5000,
              @"\nLast", @7000, @" one", @7200, @" now", @7400 ];
}

static NSData *CLFixtureSYLTWords(void) {
    return CLWithAudio(CLID3Tag(4, @[ CLID3Frame(4, "SYLT", 0, CLSYLTPayloadForms(2, CLTestFormUTF16BE,
                                                                                  CLTestFormUTF16BEBare,
                                                                                  CLSYLTWordEntries())) ],
                                0));
}

static NSData *CLFixtureID3v22(void) {
    return CLWithAudio(CLID3Tag(2, @[ CLID3Frame(2, "TT2", 0, CLTextPayload(@"Title")),
                                      CLID3Frame(2, "ULT", 0, CLUSLTPayload(@"Old tag\nStill read", CLTestFormLatin1)) ],
                                4));
}

static NSData *CLFixtureMP4(void) {
    return CLMP4File(@[ CLItem("\xA9nam", @"Title"), CLItem("\xA9lyr", @"Plain from lyr"),
                        CLFreeformItem(@"LYRICS", kCLLRCText) ],
                     CLMP4OptionLargeMoov, nil);
}

static NSData *CLFixtureFLAC(void) {
    NSData *prefix = CLID3Tag(3, @[ CLID3Frame(3, "TIT2", 0, CLTextPayload(@"Title")) ], 8);
    return CLFLACFile(prefix, @[ @"TITLE=Title", @"LYRICS=Plain lyrics\nLine two",
                                 [@"SYNCEDLYRICS=" stringByAppendingString:kCLLRCText] ]);
}

static NSData *CLFixtureOggVorbis(void) {
    NSString *filler = [@"DESCRIPTION=" stringByPaddingToLength:470 withString:@"x" startingAtIndex:0];
    NSData *comment = CLVorbisCommentPacket(@[ @"TITLE=Title", filler,
                                               [@"LYRICS=" stringByAppendingString:kCLLRCText] ]);
    return CLOggFile(@[ CLVorbisIdentification(), comment, CLVorbisSetup() ], 2, YES);
}

static NSData *CLFixtureOpus(void) {
    return CLOggFile(@[ CLOpusHead(), CLOpusTags(@[ @"ARTIST=Artist", @"UNSYNCED LYRICS=Opus plain\nline two" ]) ],
                     255, NO);
}

static NSData *CLFixtureWAV(void) {
    NSData *tag = CLID3Tag(3, @[ CLID3Frame(3, "USLT", 0, CLUSLTPayload(@"From a WAV", CLTestFormLatin1)) ], 3);
    return CLWAVFile(tag, "id3 ");
}

static NSData *CLFixtureAIFF(void) {
    NSData *tag = CLID3Tag(4, @[ CLID3Frame(4, "USLT", 0, CLUSLTPayload(@"From an AIFF", CLTestFormUTF8)) ], 1);
    return CLAIFFFile(tag);
}

#pragma mark - ID3

static void CLTestID3v23USLTEncodings(void) {
    NSString *latin = @"Café au lait\nSecond line";
    CLTestForm latinForms[] = { CLTestFormLatin1, CLTestFormUTF16LE, CLTestFormUTF16BE, CLTestFormUTF16BEBare,
                                CLTestFormUTF8 };
    for (size_t i = 0; i < sizeof(latinForms) / sizeof(latinForms[0]); i++) {
        NSData *file = CLWithAudio(CLID3Tag(3, @[ CLID3Frame(3, "TIT2", 0, CLTextPayload(@"Title")),
                                                  CLID3Frame(3, "USLT", 0, CLUSLTPayload(latin, latinForms[i])) ],
                                            64));
        CLLyrics *lyrics = CLRead(file);
        CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
        CL_ASSERT_EQ(lyrics.plainText, latin);
        CL_ASSERT_EQ(lyrics.source, kCLTestSource);
        CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)0);
    }

    // Outside Latin-1: a surrogate pair survives both byte orders.
    CLLyrics *lyrics = CLRead(CLFixtureID3v23UTF16());
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, @"Grüße 🎵\nZweite Zeile");

    NSData *bigEndian = CLID3Tag(3, @[ CLID3Frame(3, "USLT", 0, CLUSLTPayload(@"Grüße 🎵", CLTestFormUTF16BE)) ], 0);
    CL_ASSERT_EQ(CLRead(bigEndian).plainText, @"Grüße 🎵");

    // Windows-1252 bytes in an encoding-0 frame (curly quotes) read as 1252, not as C1 controls.
    NSMutableData *payload = [NSMutableData data];
    CLPut8(payload, 0);
    CLPutASCII(payload, "eng");
    CLPut8(payload, 0);
    const uint8_t quoted[] = { 0x93, 'H', 'i', 0x94, ' ', 0x80 };
    [payload appendBytes:quoted length:sizeof(quoted)];
    CL_ASSERT_EQ(CLRead(CLID3Tag(3, @[ CLID3Frame(3, "USLT", 0, payload) ], 0)).plainText, @"“Hi” €");
}

static void CLTestID3v24SynchsafeSizes(void) {
    NSMutableString *text = [NSMutableString string];
    for (int i = 1; i <= 12; i++) [text appendFormat:@"line %d of a lyric long enough\n", i];
    [text appendString:@"the end"];
    NSData *tag = CLID3Tag(4, @[ CLID3Frame(4, "USLT", 0, CLUSLTPayload(text, CLTestFormUTF8)),
                                 CLID3Frame(4, "TIT2", 0, CLTextPayload(@"Title")) ],
                           20);
    CLLyrics *lyrics = CLRead(CLWithAudio(tag));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, text);

    // iTunes-style: a 2.4 tag whose frame sizes were written as plain 2.3 integers.
    NSData *itunes = CLID3Tag(4, @[ CLID3Frame(3, "USLT", 0, CLUSLTPayload(text, CLTestFormUTF8)),
                                    CLID3Frame(4, "TIT2", 0, CLTextPayload(@"Title")) ],
                              20);
    CL_ASSERT_EQ(CLRead(CLWithAudio(itunes)).plainText, text);
}

static void CLTestID3Unsynchronisation(void) {
    NSString *text = CLLongLatin1Lyric(120);
    CLLyrics *lyrics = CLRead(CLFixtureID3v24Unsync(text));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, text);

    // 2.3 whole-tag: USLT payload = 1 + 3 + "desc\0" + 246 bytes of text = 255 bytes.
    NSString *longText = CLLongLatin1Lyric(246);
    lyrics = CLRead(CLFixtureID3v23TagUnsync(longText));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, longText);
}

static void CLTestID3v22AndExtendedHeaders(void) {
    CLLyrics *lyrics = CLRead(CLFixtureID3v22());
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, @"Old tag\nStill read");

    NSData *uslt3 = CLID3Frame(3, "USLT", 0, CLUSLTPayload(@"After a 2.3 extended header", CLTestFormLatin1));
    NSMutableData *body3 = [NSMutableData data];
    CLPutBE32(body3, 6);                            // excludes itself
    CLPutBE16(body3, 0);
    CLPutBE32(body3, 0);                            // padding size
    [body3 appendData:uslt3];
    CL_ASSERT_EQ(CLRead(CLID3TagWithBody(3, 0x40, body3)).plainText, @"After a 2.3 extended header");

    NSData *uslt4 = CLID3Frame(4, "USLT", 0, CLUSLTPayload(@"After a 2.4 extended header", CLTestFormUTF8));
    NSMutableData *body4 = [NSMutableData data];
    CLPutSynchsafe(body4, 6);                       // includes itself
    CLPut8(body4, 1);                               // one flag byte
    CLPut8(body4, 0);
    [body4 appendData:uslt4];
    CL_ASSERT_EQ(CLRead(CLID3TagWithBody(4, 0x40, body4)).plainText, @"After a 2.4 extended header");
}

static void CLTestID3SkipsCompressedAndEncryptedFrames(void) {
    NSData *compressed = CLID3Frame(3, "USLT", 0x0080, CLUSLTPayload(@"Compressed", CLTestFormLatin1));
    NSData *encrypted = CLID3Frame(4, "USLT", 0x0004, CLUSLTPayload(@"Encrypted", CLTestFormLatin1));
    NSData *plain = CLID3Frame(3, "USLT", 0, CLUSLTPayload(@"Readable", CLTestFormLatin1));
    CL_ASSERT_EQ(CLRead(CLID3Tag(3, @[ compressed, plain ], 0)).plainText, @"Readable");
    CL_ASSERT_NIL(CLRead(CLID3Tag(4, @[ encrypted ], 0)));

    // 2.3 grouping identity: one extra byte before the payload.
    NSMutableData *grouped = [NSMutableData data];
    CLPut8(grouped, 7);
    [grouped appendData:CLUSLTPayload(@"Grouped", CLTestFormLatin1)];
    CL_ASSERT_EQ(CLRead(CLID3Tag(3, @[ CLID3Frame(3, "USLT", 0x0020, grouped) ], 0)).plainText, @"Grouped");
}

static void CLTestSYLTMilliseconds(void) {
    CLLyrics *lyrics = CLRead(CLFixtureSYLT());
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)4);
    CL_ASSERT_NEAR(CLLineAt(lyrics, 0).time, 1.0, 0.0005);
    CL_ASSERT_NEAR(CLLineAt(lyrics, 1).time, 2.5, 0.0005);
    CL_ASSERT_NEAR(CLLineAt(lyrics, 2).time, 4.0, 0.0005);
    CL_ASSERT_NEAR(CLLineAt(lyrics, 3).time, 6.0, 0.0005);
    CL_ASSERT_EQ(CLLineAt(lyrics, 0).text, @"First line");
    CL_ASSERT_EQ(CLLineAt(lyrics, 1).text, @"Second line");
    CL_ASSERT_EQ(CLLineAt(lyrics, 2).text, @"");
    CL_ASSERT_EQ(CLLineAt(lyrics, 3).text, @"Third");
    CL_ASSERT_EQ(lyrics.plainText, @"First line\nSecond line\n\nThird");

    // UTF-16 with a BOM on every string.
    NSData *utf16 = CLID3Tag(3, @[ CLID3Frame(3, "SYLT", 0, CLSYLTPayload(2, CLTestFormUTF16LE, CLSYLTLineEntries())) ], 0);
    lyrics = CLRead(utf16);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)4);
    CL_ASSERT_EQ(CLLineAt(lyrics, 1).text, @"Second line");

    // Entries out of order are sorted.
    NSData *unsorted = CLID3Tag(3, @[ CLID3Frame(3, "SYLT", 0, CLSYLTPayload(2, CLTestFormLatin1,
                                                                             @[ @"B", @2000, @"A", @1000 ])) ], 0);
    lyrics = CLRead(unsorted);
    CL_ASSERT_EQ(CLLineAt(lyrics, 0).text, @"A");
    CL_ASSERT_EQ(CLLineAt(lyrics, 1).text, @"B");

    // Lone line breaks between whole-line entries are gap markers, not a reason to join entries.
    NSData *gaps = CLID3Tag(3, @[ CLID3Frame(3, "SYLT", 0, CLSYLTPayload(2, CLTestFormUTF8,
                                                                         @[ @"First line", @1000, @"\n", @2000,
                                                                            @"Second line", @3000 ])) ], 0);
    lyrics = CLRead(gaps);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)3);
    CL_ASSERT_EQ(CLLineAt(lyrics, 0).text, @"First line");
    CL_ASSERT_EQ(CLLineAt(lyrics, 1).text, @"");
    CL_ASSERT_EQ(CLLineAt(lyrics, 2).text, @"Second line");
}

static void CLTestSYLTWordTimedEntriesAreJoined(void) {
    // The descriptor carries a big-endian BOM and the entries none: they must be read big-endian.
    CLLyrics *lyrics = CLRead(CLFixtureSYLTWords());
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)4);
    CL_ASSERT_EQ(CLLineAt(lyrics, 0).text, @"Hello big world");
    CL_ASSERT_NEAR(CLLineAt(lyrics, 0).time, 1.0, 0.0005);
    CL_ASSERT_EQ(CLLineAt(lyrics, 1).text, @"Second line here");
    CL_ASSERT_NEAR(CLLineAt(lyrics, 1).time, 3.0, 0.0005);
    CL_ASSERT_EQ(CLLineAt(lyrics, 2).text, @"");
    CL_ASSERT_NEAR(CLLineAt(lyrics, 2).time, 5.0, 0.0005);
    CL_ASSERT_EQ(CLLineAt(lyrics, 3).text, @"Last one now");
    CL_ASSERT_NEAR(CLLineAt(lyrics, 3).time, 7.0, 0.0005);
}

static void CLTestSYLTIgnoredShapes(void) {
    // MPEG-frame stamps need the audio stream: ignored.
    NSData *frames = CLID3Frame(3, "SYLT", 0, CLSYLTPayload(1, CLTestFormLatin1, CLSYLTLineEntries()));
    CL_ASSERT_NIL(CLRead(CLID3Tag(3, @[ frames ], 0)));
    CLLyrics *lyrics = CLRead(CLID3Tag(3, @[ frames, CLID3Frame(3, "USLT", 0, CLUSLTPayload(@"Fallback", CLTestFormLatin1)) ], 0));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, @"Fallback");

    // Every stamp equal: no timing, so plain text.
    NSData *flat = CLID3Frame(3, "SYLT", 0, CLSYLTPayload(2, CLTestFormLatin1, @[ @"One", @0, @"Two", @0 ]));
    lyrics = CLRead(CLID3Tag(3, @[ flat ], 0));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, @"One\nTwo");
}

static void CLTestTXXXLyrics(void) {
    CLLyrics *lyrics = CLRead(CLID3Tag(3, @[ CLID3Frame(3, "TXXX", 0, CLTXXXPayload(@"LYRICS", @"From TXXX\nLine 2",
                                                                                   CLTestFormLatin1)) ], 0));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, @"From TXXX\nLine 2");

    lyrics = CLRead(CLID3Tag(4, @[ CLID3Frame(4, "TXXX", 0, CLTXXXPayload(@"unsynced lyrics", @"Lowercase key",
                                                                         CLTestFormUTF8)) ], 0));
    CL_ASSERT_EQ(lyrics.plainText, @"Lowercase key");

    lyrics = CLRead(CLID3Tag(3, @[ CLID3Frame(3, "TXXX", 0, CLTXXXPayload(@"LYRICS-ENG", @"Language suffix",
                                                                         CLTestFormUTF16LE)) ], 0));
    CL_ASSERT_EQ(lyrics.plainText, @"Language suffix");

    CL_ASSERT_NIL(CLRead(CLID3Tag(3, @[ CLID3Frame(3, "TXXX", 0, CLTXXXPayload(@"COMMENT", @"Not lyrics",
                                                                              CLTestFormLatin1)),
                                        CLID3Frame(3, "TXXX", 0, CLTXXXPayload(@"LYRICIST", @"Not lyrics either",
                                                                              CLTestFormLatin1)) ], 0)));
}

static void CLTestUSLTHoldingLRC(void) {
    CLLyrics *lyrics = CLRead(CLID3Tag(3, @[ CLID3Frame(3, "USLT", 0, CLUSLTPayload(kCLLRCText, CLTestFormUTF8)) ], 0));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)2);
    CL_ASSERT_NEAR(CLLineAt(lyrics, 0).time, 1.0, 0.0005);
    CL_ASSERT_NEAR(CLLineAt(lyrics, 1).time, 3.5, 0.0005);
    CL_ASSERT_EQ(CLLineAt(lyrics, 1).text, @"Second");
    CL_ASSERT_EQ(lyrics.plainText, @"First\nSecond");
}

static void CLTestCandidateChoice(void) {
    // Plain USLT first, SYLT later: synced wins.
    CLLyrics *lyrics = CLRead(CLFixtureSYLT());
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(CLLineAt(lyrics, 0).text, @"First line");

    // Plain USLT, then a USLT holding LRC: the LRC one wins.
    lyrics = CLRead(CLID3Tag(3, @[ CLID3Frame(3, "USLT", 0, CLUSLTPayload(@"Plain", CLTestFormLatin1)),
                                   CLID3Frame(3, "USLT", 0, CLUSLTPayload(kCLLRCText, CLTestFormLatin1)) ], 0));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(CLLineAt(lyrics, 0).text, @"First");

    // Two synced candidates: the first in document order.
    lyrics = CLRead(CLID3Tag(3, @[ CLID3Frame(3, "USLT", 0, CLUSLTPayload(@"[00:05.00]Early\n[00:06.00]Two",
                                                                         CLTestFormLatin1)),
                                   CLID3Frame(3, "USLT", 0, CLUSLTPayload(kCLLRCText, CLTestFormLatin1)) ], 0));
    CL_ASSERT_EQ(CLLineAt(lyrics, 0).text, @"Early");

    // Only plain candidates: the first.
    lyrics = CLRead(CLID3Tag(3, @[ CLID3Frame(3, "USLT", 0, CLUSLTPayload(@"First plain", CLTestFormLatin1)),
                                   CLID3Frame(3, "TXXX", 0, CLTXXXPayload(@"LYRICS", @"Second plain", CLTestFormLatin1)) ],
                             0));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, @"First plain");
}

#pragma mark - MP4

static void CLTestMP4Lyrics(void) {
    CLLyrics *lyrics = CLRead(CLMP4File(@[ CLItem("\xA9nam", @"Title"), CLItem("\xA9lyr", @"Line one\nLine two") ], 0, nil));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, @"Line one\nLine two");

    // QuickTime-style meta (no version/flags) and a 64-bit moov.
    lyrics = CLRead(CLMP4File(@[ CLItem("\xA9lyr", @"Bare meta") ], CLMP4OptionBareMeta | CLMP4OptionLargeMoov, nil));
    CL_ASSERT_EQ(lyrics.plainText, @"Bare meta");

    // "----" LYRICS holding LRC beats the plain ©lyr before it.
    lyrics = CLRead(CLFixtureMP4());
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)2);
    CL_ASSERT_EQ(CLLineAt(lyrics, 0).text, @"First");

    // A free-form atom with another name is not lyrics.
    CL_ASSERT_NIL(CLRead(CLMP4File(@[ CLFreeformItem(@"iTunNORM", @"00000A0B") ], 0, nil)));
    CL_ASSERT_NIL(CLRead(CLMP4File(@[ CLItem("\xA9nam", @"Only a title") ], 0, nil)));
}

static NSData *CLBigMdatBeforeMoov(void) {
    // A 1 MB 64-bit mdat whose first bytes look like a moov with other lyrics: it must be skipped
    // by its header, never walked.
    NSData *decoy = CLMP4File(@[ CLItem("\xA9lyr", @"WRONG") ], 0, nil);
    NSMutableData *payload = [decoy mutableCopy];
    CLPutZeros(payload, (1u << 20) - payload.length);
    return CLMP4File(@[ CLItem("\xA9lyr", @"After the mdat") ], 0, CLLargeAtom("mdat", payload));
}

static void CLTestMP4SkipsMdat(void) {
    NSData *file = CLBigMdatBeforeMoov();
    CL_ASSERT_EQ(CLRead(file).plainText, @"After the mdat");

    // The same file memory-mapped, as the provider will pass it.
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"CLEmbeddedLyricsReaderTests-%d.m4a", (int)getpid()]];
    CL_ASSERT_TRUE([file writeToFile:path atomically:NO]);
    NSData *mapped = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedAlways error:NULL];
    CL_ASSERT_NOT_NIL(mapped);
    CL_ASSERT_EQ([CLEmbeddedLyricsReader lyricsFromAudioData:mapped source:kCLTestSource].plainText, @"After the mdat");
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void CLTestMP4DepthIsCapped(void) {
    NSData *nested = CLAtom("ilst", CLItem("\xA9lyr", @"Too deep"));
    for (int i = 0; i < 40; i++) nested = CLAtom("moov", nested);
    NSMutableData *file = [NSMutableData data];
    CLPutBE32(file, 16);
    CLPutASCII(file, "ftypM4A ");
    CLPutBE32(file, 0);
    [file appendData:nested];
    CL_ASSERT_NIL(CLRead(file));
}

#pragma mark - FLAC / Ogg

static void CLTestFLAC(void) {
    CLLyrics *lyrics = CLRead(CLFixtureFLAC());
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)2);
    CL_ASSERT_NEAR(CLLineAt(lyrics, 1).time, 3.5, 0.0005);

    lyrics = CLRead(CLFLACFile(nil, @[ @"TITLE=Title", @"unsyncedlyrics=Only plain\nhere" ]));
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, @"Only plain\nhere");

    // ID3v2.4 prefix with a footer before "fLaC".
    NSMutableData *prefix = [NSMutableData data];
    NSData *frames = CLID3Frame(4, "TIT2", 0, CLTextPayload(@"Title"));
    CLPutASCII(prefix, "ID3");
    CLPut8(prefix, 4);
    CLPut8(prefix, 0);
    CLPut8(prefix, 0x10);
    CLPutSynchsafe(prefix, (uint32_t)frames.length);
    [prefix appendData:frames];
    CLPutASCII(prefix, "3DI");
    CLPut8(prefix, 4);
    CLPut8(prefix, 0);
    CLPut8(prefix, 0x10);
    CLPutSynchsafe(prefix, (uint32_t)frames.length);
    lyrics = CLRead(CLFLACFile(prefix, @[ @"LYRICS=Behind a footer" ]));
    CL_ASSERT_EQ(lyrics.plainText, @"Behind a footer");

    CL_ASSERT_NIL(CLRead(CLFLACFile(nil, @[ @"TITLE=Title", @"ARTIST=Artist" ])));
}

static void CLTestOgg(void) {
    CLLyrics *lyrics = CLRead(CLFixtureOggVorbis());
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)2);
    CL_ASSERT_EQ(CLLineAt(lyrics, 0).text, @"First");
    CL_ASSERT_EQ(CLLineAt(lyrics, 1).text, @"Second");

    lyrics = CLRead(CLFixtureOpus());
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, @"Opus plain\nline two");

    CL_ASSERT_NIL(CLRead(CLOggFile(@[ CLVorbisIdentification(), CLVorbisCommentPacket(@[ @"TITLE=No lyrics" ]),
                                      CLVorbisSetup() ], 255, NO)));
}

#pragma mark - WAV / AIFF

static void CLTestWAVAndAIFF(void) {
    CLLyrics *lyrics = CLRead(CLFixtureWAV());
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, @"From a WAV");

    NSData *upper = CLID3Tag(3, @[ CLID3Frame(3, "USLT", 0, CLUSLTPayload(@"Upper-case chunk", CLTestFormLatin1)) ], 0);
    CL_ASSERT_EQ(CLRead(CLWAVFile(upper, "ID3 ")).plainText, @"Upper-case chunk");

    lyrics = CLRead(CLFixtureAIFF());
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, @"From an AIFF");
}

#pragma mark - Nothing to find

static void CLTestNoLyrics(void) {
    CL_ASSERT_NIL([CLEmbeddedLyricsReader lyricsFromAudioData:nil source:kCLTestSource]);
    CL_ASSERT_NIL(CLRead([NSData data]));
    CL_ASSERT_NIL(CLRead(CLID3Tag(3, @[ CLID3Frame(3, "TIT2", 0, CLTextPayload(@"Only a title")) ], 16)));
    CL_ASSERT_NIL(CLRead([NSData dataWithBytes:"ID3\x03\x00\x00\x00" length:7]));

    NSMutableData *avi = [NSMutableData data];
    CLPutASCII(avi, "RIFF");
    CLPutLE32(avi, 100);
    CLPutASCII(avi, "AVI LIST");
    CLPutZeros(avi, 100);
    CL_ASSERT_NIL(CLRead(avi));

    const uint8_t png[] = { 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 'I', 'H', 'D', 'R' };
    CL_ASSERT_NIL(CLRead([NSData dataWithBytes:png length:sizeof(png)]));

    NSMutableData *noise = [NSMutableData data];
    uint32_t state = 12345;
    for (int i = 0; i < 4096; i++) {
        state = state * 1103515245u + 12345u;
        CLPut8(noise, (uint8_t)(state >> 16));
    }
    CL_ASSERT_NIL(CLRead(noise));
}

#pragma mark - Text helpers

static NSData *CLBytes(const char *bytes, size_t length) {
    return [NSData dataWithBytes:bytes length:length];
}

static void CLTestStringFromTextData(void) {
    CL_ASSERT_NIL([CLEmbeddedLyricsReader stringFromTextData:nil]);
    CL_ASSERT_NIL([CLEmbeddedLyricsReader stringFromTextData:[NSData data]]);

    NSString *text = @"Grüße [00:01.00] 🎵";
    CL_ASSERT_EQ([CLEmbeddedLyricsReader stringFromTextData:[text dataUsingEncoding:NSUTF8StringEncoding]], text);

    NSMutableData *utf8BOM = [NSMutableData dataWithBytes:"\xEF\xBB\xBF" length:3];
    [utf8BOM appendData:[text dataUsingEncoding:NSUTF8StringEncoding]];
    CL_ASSERT_EQ([CLEmbeddedLyricsReader stringFromTextData:utf8BOM], text);

    NSMutableData *utf16LE = [NSMutableData dataWithBytes:"\xFF\xFE" length:2];
    [utf16LE appendData:[text dataUsingEncoding:NSUTF16LittleEndianStringEncoding]];
    CL_ASSERT_EQ([CLEmbeddedLyricsReader stringFromTextData:utf16LE], text);

    NSMutableData *utf16BE = [NSMutableData dataWithBytes:"\xFE\xFF" length:2];
    [utf16BE appendData:[text dataUsingEncoding:NSUTF16BigEndianStringEncoding]];
    CL_ASSERT_EQ([CLEmbeddedLyricsReader stringFromTextData:utf16BE], text);

    CL_ASSERT_EQ([CLEmbeddedLyricsReader stringFromTextData:CLBytes("\x93Hi\x94 \x80", 6)], @"“Hi” €");
    CL_ASSERT_EQ([CLEmbeddedLyricsReader stringFromTextData:CLBytes("Caf\xE9", 4)], @"Café");
    // 0x81 is undefined in Windows-1252: still decoded (as ISO-8859-1), never nil.
    CL_ASSERT_NOT_NIL([CLEmbeddedLyricsReader stringFromTextData:CLBytes("a\x81" "b", 3)]);
    CL_ASSERT_EQ([CLEmbeddedLyricsReader stringFromTextData:CLBytes("\xEF\xBB\xBF", 3)], @"");
}

static CLLyrics *CLFromText(NSString *text) {
    return [CLEmbeddedLyricsReader lyricsFromText:text source:kCLTestSource];
}

static void CLTestLyricsFromText(void) {
    CL_ASSERT_NIL([CLEmbeddedLyricsReader lyricsFromText:nil source:kCLTestSource]);
    CL_ASSERT_NIL(CLFromText(@""));
    CL_ASSERT_NIL(CLFromText(@"  \n \r\n\t"));
    CL_ASSERT_NIL(CLFromText(@"[ar:Artist]\n[ti:Title]\n[length: 03:12]\n"));
    CL_ASSERT_NIL(CLFromText(@"[00:01.00]\n[00:02.00]"));   // timing without a word

    // LRC header tags go, CRLF and CR become LF, the result is trimmed.
    CLLyrics *lyrics = CLFromText(@"[ar:Artist]\r\n[ti:Title]\r\n[AL:Album]\r\n\r\nFirst line\r\nSecond line\rThird\r\n");
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, @"First line\nSecond line\nThird");
    CL_ASSERT_EQ(lyrics.source, kCLTestSource);

    // Section labels are lyrics, not LRC tags.
    NSString *sections = @"[Chorus: Someone]\nLa la\n\n[Verse 1]\nDa da\n[Intro]";
    CL_ASSERT_EQ(CLFromText(sections).plainText, sections);

    // One stray timestamp in a plain lyric: still plain, text untouched.
    NSString *stray = @"[00:00]Intro\nSecond line\nThird line";
    lyrics = CLFromText(stray);
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindPlain);
    CL_ASSERT_EQ(lyrics.plainText, stray);

    // A one-line LRC is synced.
    lyrics = CLFromText(@"[ti:Title]\n[00:12.00]Only line");
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)1);
    CL_ASSERT_NEAR(CLLineAt(lyrics, 0).time, 12.0, 0.0005);

    // Two timed lines of five: plain. Three of five: synced (untimed lines dropped).
    CL_ASSERT_EQ((long)CLFromText(@"[00:01]a\n[00:02]b\nc\nd\ne").kind, (long)CLLyricsKindPlain);
    lyrics = CLFromText(@"[00:01]a\n[00:02]b\n[00:03]c\nd\ne");
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)3);

    // A full LRC with a BOM, CRLF and an instrumental gap.
    lyrics = CLFromText(@"﻿[ar:A]\r\n[00:01.00]One\r\n[00:02.00]\r\n[00:03.00]Three\r\n");
    CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced);
    CL_ASSERT_EQ(lyrics.lines.count, (NSUInteger)3);
    CL_ASSERT_EQ(CLLineAt(lyrics, 1).text, @"");
    CL_ASSERT_EQ(lyrics.plainText, @"One\n\nThree");
    CL_ASSERT_EQ(lyrics.source, kCLTestSource);
}

#pragma mark - Robustness

/// Feeds every prefix of `fixture`, then the fixture with each position overwritten by a few
/// length-field shapes (0xFF, 0x00, 0x80, FF FF FF FF, 7F FF FF FF). Nothing may crash, hang or
/// read out of bounds; the results themselves are not checked.
static void CLSweepFixture(const char *name, NSData *fixture) {
    const uint8_t *bytes = fixture.bytes;
    size_t length = fixture.length;
    NSUInteger runs = 0;
    for (size_t cut = 0; cut <= length; cut++) {
        @autoreleasepool {
            (void)[CLEmbeddedLyricsReader lyricsFromAudioData:CLExactCopy(bytes, cut) source:kCLTestSource];
            runs++;
        }
    }

    static const uint8_t patterns[][4] = {
        { 0xFF, 0, 0, 0 }, { 0x00, 0, 0, 0 }, { 0x80, 0, 0, 0 }, { 0xFF, 0xFF, 0xFF, 0xFF }, { 0x7F, 0xFF, 0xFF, 0xFF },
    };
    static const size_t patternLengths[] = { 1, 1, 1, 4, 4 };
    size_t patternCount = sizeof(patternLengths) / sizeof(patternLengths[0]);
    uint8_t *scratch = malloc(length);
    for (size_t i = 0; scratch && i < length; i++) {
        for (size_t p = 0; p < patternCount; p++) {
            @autoreleasepool {
                memcpy(scratch, bytes, length);
                memcpy(scratch + i, patterns[p], MIN(patternLengths[p], length - i));
                (void)[CLEmbeddedLyricsReader lyricsFromAudioData:CLExactCopy(scratch, length) source:kCLTestSource];
                runs++;
            }
        }
    }
    free(scratch);
    CLTestRecordResult(runs == (length + 1) + length * patternCount, name, __FILE__, __LINE__);
}

static void CLTestRobustness(void) {
    CLSweepFixture("sweep: ID3v2.3 UTF-16 USLT", CLFixtureID3v23UTF16());
    CLSweepFixture("sweep: ID3v2.4 frame unsync", CLFixtureID3v24Unsync(CLLongLatin1Lyric(60)));
    CLSweepFixture("sweep: ID3v2.3 tag unsync", CLFixtureID3v23TagUnsync(CLLongLatin1Lyric(246)));
    CLSweepFixture("sweep: ID3v2.2 ULT", CLFixtureID3v22());
    CLSweepFixture("sweep: SYLT lines", CLFixtureSYLT());
    CLSweepFixture("sweep: SYLT words UTF-16", CLFixtureSYLTWords());
    // Frames that end exactly where the data ends, so reading past a frame is reading past the buffer.
    CLSweepFixture("sweep: SYLT ends the data",
                   CLID3Tag(3, @[ CLID3Frame(3, "SYLT", 0, CLSYLTPayload(2, CLTestFormUTF16LE, CLSYLTLineEntries())) ], 0));
    CLSweepFixture("sweep: TXXX ends the data",
                   CLID3Tag(4, @[ CLID3Frame(4, "TXXX", 0, CLTXXXPayload(@"LYRICS", @"Last frame", CLTestFormUTF16LE)) ], 0));
    CLSweepFixture("sweep: USLT ends the data",
                   CLID3Tag(3, @[ CLID3Frame(3, "USLT", 0, CLUSLTPayload(@"Last frame", CLTestFormUTF8)) ], 0));
    NSMutableData *odd = [CLTXXXPayload(@"LYRICS", @"Odd length", CLTestFormUTF16LE) mutableCopy];
    CLPut8(odd, 'x');                               // half a UTF-16 unit, then the data ends
    CLSweepFixture("sweep: odd-length UTF-16 ends the data", CLID3Tag(3, @[ CLID3Frame(3, "TXXX", 0, odd) ], 0));
    CLSweepFixture("sweep: MP4", CLFixtureMP4());
    CLSweepFixture("sweep: FLAC with ID3", CLFixtureFLAC());
    CLSweepFixture("sweep: Ogg Vorbis", CLFixtureOggVorbis());
    CLSweepFixture("sweep: Opus", CLFixtureOpus());
    CLSweepFixture("sweep: WAV", CLFixtureWAV());
    CLSweepFixture("sweep: AIFF", CLFixtureAIFF());

    // Hand-made hostile headers.
    NSMutableData *hugeFrame = [NSMutableData data];
    CLPutASCII(hugeFrame, "ID3");
    CLPut8(hugeFrame, 4);
    CLPut8(hugeFrame, 0);
    CLPut8(hugeFrame, 0);
    CLPutSynchsafe(hugeFrame, 0x0FFFFFFF);
    CLPutASCII(hugeFrame, "USLT");
    CLPutSynchsafe(hugeFrame, 0x0FFFFFFF);
    CLPutBE16(hugeFrame, 0);
    CLPutZeros(hugeFrame, 8);
    CL_ASSERT_NIL(CLRead(hugeFrame));

    NSMutableData *hugeAtom = [NSMutableData data];
    CLPutBE32(hugeAtom, 16);
    CLPutASCII(hugeAtom, "ftypM4A ");
    CLPutBE32(hugeAtom, 0);
    CLPutBE32(hugeAtom, 1);
    CLPutASCII(hugeAtom, "moov");
    CLPutBE64(hugeAtom, UINT64_MAX);
    CLPutBE32(hugeAtom, 1);
    CLPutASCII(hugeAtom, "udta");
    CLPutBE64(hugeAtom, UINT64_MAX - 7);
    CL_ASSERT_NIL(CLRead(hugeAtom));

    NSMutableData *manyComments = [NSMutableData data];
    CLPutASCII(manyComments, "fLaC");
    NSMutableData *comment = [NSMutableData data];
    CLPutLE32(comment, 0);
    CLPutLE32(comment, UINT32_MAX);
    CLPutLE32(comment, 0);                          // many empty comments would follow
    CLPutFLACBlock(manyComments, 4, YES, comment);
    CL_ASSERT_NIL(CLRead(manyComments));
}

void CLRunEmbeddedLyricsReaderTests(void) {
    CLTestBeginSuite("CLEmbeddedLyricsReader");
    CLTestID3v23USLTEncodings();
    CLTestID3v24SynchsafeSizes();
    CLTestID3Unsynchronisation();
    CLTestID3v22AndExtendedHeaders();
    CLTestID3SkipsCompressedAndEncryptedFrames();
    CLTestSYLTMilliseconds();
    CLTestSYLTWordTimedEntriesAreJoined();
    CLTestSYLTIgnoredShapes();
    CLTestTXXXLyrics();
    CLTestUSLTHoldingLRC();
    CLTestCandidateChoice();
    CLTestMP4Lyrics();
    CLTestMP4SkipsMdat();
    CLTestMP4DepthIsCapped();
    CLTestFLAC();
    CLTestOgg();
    CLTestWAVAndAIFF();
    CLTestNoLyrics();
    CLTestStringFromTextData();
    CLTestLyricsFromText();
    CLTestRobustness();
}
