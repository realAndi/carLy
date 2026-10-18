#import "CLLayoutPreviewModel.h"
#import "CLPrefsShared.h"
#import "UI/CLLayoutGeometry.h"
#import "Util/CLPrefsKeys.h"

@implementation CLLayoutPreviewModel

+ (instancetype)modelWithStagedValues:(NSDictionary<NSString *, id> *)staged {
    // Same defaults and legacy mappings as CLPrefs.m, so a fresh install previews exactly what it
    // will show and an old plist previews what the tweak makes of it.
    id (^value)(NSString *) = ^id(NSString *key) {
        id stagedValue = staged[key];
        return stagedValue ?: [CLPrefsShared rawValueForKey:key];
    };
    NSInteger (^integer)(NSString *, NSInteger) = ^NSInteger(NSString *key, NSInteger def) {
        id raw = value(key);
        return [raw isKindOfClass:NSNumber.class] ? [(NSNumber *)raw integerValue] : def;
    };
    double (^number)(NSString *, double) = ^double(NSString *key, double def) {
        id raw = value(key);
        return [raw isKindOfClass:NSNumber.class] ? [(NSNumber *)raw doubleValue] : def;
    };
    BOOL (^boolean)(NSString *, BOOL) = ^BOOL(NSString *key, BOOL def) {
        id raw = value(key);
        return [raw isKindOfClass:NSNumber.class] ? [(NSNumber *)raw boolValue] : def;
    };
    NSString *(^string)(NSString *, NSString *) = ^NSString *(NSString *key, NSString *def) {
        id raw = value(key);
        return [raw isKindOfClass:NSString.class] ? (NSString *)raw : def;
    };

    CLLayoutPreviewModel *model = [CLLayoutPreviewModel new];
    model.layoutMode = CLLayoutModeNormalize(integer(CLPrefKeyLyricsMode, CLLayoutModeSideBySide));
    model.artworkCornerRadius = MAX(0.0, MIN(200.0, number(CLPrefKeyArtworkCornerRadius, 12.0)));
    model.backdropStyle = MAX((NSInteger)0, MIN((NSInteger)1, integer(CLPrefKeyBackdropStyle, 0)));
    model.backdropOpacity = MAX(0.0, MIN(1.0, number(CLPrefKeyBackdropOpacity, 1.0)));
    model.tintFromArtwork = boolean(CLPrefKeyTintFromArtwork, NO);
    model.accentColorHex = string(CLPrefKeyAccentColor, @"");
    model.showAlbum = boolean(CLPrefKeyShowAlbum, YES);
    NSInteger progress = MAX((NSInteger)0, MIN((NSInteger)2, integer(CLPrefKeyProgressBarStyle, 0)));
    model.progressBarStyle = (progress == 1) ? 0 : progress;      // 1 was the removed thin bar
    model.hidePlaybackRateButton = boolean(CLPrefKeyHidePlaybackRateButton, NO);
    model.hideQueueButton = boolean(CLPrefKeyHideQueueButton, NO);
    model.showLyricsButton = boolean(CLPrefKeyShowLyricsButton, YES);
    model.lyricsSide = MAX((NSInteger)0, MIN((NSInteger)1, integer(CLPrefKeyLyricsSide, 0)));

    model.lyricsFontSize = MAX(10.0, MIN(80.0, number(CLPrefKeyLyricsFontSize, 24.0)));
    model.lyricsFontWeight = MAX((NSInteger)100, MIN((NSInteger)900, integer(CLPrefKeyLyricsFontWeight, 600)));
    model.lyricsAlignment = MAX((NSInteger)0, MIN((NSInteger)2, integer(CLPrefKeyLyricsAlignment, 0)));
    model.lyricsCurrentColorHex = string(CLPrefKeyLyricsCurrentColor, @"#FFFFFF");
    model.lyricsNextColorHex = string(CLPrefKeyLyricsNextColor, @"#FFFFFF");
    model.lyricsNextAlpha = MAX(0.0, MIN(1.0, number(CLPrefKeyLyricsNextAlpha, 0.45)));
    model.lyricsBackground = MAX((NSInteger)0, MIN((NSInteger)2, integer(CLPrefKeyLyricsBackground, 0)));
    model.lyricsBackgroundColorHex = string(CLPrefKeyLyricsBackgroundColor, @"#000000");
    model.lyricsBackgroundAlpha = MAX(0.0, MIN(1.0, number(CLPrefKeyLyricsBackgroundAlpha, 0.35)));
    return model;
}

- (id)copyWithZone:(NSZone *)zone {
    CLLayoutPreviewModel *copy = [[self.class allocWithZone:zone] init];
    copy.layoutMode = self.layoutMode;
    copy.artworkCornerRadius = self.artworkCornerRadius;
    copy.backdropStyle = self.backdropStyle;
    copy.backdropOpacity = self.backdropOpacity;
    copy.tintFromArtwork = self.tintFromArtwork;
    copy.accentColorHex = self.accentColorHex;
    copy.showAlbum = self.showAlbum;
    copy.progressBarStyle = self.progressBarStyle;
    copy.hidePlaybackRateButton = self.hidePlaybackRateButton;
    copy.hideQueueButton = self.hideQueueButton;
    copy.showLyricsButton = self.showLyricsButton;
    copy.lyricsSide = self.lyricsSide;
    copy.lyricsFontSize = self.lyricsFontSize;
    copy.lyricsFontWeight = self.lyricsFontWeight;
    copy.lyricsAlignment = self.lyricsAlignment;
    copy.lyricsCurrentColorHex = self.lyricsCurrentColorHex;
    copy.lyricsNextColorHex = self.lyricsNextColorHex;
    copy.lyricsNextAlpha = self.lyricsNextAlpha;
    copy.lyricsBackground = self.lyricsBackground;
    copy.lyricsBackgroundColorHex = self.lyricsBackgroundColorHex;
    copy.lyricsBackgroundAlpha = self.lyricsBackgroundAlpha;
    return copy;
}

@end
