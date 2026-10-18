// Everything the Layout page's preview needs to draw one Now Playing screen: the staged layout
// values (what the user is about to apply) plus the committed lyric text style (font size,
// colours, alignment — those live on the Lyrics page and apply live). Plain values, no UIKit
// state, copyable, so the big preview and the four layout cards can each hold their own.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLLayoutPreviewModel : NSObject <NSCopying>

// Layout (staged on the Layout page). Keys and meanings: Tweak/Util/CLPrefsKeys.h.
@property (nonatomic) NSInteger layoutMode;            ///< lyricsMode, normalised (1 and 3 read as 4; 0, 2, 4)
@property (nonatomic) double artworkCornerRadius;
@property (nonatomic) NSInteger backdropStyle;
@property (nonatomic) double backdropOpacity;
@property (nonatomic) BOOL tintFromArtwork;
@property (nonatomic, copy) NSString *accentColorHex;
@property (nonatomic) BOOL showAlbum;
@property (nonatomic) NSInteger progressBarStyle;      ///< 0 show, 2 hide (a stored 1 reads as 0)
@property (nonatomic) BOOL hidePlaybackRateButton;
@property (nonatomic) BOOL hideQueueButton;
@property (nonatomic) BOOL showLyricsButton;          ///< the microphone in the play-mode row (full-screen lyrics)
@property (nonatomic) NSInteger lyricsSide;           ///< 0 right, 1 left (CLLayoutLyricsSide)

// Lyric text style (committed values from the Lyrics page).
@property (nonatomic) double lyricsFontSize;
@property (nonatomic) NSInteger lyricsFontWeight;
@property (nonatomic) NSInteger lyricsAlignment;
@property (nonatomic, copy) NSString *lyricsCurrentColorHex;
@property (nonatomic, copy) NSString *lyricsNextColorHex;
@property (nonatomic) double lyricsNextAlpha;
@property (nonatomic) NSInteger lyricsBackground;
@property (nonatomic, copy) NSString *lyricsBackgroundColorHex;
@property (nonatomic) double lyricsBackgroundAlpha;

/// The committed preferences, with `staged` (key -> value, CLPrefKey* keys) laid over them.
+ (instancetype)modelWithStagedValues:(nullable NSDictionary<NSString *, id> *)staged;

@end

NS_ASSUME_NONNULL_END
