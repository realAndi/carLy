#import "UI/CLLyricsStyle.h"
#import "Util/CLColor.h"
#import "Util/CLLog.h"
#import "Util/CLPrefs.h"

NSString *const CLLyricsNoteGlyph = @"♪";   // MUSIC NOTE

BOOL CLLyricsTextIsGap(NSString *text) {
    if (text.length == 0) return YES;
    static NSCharacterSet *notesAndSpace;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *set = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
        [set addCharactersInRange:NSMakeRange(0x2669, 4)];    // ♩ ♪ ♫ ♬
        [set addCharactersInRange:NSMakeRange(0xFE0E, 2)];    // text / emoji presentation selectors
        notesAndSpace = [set copy];
    });
    // 🎵 and 🎶 are surrogate pairs, which trimming (one UTF-16 unit at a time) never matches.
    // Literal search, or "🎶" would not match inside "🎶" + U+FE0F (one composed sequence).
    NSString *rest = text;
    for (NSString *emoji in @[ @"🎵", @"🎶" ]) {
        rest = [rest stringByReplacingOccurrencesOfString:emoji withString:@"" options:NSLiteralSearch
                                                    range:NSMakeRange(0, rest.length)];
    }
    return [rest stringByTrimmingCharactersInSet:notesAndSpace].length == 0;
}

void CLUIRunOnMain(dispatch_block_t block) {
    if (!block) return;
    if (NSThread.isMainThread) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

void CLUISafePerform(NSString *what, dispatch_block_t block) {
    if (!block) return;
    @try {
        block();
    } @catch (NSException *exception) {
        CLLogError(@"[ui] %@ raised %@: %@", what ?: @"(work)", exception.name, exception.reason);
    }
}

static CGFloat CLClampFloat(double value, double minimum, double maximum) {
    if (!(value == value)) return (CGFloat)minimum;   // NaN
    if (value < minimum) return (CGFloat)minimum;
    if (value > maximum) return (CGFloat)maximum;
    return (CGFloat)value;
}

static NSInteger CLClampInteger(NSInteger value, NSInteger minimum, NSInteger maximum) {
    if (value < minimum) return minimum;
    if (value > maximum) return maximum;
    return value;
}

/// YES when a font with this family (or PostScript) name is installed. The installed font list is
/// read once per process: a font installed afterwards only takes effect on the next respawn.
static BOOL CLFontFamilyExists(NSString *family) {
    if (family.length == 0) return NO;
    static NSSet<NSString *> *families;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableSet *set = [NSMutableSet set];
        for (NSString *name in UIFont.familyNames) {
            if (name.length) [set addObject:name.lowercaseString];
        }
        families = [set copy];
    });
    if ([families containsObject:family.lowercaseString]) return YES;
    return [UIFont fontWithName:family size:12.0] != nil;
}

/// Multiplies a colour's own alpha by `alpha` (so "#FFFFFF80" at 0.5 ends up at 0.25).
static UIColor *CLColorWithScaledAlpha(UIColor *color, CGFloat alpha) {
    if (!color) return UIColor.whiteColor;
    CGFloat base = CGColorGetAlpha(color.CGColor);
    return [color colorWithAlphaComponent:CLClampFloat(base * alpha, 0.0, 1.0)];
}

@implementation CLLyricsStyle {
    UIFont *_cachedCurrentFont;
    UIFont *_cachedSecondaryFont;
}

+ (instancetype)currentStyle {
    CLPrefs *prefs = CLPrefs.shared;
    CLLyricsStyle *style = [[CLLyricsStyle alloc] init];
    if (!style) return style;

    style->_fontFamily = [(prefs.lyricsFontFamily ?: @"") copy];
    style->_fontSize = CLClampFloat(prefs.lyricsFontSize, 10.0, 80.0);
    style->_fontWeight = [CLColor fontWeightFromNumeric:prefs.lyricsFontWeight];

    UIColor *current = [CLColor colorWithHex:prefs.lyricsCurrentColorHex fallback:UIColor.whiteColor];
    UIColor *next = [CLColor colorWithHex:prefs.lyricsNextColorHex fallback:UIColor.whiteColor];
    style->_currentColor = current;
    style->_nextColor = CLColorWithScaledAlpha(next, CLClampFloat(prefs.lyricsNextAlpha, 0.0, 1.0));

    switch (prefs.lyricsAlignment) {
        case 1: style->_alignment = NSTextAlignmentCenter; break;
        case 2: style->_alignment = NSTextAlignmentRight; break;
        default: style->_alignment = NSTextAlignmentLeft; break;
    }

    style->_animations = prefs.lyricsAnimations;
    style->_showNoteOnGap = prefs.lyricsShowNoteOnGap;
    style->_showPlainWhenUnsynced = prefs.lyricsShowPlainWhenUnsynced;
    style->_backgroundStyle = CLClampInteger(prefs.lyricsBackground, 0, 2);

    if (style->_backgroundStyle != 0) {
        UIColor *fill = [CLColor colorWithHex:prefs.lyricsBackgroundColorHex fallback:UIColor.blackColor];
        style->_backgroundFill = CLColorWithScaledAlpha(fill, CLClampFloat(prefs.lyricsBackgroundAlpha, 0.0, 1.0));
    }
    return style;
}

- (UIFont *)fontWithSize:(CGFloat)size weight:(UIFontWeight)weight {
    CGFloat points = CLClampFloat(size, 8.0, 96.0);
    if (_fontFamily.length > 0 && CLFontFamilyExists(_fontFamily)) {
        UIFontDescriptor *descriptor = [UIFontDescriptor fontDescriptorWithFontAttributes:@{
            UIFontDescriptorFamilyAttribute : _fontFamily,
            UIFontDescriptorTraitsAttribute : @{ UIFontWeightTrait : @(weight) },
        }];
        UIFont *font = [UIFont fontWithDescriptor:descriptor size:points];
        if (font) return font;
        font = [UIFont fontWithName:_fontFamily size:points];
        if (font) return font;
    }
    return [UIFont systemFontOfSize:points weight:weight];
}

- (UIFont *)currentLineFont {
    if (!_cachedCurrentFont) _cachedCurrentFont = [self fontWithSize:_fontSize weight:_fontWeight];
    return _cachedCurrentFont;
}

- (UIFont *)secondaryLineFont {
    if (!_cachedSecondaryFont) {
        UIFontWeight lighter = _fontWeight - 0.15;
        if (lighter < UIFontWeightUltraLight) lighter = UIFontWeightUltraLight;
        _cachedSecondaryFont = [self fontWithSize:_fontSize * 0.78 weight:lighter];
    }
    return _cachedSecondaryFont;
}

- (BOOL)isEqualToStyle:(CLLyricsStyle *)other {
    if (other == self) return YES;
    if (![other isKindOfClass:CLLyricsStyle.class]) return NO;
    if (![_fontFamily isEqualToString:other->_fontFamily]) return NO;
    if (fabs(_fontSize - other->_fontSize) > 0.01) return NO;
    if (fabs(_fontWeight - other->_fontWeight) > 0.001) return NO;
    if (_alignment != other->_alignment) return NO;
    if (_animations != other->_animations) return NO;
    if (_showNoteOnGap != other->_showNoteOnGap) return NO;
    if (_showPlainWhenUnsynced != other->_showPlainWhenUnsynced) return NO;
    if (_backgroundStyle != other->_backgroundStyle) return NO;
    if (![[CLColor hexFromColor:_currentColor] isEqualToString:[CLColor hexFromColor:other->_currentColor]]) return NO;
    if (![[CLColor hexFromColor:_nextColor] isEqualToString:[CLColor hexFromColor:other->_nextColor]]) return NO;
    if ((_backgroundFill == nil) != (other->_backgroundFill == nil)) return NO;
    if (_backgroundFill && ![[CLColor hexFromColor:_backgroundFill] isEqualToString:[CLColor hexFromColor:other->_backgroundFill]]) return NO;
    return YES;
}

- (BOOL)isEqual:(id)object {
    if (object == self) return YES;
    if (![object isKindOfClass:CLLyricsStyle.class]) return NO;
    return [self isEqualToStyle:object];
}

- (NSUInteger)hash {
    return (NSUInteger)(_fontSize * 10.0) ^ (NSUInteger)(_alignment << 8) ^ (NSUInteger)(_backgroundStyle << 16) ^ _fontFamily.hash;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;   // immutable
}

@end
