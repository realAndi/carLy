#import "CLPrefsColor.h"

static BOOL CLIsHexDigit(unichar c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

static BOOL CLHexNibble(unichar c, uint8_t *outValue) {
    if (c >= '0' && c <= '9') { *outValue = (uint8_t)(c - '0'); return YES; }
    if (c >= 'a' && c <= 'f') { *outValue = (uint8_t)(c - 'a' + 10); return YES; }
    if (c >= 'A' && c <= 'F') { *outValue = (uint8_t)(c - 'A' + 10); return YES; }
    return NO;
}

/// Reads two hex digits starting at `index` and returns a 0...255 byte, or NO if either digit is
/// not a hex character.
static BOOL CLHexByte(NSString *s, NSUInteger index, uint8_t *outValue) {
    if (index + 1 >= s.length) return NO;
    uint8_t hi = 0, lo = 0;
    if (!CLHexNibble([s characterAtIndex:index], &hi)) return NO;
    if (!CLHexNibble([s characterAtIndex:index + 1], &lo)) return NO;
    *outValue = (uint8_t)((hi << 4) | lo);
    return YES;
}

@implementation CLPrefsColor

+ (UIColor *)colorWithHex:(nullable NSString *)hex fallback:(UIColor *)fallback {
    if (hex.length == 0) return fallback;
    NSString *s = [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([s hasPrefix:@"#"]) s = [s substringFromIndex:1];
    if (s.length == 0) return fallback;

    for (NSUInteger i = 0; i < s.length; i++) {
        if (!CLIsHexDigit([s characterAtIndex:i])) return fallback;
    }

    uint8_t r = 0, g = 0, b = 0, a = 255;
    switch (s.length) {
        case 3: { // RGB shorthand
            uint8_t rr, gg, bb;
            if (!CLHexNibble([s characterAtIndex:0], &rr) ||
                !CLHexNibble([s characterAtIndex:1], &gg) ||
                !CLHexNibble([s characterAtIndex:2], &bb)) return fallback;
            r = (uint8_t)(rr * 17); g = (uint8_t)(gg * 17); b = (uint8_t)(bb * 17);
            break;
        }
        case 4: { // RGBA shorthand
            uint8_t rr, gg, bb, aa;
            if (!CLHexNibble([s characterAtIndex:0], &rr) ||
                !CLHexNibble([s characterAtIndex:1], &gg) ||
                !CLHexNibble([s characterAtIndex:2], &bb) ||
                !CLHexNibble([s characterAtIndex:3], &aa)) return fallback;
            r = (uint8_t)(rr * 17); g = (uint8_t)(gg * 17); b = (uint8_t)(bb * 17); a = (uint8_t)(aa * 17);
            break;
        }
        case 6: // RRGGBB
            if (!CLHexByte(s, 0, &r) || !CLHexByte(s, 2, &g) || !CLHexByte(s, 4, &b)) return fallback;
            break;
        case 8: // RRGGBBAA
            if (!CLHexByte(s, 0, &r) || !CLHexByte(s, 2, &g) || !CLHexByte(s, 4, &b) || !CLHexByte(s, 6, &a)) return fallback;
            break;
        default:
            return fallback;
    }

    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a / 255.0];
}

+ (NSString *)hexFromColor:(UIColor *)color {
    if (!color) return @"#000000";
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        // Grayscale/CMYK-safe fallback via the color's CGColor components.
        CGColorRef cg = color.CGColor;
        size_t n = CGColorGetNumberOfComponents(cg);
        const CGFloat *comps = CGColorGetComponents(cg);
        if (comps && n >= 1) {
            if (n >= 4) { r = comps[0]; g = comps[1]; b = comps[2]; a = comps[3]; }
            else if (n >= 2) { r = g = b = comps[0]; a = comps[1]; }
            else { r = g = b = comps[0]; a = 1; }
        }
    }
    uint8_t ri = (uint8_t)round(MAX(0.0, MIN(1.0, r)) * 255.0);
    uint8_t gi = (uint8_t)round(MAX(0.0, MIN(1.0, g)) * 255.0);
    uint8_t bi = (uint8_t)round(MAX(0.0, MIN(1.0, b)) * 255.0);
    uint8_t ai = (uint8_t)round(MAX(0.0, MIN(1.0, a)) * 255.0);
    if (ai >= 255) {
        return [NSString stringWithFormat:@"#%02X%02X%02X", ri, gi, bi];
    }
    return [NSString stringWithFormat:@"#%02X%02X%02X%02X", ri, gi, bi, ai];
}

@end
