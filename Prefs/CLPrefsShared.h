// Shared, dependency-free helpers used by every controller in this bundle: typed CFPreferences
// access against the com.andi.carly domain, and Darwin notification posting.
// Header-only key/domain constants come from Tweak/Util/CLPrefsKeys.h (the single source of
// truth for key strings); nothing here links against any Tweak/*.m implementation file.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLPrefsShared : NSObject

// MARK: Typed reads. Each returns `def` when the key is absent or holds the wrong type; never
// throws, never blocks longer than a small CFPreferences plist read.
+ (BOOL)boolForKey:(NSString *)key default:(BOOL)def;
+ (double)doubleForKey:(NSString *)key default:(double)def;
+ (NSInteger)integerForKey:(NSString *)key default:(NSInteger)def;
+ (NSString *)stringForKey:(NSString *)key default:(NSString *)def;
+ (NSArray<NSString *> *)stringArrayForKey:(NSString *)key default:(NSArray<NSString *> *)def;
/// Raw, untyped read (CFPreferencesCopyAppValue bridged to an NSObject), for export/diagnostics.
+ (nullable id)rawValueForKey:(NSString *)key;

// MARK: Writes.
/// Writes one value. A nil value removes the key. Does NOT synchronize by itself; batch several
/// -setValue:forKey: calls then call +synchronize once.
+ (void)setValue:(nullable id)value forKey:(NSString *)key;
/// Removes every key in `keys`.
+ (void)removeValuesForKeys:(NSArray<NSString *> *)keys;
/// Flushes pending writes to disk. Cheap but not free; call once per user action, not per keystroke.
+ (void)synchronize;

// MARK: Darwin notifications (com.andi.carly/...).
+ (void)postDarwinNotificationNamed:(NSString *)name;
/// Convenience: +synchronize, then post "prefsChanged". Call after any value write the running
/// tweak needs to pick up live.
+ (void)notifyPrefsChanged;
/// Convenience: post "clearCache" (no synchronize; nothing to flush).
+ (void)notifyClearCache;
/// Convenience: post "resetDefaults". Call after the keys have already been removed.
+ (void)notifyResetDefaults;

// MARK: The app list (Apps page and its picker).
/// "enabledApps", trimmed and de-duplicated, in order; the tweak's default when unset.
+ (NSArray<NSString *> *)enabledApps;
/// Writes "enabledApps" and posts prefsChanged.
+ (void)setEnabledApps:(NSArray<NSString *> *)apps;

/// Every CLPrefKey* string the tweak reads (0.5.0), in the same grouping as CLPrefsKeys.h's table.
/// Export writes these, Import accepts only these, Reset removes these (plus +legacyKeys).
+ (NSArray<NSString *> *)allKnownKeys;

/// Keys older versions wrote that nothing reads any more (the two-line overlay's position and
/// line count, the artwork scale, the title font size, compact mode, the app-badge switch).
/// They are listed here, as plain strings, so Reset All Settings can drop them from the domain;
/// they are not in +allKnownKeys, so Export skips them and Import ignores them.
+ (NSArray<NSString *> *)legacyKeys;

@end

NS_ASSUME_NONNULL_END
