// Local, self-contained hex <-> UIColor helper for this bundle only. Mirrors the behaviour of
// Tweak/Util/CLColor.h exactly (same accepted formats, same rounding) so colours picked here read
// back identically in the tweak, but is reimplemented rather than importing CLColor.m: the Prefs
// bundle does not build or link any Tweak/*.m implementation file.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLPrefsColor : NSObject

/// Parses "#RGB", "#RGBA", "#RRGGBB" or "#RRGGBBAA" (case-insensitive, leading "#" optional).
/// Shorthand forms double each digit. Returns `fallback` for nil/empty/malformed input. Never throws.
+ (UIColor *)colorWithHex:(nullable NSString *)hex fallback:(UIColor *)fallback;

/// Renders back to "#RRGGBB" (opaque) or "#RRGGBBAA" (translucent), uppercase hex digits.
+ (NSString *)hexFromColor:(UIColor *)color;

@end

NS_ASSUME_NONNULL_END
