#import "CLPrefsShared.h"
#import <CoreFoundation/CoreFoundation.h>
// Header-only: pure #define macros, nothing to link. Single source of truth for key strings.
#import "Util/CLPrefsKeys.h"

@implementation CLPrefsShared

+ (nullable id)rawValueForKey:(NSString *)key {
    if (key.length == 0) return nil;
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)CLPrefsDomain);
    if (!value) return nil;
    id obj = (__bridge_transfer id)value;
    return obj;
}

+ (BOOL)boolForKey:(NSString *)key default:(BOOL)def {
    id v = [self rawValueForKey:key];
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
    return def;
}

+ (double)doubleForKey:(NSString *)key default:(double)def {
    id v = [self rawValueForKey:key];
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v doubleValue];
    return def;
}

+ (NSInteger)integerForKey:(NSString *)key default:(NSInteger)def {
    id v = [self rawValueForKey:key];
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v integerValue];
    return def;
}

+ (NSString *)stringForKey:(NSString *)key default:(NSString *)def {
    id v = [self rawValueForKey:key];
    if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
    return def;
}

+ (NSArray<NSString *> *)stringArrayForKey:(NSString *)key default:(NSArray<NSString *> *)def {
    id v = [self rawValueForKey:key];
    if (![v isKindOfClass:[NSArray class]]) return def;
    NSArray *raw = (NSArray *)v;
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:raw.count];
    for (id item in raw) {
        if ([item isKindOfClass:[NSString class]]) [out addObject:item];
    }
    return out.count > 0 ? out : def;
}

+ (void)setValue:(nullable id)value forKey:(NSString *)key {
    if (key.length == 0) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef _Nullable)(value), (__bridge CFStringRef)CLPrefsDomain);
}

+ (void)removeValuesForKeys:(NSArray<NSString *> *)keys {
    for (NSString *key in keys) {
        if (![key isKindOfClass:[NSString class]]) continue;
        [self setValue:nil forKey:key];
    }
}

+ (void)synchronize {
    CFPreferencesAppSynchronize((__bridge CFStringRef)CLPrefsDomain);
}

+ (void)postDarwinNotificationNamed:(NSString *)name {
    if (name.length == 0) return;
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    if (!center) return;
    CFNotificationCenterPostNotification(center, (CFStringRef)name, NULL, NULL, YES);
}

+ (void)notifyPrefsChanged {
    [self synchronize];
    [self postDarwinNotificationNamed:CLPrefsDarwinNotificationPrefsChanged];
}

+ (void)notifyClearCache {
    [self postDarwinNotificationNamed:CLPrefsDarwinNotificationClearCache];
}

+ (void)notifyResetDefaults {
    [self postDarwinNotificationNamed:CLPrefsDarwinNotificationResetDefaults];
}

+ (NSArray<NSString *> *)enabledApps {
    NSArray<NSString *> *apps = [self stringArrayForKey:CLPrefKeyEnabledApps
                                                default:@[ @"com.spotify.client", @"com.apple.Music" ]];
    // Defensive de-dupe while preserving order, in case the array was hand-edited elsewhere.
    NSMutableArray<NSString *> *seen = [NSMutableArray arrayWithCapacity:apps.count];
    for (NSString *app in apps) {
        NSString *trimmed = [app stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0 && ![seen containsObject:trimmed]) [seen addObject:trimmed];
    }
    return seen;
}

+ (void)setEnabledApps:(NSArray<NSString *> *)apps {
    [self setValue:apps ?: @[] forKey:CLPrefKeyEnabledApps];
    [self notifyPrefsChanged];
}

+ (NSArray<NSString *> *)allKnownKeys {
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            // General
            CLPrefKeyEnabled, CLPrefKeyDebugLogging, CLPrefKeyEnabledApps, CLPrefKeyAllApps,
            // Lyrics
            CLPrefKeyLyricsMode, CLPrefKeyLyricsFontFamily,
            CLPrefKeyLyricsFontSize, CLPrefKeyLyricsFontWeight, CLPrefKeyLyricsCurrentColor,
            CLPrefKeyLyricsNextColor, CLPrefKeyLyricsNextAlpha, CLPrefKeyLyricsAlignment,
            CLPrefKeyLyricsAnimations, CLPrefKeyLyricsShowPlainWhenUnsynced,
            CLPrefKeyLyricsOffsetMs, CLPrefKeyServiceLyricsOffsetMs, CLPrefKeyLyricsShowNoteOnGap, CLPrefKeyLyricsBackground,
            CLPrefKeyLyricsBackgroundColor, CLPrefKeyLyricsBackgroundAlpha,
            // Layout
            CLPrefKeyArtworkCornerRadius, CLPrefKeyBackdropStyle,
            CLPrefKeyBackdropOpacity, CLPrefKeyTintFromArtwork, CLPrefKeyAccentColor,
            CLPrefKeyShowAlbum, CLPrefKeyProgressBarStyle, CLPrefKeyHidePlaybackRateButton,
            CLPrefKeyHideQueueButton, CLPrefKeyShowLyricsButton, CLPrefKeyLyricsSide,
            // Sources
            CLPrefKeyProviderOrder, CLPrefKeyEmbeddedLyricsEnabled, CLPrefKeyAppleMusicLyricsEnabled,
            CLPrefKeySpotifyLyricsEnabled, CLPrefKeyLRCLibEnabled, CLPrefKeySpotifyCacheEnabled,
            CLPrefKeyCustomEndpointEnabled, CLPrefKeyCustomEndpointURL,
            CLPrefKeyCustomEndpointHeaderName, CLPrefKeyCustomEndpointHeaderValue,
            CLPrefKeyOfflineOnly, CLPrefKeyCacheNegativeHours,
        ];
    });
    return keys;
}

+ (NSArray<NSString *> *)legacyKeys {
    // Plain strings on purpose: CLPrefsKeys.h no longer defines these (0.5.0 removed them), and
    // this list is the only place they still exist.
    return @[ @"lyricsPosition", @"lyricsMaxLines", @"artworkScale", @"titleFontSize", @"compactMode", @"hideAppBadge" ];
}

@end
