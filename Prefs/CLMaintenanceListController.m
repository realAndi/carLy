#import "CLMaintenanceListController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "CLPrefsShared.h"
#import "Util/CLPrefsKeys.h"

typedef NS_ENUM(NSInteger, CLPrefValueType) {
    CLPrefValueTypeBool,
    CLPrefValueTypeNumber,     // int or float, both come back as NSNumber from JSON/plist
    CLPrefValueTypeString,
    CLPrefValueTypeStringArray,
};

static NSString *const kCLExportFileName = @"carLySettings.json";
static NSString *const kCLCachedSongsSpecifierID = @"cachedSongs";
/// The tweak's lyrics cache (CLLyricsCache: <NSCachesDirectory>/carLy/lyrics/<key>.json inside
/// CarPlayTemplateUIHost, whose caches directory is the plain /var/mobile one). Settings' own
/// NSCachesDirectory is its sandbox container, so the path is spelled out here.
static NSString *const kCLLyricsCacheDirectory = @"/var/mobile/Library/Caches/carLy/lyrics";

@interface CLMaintenanceListController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) NSURL *pendingExportURL;
@end

@implementation CLMaintenanceListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Maintenance" target:self];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self cl_refreshCachedSongs];
}

#pragma mark - Cached songs

- (void)cl_refreshCachedSongs {
    if ([self specifierForID:kCLCachedSongsSpecifierID]) [self reloadSpecifierID:kCLCachedSongsSpecifierID animated:NO];
}

/// "128 songs · 3.2 MB", "1 song · 12 KB" or "No cached songs": every .json under the cache
/// directory (lyrics and remembered misses alike). A missing or unreadable directory counts as empty.
- (id)cl_cachedSongsSummary:(PSSpecifier *)specifier {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:kCLLyricsCacheDirectory error:NULL];
    NSUInteger count = 0;
    unsigned long long bytes = 0;
    for (NSString *name in names) {
        if (![name.pathExtension.lowercaseString isEqualToString:@"json"]) continue;
        NSDictionary *attributes = [fm attributesOfItemAtPath:[kCLLyricsCacheDirectory stringByAppendingPathComponent:name] error:NULL];
        if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
        count++;
        bytes += [attributes fileSize];
    }
    if (count == 0) return @"No cached songs";
    NSString *size = [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
    return [NSString stringWithFormat:@"%lu song%@ · %@", (unsigned long)count, count == 1 ? @"" : @"s", size];
}

#pragma mark - Key type table (mirrors the table in Tweak/Util/CLPrefsKeys.h)

- (NSDictionary<NSString *, NSNumber *> *)cl_keyTypes {
    static NSDictionary<NSString *, NSNumber *> *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary<NSString *, NSNumber *> *t = [NSMutableDictionary dictionary];
        void (^mark)(NSString *, CLPrefValueType) = ^(NSString *key, CLPrefValueType type) {
            t[key] = @(type);
        };
        mark(CLPrefKeyEnabled, CLPrefValueTypeBool);
        mark(CLPrefKeyDebugLogging, CLPrefValueTypeBool);
        mark(CLPrefKeyEnabledApps, CLPrefValueTypeStringArray);
        mark(CLPrefKeyAllApps, CLPrefValueTypeBool);

        mark(CLPrefKeyLyricsMode, CLPrefValueTypeNumber);
        mark(CLPrefKeyLyricsFontFamily, CLPrefValueTypeString);
        mark(CLPrefKeyLyricsFontSize, CLPrefValueTypeNumber);
        mark(CLPrefKeyLyricsFontWeight, CLPrefValueTypeNumber);
        mark(CLPrefKeyLyricsCurrentColor, CLPrefValueTypeString);
        mark(CLPrefKeyLyricsNextColor, CLPrefValueTypeString);
        mark(CLPrefKeyLyricsNextAlpha, CLPrefValueTypeNumber);
        mark(CLPrefKeyLyricsAlignment, CLPrefValueTypeNumber);
        mark(CLPrefKeyLyricsAnimations, CLPrefValueTypeBool);
        mark(CLPrefKeyLyricsShowPlainWhenUnsynced, CLPrefValueTypeBool);
        mark(CLPrefKeyLyricsOffsetMs, CLPrefValueTypeNumber);
        mark(CLPrefKeyServiceLyricsOffsetMs, CLPrefValueTypeNumber);
        mark(CLPrefKeyLyricsShowNoteOnGap, CLPrefValueTypeBool);
        mark(CLPrefKeyLyricsBackground, CLPrefValueTypeNumber);
        mark(CLPrefKeyLyricsBackgroundColor, CLPrefValueTypeString);
        mark(CLPrefKeyLyricsBackgroundAlpha, CLPrefValueTypeNumber);

        mark(CLPrefKeyArtworkCornerRadius, CLPrefValueTypeNumber);
        mark(CLPrefKeyBackdropStyle, CLPrefValueTypeNumber);
        mark(CLPrefKeyBackdropOpacity, CLPrefValueTypeNumber);
        mark(CLPrefKeyTintFromArtwork, CLPrefValueTypeBool);
        mark(CLPrefKeyAccentColor, CLPrefValueTypeString);
        mark(CLPrefKeyShowAlbum, CLPrefValueTypeBool);
        mark(CLPrefKeyProgressBarStyle, CLPrefValueTypeNumber);
        mark(CLPrefKeyHidePlaybackRateButton, CLPrefValueTypeBool);
        mark(CLPrefKeyHideQueueButton, CLPrefValueTypeBool);
        mark(CLPrefKeyShowLyricsButton, CLPrefValueTypeBool);
        mark(CLPrefKeyLyricsSide, CLPrefValueTypeNumber);

        mark(CLPrefKeyProviderOrder, CLPrefValueTypeStringArray);
        mark(CLPrefKeyEmbeddedLyricsEnabled, CLPrefValueTypeBool);
        mark(CLPrefKeyAppleMusicLyricsEnabled, CLPrefValueTypeBool);
        mark(CLPrefKeyLRCLibEnabled, CLPrefValueTypeBool);
        mark(CLPrefKeySpotifyLyricsEnabled, CLPrefValueTypeBool);
        mark(CLPrefKeySpotifyCacheEnabled, CLPrefValueTypeBool);
        mark(CLPrefKeyCustomEndpointEnabled, CLPrefValueTypeBool);
        mark(CLPrefKeyCustomEndpointURL, CLPrefValueTypeString);
        mark(CLPrefKeyCustomEndpointHeaderName, CLPrefValueTypeString);
        mark(CLPrefKeyCustomEndpointHeaderValue, CLPrefValueTypeString);
        mark(CLPrefKeyOfflineOnly, CLPrefValueTypeBool);
        mark(CLPrefKeyCacheNegativeHours, CLPrefValueTypeNumber);
        table = t;
    });
    return table;
}

#pragma mark - Clear cache

// Named cl_…, never plain -clearCache: that is a private PSListController method which Preferences
// itself calls from -reload (so the alert popped up on opening the page) and from -dealloc (where
// the weak self below aborted Settings on leaving it). Every button action in the plists carries
// the prefix for the same reason; scripts/check-prefs-plists.py enforces it.
- (void)cl_clearLyricsCache {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear Lyrics Cache?"
                                                                     message:@"Removes every cached lyric on disk. Lyrics will be looked up again the next time each song plays."
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [CLPrefsShared notifyClearCache];
        // The running tweak empties the directory when it receives the notification; refresh the
        // count now and again once it has had a moment.
        [weakSelf cl_refreshCachedSongs];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf cl_refreshCachedSongs];
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Reset all settings

- (void)cl_resetToDefaults {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset All Settings?"
                                                                     message:@"Every carLy setting goes back to its default. This cannot be undone."
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf cl_performReset];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)cl_performReset {
    // Current keys plus the ones older versions wrote, so nothing stale is left in the domain.
    [CLPrefsShared removeValuesForKeys:[CLPrefsShared allKnownKeys]];
    [CLPrefsShared removeValuesForKeys:[CLPrefsShared legacyKeys]];
    [CLPrefsShared synchronize];
    [CLPrefsShared notifyResetDefaults];
    [CLPrefsShared notifyPrefsChanged];
    // Every specifier on every page reads live from CFPreferences on next display, so simply
    // reloading this page's own table is enough visual feedback; no full-bundle relaunch needed.
    [self reloadSpecifiers];   // not the -tableView getter: 17.3 has only -table
}

#pragma mark - Export

- (void)cl_exportSettings {
    NSDictionary<NSString *, NSNumber *> *types = [self cl_keyTypes];
    NSMutableDictionary<NSString *, id> *values = [NSMutableDictionary dictionaryWithCapacity:types.count];
    for (NSString *key in types) {
        id raw = [CLPrefsShared rawValueForKey:key];
        if (raw != nil) values[key] = raw;
    }

    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:values options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (!json) {
        [self cl_presentSimpleAlertTitle:@"Export Failed" message:error.localizedDescription ?: @"Could not encode settings."];
        return;
    }

    NSURL *tmpURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:kCLExportFileName]];
    if (![json writeToURL:tmpURL options:NSDataWritingAtomic error:&error]) {
        [self cl_presentSimpleAlertTitle:@"Export Failed" message:error.localizedDescription ?: @"Could not write the settings file."];
        return;
    }
    self.pendingExportURL = tmpURL;

    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[tmpURL] applicationActivities:nil];
    // Required on iPad (and harmless everywhere else) so the share sheet has an anchor.
    activity.popoverPresentationController.sourceView = self.view;
    activity.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    activity.popoverPresentationController.permittedArrowDirections = 0;
    [self presentViewController:activity animated:YES completion:nil];
}

#pragma mark - Import

- (void)cl_importSettings {
    NSArray<UTType *> *types = @[ UTTypeJSON ];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;

    BOOL accessing = [url startAccessingSecurityScopedResource];
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
    if (accessing) [url stopAccessingSecurityScopedResource];

    if (!data) {
        [self cl_presentSimpleAlertTitle:@"Import Failed" message:error.localizedDescription ?: @"Could not read the file."];
        return;
    }

    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![parsed isKindOfClass:[NSDictionary class]]) {
        [self cl_presentSimpleAlertTitle:@"Import Failed" message:@"That file is not a valid carLy settings export."];
        return;
    }

    // Keys the type table does not know — including the ones older versions exported
    // (+[CLPrefsShared legacyKeys]) — are skipped, never written.
    NSDictionary<NSString *, id> *dict = (NSDictionary *)parsed;
    NSDictionary<NSString *, NSNumber *> *types = [self cl_keyTypes];
    NSUInteger applied = 0, skipped = 0;
    for (NSString *key in dict) {
        if (![key isKindOfClass:[NSString class]]) { skipped++; continue; }
        NSNumber *typeBox = types[key];
        if (!typeBox) { skipped++; continue; } // unknown key, ignore rather than write arbitrary data
        id value = dict[key];
        if (![self cl_value:value matchesType:(CLPrefValueType)typeBox.integerValue]) { skipped++; continue; }
        [CLPrefsShared setValue:value forKey:key];
        applied++;
    }
    [CLPrefsShared notifyPrefsChanged];

    [self reloadSpecifiers];   // not the -tableView getter: 17.3 has only -table

    NSString *message = [NSString stringWithFormat:@"Applied %lu setting%@.%@",
                          (unsigned long)applied, applied == 1 ? @"" : @"s",
                          skipped > 0 ? [NSString stringWithFormat:@" Skipped %lu unrecognized or malformed value%@.", (unsigned long)skipped, skipped == 1 ? @"" : @"s"] : @""];
    [self cl_presentSimpleAlertTitle:@"Import Complete" message:message];
}

- (BOOL)cl_value:(id)value matchesType:(CLPrefValueType)type {
    switch (type) {
        case CLPrefValueTypeBool:
        case CLPrefValueTypeNumber:
            return [value isKindOfClass:[NSNumber class]];
        case CLPrefValueTypeString:
            return [value isKindOfClass:[NSString class]];
        case CLPrefValueTypeStringArray: {
            if (![value isKindOfClass:[NSArray class]]) return NO;
            for (id item in (NSArray *)value) {
                if (![item isKindOfClass:[NSString class]]) return NO;
            }
            return YES;
        }
    }
    return NO;
}

#pragma mark - Helpers

- (void)cl_presentSimpleAlertTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
