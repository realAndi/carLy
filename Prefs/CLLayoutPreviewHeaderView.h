// The Layout page's table header: the big preview of the staged layout with a caption naming the
// screen and what it actually shows there, a screen-shape picker, a row of three cards (one per
// layout) that pick the layout with a tap, and a description of the staged layout. Owns no
// preferences; the list controller feeds it a model and hears back about taps.
#import <UIKit/UIKit.h>
#import "CLLayoutPreviewView.h"

NS_ASSUME_NONNULL_BEGIN

/// The cards, in order, and the lyricsMode each one stands for: Off, No Artwork (2), Side by Side. A card's tag is its index here; this table is the only index -> mode mapping.
NSArray<NSNumber *> *CLLayoutCardModes(void);

@interface CLLayoutPreviewHeaderView : UIView

/// The staged values. Setting it redraws the preview, the captions and every card (cards keep
/// their own mode). -setModel:animated: crossfades the big preview.
@property (nonatomic, copy, nullable) CLLayoutPreviewModel *model;
- (void)setModel:(nullable CLLayoutPreviewModel *)model animated:(BOOL)animated;
@property (nonatomic) CLPreviewScreen screen;
/// Called when a layout card is tapped, with the card's lyricsMode value (CLLayoutCardModes()).
@property (nonatomic, copy, nullable) void (^onLayoutPicked)(NSInteger layoutMode);
/// Called when the screen-shape picker changes `screen` (not when the controller sets it).
@property (nonatomic, copy, nullable) void (^onScreenChanged)(CLPreviewScreen screen);

/// The height this header wants at `width`. Independent of the model, so the table never jumps.
+ (CGFloat)preferredHeightForWidth:(CGFloat)width;

@end

NS_ASSUME_NONNULL_END
