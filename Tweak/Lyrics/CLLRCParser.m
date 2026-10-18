// CLLRCParser.m — see CLLRCParser.h for the accepted syntax. Hand-rolled scanner (no
// NSRegularExpression) so the cost is predictable on a 300-line lyric file.
#import "CLLRCParser.h"
#import <math.h>

/// Parses the text between '[' and ']' (or '<' and '>') as a timestamp.
/// Returns NO for metadata tags, free text, or anything numerically implausible.
static BOOL CLParseTimestamp(NSString *content, NSTimeInterval *outTime) {
    NSString *trimmed = [content stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSUInteger length = trimmed.length;
    if (length == 0 || length > 24) return NO;

    NSUInteger values[4] = {0, 0, 0, 0};
    NSUInteger digits[4] = {0, 0, 0, 0};
    // Four slots for at most three separators: the trailing-separator check below indexes
    // separators[count - 1], and `count` reaches 4 for the [hh:mm:ss.xx] form. Index 3 is never
    // written (a separator seen while count == 4 is rejected in the separator branch), so it
    // stays 0 and that check passes, which is the intended answer for a four-group timestamp.
    unichar separators[4] = {0, 0, 0, 0};
    NSUInteger count = 0;
    NSUInteger index = 0;

    while (index < length) {
        unichar c = [trimmed characterAtIndex:index];
        if (c >= '0' && c <= '9') {
            if (count >= 4) return NO;
            NSUInteger value = 0;
            NSUInteger digitCount = 0;
            while (index < length) {
                c = [trimmed characterAtIndex:index];
                if (c < '0' || c > '9') break;
                if (digitCount < 9) value = value * 10 + (NSUInteger)(c - '0');
                digitCount++;
                index++;
            }
            if (digitCount > 9) return NO;
            values[count] = value;
            digits[count] = digitCount;
            count++;
        } else if (c == ':' || c == '.') {
            if (count == 0 || count > 3) return NO;        // leading or trailing separator
            if (separators[count - 1] != 0) return NO;     // two separators in a row
            separators[count - 1] = c;
            index++;
        } else {
            return NO;                                     // letters etc. -> metadata or text
        }
    }

    if (count < 2) return NO;                              // a bare number is not a timestamp
    if (separators[0] != ':') return NO;                   // "3.5" is not a timestamp
    if (separators[count - 1] != 0) return NO;             // "01:23." -> reject

    NSUInteger minutesIndex = 0;
    NSUInteger secondsIndex = 1;
    NSUInteger fractionIndex = NSNotFound;
    NSTimeInterval hours = 0;

    if (count == 2) {
        // [mm:ss]
    } else if (count == 3) {
        // [mm:ss.xx] and the [mm:ss:xx] variant both mean hundredths; hours are not used in LRC.
        fractionIndex = 2;
    } else {  // count == 4 -> [hh:mm:ss.xx]
        if (separators[1] != ':') return NO;
        hours = (NSTimeInterval)values[0];
        minutesIndex = 1;
        secondsIndex = 2;
        fractionIndex = 3;
    }

    if (hours > 24) return NO;
    if (digits[minutesIndex] == 0 || digits[minutesIndex] > 4) return NO;
    if (digits[secondsIndex] == 0 || digits[secondsIndex] > 2) return NO;
    if (values[secondsIndex] > 99) return NO;
    if (values[minutesIndex] > 5999) return NO;

    NSTimeInterval fraction = 0;
    if (fractionIndex != NSNotFound) {
        NSUInteger fractionDigits = digits[fractionIndex];
        if (fractionDigits == 0 || fractionDigits > 6) return NO;
        fraction = (NSTimeInterval)values[fractionIndex] / pow(10.0, (double)fractionDigits);
    }

    NSTimeInterval time = hours * 3600.0 + (NSTimeInterval)values[minutesIndex] * 60.0 +
                          (NSTimeInterval)values[secondsIndex] + fraction;
    if (!isfinite(time) || time < 0 || time > 24 * 3600.0) return NO;
    if (outTime) *outTime = time;
    return YES;
}

/// "[offset:+250]" -> 250 ms. Returns NO for every other tag.
static BOOL CLParseOffsetTag(NSString *content, double *outMilliseconds) {
    NSRange colon = [content rangeOfString:@":"];
    if (colon.location == NSNotFound) return NO;
    NSString *key = [[content substringToIndex:colon.location]
                     stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([key caseInsensitiveCompare:@"offset"] != NSOrderedSame) return NO;

    NSString *value = [[content substringFromIndex:NSMaxRange(colon)]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (value.length == 0 || value.length > 12) return NO;

    NSScanner *scanner = [NSScanner scannerWithString:value];
    scanner.charactersToBeSkipped = nil;
    double milliseconds = 0;
    if (![scanner scanDouble:&milliseconds]) return NO;
    if (!scanner.isAtEnd) return NO;
    if (!isfinite(milliseconds) || fabs(milliseconds) > 600000.0) return NO;   // ±10 min sanity
    if (outMilliseconds) *outMilliseconds = milliseconds;
    return YES;
}

/// YES for "[ar:...]"-shaped metadata: an alphabetic key followed by ':'.
static BOOL CLLooksLikeMetadataTag(NSString *content) {
    NSRange colon = [content rangeOfString:@":"];
    if (colon.location == NSNotFound || colon.location == 0) return NO;
    NSString *key = [content substringToIndex:colon.location];
    for (NSUInteger i = 0; i < key.length; i++) {
        unichar c = [key characterAtIndex:i];
        BOOL letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '-';
        if (!letter) return NO;
    }
    return YES;
}

/// Removes enhanced-LRC word timestamps ("<00:12.34>") and collapses the whitespace they leave.
static NSString *CLStripWordTimestamps(NSString *text) {
    if (text.length == 0 || [text rangeOfString:@"<"].location == NSNotFound) return text;

    NSMutableString *output = [NSMutableString stringWithCapacity:text.length];
    NSUInteger length = text.length;
    NSUInteger index = 0;
    NSUInteger chunkStart = 0;
    BOOL stripped = NO;

    while (index < length) {
        if ([text characterAtIndex:index] == '<') {
            NSRange close = [text rangeOfString:@">"
                                        options:0
                                          range:NSMakeRange(index, length - index)];
            if (close.location != NSNotFound) {
                NSRange innerRange = NSMakeRange(index + 1, close.location - index - 1);
                NSTimeInterval ignored = 0;
                if (CLParseTimestamp([text substringWithRange:innerRange], &ignored)) {
                    if (index > chunkStart) {
                        [output appendString:[text substringWithRange:
                                              NSMakeRange(chunkStart, index - chunkStart)]];
                    }
                    index = NSMaxRange(close);
                    chunkStart = index;
                    stripped = YES;
                    continue;
                }
            }
        }
        index++;
    }
    if (!stripped) return text;
    if (length > chunkStart) {
        [output appendString:[text substringWithRange:NSMakeRange(chunkStart, length - chunkStart)]];
    }

    NSArray<NSString *> *words = [output componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *kept = [NSMutableArray arrayWithCapacity:words.count];
    for (NSString *word in words) {
        if (word.length) [kept addObject:word];
    }
    return [kept componentsJoinedByString:@" "];
}

@implementation CLLRCParser

+ (NSArray<CLLyricLine *> *)parse:(NSString *)lrc {
    if (![lrc isKindOfClass:[NSString class]] || lrc.length == 0) return nil;
    // A UTF-8 BOM survives NSString decoding as U+FEFF, which is not whitespace: left in place it
    // would hide the first '[' and cost us the first line of every BOM-prefixed .lrc file.
    if ([lrc hasPrefix:@"\uFEFF"]) lrc = [lrc substringFromIndex:1];

    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSMutableArray<CLLyricLine *> *lines = [NSMutableArray array];
    double offsetMilliseconds = 0;
    BOOL haveOffset = NO;

    NSArray<NSString *> *rawLines =
        [lrc componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    for (NSString *rawLine in rawLines) {
        @autoreleasepool {
            NSUInteger length = rawLine.length;
            if (length == 0) continue;

            NSMutableArray<NSNumber *> *stamps = [NSMutableArray array];
            NSUInteger index = 0;

            while (index < length) {
                while (index < length && [whitespace characterIsMember:[rawLine characterAtIndex:index]]) {
                    index++;
                }
                if (index >= length || [rawLine characterAtIndex:index] != '[') break;

                NSRange close = [rawLine rangeOfString:@"]"
                                               options:0
                                                 range:NSMakeRange(index, length - index)];
                if (close.location == NSNotFound) break;

                NSString *content = [rawLine substringWithRange:
                                     NSMakeRange(index + 1, close.location - index - 1)];
                NSTimeInterval stamp = 0;
                if (CLParseTimestamp(content, &stamp)) {
                    [stamps addObject:@(stamp)];
                    index = NSMaxRange(close);
                    continue;
                }
                // Not a timestamp. Once we have stamps the rest of the line is lyric text
                // ("[00:12.00][Chorus] ..." must keep "[Chorus]").
                if (stamps.count > 0) break;
                if (!CLLooksLikeMetadataTag(content)) break;

                double milliseconds = 0;
                if (!haveOffset && CLParseOffsetTag(content, &milliseconds)) {
                    offsetMilliseconds = milliseconds;
                    haveOffset = YES;
                }
                index = NSMaxRange(close);
            }

            if (stamps.count == 0) continue;   // metadata-only or untimed line

            NSString *text = [[rawLine substringFromIndex:index] stringByTrimmingCharactersInSet:whitespace];
            text = CLStripWordTimestamps(text);
            for (NSNumber *stamp in stamps) {
                [lines addObject:[CLLyricLine lineWithTime:stamp.doubleValue text:text]];
            }
        }
    }

    if (lines.count == 0) return nil;

    if (haveOffset && fabs(offsetMilliseconds) > 0.0) {
        NSTimeInterval shift = offsetMilliseconds / 1000.0;   // '+' => lyrics appear earlier
        for (CLLyricLine *line in lines) {
            line.time = line.time - shift;                    // setter clamps at 0
        }
    }

    [lines sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(CLLyricLine *a, CLLyricLine *b) {
        if (a.time < b.time) return NSOrderedAscending;
        if (a.time > b.time) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return lines;
}

+ (NSString *)plainTextFromLines:(NSArray<CLLyricLine *> *)lines {
    if (![lines isKindOfClass:[NSArray class]] || lines.count == 0) return @"";
    NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithCapacity:lines.count];
    for (CLLyricLine *line in lines) {
        if (![line isKindOfClass:[CLLyricLine class]]) continue;
        [texts addObject:line.text ?: @""];
    }
    return [texts componentsJoinedByString:@"\n"];
}

@end
