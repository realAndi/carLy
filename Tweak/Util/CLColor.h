// Contract: owned by the prefs-model slice. The only file in Util allowed to import UIKit — every
// preference that represents a colour is stored and passed around as a hex string (see
// CLPrefsKeys.h / CLPrefs.h); this is where that string becomes a UIColor and back.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLColor : NSObject

/// Parses a hex colour string into a UIColor. Accepts "#RGB", "#RGBA", "#RRGGBB" and
/// "#RRGGBBAA" (case-insensitive, the leading "#" is optional). Shorthand forms double each
/// digit (e.g. "#0F0" == "#00FF00"). Returns `fallback` for nil/empty input or any string that is
/// not exactly one of those four hex lengths, or that contains a non-hex character. Never throws.
+ (UIColor *)colorWithHex:(nullable NSString *)hex fallback:(UIColor *)fallback;

/// Renders a UIColor back to a hex string: "#RRGGBB" when the colour is fully opaque, otherwise
/// "#RRGGBBAA". Components are read via -getRed:green:blue:alpha: (with a grayscale/CMYK-safe
/// fallback through the color's CGColor) so it round-trips colours from
/// UIColorPickerViewController as well as ones built with +colorWithHex:fallback:.
+ (NSString *)hexFromColor:(UIColor *)color;

/// Maps a CSS-style numeric font weight (100...900, matching the lyricsFontWeight preference) to
/// a UIFontWeight, linearly interpolating between the nine named weights for values that do not
/// land exactly on a multiple of 100. Values outside 100...900 are clamped.
+ (UIFontWeight)fontWeightFromNumeric:(NSInteger)numeric;

@end

NS_ASSUME_NONNULL_END
