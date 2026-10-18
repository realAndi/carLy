// Minimal protobuf wire-format reader: no descriptors, no generated code, no dependencies.
// It is used to decode Spotify's cached `color-lyrics` response bodies (see
// docs/research/spotify-local-lyrics.md), so it only has to understand the wire format.
//
// Hard guarantees (this code runs inside a system UI process):
//   * never reads outside the buffer it was given;
//   * never raises, never asserts, never logs;
//   * malformed or truncated input stops iteration and makes the enumeration methods return NO;
//     fields decoded before the damage are still handed to the block, so a caller may keep them.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, CLProtobufWireType) {
    CLProtobufWireTypeVarint = 0,
    CLProtobufWireTypeFixed64 = 1,
    CLProtobufWireTypeLengthDelimited = 2,
    CLProtobufWireTypeStartGroup = 3,   // deprecated in protobuf; treated as malformed here
    CLProtobufWireTypeEndGroup = 4,     // deprecated in protobuf; treated as malformed here
    CLProtobufWireTypeFixed32 = 5,
};

/// Invoked once per field, in wire order.
/// `value`  — varint payload, or the zero-extended fixed32/fixed64 payload, or, for a
///            length-delimited field, the byte length of `data`.
/// `data`   — the bytes of a length-delimited field (a nested message, string or packed array);
///            nil for every other wire type. Never nil-but-length-delimited.
/// `stop`   — set *stop = YES to end the iteration early; the enumeration still returns YES.
typedef void (^CLProtobufFieldHandler)(uint32_t fieldNumber,
                                       CLProtobufWireType wireType,
                                       uint64_t value,
                                       NSData *_Nullable data,
                                       BOOL *stop);

@interface CLProtobufReader : NSObject

/// The reader keeps its own reference to `data`; passing nil yields an empty reader.
- (instancetype)initWithData:(nullable NSData *)data NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSUInteger offset;       // bytes consumed so far
@property (nonatomic, readonly) NSUInteger remaining;    // bytes left
@property (nonatomic, readonly, getter=isAtEnd) BOOL atEnd;

/// Cursor primitives. Each returns NO and leaves the cursor untouched when the buffer is too
/// short (or, for varints, when the encoding exceeds the legal ten bytes).
- (BOOL)readVarint:(nullable uint64_t *)outValue;
- (BOOL)readFixed32:(nullable uint32_t *)outValue;
- (BOOL)readFixed64:(nullable uint64_t *)outValue;
/// Length-delimited payload: a varint length followed by that many bytes. Returns nil on a
/// truncated or oversized length; returns a zero-length NSData for a legitimately empty field.
- (nullable NSData *)readLengthDelimited;

/// Walks the remaining fields. Returns NO if the input is malformed (bad tag, unsupported group
/// wire type, truncated varint or payload), YES when the buffer was consumed cleanly or the
/// handler asked to stop.
- (BOOL)enumerateFieldsUsingBlock:(CLProtobufFieldHandler)handler;
/// Convenience for one-shot decoding of a message (or of a nested message payload).
+ (BOOL)enumerateFieldsInData:(nullable NSData *)data usingBlock:(CLProtobufFieldHandler)handler;

/// UTF-8 decode of a length-delimited payload; nil when the bytes are not valid UTF-8.
+ (nullable NSString *)stringFromData:(nullable NSData *)data;
/// sint32 / sint64 (zig-zag) decoding of a varint payload.
+ (int32_t)zigZagDecoded32:(uint64_t)value;
+ (int64_t)zigZagDecoded64:(uint64_t)value;
/// Reinterpretation of fixed-width payloads.
+ (float)floatFromFixed32:(uint32_t)value;
+ (double)doubleFromFixed64:(uint64_t)value;

@end

NS_ASSUME_NONNULL_END
