// CLTTMLParser.m — see CLTTMLParser.h for what comes out. NSXMLParser (libxml2) reads the XML; a
// private delegate keeps a few counters plus the state of the open <p>, and records one entry per
// non-empty <p>. Everything after that is plain array work.
//
// Hardening (this runs inside the Music app, on text that came over the network):
//   * a document carrying a DTD ("<!DOCTYPE" / "<!ENTITY") is refused before parsing. TTML never
//     has one, and internal entities are the one thing NSXMLParser expands even with external
//     entity resolution off ("billion laughs");
//   * input longer than kCLTTMLMaxLength UTF-16 units is refused; Apple's longest word-timed
//     documents are a few hundred KB;
//   * a leading BOM, whitespace and "<?xml ...?>" declaration are dropped: libxml2 gets the string
//     as UTF-8, so a declaration naming another encoding would make it misread the bytes;
//   * the walk keeps depth counters only (no recursion, no element stack); libxml2 caps nesting.
//
// Namespaces are not processed. Element and attribute names arrive qualified ("tt:p",
// "itunes:timing", "ttm:role") and are matched on their local part, so a document reads the same
// whether TTML is its default namespace or a prefixed one.
//
// Times are absolute track times, the way Apple writes them (a <div>'s `begin` repeats its first
// <p>'s): TTML's parent-relative timing and `dur` are not applied, <body> and <div> times are
// ignored. A <p> without a usable `begin` takes the earliest `begin` among its spans, one without a
// usable `end` the latest span `end`.
// Two refinements of the header's rules, both invisible on ordinary single-voice lyrics:
//   * the instrumental blank line goes at the latest `end` of every line so far, not only the
//     previous line's: in a duet a long line can still be running after a shorter, later-starting
//     one has ended, and blanking the panel then would be wrong;
//   * a background-vocal group is followed by a space as well as preceded by one, so main text
//     after "(ooh)" never glues onto it.
#import "CLTTMLParser.h"
#import "Util/CLLog.h"
#import <math.h>

const NSTimeInterval kCLTTMLGapForBlankLine = 5.0;

/// Longer input (UTF-16 units) is refused without parsing.
static const NSUInteger kCLTTMLMaxLength = 8 * 1024 * 1024;
/// No clock value is this long; longer strings are not times. (An enum: it sizes a stack buffer.)
enum { kCLTTMLMaxClockLength = 32 };
/// TTML times carry milliseconds, so a gap of exactly kCLTTMLGapForBlankLine computed from two of
/// them may come out a hair short in binary floating point.
static const NSTimeInterval kCLTTMLGapTolerance = 0.0005;

// Keys of the per-<p> records the reader produces.
static NSString *const kCLTTMLText = @"text";
static NSString *const kCLTTMLBegin = @"begin";     // NSNumber, NAN when the <p> has no usable time
static NSString *const kCLTTMLEnd = @"end";         // NSNumber, NAN when unknown
static NSString *const kCLTTMLStanza = @"stanza";   // NSNumber, equal for <p>s in the same <div>

#pragma mark - Helpers

/// "tt:p" -> "p", "p" -> "p".
static NSString *CLTTMLLocalName(NSString *qualifiedName) {
    if (![qualifiedName isKindOfClass:[NSString class]]) return @"";
    NSRange colon = [qualifiedName rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location == NSNotFound) return qualifiedName;
    return [qualifiedName substringFromIndex:NSMaxRange(colon)];
}

/// The attribute called `name`, with or without a namespace prefix ("timing" finds
/// "itunes:timing"). An unprefixed attribute wins; among prefixed ones the smallest key does, so
/// the answer never depends on dictionary order. Namespace declarations never match.
static NSString *CLTTMLAttribute(NSDictionary *attributes, NSString *name) {
    if (![attributes isKindOfClass:[NSDictionary class]]) return nil;
    id exact = attributes[name];
    if ([exact isKindOfClass:[NSString class]]) return exact;

    NSString *bestKey = nil;
    for (id key in attributes) {
        if (![key isKindOfClass:[NSString class]]) continue;
        if ([key isEqualToString:@"xmlns"] || [key hasPrefix:@"xmlns:"]) continue;
        if (![CLTTMLLocalName(key) isEqualToString:name]) continue;
        if (!bestKey || [key compare:bestKey] == NSOrderedAscending) bestKey = key;
    }
    id value = bestKey ? attributes[bestKey] : nil;
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

/// YES when a whitespace-separated ttm:role list contains "x-bg".
static BOOL CLTTMLIsBackgroundRole(NSString *role) {
    if (role.length == 0) return NO;
    for (NSString *token in [role componentsSeparatedByCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        if ([token caseInsensitiveCompare:@"x-bg"] == NSOrderedSame) return YES;
    }
    return NO;
}

/// Runs of whitespace (the newlines and indentation of pretty-printed XML included) -> one space,
/// trimmed.
static NSString *CLTTMLCollapseWhitespace(NSString *text) {
    NSArray<NSString *> *words = [text componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *kept = [NSMutableArray arrayWithCapacity:words.count];
    for (NSString *word in words) {
        if (word.length) [kept addObject:word];
    }
    return [kept componentsJoinedByString:@" "];
}

/// Scans digits, plus ".digits" when `allowFraction`, at *index. NO when there is no leading digit
/// or a '.' has no digit after it. Only the first nine fraction digits count.
static BOOL CLTTMLScanNumber(const unichar *chars, NSUInteger length, NSUInteger *index,
                             BOOL allowFraction, double *outValue) {
    NSUInteger i = *index;
    double value = 0;
    NSUInteger digits = 0;
    while (i < length && chars[i] >= '0' && chars[i] <= '9') {
        value = value * 10.0 + (double)(chars[i] - '0');
        digits++;
        i++;
    }
    if (digits == 0) return NO;

    if (allowFraction && i < length && chars[i] == '.') {
        i++;
        unsigned long long fraction = 0;
        NSUInteger fractionDigits = 0;
        NSUInteger counted = 0;
        while (i < length && chars[i] >= '0' && chars[i] <= '9') {
            if (counted < 9) {
                fraction = fraction * 10 + (unsigned long long)(chars[i] - '0');
                counted++;
            }
            fractionDigits++;
            i++;
        }
        if (fractionDigits == 0) return NO;
        value += (double)fraction / pow(10.0, (double)counted);
    }
    *index = i;
    *outValue = value;
    return YES;
}

/// The UTF-8 bytes handed to libxml2, or nil for input refused before parsing (see the top).
static NSData *CLTTMLDocumentData(NSString *ttml) {
    if (![ttml isKindOfClass:[NSString class]]) return nil;
    NSUInteger length = ttml.length;
    if (length == 0 || length > kCLTTMLMaxLength) return nil;

    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSUInteger start = 0;
    while (start < length) {
        unichar c = [ttml characterAtIndex:start];
        if (c != 0xFEFF && ![whitespace characterIsMember:c]) break;
        start++;
    }
    if (start == length) return nil;

    NSString *document = start ? [ttml substringFromIndex:start] : ttml;
    if ([document hasPrefix:@"<?xml"]) {
        NSRange close = [document rangeOfString:@"?>"];
        if (close.location == NSNotFound) return nil;
        document = [document substringFromIndex:NSMaxRange(close)];
    }
    if ([document rangeOfString:@"<!DOCTYPE"].location != NSNotFound ||
        [document rangeOfString:@"<!ENTITY"].location != NSNotFound) {
        return nil;
    }
    NSData *data = [document dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
    return data.length ? data : nil;
}

#pragma mark - Document reader

/// NSXMLParser delegate: one pass over the document, one record per non-empty <p> (keys above), in
/// document order. Everything inside <head> is skipped.
@interface CLTTMLDocumentReader : NSObject <NSXMLParserDelegate>
@property (nonatomic, readonly) BOOL rootIsTT;
@property (nonatomic, readonly, copy) NSString *timing;   // the root's itunes:timing, nil if absent
@property (nonatomic, readonly) NSMutableArray<NSDictionary *> *paragraphs;
@end

@implementation CLTTMLDocumentReader {
    NSUInteger _depth;             // depth of the element being opened or closed; the root is 1
    NSUInteger _headDepth;         // depth of the open <head>, 0 outside it
    NSUInteger _paragraphDepth;    // depth of the open <p>, 0 outside one
    NSUInteger _backgroundDepth;   // depth of the open x-bg span inside the <p>, 0 outside one
    NSInteger _stanza;             // bumped at every <div> boundary outside a <p>
    NSMutableString *_text;        // raw text of the open <p>
    NSTimeInterval _begin;         // the open <p>'s own begin/end, NAN when missing
    NSTimeInterval _end;
    NSTimeInterval _spanBegin;     // earliest span begin / latest span end inside it, NAN if none
    NSTimeInterval _spanEnd;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _paragraphs = [NSMutableArray array];
        _text = [NSMutableString string];
    }
    return self;
}

- (void)parser:(NSXMLParser *)parser
    didStartElement:(NSString *)elementName
       namespaceURI:(NSString *)namespaceURI
      qualifiedName:(NSString *)qName
         attributes:(NSDictionary<NSString *, NSString *> *)attributes {
    _depth++;
    NSString *name = CLTTMLLocalName(elementName);
    if (_depth == 1) {
        if (![name isEqualToString:@"tt"]) {
            [parser abortParsing];
            return;
        }
        _rootIsTT = YES;
        _timing = [CLTTMLAttribute(attributes, @"timing") copy];
        return;
    }
    if (!_rootIsTT || _headDepth) return;

    if (_paragraphDepth == 0) {
        if ([name isEqualToString:@"head"]) {
            _headDepth = _depth;
        } else if ([name isEqualToString:@"div"]) {
            _stanza++;
        } else if ([name isEqualToString:@"p"]) {
            [self cl_openParagraphWithAttributes:attributes];
        }
        return;
    }

    if ([name isEqualToString:@"br"]) {
        [_text appendString:@" "];
    } else if ([name isEqualToString:@"span"]) {
        [self cl_openSpanWithAttributes:attributes];
    }
}

- (void)parser:(NSXMLParser *)parser
    didEndElement:(NSString *)elementName
     namespaceURI:(NSString *)namespaceURI
    qualifiedName:(NSString *)qName {
    if (_depth == 0) return;
    NSUInteger depth = _depth--;
    if (!_rootIsTT || depth == 1) return;

    if (_headDepth) {
        if (depth == _headDepth) _headDepth = 0;
        return;
    }
    if (_paragraphDepth == 0) {
        if ([CLTTMLLocalName(elementName) isEqualToString:@"div"]) _stanza++;
        return;
    }
    if (depth == _backgroundDepth) {
        _backgroundDepth = 0;
        [self cl_appendSeparator];
    }
    if (depth == _paragraphDepth) [self cl_closeParagraph];
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    if (_paragraphDepth == 0 || string.length == 0) return;
    [_text appendString:string];
}

- (void)parser:(NSXMLParser *)parser foundIgnorableWhitespace:(NSString *)whitespaceString {
    if (_paragraphDepth == 0 || whitespaceString.length == 0) return;
    [_text appendString:whitespaceString];
}

- (void)parser:(NSXMLParser *)parser foundCDATA:(NSData *)CDATABlock {
    if (_paragraphDepth == 0 || CDATABlock.length == 0) return;
    NSString *string = [[NSString alloc] initWithData:CDATABlock encoding:NSUTF8StringEncoding];
    if (string.length) [_text appendString:string];
}

#pragma mark Paragraph state

- (void)cl_openParagraphWithAttributes:(NSDictionary *)attributes {
    _paragraphDepth = _depth;
    _backgroundDepth = 0;
    [_text setString:@""];
    _begin = [CLTTMLParser timeFromClockValue:CLTTMLAttribute(attributes, @"begin")];
    _end = [CLTTMLParser timeFromClockValue:CLTTMLAttribute(attributes, @"end")];
    _spanBegin = NAN;
    _spanEnd = NAN;
}

- (void)cl_openSpanWithAttributes:(NSDictionary *)attributes {
    NSTimeInterval begin = [CLTTMLParser timeFromClockValue:CLTTMLAttribute(attributes, @"begin")];
    if (!isnan(begin)) _spanBegin = isnan(_spanBegin) ? begin : fmin(_spanBegin, begin);
    NSTimeInterval end = [CLTTMLParser timeFromClockValue:CLTTMLAttribute(attributes, @"end")];
    if (!isnan(end)) _spanEnd = isnan(_spanEnd) ? end : fmax(_spanEnd, end);

    if (_backgroundDepth || !CLTTMLIsBackgroundRole(CLTTMLAttribute(attributes, @"role"))) return;
    _backgroundDepth = _depth;
    [self cl_appendSeparator];
}

/// A space, unless the text is still empty or already ends in whitespace.
- (void)cl_appendSeparator {
    NSUInteger length = _text.length;
    if (length == 0) return;
    unichar last = [_text characterAtIndex:length - 1];
    if ([[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:last]) return;
    [_text appendString:@" "];
}

- (void)cl_closeParagraph {
    _paragraphDepth = 0;
    _backgroundDepth = 0;
    NSString *text = CLTTMLCollapseWhitespace(_text);
    [_text setString:@""];
    if (text.length == 0) return;

    NSTimeInterval begin = isnan(_begin) ? _spanBegin : _begin;
    NSTimeInterval end = isnan(_end) ? _spanEnd : _end;
    [_paragraphs addObject:@{ kCLTTMLText: text,
                              kCLTTMLBegin: @(begin),
                              kCLTTMLEnd: @(end),
                              kCLTTMLStanza: @(_stanza) }];
}

@end

#pragma mark - Building lyrics

/// One row per <p> in document order, an empty row wherever the stanza (<div>) changes.
static NSString *CLTTMLPlainText(NSArray<NSDictionary *> *paragraphs) {
    NSMutableArray<NSString *> *rows = [NSMutableArray arrayWithCapacity:paragraphs.count + 8];
    NSNumber *stanza = nil;
    for (NSDictionary *paragraph in paragraphs) {
        if (stanza && ![stanza isEqual:paragraph[kCLTTMLStanza]]) [rows addObject:@""];
        stanza = paragraph[kCLTTMLStanza];
        [rows addObject:paragraph[kCLTTMLText]];
    }
    return [rows componentsJoinedByString:@"\n"];
}

/// Timed <p>s sorted by begin (stable), with an empty line in every long enough silence.
static NSArray<CLLyricLine *> *CLTTMLSyncedLines(NSArray<NSDictionary *> *paragraphs) {
    NSMutableArray<NSDictionary *> *timed = [NSMutableArray arrayWithCapacity:paragraphs.count];
    for (NSDictionary *paragraph in paragraphs) {
        if (!isnan([paragraph[kCLTTMLBegin] doubleValue])) [timed addObject:paragraph];
    }
    [timed sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double left = [a[kCLTTMLBegin] doubleValue];
        double right = [b[kCLTTMLBegin] doubleValue];
        if (left < right) return NSOrderedAscending;
        if (left > right) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSMutableArray<CLLyricLine *> *lines = [NSMutableArray arrayWithCapacity:timed.count + 8];
    NSTimeInterval latestEnd = NAN;
    for (NSUInteger i = 0; i < timed.count; i++) {
        NSDictionary *paragraph = timed[i];
        NSTimeInterval begin = [paragraph[kCLTTMLBegin] doubleValue];
        NSTimeInterval end = [paragraph[kCLTTMLEnd] doubleValue];
        [lines addObject:[CLLyricLine lineWithTime:begin text:paragraph[kCLTTMLText]]];

        if (isnan(end) || end < begin) continue;   // unknown (or nonsense) end: no break after it
        latestEnd = isnan(latestEnd) ? end : fmax(latestEnd, end);
        if (i + 1 == timed.count) break;           // nothing after the last line

        NSTimeInterval next = [timed[i + 1][kCLTTMLBegin] doubleValue];
        if (next - latestEnd >= kCLTTMLGapForBlankLine - kCLTTMLGapTolerance) {
            [lines addObject:[CLLyricLine lineWithTime:latestEnd text:@""]];
        }
    }
    return lines;
}

@implementation CLTTMLParser

+ (CLLyrics *)lyricsFromTTML:(NSString *)ttml source:(NSString *)source {
    NSData *data = CLTTMLDocumentData(ttml);
    if (!data) return nil;

    CLTTMLDocumentReader *reader = [[CLTTMLDocumentReader alloc] init];
    BOOL parsed = NO;
    @autoreleasepool {
        NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
        parser.shouldResolveExternalEntities = NO;
        parser.shouldProcessNamespaces = NO;
        parser.shouldReportNamespacePrefixes = NO;
        parser.delegate = reader;
        parsed = [parser parse];
        if (!parsed) {
            NSError *error = parser.parserError;
            CLLogDebug(@"[ttml] not parsed: %@ %ld at line %ld (root tt: %d)",
                       error.domain ?: @"?", (long)error.code, (long)parser.lineNumber, reader.rootIsTT);
        }
        parser.delegate = nil;
    }
    if (!parsed || !reader.rootIsTT || reader.paragraphs.count == 0) return nil;

    NSString *plainText = CLTTMLPlainText(reader.paragraphs);
    NSString *timing = [reader.timing stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL transcript = timing && [timing caseInsensitiveCompare:@"None"] == NSOrderedSame;
    if (!transcript) {
        NSArray<CLLyricLine *> *lines = CLTTMLSyncedLines(reader.paragraphs);
        if (lines.count) {
            CLLyrics *lyrics = [CLLyrics syncedWithLines:lines source:source];
            lyrics.plainText = plainText;
            return lyrics;
        }
    }
    CLLyrics *lyrics = [CLLyrics plainWithText:plainText source:source];
    return lyrics.kind == CLLyricsKindPlain ? lyrics : nil;
}

+ (NSTimeInterval)timeFromClockValue:(NSString *)value {
    if (![value isKindOfClass:[NSString class]]) return NAN;
    NSString *trimmed = [value stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSUInteger length = trimmed.length;
    if (length == 0 || length > kCLTTMLMaxClockLength) return NAN;
    unichar chars[kCLTTMLMaxClockLength];
    [trimmed getCharacters:chars range:NSMakeRange(0, length)];

    NSUInteger colons = 0;
    for (NSUInteger i = 0; i < length; i++) {
        if (chars[i] == ':') colons++;
    }

    NSUInteger index = 0;
    double seconds = 0;
    if (colons == 0) {
        // Offset time: "10.018" (seconds), "12.3s", "450ms", "1.5m", "0.5h".
        double number = 0;
        if (!CLTTMLScanNumber(chars, length, &index, YES, &number)) return NAN;
        NSString *metric = [trimmed substringFromIndex:index];
        double scale = 0;
        if (metric.length == 0 || [metric isEqualToString:@"s"]) scale = 1;
        else if ([metric isEqualToString:@"ms"]) scale = 0.001;
        else if ([metric isEqualToString:@"m"]) scale = 60;
        else if ([metric isEqualToString:@"h"]) scale = 3600;
        else return NAN;   // frames ("f") and ticks ("t") need rates Apple never declares
        seconds = number * scale;
    } else {
        // Clock time: "1:02.345" (m:s) or "01:02:03.456" (h:m:s); only the seconds carry a fraction.
        if (colons > 2) return NAN;   // "hh:mm:ss:frames" included
        double total = 0;
        for (NSUInteger part = 0; part < colons; part++) {
            double whole = 0;
            if (!CLTTMLScanNumber(chars, length, &index, NO, &whole)) return NAN;
            if (index >= length || chars[index] != ':') return NAN;
            index++;
            total = total * 60.0 + whole;
        }
        double last = 0;
        if (!CLTTMLScanNumber(chars, length, &index, YES, &last)) return NAN;
        if (index != length) return NAN;
        seconds = total * 60.0 + last;
    }
    if (!isfinite(seconds) || seconds < 0) return NAN;
    return seconds;
}

@end
