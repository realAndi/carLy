// A schematic CarPlay Now Playing screen drawn with Core Graphics: the host's own layout as
// CarPlayUI 17.3 would build it for the chosen screen (stacked or side artwork, the column for
// Side by Side, the artwork-less strip or column for No Artwork), with the lyrics where
// CLLayoutCustomizer puts them. Which of those happens, and every rect, comes from the same
// UI/CLLayoutGeometry.h the tweak uses, so what the preview shows is what the car gets — as a
// diagram, not a screenshot.
#import <UIKit/UIKit.h>
#import "CLLayoutPreviewModel.h"

NS_ASSUME_NONNULL_BEGIN

/// Head-unit shapes worth previewing: the common wide one, a very short ultrawide (1920x720 @3x,
/// where neither the stacked column nor the strip fits) and a portrait display (the host stacks
/// by itself; the strip is what a split becomes there).
typedef NS_ENUM(NSInteger, CLPreviewScreen) {
    CLPreviewScreenWide = 0,    ///< 800 x 480 pt @2x
    CLPreviewScreenShort = 1,   ///< 640 x 240 pt @3x with a 45 pt sidebar
    CLPreviewScreenTall = 2,    ///< 600 x 800 pt @2x
};

@interface CLLayoutPreviewView : UIView

@property (nonatomic, copy, nullable) CLLayoutPreviewModel *model;
@property (nonatomic) CLPreviewScreen screen;
/// Card mode: lyrics and text become bars, fine detail is dropped. For the small layout cards.
@property (nonatomic) BOOL card;
/// Draws the full-screen lyrics view (the microphone's) instead of the layout. Only while the
/// model has the Lyrics Button on and a layout other than Off.
@property (nonatomic) BOOL fullScreen;

+ (CGSize)pointSizeForScreen:(CLPreviewScreen)screen;
+ (CGRect)safeAreaForScreen:(CLPreviewScreen)screen;
/// The unit's display scale (points -> pixels), which decides the host's button size.
+ (CGFloat)displayScaleForScreen:(CLPreviewScreen)screen;
+ (NSString *)titleForScreen:(CLPreviewScreen)screen;

@end

NS_ASSUME_NONNULL_END
