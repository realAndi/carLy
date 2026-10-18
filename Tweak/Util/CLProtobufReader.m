#import "CLProtobufReader.h"
#import <string.h>

@implementation CLProtobufReader {
    NSData *_data;
    const uint8_t *_bytes;   // NULL only when _length == 0
    NSUInteger _length;
    NSUInteger _offset;
}

- (instancetype)initWithData:(NSData *)data {
    self = [super init];
    if (!self) return nil;
    _data = [data copy] ?: [NSData data];
    _length = _data.length;
    _bytes = _length > 0 ? (const uint8_t *)_data.bytes : NULL;
    if (!_bytes) _length = 0;
    _offset = 0;
    return self;
}

#pragma mark - Cursor

- (NSUInteger)offset { return _offset; }
- (NSUInteger)remaining { return _length - _offset; }
- (BOOL)isAtEnd { return _offset >= _length; }

- (BOOL)readVarint:(uint64_t *)outValue {
    uint64_t result = 0;
    NSUInteger shift = 0;
    NSUInteger cursor = _offset;
    while (cursor < _length) {
        uint8_t byte = _bytes[cursor];
        cursor += 1;
        // Bits past 64 are discarded, as every protobuf implementation does for over-long
        // encodings of negative 32-bit values.
        if (shift < 64) result |= ((uint64_t)(byte & 0x7F)) << shift;
        shift += 7;
        if ((byte & 0x80) == 0) {
            _offset = cursor;
            if (outValue) *outValue = result;
            return YES;
        }
        if (shift >= 70) return NO;   // more than ten bytes: malformed
    }
    return NO;                        // truncated
}

- (BOOL)readFixed32:(uint32_t *)outValue {
    if (_length - _offset < 4) return NO;
    uint32_t result = 0;
    for (NSUInteger i = 0; i < 4; i++) result |= ((uint32_t)_bytes[_offset + i]) << (8 * i);
    _offset += 4;
    if (outValue) *outValue = result;
    return YES;
}

- (BOOL)readFixed64:(uint64_t *)outValue {
    if (_length - _offset < 8) return NO;
    uint64_t result = 0;
    for (NSUInteger i = 0; i < 8; i++) result |= ((uint64_t)_bytes[_offset + i]) << (8 * i);
    _offset += 8;
    if (outValue) *outValue = result;
    return YES;
}

- (NSData *)readLengthDelimited {
    NSUInteger saved = _offset;
    uint64_t payloadLength = 0;
    if (![self readVarint:&payloadLength]) { _offset = saved; return nil; }
    if (payloadLength > (uint64_t)(_length - _offset)) { _offset = saved; return nil; }
    NSData *payload = [_data subdataWithRange:NSMakeRange(_offset, (NSUInteger)payloadLength)];
    if (!payload) { _offset = saved; return nil; }
    _offset += (NSUInteger)payloadLength;
    return payload;
}

#pragma mark - Enumeration

- (BOOL)enumerateFieldsUsingBlock:(CLProtobufFieldHandler)handler {
    if (!handler) return NO;
    while (_offset < _length) {
        uint64_t tag = 0;
        if (![self readVarint:&tag]) return NO;
        uint64_t rawFieldNumber = tag >> 3;
        // Field numbers start at 1 and stop at 2^29 - 1; anything else means we lost the frame.
        if (rawFieldNumber == 0 || rawFieldNumber > 0x1FFFFFFFULL) return NO;
        uint32_t fieldNumber = (uint32_t)rawFieldNumber;
        CLProtobufWireType wireType = (CLProtobufWireType)(tag & 0x07);

        BOOL stop = NO;
        switch (wireType) {
            case CLProtobufWireTypeVarint: {
                uint64_t value = 0;
                if (![self readVarint:&value]) return NO;
                handler(fieldNumber, wireType, value, nil, &stop);
                break;
            }
            case CLProtobufWireTypeFixed64: {
                uint64_t value = 0;
                if (![self readFixed64:&value]) return NO;
                handler(fieldNumber, wireType, value, nil, &stop);
                break;
            }
            case CLProtobufWireTypeLengthDelimited: {
                NSData *payload = [self readLengthDelimited];
                if (!payload) return NO;
                handler(fieldNumber, wireType, (uint64_t)payload.length, payload, &stop);
                break;
            }
            case CLProtobufWireTypeFixed32: {
                uint32_t value = 0;
                if (![self readFixed32:&value]) return NO;
                handler(fieldNumber, wireType, (uint64_t)value, nil, &stop);
                break;
            }
            case CLProtobufWireTypeStartGroup:
            case CLProtobufWireTypeEndGroup:
            default:
                return NO;   // groups and reserved wire types 6/7 are not supported
        }
        if (stop) return YES;
    }
    return YES;
}

+ (BOOL)enumerateFieldsInData:(NSData *)data usingBlock:(CLProtobufFieldHandler)handler {
    if (data.length == 0 || !handler) return NO;
    CLProtobufReader *reader = [[self alloc] initWithData:data];
    return [reader enumerateFieldsUsingBlock:handler];
}

#pragma mark - Payload helpers

+ (NSString *)stringFromData:(NSData *)data {
    if (!data) return nil;
    if (data.length == 0) return @"";
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

+ (int32_t)zigZagDecoded32:(uint64_t)value {
    uint32_t truncated = (uint32_t)value;
    return (int32_t)((truncated >> 1) ^ (uint32_t)(~(truncated & 1) + 1));
}

+ (int64_t)zigZagDecoded64:(uint64_t)value {
    return (int64_t)((value >> 1) ^ (uint64_t)(~(value & 1) + 1));
}

+ (float)floatFromFixed32:(uint32_t)value {
    float result = 0.0f;
    memcpy(&result, &value, sizeof(result));
    return result;
}

+ (double)doubleFromFixed64:(uint64_t)value {
    double result = 0.0;
    memcpy(&result, &value, sizeof(result));
    return result;
}

@end
