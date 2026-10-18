// Owned by the ui slice. One immutable snapshot of every *visual* lyrics preference, resolved
// once from CLPrefs so the panel renders the same everywhere and so a re-style can be skipped
// when nothing actually changed. UIKit lives here (CLPrefs itself is UIKit-free and
// hands colours out as hex strings).
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Shown for a timed line with empty text (an instrumental gap) when lyricsShowNoteOnGap is on.
extern NSString *const CLLyricsNoteGlyph;

/// YES when a line has no words: empty, or nothing but music notes (♩ ♪ ♫ ♬ 🎵 🎶) and spaces.
/// Spotify writes "♪" as the text of its instrumental breaks; read as a gap, those follow
/// lyricsShowNoteOnGap like every other gap instead of always drawing their own note.
BOOL CLLyricsTextIsGap(NSString *_Nullable text);

/// Runs `block` on the main queue: synchronously when the caller is already there, asynchronously
/// otherwise. Every public UI entry point funnels through this so a provider callback that
/// arrives on a background queue can never touch UIKit off-main.
void CLUIRunOnMain(dispatch_block_t _Nullable block);

/// Runs `block` and swallows (and logs) any NSException it raises, exactly like the hooks' own
/// CLSafePerform. The hook bodies are already wrapped, but the UI layer is *also* driven by two
/// callbacks that never pass through a hook — CLPrefsDidChangeNotification, posted from a bare
/// dispatch_async in CLPrefs, and the CLLyricsController observer block, driven by the sync
/// engine's timer — and an exception escaping either of those unwinds into a dispatch block with
/// no handler, which aborts CarPlayTemplateUIHost and takes the whole CarPlay screen down. Every
/// externally-reachable entry point of the UI layer goes through this.
void CLUISafePerform(NSString *_Nullable what, dispatch_block_t _Nullable block);

@interface CLLyricsStyle : NSObject <NSCopying>

/// Resolves the current values from `[CLPrefs shared]`. Cheap (no I/O); call it whenever
/// CLPrefsDidChangeNotification fires, then compare with -isEqualToStyle: to skip needless work.
+ (instancetype)currentStyle;

@property (nonatomic, readonly, copy) NSString *fontFamily;   ///< "" means the system font
@property (nonatomic, readonly) CGFloat fontSize;             ///< clamped to 10...80
@property (nonatomic, readonly) UIFontWeight fontWeight;
@property (nonatomic, readonly) UIColor *currentColor;
@property (nonatomic, readonly) UIColor *nextColor;           ///< lyricsNextAlpha already applied
@property (nonatomic, readonly) NSTextAlignment alignment;
@property (nonatomic, readonly) BOOL animations;
@property (nonatomic, readonly) BOOL showNoteOnGap;
@property (nonatomic, readonly) BOOL showPlainWhenUnsynced;
@property (nonatomic, readonly) NSInteger backgroundStyle;    ///< 0 none, 1 translucent pill, 2 solid
@property (nonatomic, readonly, nullable) UIColor *backgroundFill;  ///< nil when backgroundStyle == 0

/// Font in the configured family, falling back to the system font when the family is not
/// installed. Never returns nil.
- (UIFont *)fontWithSize:(CGFloat)size weight:(UIFontWeight)weight;
/// The active line's font (fontSize / fontWeight).
@property (nonatomic, readonly) UIFont *currentLineFont;
/// The upcoming lines' font (78 % of fontSize, one step lighter).
@property (nonatomic, readonly) UIFont *secondaryLineFont;

- (BOOL)isEqualToStyle:(nullable CLLyricsStyle *)other;

@end

NS_ASSUME_NONNULL_END
