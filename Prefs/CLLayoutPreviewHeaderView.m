#import "CLLayoutPreviewHeaderView.h"
#import "UI/CLLayoutGeometry.h"

// Vertical rhythm, top to bottom. +preferredHeightForWidth: sums exactly these.
static const CGFloat kCLHeaderPadding = 16.0;      // top and bottom
static const CGFloat kCLPreviewHeight = 210.0;     // the big preview is letterboxed in this
static const CGFloat kCLPreviewCaptionGap = 6.0;
static const CGFloat kCLCaptionLineHeight = 16.0;  // 13 pt text; two lines are always reserved
static const CGFloat kCLCaptionSegmentGap = 10.0;
static const CGFloat kCLSegmentHeight = 32.0;
static const CGFloat kCLSegmentCardsGap = 12.0;
static const CGFloat kCLCardSpacing = 8.0;
static const CGFloat kCLCardLabelHeight = 16.0;
static const CGFloat kCLCardsDescriptionGap = 8.0;
static const CGFloat kCLTextSize = 13.0;

NSArray<NSNumber *> *CLLayoutCardModes(void) {
    return @[ @(CLLayoutModeOff), @(CLLayoutModeFullPanel), @(CLLayoutModeSideBySide) ];
}

/// The name of a lyricsMode (a card) and of an effective mode (what a screen shows).
static NSString *CLLayoutModeName(NSInteger mode) {
    switch (mode) {
        case CLLayoutModeOff: return @"Off";
        case CLLayoutModeFullPanel: return @"No Artwork";
        case CLLayoutModeSideBySide: return @"Side by Side";
        default: return @"";
    }
}

static NSString *CLLayoutEffectiveModeName(NSInteger effectiveMode) {
    switch (effectiveMode) {
        case CLLayoutEffectiveOff: return @"Off";
        case CLLayoutEffectiveSideBySide: return @"Side by Side";
        case CLLayoutEffectiveFullPanel: return @"No Artwork";
        default: return @"";
    }
}

/// What the staged layout means, under the cards.
static NSString *CLLayoutModeDescription(NSInteger mode) {
    switch (mode) {
        case CLLayoutModeOff: return @"CarPlay's own Now Playing screen. The microphone still opens full-screen lyrics.";
        case CLLayoutModeFullPanel: return @"Lyrics take most of the screen. CarPlay's compact player, without the cover, sits below them, or beside them on short screens.";
        case CLLayoutModeSideBySide: return @"Player on the left, scrolling lyrics on the right. Screens too narrow to split show No Artwork.";
        default: return @"";
    }
}

/// The second caption line when a screen cannot show the staged layout as such; nil when it can.
static NSString *CLLayoutFallbackCaption(NSInteger mode, NSInteger effectiveMode) {
    if (effectiveMode == CLLayoutEffectiveOff && mode != CLLayoutModeOff) {
        return @"Too small for lyrics — shows CarPlay's own screen here";
    }
    if (mode == CLLayoutModeFullPanel && effectiveMode == CLLayoutEffectiveSideBySide) {
        return @"Too short for the strip — shows Side by Side here";
    }
    if (mode == CLLayoutModeSideBySide && effectiveMode == CLLayoutEffectiveFullPanel) {
        return @"Too narrow to split — shows No Artwork here";
    }
    return nil;
}

static UIFont *CLCaptionFont(void) { return [UIFont systemFontOfSize:kCLTextSize]; }

/// The microphone (and so full-screen lyrics) exists for these staged values, on every layout.
static BOOL CLHeaderOffersFullScreen(CLLayoutPreviewModel *model) {
    return model && model.showLyricsButton;
}

/// Height of the tallest of the four descriptions at `width`, never less than two lines: the
/// header's height does not depend on which card is selected.
static CGFloat CLDescriptionHeightForWidth(CGFloat width) {
    CGFloat tallest = 2.0 * kCLCaptionLineHeight;
    NSDictionary *attributes = @{ NSFontAttributeName: CLCaptionFont() };
    for (NSNumber *mode in CLLayoutCardModes()) {
        CGRect box = [CLLayoutModeDescription(mode.integerValue) boundingRectWithSize:CGSizeMake(MAX(1.0, width), CGFLOAT_MAX)
                                                                              options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                                           attributes:attributes context:nil];
        tallest = MAX(tallest, ceil(CGRectGetHeight(box)));
    }
    return tallest;
}

static CGFloat CLCardWidthForContentWidth(CGFloat contentWidth) {
    CGFloat cards = (CGFloat)CLLayoutCardModes().count;
    return floor((contentWidth - (cards - 1.0) * kCLCardSpacing) / cards);
}

@implementation CLLayoutPreviewHeaderView {
    CLLayoutPreviewView *_preview;
    UILabel *_captionLabel;
    UISegmentedControl *_screenControl;
    NSArray<UIView *> *_cards;              // containers, tag = index into CLLayoutCardModes()
    NSArray<CLLayoutPreviewView *> *_cardPreviews;
    NSArray<UIImageView *> *_cardChecks;
    NSArray<UILabel *> *_cardLabels;
    UILabel *_descriptionLabel;
}

+ (CGFloat)preferredHeightForWidth:(CGFloat)width {
    CGFloat contentWidth = MAX(1.0, width - 2.0 * kCLHeaderPadding);
    CGFloat cardPreviewHeight = round(CLCardWidthForContentWidth(contentWidth) * 2.0 / 3.0);
    return kCLHeaderPadding + kCLPreviewHeight + kCLPreviewCaptionGap + 2.0 * kCLCaptionLineHeight + kCLCaptionSegmentGap +
           kCLSegmentHeight + kCLSegmentCardsGap + cardPreviewHeight + kCLCardLabelHeight + kCLCardsDescriptionGap +
           CLDescriptionHeightForWidth(contentWidth) + kCLHeaderPadding;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        CGFloat hairline = 1.0 / MAX(1.0, UIScreen.mainScreen.scale);

        _preview = [[CLLayoutPreviewView alloc] initWithFrame:CGRectZero];
        _preview.backgroundColor = UIColor.blackColor;
        _preview.layer.borderWidth = hairline;
        _preview.layer.borderColor = UIColor.separatorColor.CGColor;
        // A tap shows what the microphone opens: the full-screen lyrics on the same screen.
        _preview.userInteractionEnabled = YES;
        [_preview addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cl_previewTapped:)]];
        _preview.accessibilityTraits = UIAccessibilityTraitButton;
        [self addSubview:_preview];

        _captionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _captionLabel.font = CLCaptionFont();
        _captionLabel.textColor = UIColor.secondaryLabelColor;
        _captionLabel.textAlignment = NSTextAlignmentCenter;
        _captionLabel.numberOfLines = 2;
        [self addSubview:_captionLabel];

        NSMutableArray<NSString *> *screens = [NSMutableArray array];
        for (NSInteger screen = CLPreviewScreenWide; screen <= CLPreviewScreenTall; screen++) {
            [screens addObject:[CLLayoutPreviewView titleForScreen:(CLPreviewScreen)screen]];
        }
        _screenControl = [[UISegmentedControl alloc] initWithItems:screens];
        _screenControl.selectedSegmentIndex = 0;
        [_screenControl addTarget:self action:@selector(cl_screenChanged:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:_screenControl];

        NSMutableArray<UIView *> *cards = [NSMutableArray array];
        NSMutableArray<CLLayoutPreviewView *> *previews = [NSMutableArray array];
        NSMutableArray<UIImageView *> *checks = [NSMutableArray array];
        NSMutableArray<UILabel *> *labels = [NSMutableArray array];
        NSArray<NSNumber *> *modes = CLLayoutCardModes();
        UIImage *checkImage = [UIImage systemImageNamed:@"checkmark.circle.fill"
                                      withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18.0 weight:UIImageSymbolWeightSemibold]];
        for (NSUInteger index = 0; index < modes.count; index++) {
            NSString *name = CLLayoutModeName(modes[index].integerValue);
            UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
            card.tag = (NSInteger)index;
            [card addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cl_cardTapped:)]];
            card.isAccessibilityElement = YES;
            card.accessibilityLabel = name;
            card.accessibilityTraits = UIAccessibilityTraitButton;

            CLLayoutPreviewView *preview = [[CLLayoutPreviewView alloc] initWithFrame:CGRectZero];
            preview.card = YES;
            preview.screen = CLPreviewScreenWide;       // cards always show the wide screen
            preview.backgroundColor = UIColor.blackColor;
            preview.layer.cornerRadius = 8.0;
            preview.userInteractionEnabled = NO;
            [card addSubview:preview];

            UIImageView *check = [[UIImageView alloc] initWithImage:checkImage];
            check.contentMode = UIViewContentModeCenter;
            check.hidden = YES;
            [card addSubview:check];

            UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
            label.text = name;
            label.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
            label.textAlignment = NSTextAlignmentCenter;
            label.adjustsFontSizeToFitWidth = YES;
            label.minimumScaleFactor = 0.8;
            [card addSubview:label];

            [self addSubview:card];
            [cards addObject:card];
            [previews addObject:preview];
            [checks addObject:check];
            [labels addObject:label];
        }
        _cards = cards;
        _cardPreviews = previews;
        _cardChecks = checks;
        _cardLabels = labels;

        _descriptionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _descriptionLabel.font = CLCaptionFont();
        _descriptionLabel.textColor = UIColor.secondaryLabelColor;
        _descriptionLabel.textAlignment = NSTextAlignmentCenter;
        _descriptionLabel.numberOfLines = 0;
        [self addSubview:_descriptionLabel];
    }
    return self;
}

#pragma mark - Model

- (void)setModel:(CLLayoutPreviewModel *)model {
    [self setModel:model animated:NO];
}

- (void)setModel:(CLLayoutPreviewModel *)model animated:(BOOL)animated {
    _model = [model copy];
    CLLayoutPreviewView *preview = _preview;
    if (animated) {
        [UIView transitionWithView:preview duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{ preview.model = model; } completion:nil];
    } else {
        preview.model = model;
    }
    if (!CLHeaderOffersFullScreen(model)) preview.fullScreen = NO;
    NSArray<NSNumber *> *modes = CLLayoutCardModes();
    for (NSUInteger i = 0; i < _cardPreviews.count && i < modes.count; i++) {
        CLLayoutPreviewModel *cardModel = [model copy];
        cardModel.layoutMode = modes[i].integerValue;
        _cardPreviews[i].model = cardModel;
    }
    [self cl_updateSelection];
    [self cl_updateCaptions];
}

- (void)setScreen:(CLPreviewScreen)screen {
    _screen = screen;
    if (_screenControl.selectedSegmentIndex != screen) _screenControl.selectedSegmentIndex = screen;
    _preview.screen = screen;
    [self cl_updateCaptions];
    [self setNeedsLayout];
}

- (void)cl_updateSelection {
    NSInteger selected = _model ? _model.layoutMode : NSNotFound;
    UIColor *tint = self.tintColor ?: UIColor.systemBlueColor;
    CGFloat hairline = 1.0 / MAX(1.0, UIScreen.mainScreen.scale);
    NSArray<NSNumber *> *modes = CLLayoutCardModes();
    for (NSUInteger i = 0; i < _cardPreviews.count && i < modes.count; i++) {
        BOOL isSelected = (modes[i].integerValue == selected);
        _cardPreviews[i].layer.borderWidth = isSelected ? 2.0 : hairline;
        _cardPreviews[i].layer.borderColor = (isSelected ? tint : UIColor.separatorColor).CGColor;
        _cardChecks[i].hidden = !isSelected;
        _cardChecks[i].tintColor = tint;
        _cardLabels[i].textColor = isSelected ? tint : UIColor.secondaryLabelColor;
        _cardLabels[i].font = [UIFont systemFontOfSize:11.0 weight:isSelected ? UIFontWeightSemibold : UIFontWeightMedium];
        _cards[i].accessibilityTraits = UIAccessibilityTraitButton | (isSelected ? UIAccessibilityTraitSelected : 0);
    }
}

/// "800 × 480 · No Artwork" (the screen, and what it shows for the staged layout), plus a second
/// line when that differs from the staged layout; the description of the staged layout below.
- (void)cl_updateCaptions {
    if (!_model) {
        _captionLabel.text = nil;
        _descriptionLabel.text = nil;
        return;
    }
    NSInteger mode = _model.layoutMode;
    CGSize size = [CLLayoutPreviewView pointSizeForScreen:_screen];
    CGRect safe = [CLLayoutPreviewView safeAreaForScreen:_screen];
    CLLayoutPlan plan = CLLayoutPlanMake(mode, safe, CLLayoutDefaultSideArtworkRatio, YES);
    NSString *caption = nil;
    if (_preview.fullScreen) {
        caption = [NSString stringWithFormat:@"%.0f × %.0f · Full-Screen Lyrics\nTap the preview to go back", size.width, size.height];
    } else {
        caption = [NSString stringWithFormat:@"%.0f × %.0f · %@", size.width, size.height, CLLayoutEffectiveModeName(plan.effectiveMode)];
        NSString *second = CLLayoutFallbackCaption(mode, plan.effectiveMode);
        if (!second && CLHeaderOffersFullScreen(_model)) second = @"Tap the preview for full-screen lyrics";
        if (second) caption = [caption stringByAppendingFormat:@"\n%@", second];
    }
    _captionLabel.text = caption;
    _descriptionLabel.text = CLLayoutModeDescription(mode);
}

- (void)tintColorDidChange {
    [super tintColorDidChange];
    [self cl_updateSelection];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // CGColors do not follow appearance changes by themselves.
    _preview.layer.borderColor = UIColor.separatorColor.CGColor;
    [self cl_updateSelection];
}

#pragma mark - Actions

- (void)cl_screenChanged:(UISegmentedControl *)control {
    self.screen = (CLPreviewScreen)MAX((NSInteger)0, control.selectedSegmentIndex);
    if (_onScreenChanged) _onScreenChanged(self.screen);
}

- (void)cl_previewTapped:(UITapGestureRecognizer *)recognizer {
    if (!CLHeaderOffersFullScreen(_model)) return;
    CLLayoutPreviewView *preview = _preview;
    BOOL fullScreen = !preview.fullScreen;
    [UIView transitionWithView:preview duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{ preview.fullScreen = fullScreen; } completion:nil];
    [self cl_updateCaptions];
}

- (void)cl_cardTapped:(UITapGestureRecognizer *)recognizer {
    NSInteger index = recognizer.view.tag;
    NSArray<NSNumber *> *modes = CLLayoutCardModes();
    if (index < 0 || index >= (NSInteger)modes.count) return;
    if (_onLayoutPicked) _onLayoutPicked(modes[(NSUInteger)index].integerValue);
}

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat contentWidth = MAX(1.0, width - 2.0 * kCLHeaderPadding);
    CGFloat y = kCLHeaderPadding;

    // The preview keeps the screen's aspect inside a fixed height, centred.
    CGSize screen = [CLLayoutPreviewView pointSizeForScreen:_screen];
    CGFloat scale = MIN(contentWidth / screen.width, kCLPreviewHeight / screen.height);
    CGSize previewSize = CGSizeMake(round(screen.width * scale), round(screen.height * scale));
    _preview.frame = CGRectMake(round(kCLHeaderPadding + (contentWidth - previewSize.width) / 2.0),
                                round(y + (kCLPreviewHeight - previewSize.height) / 2.0),
                                previewSize.width, previewSize.height);
    y += kCLPreviewHeight + kCLPreviewCaptionGap;

    _captionLabel.frame = CGRectMake(kCLHeaderPadding, y, contentWidth, 2.0 * kCLCaptionLineHeight);
    y += 2.0 * kCLCaptionLineHeight + kCLCaptionSegmentGap;

    _screenControl.frame = CGRectMake(kCLHeaderPadding, y, contentWidth, kCLSegmentHeight);
    y += kCLSegmentHeight + kCLSegmentCardsGap;

    CGFloat cardWidth = CLCardWidthForContentWidth(contentWidth);
    CGFloat cardPreviewHeight = round(cardWidth * 2.0 / 3.0);
    CGFloat cardHeight = cardPreviewHeight + kCLCardLabelHeight;
    for (NSUInteger i = 0; i < _cards.count; i++) {
        CGFloat x = kCLHeaderPadding + (CGFloat)i * (cardWidth + kCLCardSpacing);
        _cards[i].frame = CGRectMake(x, y, cardWidth, cardHeight);
        _cardPreviews[i].frame = CGRectMake(0.0, 0.0, cardWidth, cardPreviewHeight);
        _cardChecks[i].frame = CGRectMake(cardWidth - 4.0 - 20.0, 4.0, 20.0, 20.0);
        _cardLabels[i].frame = CGRectMake(0.0, cardPreviewHeight, cardWidth, kCLCardLabelHeight);
    }
    y += cardHeight + kCLCardsDescriptionGap;

    _descriptionLabel.frame = CGRectMake(kCLHeaderPadding, y, contentWidth, CLDescriptionHeightForWidth(contentWidth));
}

@end
