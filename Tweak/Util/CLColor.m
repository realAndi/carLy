#import "CLColor.h"

// MARK: - Hex digit helpers

static BOOL CLIsHexDigit(unichar c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

static NSUInteger CLHexNibble(unichar c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return 0;
}

/// One shorthand digit ("F") doubled into a byte (0xFF).
static NSUInteger CLHexByteFromShorthand(unichar c) {
    NSUInteger nibble = CLHexNibble(c);
    return (nibble << 4) | nibble;
}

static NSUInteger CLHexByteFromPair(unichar hi, unichar lo) {
    return (CLHexNibble(hi) << 4) | CLHexNibble(lo);
}

@implementation CLColor

+ (UIColor *)colorWithHex:(NSString *)hex fallback:(UIColor *)fallback {
    if (hex.length == 0) return fallback;

    NSString *s = [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([s hasPrefix:@"#"]) s = [s substringFromIndex:1];
    if (s.length == 0) return fallback;

    for (NSUInteger i = 0; i < s.length; i++) {
        if (!CLIsHexDigit([s characterAtIndex:i])) return fallback;
    }

    NSUInteger r = 0, g = 0, b = 0, a = 255;
    switch (s.length) {
        case 3: // RGB
            r = CLHexByteFromShorthand([s characterAtIndex:0]);
            g = CLHexByteFromShorthand([s characterAtIndex:1]);
            b = CLHexByteFromShorthand([s characterAtIndex:2]);
            break;
        case 4: // RGBA
            r = CLHexByteFromShorthand([s characterAtIndex:0]);
            g = CLHexByteFromShorthand([s characterAtIndex:1]);
            b = CLHexByteFromShorthand([s characterAtIndex:2]);
            a = CLHexByteFromShorthand([s characterAtIndex:3]);
            break;
        case 6: // RRGGBB
            r = CLHexByteFromPair([s characterAtIndex:0], [s characterAtIndex:1]);
            g = CLHexByteFromPair([s characterAtIndex:2], [s characterAtIndex:3]);
            b = CLHexByteFromPair([s characterAtIndex:4], [s characterAtIndex:5]);
            break;
        case 8: // RRGGBBAA
            r = CLHexByteFromPair([s characterAtIndex:0], [s characterAtIndex:1]);
            g = CLHexByteFromPair([s characterAtIndex:2], [s characterAtIndex:3]);
            b = CLHexByteFromPair([s characterAtIndex:4], [s characterAtIndex:5]);
            a = CLHexByteFromPair([s characterAtIndex:6], [s characterAtIndex:7]);
            break;
        default:
            return fallback;
    }

    return [UIColor colorWithRed:(CGFloat)r / 255.0
                            green:(CGFloat)g / 255.0
                             blue:(CGFloat)b / 255.0
                            alpha:(CGFloat)a / 255.0];
}

+ (NSString *)hexFromColor:(UIColor *)color {
    if (!color) return @"#000000";

    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        // Not an RGB-representable color space (e.g. grayscale, or a pattern color) — fall back to
        // reading the raw CGColor components rather than crashing or guessing.
        CGColorRef cgColor = color.CGColor;
        size_t componentCount = CGColorGetNumberOfComponents(cgColor);
        const CGFloat *components = CGColorGetComponents(cgColor);
        if (components) {
            if (componentCount == 2) {
                // Grayscale + alpha.
                r = g = b = components[0];
                a = components[1];
            } else if (componentCount >= 4) {
                r = components[0];
                g = components[1];
                b = components[2];
                a = components[3];
            }
        }
    }

    r = MAX((CGFloat)0.0, MIN((CGFloat)1.0, r));
    g = MAX((CGFloat)0.0, MIN((CGFloat)1.0, g));
    b = MAX((CGFloat)0.0, MIN((CGFloat)1.0, b));
    a = MAX((CGFloat)0.0, MIN((CGFloat)1.0, a));

    unsigned int R = (unsigned int)lround(r * 255.0);
    unsigned int G = (unsigned int)lround(g * 255.0);
    unsigned int B = (unsigned int)lround(b * 255.0);
    unsigned int A = (unsigned int)lround(a * 255.0);

    if (A == 255) {
        return [NSString stringWithFormat:@"#%02X%02X%02X", R, G, B];
    }
    return [NSString stringWithFormat:@"#%02X%02X%02X%02X", R, G, B, A];
}

+ (UIFontWeight)fontWeightFromNumeric:(NSInteger)numeric {
    NSInteger n = numeric;
    if (n < 100) n = 100;
    if (n > 900) n = 900;

    static const NSInteger kWeightSteps[] = {100, 200, 300, 400, 500, 600, 700, 800, 900};
    // Values line up with Apple's named UIFontWeight constants for the CSS-style 100...900 scale.
    const UIFontWeight kWeightValues[] = {
        UIFontWeightUltraLight,
        UIFontWeightThin,
        UIFontWeightLight,
        UIFontWeightRegular,
        UIFontWeightMedium,
        UIFontWeightSemibold,
        UIFontWeightBold,
        UIFontWeightHeavy,
        UIFontWeightBlack,
    };
    NSUInteger stepCount = sizeof(kWeightSteps) / sizeof(kWeightSteps[0]);

    for (NSUInteger i = 0; i < stepCount; i++) {
        if (kWeightSteps[i] == n) return kWeightValues[i];
    }
    for (NSUInteger i = 0; i + 1 < stepCount; i++) {
        NSInteger lo = kWeightSteps[i];
        NSInteger hi = kWeightSteps[i + 1];
        if (n > lo && n < hi) {
            double t = (double)(n - lo) / (double)(hi - lo);
            return (UIFontWeight)(kWeightValues[i] + t * (kWeightValues[i + 1] - kWeightValues[i]));
        }
    }
    return UIFontWeightRegular;
}

@end
