// CLLyricsTypes.m — implementation of the shared lyrics contract declared in CLLyricsTypes.h.
//
// Foundation + CommonCrypto only (no UIKit): every other slice, the on-device test tool and any
// future out-of-process helper can link this file.
//
// Derived CLTrack values
//   spotifyTrackID  "spotify:track:<base62>[#<uuid>]" -> "<base62>". The prefix match is
//                   case-insensitive, the id is cut at the first '#', and anything that is not
//                   pure base62 ([0-9A-Za-z]) is rejected so callers never build a path or a
//                   query from junk. nil for every other identifier shape.
//   cacheKey        hex SHA-1 of the lowercased string "artist|title|<duration rounded to a
//                   whole second>". Deliberately independent of album and bundle id so the same
//                   song reported slightly differently by two apps shares one cache entry.
//                   Non-finite or negative durations are treated as 0.
//
// CLLyrics
//   The factories stamp fetchedAt with the current unix time (the cache TTL depends on it) and
//   collapse "empty" results to CLLyricsKindNone, so a consumer can trust that kind != None
//   means there is something to show.
//   dictionaryRepresentation/lyricsWithDictionary round-trip through NSJSONSerialization:
//   { "kind": <int>, "lines": [ { "t": <seconds>, "text": <string> } ], "plainText": <string>,
//     "source": <string>, "fetchedAt": <unix seconds> }. Decoding is defensive: any malformed
//   field is dropped rather than trusted, and a dictionary without a usable "kind" yields nil.

#import "CLLyricsTypes.h"
#import <CommonCrypto/CommonDigest.h>
#import <math.h>

static NSString *const kCLSpotifyTrackPrefix = @"spotify:track:";

#pragma mark - Helpers

/// Finite, non-negative seconds. Anything else (NaN, inf, negative) becomes 0 = "unknown".
static NSTimeInterval CLSaneDuration(NSTimeInterval value) {
    if (!isfinite(value) || value <= 0) return 0;
    return value;
}

static NSString *CLSHA1Hex(NSString *input) {
    NSData *data = [(input ?: @"") dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    char hex[CC_SHA1_DIGEST_LENGTH * 2 + 1];
    static const char *alphabet = "0123456789abcdef";
    for (NSUInteger i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        hex[i * 2] = alphabet[(digest[i] >> 4) & 0xF];
        hex[i * 2 + 1] = alphabet[digest[i] & 0xF];
    }
    hex[CC_SHA1_DIGEST_LENGTH * 2] = '\0';
    return [NSString stringWithUTF8String:hex] ?: @"";
}

static BOOL CLEqualIgnoringCase(NSString *lhs, NSString *rhs) {
    NSString *left = lhs ?: @"";
    NSString *right = rhs ?: @"";
    return [left caseInsensitiveCompare:right] == NSOrderedSame;
}

/// Non-empty NSString from a JSON value, nil for NSNull / wrong class / empty string.
static NSString *CLJSONStringOrNil(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *string = (NSString *)value;
    return string.length ? string : nil;
}

#pragma mark - CLTrack

@implementation CLTrack

- (id)copyWithZone:(NSZone *)zone {
    CLTrack *copy = [[CLTrack allocWithZone:zone] init];
    copy->_title = [_title copy];
    copy->_artist = [_artist copy];
    copy->_album = [_album copy];
    copy->_duration = _duration;
    copy->_bundleIdentifier = [_bundleIdentifier copy];
    copy->_contentIdentifier = [_contentIdentifier copy];
    return copy;
}

- (NSString *)spotifyTrackID {
    NSString *identifier = self.contentIdentifier;
    if (identifier.length <= kCLSpotifyTrackPrefix.length) return nil;
    NSRange prefix = [identifier rangeOfString:kCLSpotifyTrackPrefix
                                       options:NSCaseInsensitiveSearch | NSAnchoredSearch];
    if (prefix.location != 0) return nil;

    NSString *rest = [identifier substringFromIndex:NSMaxRange(prefix)];
    NSRange hash = [rest rangeOfString:@"#"];
    if (hash.location != NSNotFound) rest = [rest substringToIndex:hash.location];
    rest = [rest stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (rest.length == 0) return nil;

    static NSCharacterSet *notBase62 = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notBase62 = [[NSCharacterSet characterSetWithCharactersInString:
                      @"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"] invertedSet];
    });
    if ([rest rangeOfCharacterFromSet:notBase62].location != NSNotFound) return nil;
    return rest;
}

- (NSString *)cacheKey {
    NSString *raw = [NSString stringWithFormat:@"%@|%@|%ld",
                     self.artist ?: @"", self.title ?: @"", lround(CLSaneDuration(self.duration))];
    return CLSHA1Hex(raw.lowercaseString);
}

- (BOOL)isSameSongAs:(CLTrack *)other {
    if (other == self) return YES;
    if (![other isKindOfClass:[CLTrack class]]) return NO;
    if (!CLEqualIgnoringCase(self.title, other.title)) return NO;
    if (!CLEqualIgnoringCase(self.artist, other.artist)) return NO;

    NSTimeInterval mine = CLSaneDuration(self.duration);
    NSTimeInterval theirs = CLSaneDuration(other.duration);
    if (mine <= 0 || theirs <= 0) return YES;   // one side does not know the duration yet
    return fabs(mine - theirs) <= 2.0;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<CLTrack %@ — %@ (%.0fs, %@)>",
            self.artist ?: @"?", self.title ?: @"?", CLSaneDuration(self.duration),
            self.bundleIdentifier ?: @"?"];
}

@end

#pragma mark - CLLyricLine

@implementation CLLyricLine

+ (instancetype)lineWithTime:(NSTimeInterval)time text:(NSString *)text {
    CLLyricLine *line = [[self alloc] init];
    line.time = (isfinite(time) && time > 0) ? time : 0;
    line.text = [text isKindOfClass:[NSString class]] ? text : @"";
    return line;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _time = 0;
        _text = @"";
    }
    return self;
}

- (void)setText:(NSString *)text {
    _text = [([text isKindOfClass:[NSString class]] ? text : @"") copy];
}

- (void)setTime:(NSTimeInterval)time {
    _time = (isfinite(time) && time > 0) ? time : 0;
}

- (BOOL)isEqual:(id)object {
    if (object == self) return YES;
    if (![object isKindOfClass:[CLLyricLine class]]) return NO;
    CLLyricLine *other = (CLLyricLine *)object;
    return fabs(other.time - self.time) < 0.0005 && [other.text isEqualToString:self.text];
}

- (NSUInteger)hash {
    return (NSUInteger)llround(self.time * 100.0) ^ self.text.hash;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<CLLyricLine %.2f (%lu chars)>",
            self.time, (unsigned long)self.text.length];
}

@end

#pragma mark - CLLyrics

@implementation CLLyrics

- (instancetype)init {
    self = [super init];
    if (self) {
        _kind = CLLyricsKindNone;
        _lines = @[];
        _source = @"";
        _fetchedAt = 0;
    }
    return self;
}

- (void)setLines:(NSArray<CLLyricLine *> *)lines {
    _lines = [([lines isKindOfClass:[NSArray class]] ? lines : @[]) copy];
}

- (void)setSource:(NSString *)source {
    _source = [([source isKindOfClass:[NSString class]] ? source : @"") copy];
}

+ (instancetype)noneFromSource:(NSString *)source {
    CLLyrics *lyrics = [[self alloc] init];
    lyrics.kind = CLLyricsKindNone;
    lyrics.source = source;
    lyrics.fetchedAt = [NSDate date].timeIntervalSince1970;
    return lyrics;
}

+ (instancetype)instrumentalFromSource:(NSString *)source {
    CLLyrics *lyrics = [[self alloc] init];
    lyrics.kind = CLLyricsKindInstrumental;
    lyrics.source = source;
    lyrics.fetchedAt = [NSDate date].timeIntervalSince1970;
    return lyrics;
}

+ (instancetype)syncedWithLines:(NSArray<CLLyricLine *> *)lines source:(NSString *)source {
    NSMutableArray<CLLyricLine *> *clean = [NSMutableArray arrayWithCapacity:lines.count];
    for (id line in ([lines isKindOfClass:[NSArray class]] ? lines : @[])) {
        if ([line isKindOfClass:[CLLyricLine class]]) [clean addObject:line];
    }
    if (clean.count == 0) return [self noneFromSource:source];   // nothing to show == no lyrics

    CLLyrics *lyrics = [[self alloc] init];
    lyrics.kind = CLLyricsKindSynced;
    lyrics.lines = clean;
    lyrics.source = source;
    lyrics.fetchedAt = [NSDate date].timeIntervalSince1970;
    return lyrics;
}

+ (instancetype)plainWithText:(NSString *)text source:(NSString *)source {
    NSString *body = [text isKindOfClass:[NSString class]] ? text : nil;
    if ([body stringByTrimmingCharactersInSet:
         [NSCharacterSet whitespaceAndNewlineCharacterSet]].length == 0) {
        return [self noneFromSource:source];
    }
    CLLyrics *lyrics = [[self alloc] init];
    lyrics.kind = CLLyricsKindPlain;
    lyrics.plainText = body;
    lyrics.source = source;
    lyrics.fetchedAt = [NSDate date].timeIntervalSince1970;
    return lyrics;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableArray<NSDictionary *> *lines = [NSMutableArray arrayWithCapacity:self.lines.count];
    for (CLLyricLine *line in self.lines) {
        if (![line isKindOfClass:[CLLyricLine class]]) continue;
        NSTimeInterval time = isfinite(line.time) ? line.time : 0;
        [lines addObject:@{ @"t": @(time), @"text": line.text ?: @"" }];
    }

    NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithCapacity:5];
    dictionary[@"kind"] = @((NSInteger)self.kind);
    dictionary[@"lines"] = lines;
    dictionary[@"source"] = self.source ?: @"";
    dictionary[@"fetchedAt"] = @(isfinite(self.fetchedAt) ? self.fetchedAt : 0);
    if (self.plainText.length) dictionary[@"plainText"] = self.plainText;
    return dictionary;
}

+ (instancetype)lyricsWithDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;

    id rawKind = dictionary[@"kind"];
    if (![rawKind isKindOfClass:[NSNumber class]]) return nil;
    NSInteger kind = [(NSNumber *)rawKind integerValue];
    if (kind < CLLyricsKindNone || kind > CLLyricsKindInstrumental) return nil;

    CLLyrics *lyrics = [[self alloc] init];
    lyrics.kind = (CLLyricsKind)kind;
    lyrics.source = CLJSONStringOrNil(dictionary[@"source"]) ?: @"";
    lyrics.plainText = CLJSONStringOrNil(dictionary[@"plainText"]);

    id rawFetchedAt = dictionary[@"fetchedAt"];
    if ([rawFetchedAt isKindOfClass:[NSNumber class]]) {
        double fetchedAt = [(NSNumber *)rawFetchedAt doubleValue];
        lyrics.fetchedAt = isfinite(fetchedAt) ? fetchedAt : 0;
    }

    id rawLines = dictionary[@"lines"];
    if ([rawLines isKindOfClass:[NSArray class]]) {
        NSMutableArray<CLLyricLine *> *lines = [NSMutableArray arrayWithCapacity:[rawLines count]];
        for (id entry in (NSArray *)rawLines) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            id rawTime = ((NSDictionary *)entry)[@"t"];
            if (![rawTime isKindOfClass:[NSNumber class]]) continue;
            double time = [(NSNumber *)rawTime doubleValue];
            if (!isfinite(time)) continue;
            NSString *text = CLJSONStringOrNil(((NSDictionary *)entry)[@"text"]) ?: @"";
            [lines addObject:[CLLyricLine lineWithTime:time text:text]];
        }
        lyrics.lines = lines;
    }

    // A "synced" record whose lines did not survive decoding is not usable as synced lyrics.
    if (lyrics.kind == CLLyricsKindSynced && lyrics.lines.count == 0) {
        lyrics.kind = lyrics.plainText.length ? CLLyricsKindPlain : CLLyricsKindNone;
    }
    return lyrics;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<CLLyrics kind=%ld lines=%lu plain=%lu source=%@>",
            (long)self.kind, (unsigned long)self.lines.count,
            (unsigned long)self.plainText.length, self.source ?: @""];
}

@end
