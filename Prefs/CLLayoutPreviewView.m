#import "CLLayoutPreviewView.h"
#import "CLPrefsColor.h"
#import "UI/CLLayoutGeometry.h"

/// The lines the preview sings. Plain filler; never real lyrics.
static NSArray<NSString *> *CLPreviewLines(void) {
    return @[ @"Headlights on the highway", @"Counting every mile", @"Radio is playing our song",
              @"Windows down, we sing along", @"Nothing left to chase", @"Only open road ahead",
              @"Take the long way home" ];
}
static const NSInteger CLPreviewCurrentLine = 3;

/// Colours of the imaginary album cover, and the accent "Use Album Colors" would derive from it.
static UIColor *CLPreviewCoverColorA(void) { return [UIColor colorWithRed:0.93 green:0.45 blue:0.22 alpha:1.0]; }
static UIColor *CLPreviewCoverColorB(void) { return [UIColor colorWithRed:0.35 green:0.12 blue:0.42 alpha:1.0]; }
static UIColor *CLPreviewArtworkAccent(void) { return [UIColor colorWithRed:0.98 green:0.62 blue:0.36 alpha:1.0]; }

@implementation CLLayoutPreviewView {
    /// One device pixel in drawing (screen-point) units for the pass in progress.
    CGFloat _hairline;
    BOOL _fullScreen;
}

+ (CGSize)pointSizeForScreen:(CLPreviewScreen)screen {
    switch (screen) {
        case CLPreviewScreenShort: return CGSizeMake(640.0, 240.0);
        case CLPreviewScreenTall: return CGSizeMake(600.0, 800.0);
        default: return CGSizeMake(800.0, 480.0);
    }
}

+ (CGRect)safeAreaForScreen:(CLPreviewScreen)screen {
    CGSize size = [self pointSizeForScreen:screen];
    // 44 pt navigation bar on top; the short display also keeps a 45 pt sidebar on the left
    // (measured in the CarPlay Simulator at 1920x720 @3x: safe area 595x196 at {45,44}).
    CGFloat left = (screen == CLPreviewScreenShort) ? 45.0 : 0.0;
    return CGRectMake(left, 44.0, size.width - left, size.height - 44.0);
}

+ (CGFloat)displayScaleForScreen:(CLPreviewScreen)screen {
    return (screen == CLPreviewScreenShort) ? 3.0 : 2.0;
}

+ (NSString *)titleForScreen:(CLPreviewScreen)screen {
    switch (screen) {
        case CLPreviewScreenShort: return @"Short";
        case CLPreviewScreenTall: return @"Tall";
        default: return @"Wide";
    }
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.contentMode = UIViewContentModeRedraw;
        self.layer.cornerRadius = 10.0;
        self.layer.masksToBounds = YES;
    }
    return self;
}

- (void)setModel:(CLLayoutPreviewModel *)model {
    _model = [model copy];
    [self setNeedsDisplay];
}

- (void)setScreen:(CLPreviewScreen)screen {
    _screen = screen;
    [self setNeedsDisplay];
}

- (void)setFullScreen:(BOOL)fullScreen {
    if (_fullScreen == fullScreen) return;
    _fullScreen = fullScreen;
    [self setNeedsDisplay];
}

- (void)setCard:(BOOL)card {
    _card = card;
    [self setNeedsDisplay];
}

#pragma mark - Drawing helpers

static void CLFillRoundedRect(CGContextRef context, CGRect rect, CGFloat radius, UIColor *color) {
    if (CGRectIsEmpty(rect)) return;
    radius = MIN(radius, MIN(CGRectGetWidth(rect), CGRectGetHeight(rect)) / 2.0);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
    CGContextSetFillColorWithColor(context, color.CGColor);
    CGContextAddPath(context, path.CGPath);
    CGContextFillPath(context);
}

static void CLFillCircle(CGContextRef context, CGPoint center, CGFloat radius, UIColor *color) {
    CGContextSetFillColorWithColor(context, color.CGColor);
    CGContextFillEllipseInRect(context, CGRectMake(center.x - radius, center.y - radius, radius * 2.0, radius * 2.0));
}

static void CLStrokeLine(CGContextRef context, CGPoint from, CGPoint to, CGFloat width, UIColor *color) {
    CGContextSetStrokeColorWithColor(context, color.CGColor);
    CGContextSetLineWidth(context, width);
    CGContextSetLineCap(context, kCGLineCapButt);
    CGContextMoveToPoint(context, from.x, from.y);
    CGContextAddLineToPoint(context, to.x, to.y);
    CGContextStrokePath(context);
}

/// A horizontal bar standing in for a line of text, aligned like the text would be.
static void CLFillTextBar(CGContextRef context, CGRect line, CGFloat widthFraction, NSInteger alignment, UIColor *color) {
    CGFloat width = CGRectGetWidth(line) * widthFraction;
    CGFloat x = CGRectGetMinX(line);
    if (alignment == 1) x = CGRectGetMidX(line) - width / 2.0;
    else if (alignment == 2) x = CGRectGetMaxX(line) - width;
    CGRect bar = CGRectMake(x, CGRectGetMinY(line), width, CGRectGetHeight(line));
    CLFillRoundedRect(context, bar, CGRectGetHeight(line) / 2.0, color);
}

static void CLDrawText(NSString *text, CGRect rect, UIFont *font, UIColor *color, NSTextAlignment alignment) {
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = alignment;
    style.lineBreakMode = NSLineBreakByTruncatingTail;
    [text drawInRect:rect withAttributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: color,
                                           NSParagraphStyleAttributeName: style }];
}

/// An SF Symbol drawn centred in `rect` at `pointSize`, in `color`.
static void CLDrawSymbol(NSString *name, CGRect rect, CGFloat pointSize, UIImageSymbolWeight weight, UIColor *color) {
    UIImage *image = [UIImage systemImageNamed:name
                             withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:weight]];
    image = [image imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
    if (!image) return;
    CGSize size = image.size;
    [image drawInRect:CGRectMake(CGRectGetMidX(rect) - size.width / 2.0, CGRectGetMidY(rect) - size.height / 2.0,
                                 size.width, size.height)];
}

/// Whether the full-screen lyrics exist for this model (the microphone is shown): every layout,
/// Off included.
static BOOL CLPreviewOffersFullScreen(CLLayoutPreviewModel *model) {
    return model.showLyricsButton;
}

static NSTextAlignment CLTextAlignment(NSInteger alignment) {
    if (alignment == 1) return NSTextAlignmentCenter;
    if (alignment == 2) return NSTextAlignmentRight;
    return NSTextAlignmentLeft;
}

static UIFontWeight CLFontWeight(NSInteger numeric) {
    if (numeric <= 100) return UIFontWeightThin;
    if (numeric <= 200) return UIFontWeightUltraLight;
    if (numeric <= 300) return UIFontWeightLight;
    if (numeric <= 400) return UIFontWeightRegular;
    if (numeric <= 500) return UIFontWeightMedium;
    if (numeric <= 600) return UIFontWeightSemibold;
    if (numeric <= 700) return UIFontWeightBold;
    if (numeric <= 800) return UIFontWeightHeavy;
    return UIFontWeightBlack;
}

#pragma mark - Drawing

- (void)drawRect:(CGRect)rect {
    CLLayoutPreviewModel *model = _model;
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!model || !context) return;

    // Everything below is drawn in screen points; the view letterboxes the screen inside itself.
    CGSize screen = [self.class pointSizeForScreen:_screen];
    CGRect bounds = self.bounds;
    CGFloat scale = MIN(CGRectGetWidth(bounds) / screen.width, CGRectGetHeight(bounds) / screen.height);
    if (!(scale > 0.0)) return;
    CGFloat offsetX = (CGRectGetWidth(bounds) - screen.width * scale) / 2.0;
    CGFloat offsetY = (CGRectGetHeight(bounds) - screen.height * scale) / 2.0;
    CGFloat pixels = MAX(1.0, self.traitCollection.displayScale);
    _hairline = 1.0 / (scale * pixels);

    CGContextSaveGState(context);
    CGContextTranslateCTM(context, offsetX, offsetY);
    CGContextScaleCTM(context, scale, scale);
    CGRect screenRect = CGRectMake(0.0, 0.0, screen.width, screen.height);
    UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:screenRect cornerRadius:10.0 / scale];
    CGContextAddPath(context, clip.CGPath);
    CGContextClip(context);

    [self cl_drawBackdropIn:context screen:screenRect model:model];
    CGRect safe = [self.class safeAreaForScreen:_screen];
    [self cl_drawNavigationBarIn:context screen:screenRect safe:safe model:model];
    if (_fullScreen && CLPreviewOffersFullScreen(model)) {
        [self cl_drawFullScreenIn:context safe:safe model:model];
        CGContextRestoreGState(context);
        return;
    }

    // The very same decision the customizer makes in the car, for this screen's safe area.
    CLLayoutPlan plan = CLLayoutPlanPlacingLyrics(CLLayoutPlanMake(model.layoutMode, safe, CLLayoutDefaultSideArtworkRatio, YES),
                                                  model.lyricsSide);
    CGRect playerSafe = CLLayoutPlayerRect(plan, safe);
    if (CGRectIsNull(playerSafe)) playerSafe = safe;
    // The view-area rect the tweak hands the host along with the safe rect (the host sizes its
    // buttons from that one): the column runs the full screen height, the strip reaches the
    // bottom edge, and the untouched host gets the whole screen.
    CGRect playerView = screenRect;
    if (plan.playerArea == CLLayoutPlayerAreaLeadingColumn) {
        CGFloat viewHeight = CLLayoutPlayerViewAreaHeight(screen, plan.playerWidth, CGRectGetHeight(safe),
                                                          [self.class displayScaleForScreen:_screen]);
        playerView = CGRectMake(CGRectGetMinX(playerSafe), 0.0, plan.playerWidth, viewHeight);
    } else if (plan.playerArea == CLLayoutPlayerAreaBottomStrip) {
        playerView = CGRectMake(CGRectGetMinX(safe), CGRectGetMinY(playerSafe), CGRectGetWidth(safe),
                                plan.playerHeight + MAX(0.0, screen.height - CGRectGetMaxY(safe)));
    }
    // The view hook reports right-hand drive for a leading column (art on the left) and left-hand
    // drive for a trailing one (art on the right): the art stays at the outer edge.
    BOOL artOnLeft = (plan.effectiveMode == CLLayoutEffectiveSideBySide) && !plan.playerOnTrailing;
    [self cl_drawPlayerIn:context safe:playerSafe viewArea:playerView plan:plan artOnLeft:artOnLeft model:model];

    // The lyrics follow the player area: beside a column (Side by Side, and No Artwork on short
    // screens) or above the strip. Off draws the stock screen.
    switch (plan.playerArea) {
        case CLLayoutPlayerAreaLeadingColumn: {
            CGRect lyrics = CLLayoutLyricsRect(plan, safe);
            // A hairline in the middle of the column gap, so the split reads as two areas.
            CGFloat x = plan.playerOnTrailing ? CGRectGetMinX(playerSafe) - CLLayoutColumnGap / 2.0
                                              : CGRectGetMinX(safe) + plan.playerWidth + CLLayoutColumnGap / 2.0;
            CLStrokeLine(context, CGPointMake(x, CGRectGetMinY(lyrics)), CGPointMake(x, CGRectGetMaxY(lyrics)),
                         _hairline, [UIColor colorWithWhite:1.0 alpha:0.15]);
            [self cl_drawPanelIn:context rect:lyrics fit:CLLayoutPanelFitColumn model:model];
            break;
        }
        case CLLayoutPlayerAreaBottomStrip: {
            CGRect lyrics = CLLayoutLyricsRect(plan, safe);
            // The strip's top edge, so it reads as the player's area rather than as wallpaper.
            CGFloat y = CGRectGetMinY(playerSafe);
            CLStrokeLine(context, CGPointMake(CGRectGetMinX(safe), y), CGPointMake(CGRectGetMaxX(safe), y),
                         _hairline, [UIColor colorWithWhite:1.0 alpha:0.10]);
            [self cl_drawPanelIn:context rect:lyrics fit:CLLayoutPanelFitRows model:model];
            break;
        }
        case CLLayoutPlayerAreaNone:
        default:
            break;
    }
    CGContextRestoreGState(context);
}

- (void)cl_drawBackdropIn:(CGContextRef)context screen:(CGRect)screen model:(CLLayoutPreviewModel *)model {
    // The host's table background, then its blurred full-bleed artwork on top of it.
    CGContextSetFillColorWithColor(context, [UIColor colorWithWhite:0.07 alpha:1.0].CGColor);
    CGContextFillRect(context, screen);
    if (model.backdropStyle == 1 || model.backdropOpacity <= 0.01) return;

    CGFloat alpha = 0.55 * model.backdropOpacity;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = @[ (id)[CLPreviewCoverColorA() colorWithAlphaComponent:alpha].CGColor,
                         (id)[CLPreviewCoverColorB() colorWithAlphaComponent:alpha * 0.8].CGColor,
                         (id)[UIColor colorWithWhite:0.07 alpha:alpha].CGColor ];
    CGFloat locations[] = { 0.0, 0.55, 1.0 };
    CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, locations);
    if (gradient) {
        CGContextSaveGState(context);
        CGContextClipToRect(context, screen);
        CGFloat radius = MAX(CGRectGetWidth(screen), CGRectGetHeight(screen)) * 0.75;
        CGContextDrawRadialGradient(context, gradient, CGPointMake(CGRectGetMaxX(screen) * 0.7, CGRectGetMidY(screen) * 0.6),
                                    0.0, CGPointMake(CGRectGetMaxX(screen) * 0.7, CGRectGetMidY(screen) * 0.6), radius,
                                    kCGGradientDrawsAfterEndLocation);
        CGContextRestoreGState(context);
        CGGradientRelease(gradient);
    }
    CGColorSpaceRelease(space);
}

- (void)cl_drawNavigationBarIn:(CGContextRef)context screen:(CGRect)screen safe:(CGRect)safe model:(CLLayoutPreviewModel *)model {
    CGRect bar = CGRectMake(CGRectGetMinX(safe), 0.0, CGRectGetWidth(safe), CGRectGetMinY(safe));
    UIColor *dim = [UIColor colorWithWhite:1.0 alpha:0.75];
    // Back chevron + app name on the left.
    CGFloat y = CGRectGetMidY(bar);
    CGContextSetStrokeColorWithColor(context, dim.CGColor);
    CGContextSetLineWidth(context, 3.0);
    CGContextSetLineCap(context, kCGLineCapRound);
    CGFloat x = CGRectGetMinX(bar) + 18.0;
    CGContextMoveToPoint(context, x + 7.0, y - 8.0);
    CGContextAddLineToPoint(context, x, y);
    CGContextAddLineToPoint(context, x + 7.0, y + 8.0);
    CGContextStrokePath(context);
    if (_card) {
        CLFillRoundedRect(context, CGRectMake(x + 18.0, y - 5.0, 70.0, 10.0), 5.0, dim);
    } else {
        CLDrawText(@"Spotify", CGRectMake(x + 18.0, y - 11.0, 160.0, 22.0),
                   [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold], dim, NSTextAlignmentLeft);
    }
    // Sidebar of the short display.
    if (CGRectGetMinX(safe) > 0.0) {
        CGContextSetFillColorWithColor(context, [UIColor colorWithWhite:1.0 alpha:0.08].CGColor);
        CGContextFillRect(context, CGRectMake(0.0, 0.0, CGRectGetMinX(safe), CGRectGetHeight(screen)));
    }
    // The queue on the right (Spotify's "Queue & Jam"); the playback speed lives in the play-mode row.
    CGFloat right = CGRectGetMaxX(bar) - 20.0;
    if (!model.hideQueueButton) {
        if (_card) CLFillRoundedRect(context, CGRectMake(right - 60.0, y - 5.0, 60.0, 10.0), 5.0, dim);
        else CLDrawText(@"Queue & Jam", CGRectMake(right - 160.0, y - 11.0, 160.0, 22.0),
                        [UIFont systemFontOfSize:17.0 weight:UIFontWeightRegular], dim, NSTextAlignmentRight);
    }
}

/// The host's Now Playing view inside `safe` (its safe rect) and `viewArea` (the rect it sizes
/// its buttons from): artwork square unless the plan hides it, song details, transport row,
/// progress bar and play-mode row, chained with the host's three equal spacers. Every height
/// comes from UI/CLLayoutGeometry.h's host constants and functions.
- (void)cl_drawPlayerIn:(CGContextRef)context safe:(CGRect)safe viewArea:(CGRect)viewArea plan:(CLLayoutPlan)plan
                artOnLeft:(BOOL)artOnLeft model:(CLLayoutPreviewModel *)model {
    CGFloat displayScale = [self.class displayScaleForScreen:_screen];
    CGFloat transport = CLLayoutHostTransportButtonHeight(viewArea.size, displayScale);
    // -[CPUINowPlayingLayoutStacked layoutMargins]: top 2, sides 27, bottom 12.
    CGRect content = CGRectInset(safe, CLLayoutHostMarginSide, 0.0);
    content.origin.y += CLLayoutHostMarginTop;
    content.size.height -= CLLayoutHostMarginTop + CLLayoutHostMarginBottom;
    BOOL showsArtwork = !plan.hidesArtwork;
    BOOL stacks = !showsArtwork || CLLayoutHostStacksSafeArea(safe, CLLayoutDefaultSideArtworkRatio);

    CGRect column = content;
    CGRect art = CGRectZero;
    BOOL large = NO;
    if (showsArtwork) {
        if (stacks) {
            CGFloat side = MIN(CGRectGetWidth(content) * 0.62, CGRectGetHeight(content) * 0.42);
            art = CGRectMake(CGRectGetMidX(content) - side / 2.0, CGRectGetMinY(content), side, side);
            column.origin.y = CGRectGetMaxY(art) + CLLayoutHostMinimumSpacer;
            column.size.height = CGRectGetMaxY(content) - column.origin.y;
            large = CLLayoutHostUsesLargeTier(CLLayoutHostTitleAreaSize(safe, YES, side, transport));
        } else if (CGRectGetWidth(safe) * displayScale < CLLayoutHostSideBandMaxScaledWidth) {
            // A short screen's side-layout player column: the side layouts' verified numbers
            // (UI/CLLayoutGeometry.h) — margin 12 below 900 px wide, else 16; art = 0.32 x the
            // width (0.27 below 800 px), centred vertically; title and transport from 22 pt right
            // of the art to 23 pt before the edge.
            CGFloat scaledWidth = CGRectGetWidth(safe) * displayScale;
            CGFloat margin = (scaledWidth < CLLayoutHostSideSmallMarginScaledWidth) ? 12.0 : 16.0;
            CGFloat multiplier = (scaledWidth < CLLayoutHostSideNarrowScaledWidth) ? CLLayoutHostSideArtMultiplierNarrow
                                                                                   : CLLayoutHostSideArtMultiplier;
            CGFloat side = MIN(round(CGRectGetWidth(safe) * multiplier), CGRectGetHeight(safe) - 2.0 * margin);
            CGFloat artX = artOnLeft ? CGRectGetMinX(safe) + margin : CGRectGetMaxX(safe) - margin - side;
            art = CGRectMake(artX, CGRectGetMidY(content) - side / 2.0, side, side);
            column.size.width = CGRectGetWidth(safe) - margin - side - (CLLayoutHostSideControlsChrome - 16.0);
            column.origin.x = artOnLeft ? CGRectGetMaxX(art) + 22.0 : CGRectGetMinX(safe) + 23.0;
            CGRect columnSafe = CGRectMake(CGRectGetMinX(column) - CLLayoutHostMarginSide, CGRectGetMinY(safe),
                                           CGRectGetWidth(column) + 2.0 * CLLayoutHostMarginSide, CGRectGetHeight(safe));
            large = CGRectGetWidth(column) >= 320.0 &&
                    CLLayoutHostTitleAreaSize(columnSafe, NO, 0.0, transport).height >= CLLayoutHostLargeTierTitleHeight;
        } else {
            // The whole of a wide screen (the stock side layout): an estimate, not the host's numbers.
            CGFloat side = MIN(CGRectGetHeight(content) - 16.0, CGRectGetWidth(content) * 0.44);
            CGFloat gap = 28.0;
            CGFloat artX = artOnLeft ? CGRectGetMinX(content) : CGRectGetMaxX(content) - side;
            art = CGRectMake(artX, CGRectGetMidY(content) - side / 2.0, side, side);
            column.size.width = CGRectGetWidth(content) - side - gap;
            if (artOnLeft) column.origin.x = CGRectGetMaxX(art) + gap;
            // The side layouts' large tier needs 320 pt beside the art and 106 pt for the title.
            CGRect columnSafe = CGRectMake(CGRectGetMinX(column) - CLLayoutHostMarginSide, CGRectGetMinY(safe),
                                           CGRectGetWidth(column) + 2.0 * CLLayoutHostMarginSide, CGRectGetHeight(safe));
            large = CGRectGetWidth(column) >= 320.0 &&
                    CLLayoutHostTitleAreaSize(columnSafe, NO, 0.0, transport).height >= CLLayoutHostLargeTierTitleHeight;
        }
    } else {
        large = CLLayoutHostUsesLargeTier(CLLayoutHostTitleAreaSize(safe, NO, 0.0, transport));
    }

    // The vertical chain: details, spacer, transport, spacer, progress, spacer, play mode.
    CGFloat detailsHeight = large ? CLLayoutHostDetailsHeightLarge : CLLayoutHostDetailsHeightSmall;
    CGFloat fixed = detailsHeight + transport + CLLayoutHostProgressHeight + CLLayoutHostPlayModeHeight;
    CGFloat spacer = MAX(CLLayoutHostMinimumSpacer, (CGRectGetHeight(column) - fixed) / 3.0);
    CGFloat y = CGRectGetMinY(column);
    CGRect details = CGRectMake(CGRectGetMinX(column), y, CGRectGetWidth(column), detailsHeight);
    y += detailsHeight + spacer;
    CGRect transportRow = CGRectMake(CGRectGetMinX(column), y, CGRectGetWidth(column), transport);
    y += transport + spacer;
    CGRect progress = CGRectMake(CGRectGetMinX(column), y, CGRectGetWidth(column), CLLayoutHostProgressHeight);
    y += CLLayoutHostProgressHeight + spacer;
    CGRect playMode = CGRectMake(CGRectGetMinX(column), y, CGRectGetWidth(column), CLLayoutHostPlayModeHeight);

    // The artwork square, rounded like the tweak rounds the brick (the lyrics replace it in mode 3).
    UIColor *accent = [self cl_accentColorForModel:model];
    if (showsArtwork) {
        [self cl_drawCoverIn:context rect:art cornerRadius:model.artworkCornerRadius];
    }

    // Song details in the host's tier: small = Callout title, Caption artist/album; large = Title.
    UIColor *label = [UIColor colorWithWhite:1.0 alpha:0.95];
    UIColor *secondary = accent ?: [UIColor colorWithWhite:1.0 alpha:0.6];
    CGFloat titleSize = large ? 24.0 : 17.0, artistSize = large ? 17.0 : 14.0, albumSize = large ? 15.0 : 14.0;
    CGFloat lineY = CGRectGetMinY(details) + 2.0;
    CGFloat textWidth = CGRectGetWidth(details);
    if (_card) {
        CLFillTextBar(context, CGRectMake(CGRectGetMinX(details), lineY, textWidth, titleSize * 0.6), 0.7, 0, label);
        lineY += titleSize * 0.6 + 6.0;
        CLFillTextBar(context, CGRectMake(CGRectGetMinX(details), lineY, textWidth, artistSize * 0.6), 0.45, 0, secondary);
        lineY += artistSize * 0.6 + 6.0;
        if (model.showAlbum) CLFillTextBar(context, CGRectMake(CGRectGetMinX(details), lineY, textWidth, albumSize * 0.6), 0.55, 0, secondary);
    } else {
        CLDrawText(@"Long Way Home", CGRectMake(CGRectGetMinX(details), lineY, textWidth, titleSize + 6.0),
                   [UIFont systemFontOfSize:titleSize weight:UIFontWeightSemibold], label, NSTextAlignmentLeft);
        lineY += titleSize + 6.0;
        CLDrawText(@"The Night Drivers", CGRectMake(CGRectGetMinX(details), lineY, textWidth, artistSize + 5.0),
                   [UIFont systemFontOfSize:artistSize weight:UIFontWeightRegular], secondary, NSTextAlignmentLeft);
        lineY += artistSize + 5.0;
        if (model.showAlbum) {
            CLDrawText(@"Open Roads", CGRectMake(CGRectGetMinX(details), lineY, textWidth, albumSize + 5.0),
                       [UIFont systemFontOfSize:albumSize weight:UIFontWeightRegular], secondary, NSTextAlignmentLeft);
        }
    }

    // Transport row: previous, play/pause, next, sized by the host's button height.
    UIColor *control = [UIColor colorWithWhite:1.0 alpha:0.9];
    CGFloat centerY = CGRectGetMidY(transportRow);
    CGFloat midX = CGRectGetMidX(transportRow);
    CGFloat unit = transport / CLLayoutHostTransportLarge;      // chevrons scale with the buttons
    CGFloat spacing = MIN(96.0 * unit, CGRectGetWidth(transportRow) / 3.2);
    CLFillCircle(context, CGPointMake(midX, centerY), transport / 2.0, control);
    if (_card) {
        // A circle and two dashes is all a card needs to read as "the player".
        for (CGFloat direction = -1.0; direction <= 1.0; direction += 2.0) {
            CGFloat x = midX + direction * spacing;
            CLFillRoundedRect(context, CGRectMake(x - 10.0 * unit, centerY - 3.0 * unit, 20.0 * unit, 6.0 * unit), 3.0 * unit, control);
        }
    } else {
        CGContextSetFillColorWithColor(context, [UIColor colorWithWhite:0.07 alpha:1.0].CGColor);
        CGContextMoveToPoint(context, midX - 6.0 * unit, centerY - 9.0 * unit);
        CGContextAddLineToPoint(context, midX + 9.0 * unit, centerY);
        CGContextAddLineToPoint(context, midX - 6.0 * unit, centerY + 9.0 * unit);
        CGContextClosePath(context);
        CGContextFillPath(context);
        for (CGFloat direction = -1.0; direction <= 1.0; direction += 2.0) {
            CGFloat x = midX + direction * spacing;
            for (NSInteger i = 0; i < 2; i++) {
                CGFloat tx = x + direction * ((CGFloat)i * 12.0 - 6.0) * unit;
                CGContextSetFillColorWithColor(context, control.CGColor);
                CGContextMoveToPoint(context, tx - direction * 7.0 * unit, centerY - 9.0 * unit);
                CGContextAddLineToPoint(context, tx + direction * 7.0 * unit, centerY);
                CGContextAddLineToPoint(context, tx - direction * 7.0 * unit, centerY + 9.0 * unit);
                CGContextClosePath(context);
                CGContextFillPath(context);
            }
        }
    }

    // Progress bar (show / hide) in the host's 10 pt slot, with the accent.
    if (model.progressBarStyle != 2) {
        CGFloat thickness = _card ? 4.0 : 6.0;
        CGRect track = CGRectMake(CGRectGetMinX(progress), CGRectGetMidY(progress) - thickness / 2.0,
                                  CGRectGetWidth(progress), thickness);
        CLFillRoundedRect(context, track, thickness / 2.0, [UIColor colorWithWhite:1.0 alpha:0.25]);
        CGRect elapsed = track;
        elapsed.size.width *= 0.38;
        CLFillRoundedRect(context, elapsed, thickness / 2.0, accent ?: [UIColor colorWithWhite:1.0 alpha:0.9]);
    }

    // Play-mode row: Spotify's four buttons and, with the Lyrics Button on, the microphone (as many
    // as the car shows, centred with the host's 16 pt gaps; dots at card size).
    NSMutableArray<NSString *> *symbols = [@[ @"plus.circle", @"shuffle", @"repeat", @"dot.radiowaves.left.and.right" ] mutableCopy];
    if (CLPreviewOffersFullScreen(model)) [symbols addObject:@"mic"];
    CGFloat buttonWidth = _card ? 20.0 : 40.0, gap = _card ? 8.0 : 16.0;
    CGFloat rowWidth = (CGFloat)symbols.count * buttonWidth + (CGFloat)(symbols.count - 1) * gap;
    CGFloat x = CGRectGetMidX(playMode) - rowWidth / 2.0;
    for (NSString *symbol in symbols) {
        CGRect slot = CGRectMake(x, CGRectGetMinY(playMode), buttonWidth, CGRectGetHeight(playMode));
        if (_card) CLFillCircle(context, CGPointMake(CGRectGetMidX(slot), CGRectGetMidY(slot)), 3.0, [UIColor colorWithWhite:1.0 alpha:0.6]);
        else CLDrawSymbol(symbol, slot, 15.0, UIImageSymbolWeightRegular, [UIColor colorWithWhite:1.0 alpha:0.85]);
        x += buttonWidth + gap;
    }
}

/// The full-screen lyrics view over `safe`, from the shared rects in UI/CLLayoutGeometry.h: the
/// lyrics, the progress line, and the row with title, previous / play-pause / next and the
/// microphone (selected).
- (void)cl_drawFullScreenIn:(CGContextRef)context safe:(CGRect)safe model:(CLLayoutPreviewModel *)model {
    [self cl_drawPanelIn:context rect:CLLayoutFullScreenLyricsRect(safe) fit:CLLayoutPanelFitRows model:model];

    UIColor *accent = [self cl_accentColorForModel:model];
    UIColor *secondary = [UIColor colorWithWhite:1.0 alpha:0.6];
    CGRect progress = CLLayoutFullScreenProgressRect(safe);
    if (model.progressBarStyle != 2) {
        CGFloat timeWidth = _card ? 0.0 : 40.0, timeGap = _card ? 0.0 : 8.0;
        if (!_card) {
            UIFont *font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightMedium];
            CLDrawText(@"1:12", CGRectMake(CGRectGetMinX(progress), CGRectGetMidY(progress) - 7.0, timeWidth, 14.0),
                       font, secondary, NSTextAlignmentLeft);
            CLDrawText(@"-2:05", CGRectMake(CGRectGetMaxX(progress) - timeWidth, CGRectGetMidY(progress) - 7.0, timeWidth, 14.0),
                       font, secondary, NSTextAlignmentRight);
        }
        CGFloat thickness = CLLayoutFullScreenProgressThickness;
        CGRect track = CGRectMake(CGRectGetMinX(progress) + timeWidth + timeGap, CGRectGetMidY(progress) - thickness / 2.0,
                                  CGRectGetWidth(progress) - 2.0 * (timeWidth + timeGap), thickness);
        CLFillRoundedRect(context, track, thickness / 2.0, [UIColor colorWithWhite:1.0 alpha:0.25]);
        CGRect fill = track;
        fill.size.width *= 0.37;
        CLFillRoundedRect(context, fill, thickness / 2.0, accent ?: [UIColor colorWithWhite:1.0 alpha:0.9]);
    }

    CGRect row = CLLayoutFullScreenRowRect(safe);
    UIColor *white = [UIColor colorWithWhite:1.0 alpha:0.95];
    // Right to left: the microphone pill, then next, play/pause, previous (the host's 36 pt row).
    CGFloat x = CGRectGetMaxX(row);
    CGRect mic = CGRectMake(x - 44.0, CGRectGetMidY(row) - 13.0, 44.0, 26.0);
    CLFillRoundedRect(context, mic, 8.0, [UIColor colorWithWhite:1.0 alpha:0.8]);
    if (!_card) CLDrawSymbol(@"mic", mic, 14.0, UIImageSymbolWeightRegular, [UIColor colorWithWhite:0.1 alpha:1.0]);
    x = CGRectGetMinX(mic) - 12.0;
    for (NSString *symbol in @[ @"forward.fill", @"pause.fill", @"backward.fill" ]) {
        CGRect slot = CGRectMake(x - 56.0, CGRectGetMinY(row), 56.0, CGRectGetHeight(row));
        if (_card) CLFillCircle(context, CGPointMake(CGRectGetMidX(slot), CGRectGetMidY(slot)), 5.0, white);
        else CLDrawSymbol(symbol, slot, 20.0, UIImageSymbolWeightSemibold, white);
        x -= 56.0 + 8.0;
    }
    // Title and artist on the left, where the screen leaves room for them.
    if (CGRectGetWidth(safe) >= CLLayoutFullScreenMinimumWidthForText) {
        CGFloat textWidth = MAX(0.0, x - CGRectGetMinX(row) - 4.0);
        if (_card) {
            CLFillTextBar(context, CGRectMake(CGRectGetMinX(row), CGRectGetMidY(row) - 9.0, textWidth, 7.0), 0.8, 0, white);
            CLFillTextBar(context, CGRectMake(CGRectGetMinX(row), CGRectGetMidY(row) + 3.0, textWidth, 6.0), 0.55, 0, accent ?: secondary);
        } else {
            CLDrawText(@"Long Way Home", CGRectMake(CGRectGetMinX(row), CGRectGetMidY(row) - 18.0, textWidth, 20.0),
                       [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold], white, NSTextAlignmentLeft);
            CLDrawText(@"The Night Drivers", CGRectMake(CGRectGetMinX(row), CGRectGetMidY(row) + 1.0, textWidth, 17.0),
                       [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular], accent ?: secondary, NSTextAlignmentLeft);
        }
    }
}

- (UIColor *)cl_accentColorForModel:(CLLayoutPreviewModel *)model {
    if (model.tintFromArtwork) return CLPreviewArtworkAccent();
    if (model.accentColorHex.length == 0) return nil;
    UIColor *sentinel = UIColor.clearColor;
    UIColor *color = [CLPrefsColor colorWithHex:model.accentColorHex fallback:sentinel];
    return (color == sentinel) ? nil : color;
}

- (void)cl_drawCoverIn:(CGContextRef)context rect:(CGRect)rect cornerRadius:(CGFloat)radius {
    if (CGRectIsEmpty(rect)) return;
    CGContextSaveGState(context);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:MIN(radius, CGRectGetWidth(rect) / 2.0)];
    CGContextAddPath(context, path.CGPath);
    CGContextClip(context);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = @[ (id)CLPreviewCoverColorA().CGColor, (id)CLPreviewCoverColorB().CGColor ];
    CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
    if (gradient) {
        CGContextDrawLinearGradient(context, gradient, CGPointMake(CGRectGetMinX(rect), CGRectGetMinY(rect)),
                                    CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect)), 0);
        CGGradientRelease(gradient);
    }
    CGColorSpaceRelease(space);
    // A sun and a road: enough to read as "a cover".
    CLFillCircle(context, CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect) + CGRectGetHeight(rect) * 0.4),
                 CGRectGetWidth(rect) * 0.16, [UIColor colorWithRed:1.0 green:0.85 blue:0.5 alpha:0.9]);
    CGContextSetFillColorWithColor(context, [UIColor colorWithWhite:0.0 alpha:0.35].CGColor);
    CGContextMoveToPoint(context, CGRectGetMidX(rect) - CGRectGetWidth(rect) * 0.06, CGRectGetMinY(rect) + CGRectGetHeight(rect) * 0.55);
    CGContextAddLineToPoint(context, CGRectGetMidX(rect) + CGRectGetWidth(rect) * 0.06, CGRectGetMinY(rect) + CGRectGetHeight(rect) * 0.55);
    CGContextAddLineToPoint(context, CGRectGetMaxX(rect), CGRectGetMaxY(rect));
    CGContextAddLineToPoint(context, CGRectGetMinX(rect), CGRectGetMaxY(rect));
    CGContextClosePath(context);
    CGContextFillPath(context);
    CGContextRestoreGState(context);
}

- (UIColor *)cl_currentLineColor:(CLLayoutPreviewModel *)model {
    return [CLPrefsColor colorWithHex:model.lyricsCurrentColorHex fallback:UIColor.whiteColor];
}

- (UIColor *)cl_nextLineColor:(CLLayoutPreviewModel *)model {
    UIColor *base = [CLPrefsColor colorWithHex:model.lyricsNextColorHex fallback:UIColor.whiteColor];
    return [base colorWithAlphaComponent:model.lyricsNextAlpha];
}

- (void)cl_drawLyricsBackgroundIn:(CGContextRef)context rect:(CGRect)rect model:(CLLayoutPreviewModel *)model {
    if (model.lyricsBackground == 0) return;
    UIColor *fill = [[CLPrefsColor colorWithHex:model.lyricsBackgroundColorHex fallback:UIColor.blackColor]
                     colorWithAlphaComponent:model.lyricsBackgroundAlpha];
    CGFloat radius = (model.lyricsBackground == 1) ? MIN(18.0, CGRectGetHeight(rect) / 2.0) : 4.0;
    CLFillRoundedRect(context, rect, radius, fill);
}

/// The scrolling panel: one font for every row, sized to the panel like CLLyricsPanelView does
/// under `fit`, the current line centred and at full colour. Cards draw a few bars instead.
- (void)cl_drawPanelIn:(CGContextRef)context rect:(CGRect)rect fit:(CLLayoutPanelFit)fit model:(CLLayoutPreviewModel *)model {
    if (CGRectGetHeight(rect) < 8.0 || CGRectGetWidth(rect) < 8.0) return;
    [self cl_drawLyricsBackgroundIn:context rect:rect model:model];
    CGFloat inset = CLLayoutPanelTextInset;      // the panel's own label padding

    CGContextSaveGState(context);
    CGContextClipToRect(context, rect);
    if (_card) {
        // Two bars (bright, dim) on a wide panel, three (dim, bright, dim) on a squarer one.
        NSInteger rows = (CGRectGetWidth(rect) >= 2.0 * CGRectGetHeight(rect)) ? 2 : 3;
        NSInteger currentRow = (rows == 2) ? 0 : 1;
        CGFloat pitch = CGRectGetHeight(rect) / ((CGFloat)rows + 0.6);
        CGFloat barHeight = MAX(2.0, pitch * 0.42);
        CGFloat top = CGRectGetMidY(rect) - ((CGFloat)rows * pitch) / 2.0;
        for (NSInteger i = 0; i < rows; i++) {
            BOOL current = (i == currentRow);
            CGRect row = CGRectMake(CGRectGetMinX(rect) + inset, top + (CGFloat)i * pitch + (pitch - barHeight) / 2.0,
                                    CGRectGetWidth(rect) - 2.0 * inset, barHeight);
            CLFillTextBar(context, row, current ? 0.85 : 0.6, model.lyricsAlignment,
                          current ? [self cl_currentLineColor:model] : [self cl_nextLineColor:model]);
        }
        CGContextRestoreGState(context);
        return;
    }

    // The very same rule CLLyricsPanelView sizes its rows by in the car.
    CGFloat size = CLLayoutPanelFontSize(rect.size, fit, model.lyricsFontSize);
    CGFloat rowHeight = ceil(size * 1.2) + 8.0;
    NSArray<NSString *> *texts = CLPreviewLines();
    CGFloat centerY = CGRectGetMidY(rect);
    NSInteger visible = (NSInteger)ceil(CGRectGetHeight(rect) / rowHeight / 2.0) + 1;
    for (NSInteger offset = -visible; offset <= visible; offset++) {
        NSInteger index = CLPreviewCurrentLine + offset;
        if (index < 0 || index >= (NSInteger)texts.count) continue;
        CGFloat y = centerY + (CGFloat)offset * rowHeight - rowHeight / 2.0;
        CGRect row = CGRectMake(CGRectGetMinX(rect) + inset, y + 4.0, CGRectGetWidth(rect) - 2.0 * inset, rowHeight - 8.0);
        BOOL current = (offset == 0);
        UIColor *color = current ? [self cl_currentLineColor:model] : [self cl_nextLineColor:model];
        CLDrawText(texts[(NSUInteger)index], row, [UIFont systemFontOfSize:size weight:CLFontWeight(model.lyricsFontWeight)],
                   color, CLTextAlignment(model.lyricsAlignment));
    }
    CGContextRestoreGState(context);
}

@end
