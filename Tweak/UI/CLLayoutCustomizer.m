#import "UI/CLLayoutCustomizer.h"
#import "UI/CLLayoutGeometry.h"
#import "UI/CLLyricsFullScreenView.h"
#import "UI/CLLyricsPanelView.h"
#import "UI/CLLyricsStyle.h"
#import "Core/CLLyricsController.h"
#import "Util/CLColor.h"
#import "Util/CLLog.h"
#import "Util/CLPrefs.h"
#import "Util/CLRuntime.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void *const CLLayoutCustomizerAssociationKey = (void *)&CLLayoutCustomizerAssociationKey;

#pragma mark - Small helpers

static UIView *CLViewOrNil(id object) {
    return [object isKindOfClass:UIView.class] ? (UIView *)object : nil;
}

static UIBarButtonItem *CLBarItemOrNil(id object) {
    return [object isKindOfClass:UIBarButtonItem.class] ? (UIBarButtonItem *)object : nil;
}

/// Auto Layout raises when a constraint's two items have no common ancestor, so every cross-view
/// constraint we build is checked with this first.
static UIView *CLNearestCommonAncestor(UIView *a, UIView *b) {
    for (UIView *x = a; x != nil; x = x.superview) {
        for (UIView *y = b; y != nil; y = y.superview) {
            if (x == y) return x;
        }
    }
    return nil;
}

/// Depth-first (pre-order) collection of the views of a class inside a view, capped so a deep
/// hierarchy cannot turn into a long walk during a layout pass.
static void CLCollectViewsOfClass(UIView *root, Class wanted, NSMutableArray *out, NSUInteger limit) {
    if (!root || !wanted || out.count >= limit) return;
    for (UIView *subview in root.subviews) {
        if ([subview isKindOfClass:wanted]) {
            [out addObject:subview];
            if (out.count >= limit) return;
        }
        CLCollectViewsOfClass(subview, wanted, out, limit);
        if (out.count >= limit) return;
    }
}

static NSArray<UILabel *> *CLLabelsIn(UIView *root, NSUInteger limit) {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    CLCollectViewsOfClass(root, UILabel.class, labels, limit);
    return labels;
}

/// Average colour of an image, sampled from an 8x8 downscale, pushed towards something readable
/// on a dark screen. Returns nil when the image cannot be rasterised.
static UIColor *CLAverageArtworkColor(UIImage *image) {
    if (!image) return nil;
    CGImageRef source = image.CGImage;
    UIImage *rendered = nil;
    if (!source) {
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.scale = 1.0;
        format.opaque = YES;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(8.0, 8.0)
                                                                                   format:format];
        rendered = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [image drawInRect:CGRectMake(0.0, 0.0, 8.0, 8.0)];
        }];
        source = rendered.CGImage;
    }
    if (!source) return nil;

    enum { side = 8 };   // compile-time constant so pixels[] is a true fixed-size array, not a VLA
    uint8_t pixels[side * side * 4];
    memset(pixels, 0, sizeof(pixels));

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    if (!space) return nil;
    CGContextRef context = CGBitmapContextCreate(pixels, side, side, 8, side * 4, space,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) return nil;
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0.0, 0.0, (CGFloat)side, (CGFloat)side), source);
    CGContextRelease(context);

    double totalR = 0.0, totalG = 0.0, totalB = 0.0, totalWeight = 0.0;
    for (size_t i = 0; i < side * side; i++) {
        double a = pixels[i * 4 + 3] / 255.0;
        if (a < 0.1) continue;
        double r = pixels[i * 4 + 0] / 255.0;
        double g = pixels[i * 4 + 1] / 255.0;
        double b = pixels[i * 4 + 2] / 255.0;
        double maximum = MAX(r, MAX(g, b));
        double minimum = MIN(r, MIN(g, b));
        // Weight colourful pixels higher so a mostly-black cover with a bright logo still tints.
        double weight = a * (0.25 + (maximum - minimum));
        totalR += r * weight;
        totalG += g * weight;
        totalB += b * weight;
        totalWeight += weight;
    }
    if (totalWeight <= 0.0) return nil;

    UIColor *average = [UIColor colorWithRed:(CGFloat)(totalR / totalWeight)
                                       green:(CGFloat)(totalG / totalWeight)
                                        blue:(CGFloat)(totalB / totalWeight)
                                       alpha:1.0];
    CGFloat hue = 0.0, saturation = 0.0, brightness = 0.0, alpha = 1.0;
    if (![average getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha]) return average;
    saturation = MIN((CGFloat)1.0, saturation * (CGFloat)1.25);
    brightness = MAX((CGFloat)0.55, MIN((CGFloat)0.95, brightness * (CGFloat)1.2));
    return [UIColor colorWithHue:hue saturation:saturation brightness:brightness alpha:1.0];
}

/// +[CLColor colorWithHex:fallback:] needs a non-nil fallback and returns it unchanged when the
/// string is unusable, so a sentinel turns it into "nil when the preference is empty/invalid".
static UIColor *CLColorFromHexOrNil(NSString *hex) {
    if (hex.length == 0) return nil;
    UIColor *sentinel = UIColor.clearColor;
    UIColor *color = [CLColor colorWithHex:hex fallback:sentinel];
    return (color == sentinel) ? nil : color;
}

static BOOL CLStringsEqualOrNil(NSString *a, NSString *b) {
    if (a.length == 0 && b.length == 0) return YES;
    return [a isEqualToString:b];
}

static NSString *CLStringOrNil(id object) {
    return [object isKindOfClass:NSString.class] ? (NSString *)object : nil;
}

/// The app a Now Playing screen belongs to: the controller's `_bundleIdentifier`, which
/// CarPlayTemplateUIHost sets. Apple Music's CarPlay screen runs in the Music app itself (0.8.0),
/// so there an empty ivar still means Apple Music.
static NSString *CLScreenBundleIdentifier(UIViewController *viewController) {
    NSString *identifier = CLStringOrNil(CLIvar(viewController, @"_bundleIdentifier"));
    if (identifier.length) return identifier;
    NSString *process = [NSBundle mainBundle].bundleIdentifier;
    return [process isEqualToString:@"com.apple.Music"] ? process : nil;
}

/// A boxed number out of a zero-argument getter on a private object, read through KVC (which boxes
/// the `d` and `Q` returns the layout getters use), or nil when the object lacks the getter or the
/// value is not a number. Debug logging only.
static NSNumber *CLNumberForGetter(id object, NSString *getter) {
    if (!CLResponds(object, getter)) return nil;
    id value = CLValueForKey(object, getter);
    return [value isKindOfClass:NSNumber.class] ? (NSNumber *)value : nil;
}

/// Debug only: every visible, small view drawn at `point` (window coordinates) and every view whose
/// class name mentions focus, rotary, arrow or indicator, with its window frame and two superviews.
/// One drive with this names whatever draws at the lyrics panel's trailing edge (the cyan "X").
static void CLLogViewsAtPoint(UIWindow *window, CGPoint point) {
    if (!window) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    NSUInteger visits = 0;
    while (stack.count > 0 && visits < 4000) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        visits++;
        if (view.isHidden || view.alpha < 0.01) continue;     // nothing under it is drawn either
        NSString *name = NSStringFromClass(view.class) ?: @"?";
        CGRect frame = [view convertRect:view.bounds toView:window];
        BOOL named = NO;
        for (NSString *word in @[ @"Focus", @"Rotary", @"Arrow", @"Indicator", @"Chevron" ]) {
            if ([name rangeOfString:word].location != NSNotFound) named = YES;
        }
        BOOL hit = CGRectContainsPoint(CGRectInset(frame, -6.0, -6.0), point) &&
                   CGRectGetWidth(frame) < 120.0 && CGRectGetHeight(frame) < 120.0;
        if (named || hit) {
            CLLogDebug(@"[ui] edge probe: %@%@ %@ in %@ < %@", hit ? @"AT POINT " : @"", name, NSStringFromCGRect(frame),
                       NSStringFromClass(view.superview.class) ?: @"-",
                       NSStringFromClass(view.superview.superview.class) ?: @"-");
        }
        for (UIView *subview in view.subviews) [stack addObject:subview];
    }
}

/// "Looking for lyrics…" / "No lyrics for this song" for a controller status, nil otherwise.
static NSString *CLLyricsStatusText(CLLyricsControllerStatus status) {
    if (status == CLLyricsControllerStatusLoading) return @"Looking for lyrics…";
    if (status == CLLyricsControllerStatusUnavailable) return @"No lyrics for this song";
    return nil;
}

/// The full-screen view's line when its panel shows nothing: why, or nil when nothing is playing.
static NSString *CLFullScreenStatusText(CLLyricsControllerStatus status, CLLyrics *lyrics) {
    NSString *text = CLLyricsStatusText(status);
    if (text) return text;
    if (status != CLLyricsControllerStatusLoaded) return nil;
    if (lyrics.kind == CLLyricsKindInstrumental) return @"Instrumental";
    return @"No synced lyrics for this song";      // plain text the user chose not to show
}

#pragma mark - Host layout override

/// CarPlayUI's CPUINowPlayingLayoutSideArtworkMinAspectRatio (1.35 on iOS 17.3): a safe area at
/// least this much wider than tall gets the artwork beside the controls, anything narrower gets
/// the stacked layout. Read from the host so a different iOS build keeps its own threshold.
static CGFloat CLSideArtworkMinAspectRatio(void) {
    static CGFloat ratio = 0.0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const double *symbol = (const double *)dlsym(RTLD_DEFAULT, "CPUINowPlayingLayoutSideArtworkMinAspectRatio");
        double value = symbol ? *symbol : 0.0;
        ratio = (isfinite(value) && value > 0.5 && value < 5.0) ? (CGFloat)value : CLLayoutDefaultSideArtworkRatio;
    });
    return ratio;
}

/// What a screen asks of the host's own layout. It lives on the Now Playing view itself, as an
/// associated object, so the view hook can read it without finding its controller and it
/// vanishes with the view. Immutable: the controller hook replaces it before every host pass.
@interface CLHostLayoutOverride : NSObject
/// Which part of the screen the host lays its Now Playing view out for: a side-by-side player
/// column at the leading edge, or the full panel's bottom strip.
@property (nonatomic, readonly) CLLayoutPlayerArea playerArea;
@property (nonatomic, readonly) CGRect viewArea;
@property (nonatomic, readonly) CGRect safeArea;
/// The host is handed allowsAlbumArt:NO, so its chooser returns the stacked layout without
/// artwork and hides the artwork square itself (verified: -recalculateLayout:… does
/// `_artworkViewBrick.hidden = !layout.showsArtwork`).
@property (nonatomic, readonly) BOOL hidesArtwork;
/// The column sits at the trailing edge (Lyrics Side: Left). The view hook then reports left-hand
/// drive, so a side layout puts the art on the right: at the outer edge, like the leading column's.
@property (nonatomic, readonly) BOOL onTrailingEdge;
@property (nonatomic, readonly) BOOL hasPlayerArea;
@end

@implementation CLHostLayoutOverride
- (instancetype)initWithPlayerArea:(CLLayoutPlayerArea)playerArea viewArea:(CGRect)viewArea
                          safeArea:(CGRect)safeArea hidesArtwork:(BOOL)hidesArtwork onTrailingEdge:(BOOL)onTrailingEdge {
    self = [super init];
    if (self) {
        _playerArea = playerArea;
        _viewArea = viewArea;
        _safeArea = safeArea;
        _hidesArtwork = hidesArtwork;
        _onTrailingEdge = onTrailingEdge;
    }
    return self;
}
- (BOOL)hasPlayerArea {
    return _playerArea != CLLayoutPlayerAreaNone;
}
@end

static const void *kCLHostLayoutOverrideKey = &kCLHostLayoutOverrideKey;

static CLHostLayoutOverride *CLHostLayoutOverrideFor(UIView *nowPlayingView) {
    if (!nowPlayingView) return nil;
    id value = objc_getAssociatedObject(nowPlayingView, kCLHostLayoutOverrideKey);
    return [value isKindOfClass:CLHostLayoutOverride.class] ? (CLHostLayoutOverride *)value : nil;
}

static void CLSetHostLayoutOverride(UIView *nowPlayingView, CLHostLayoutOverride *override) {
    if (!nowPlayingView) return;
    objc_setAssociatedObject(nowPlayingView, kCLHostLayoutOverrideKey, override, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

BOOL CLPlayerColumnRects(UIView *nowPlayingView, CGRect *viewArea, CGRect *safeArea) {
    CLHostLayoutOverride *override = CLHostLayoutOverrideFor(nowPlayingView);
    if (!override.hasPlayerArea) return NO;
    if (viewArea) *viewArea = override.viewArea;
    if (safeArea) *safeArea = override.safeArea;
    return YES;
}

BOOL CLHostLayoutHidesArtwork(UIView *nowPlayingView) {
    return CLHostLayoutOverrideFor(nowPlayingView).hidesArtwork;
}

BOOL CLHostLayoutArtworkOnLeft(UIView *nowPlayingView) {
    return !CLHostLayoutOverrideFor(nowPlayingView).onTrailingEdge;
}

/// How many vertical spacer guides the host built for its current layout (debug logging only).
static NSUInteger CLHostSpacerGuideCount(UIView *nowPlayingView) {
    id value = CLIvar(nowPlayingView, @"_verticalSpacerLayoutGuides");
    return [value isKindOfClass:NSArray.class] ? [(NSArray *)value count] : 0;
}

static BOOL sHostColumnHooksInstalled = NO;

#pragma mark -

@interface CLLayoutCustomizer () <CLLyricsPanelViewDelegate, CLLyricsFullScreenViewDelegate>
@end

@implementation CLLayoutCustomizer {
    // Resolved host views (weak: the host owns them and may replace them at any time).
    __weak UIView *_nowPlayingView;
    __weak UIView *_songDetailsView;
    __weak UIView *_progressView;
    __weak UIView *_transportControlView;
    /// The artwork square inside the Now Playing view (CPUINowPlayingView._artworkViewBrick, a
    /// CPUIShadowImageView). This is what the artwork corner radius acts on.
    __weak UIView *_artworkBrick;
    /// The host's full-bleed backdrop: CPUINowPlayingViewController._artworkView (a UIImageView the
    /// controller pins across its whole view, below the Now Playing view) and the blur effect view
    /// it puts over it (_artworkVisualEffectView). Verified in -viewDidLoad; see docs/research.
    __weak UIView *_backgroundArtworkView;
    __weak UIView *_backgroundEffectView;
    __weak UIBarButtonItem *_queueBarItem;
    __weak UIBarButtonItem *_rateBarItem;

    // Our views.
    CLLyricsPanelView *_panelView;
    /// Modes 4 and 5 only: "Looking for lyrics…" / "No lyrics for this song" where the panel would be.
    UILabel *_columnStatusLabel;
    /// The size constraints we gave the host's Now Playing view (effective 4 and 5). The host
    /// holds the same array in _nowPlayingSizeConstraints and deactivates it on its next recalculation.
    NSArray<NSLayoutConstraint *> *_playerAreaSizeConstraints;
    BOOL _loggedPlayerArea;
    /// The last -cl_screenMatchesNowPlaying answer the layout was built for; a change re-lays out.
    BOOL _screenMatchedNowPlaying;
    NSArray<NSLayoutConstraint *> *_placementConstraints;
    NSString *_placementSignature;
    /// The last host layout logged by +hostDidRecalculateLayoutForViewController: (debug only).
    NSString *_hostLayoutSignature;

    // Saved host state, for -detach.
    BOOL _artworkStateSaved;
    CGFloat _savedArtworkCornerRadius;
    BOOL _savedArtworkMasksToBounds;
    BOOL _backgroundStateSaved;
    BOOL _savedBackgroundHidden;
    CGFloat _savedBackgroundAlpha;
    BOOL _savedBackgroundEffectHidden;
    BOOL _hidingProgress;   // Progress Bar Hide is holding the host's bar hidden
    BOOL _tintStateSaved;
    UIColor *_savedProgressTintColor;
    UIColor *_savedNowPlayingTintColor;
    NSMapTable<UILabel *, UIColor *> *_savedLabelColors;
    __weak UILabel *_hiddenAlbumLabel;
    BOOL _savedAlbumLabelHidden;
    NSMutableArray<UIBarButtonItem *> *_hiddenBarItems;
    /// The host's right bar items in their original order, including the ones we took out. Restoring
    /// from stored indexes instead loses the order once two items are hidden one after the other.
    NSArray<UIBarButtonItem *> *_canonicalBarItems;

    // Cached preferences.
    BOOL _prefEnabled;
    NSInteger _lyricsMode;
    /// What this screen actually shows (-cl_updateEffectiveMode, UI/CLLayoutGeometry.h): 0 off,
    /// 4 side by side, 5 full panel ("No Artwork"). Everything below the prefs keys off this one.
    NSInteger _effectiveMode;
    double _artworkCornerRadius;
    NSInteger _backdropStyle;
    double _backdropOpacity;
    BOOL _tintFromArtwork;
    NSString *_accentColorHex;
    BOOL _showAlbum;
    NSInteger _progressBarStyle;
    BOOL _hidePlaybackRateButton;
    BOOL _hideQueueButton;
    BOOL _showLyricsButton;
    NSInteger _lyricsSide;

    // Bookkeeping.
    id _controllerToken;
    /// YES while this customizer is counted in CLLyricsController's active-display count. Exists
    /// only to keep those calls balanced (see -cl_setDisplayActive:).
    BOOL _countedAsActiveDisplay;
    UIImage *_accentSourceImage;
    UIColor *_accentColorCache;
    BOOL _applying;
    BOOL _paused;

    // Per-pass memoisation. The apply chain used to walk the song-details hierarchy three times
    // and ask for the artwork image twice in a single layout pass; these hold the answer for the
    // duration of one pass and are dropped again at the end of it, so nothing can go stale
    // between passes.
    BOOL _passCacheActive;
    NSArray<UILabel *> *_passLabels;
    UIImage *_passArtworkImage;
    BOOL _passArtworkResolved;
    BOOL _loggedLabelProbe;
    BOOL _loggedBarItemProbe;
    BOOL _loggedAnchorFallback;
    BOOL _loggedPlacementFailure;
    BOOL _scheduledEdgeProbe;

    // Full-screen lyrics (0.7.0): our microphone in the host's play-mode row opens them.
    UIButton *_micButton;
    /// The stack and play-mode view the microphone was added to (the host owns both).
    __weak UIStackView *_micStack;
    __weak UIView *_micPlayModeView;
    BOOL _fullScreen;
    CLLyricsFullScreenView *_fullScreenView;
    NSArray<NSLayoutConstraint *> *_fullScreenConstraints;
    /// YES while *we* hid the host's Now Playing view under the full-screen lyrics.
    BOOL _nowPlayingHiddenByUs;
    BOOL _savedNowPlayingHidden;
    /// The microphone glyph, rendered at the height of the host's play-mode icons.
    UIImage *_micImage;
    CGFloat _micImageHeight;
    /// The transport button held down on the full-screen view right now (-1: none). The host got
    /// its touch-down; it must get the touch-up too, even if the view goes away mid-press.
    NSInteger _pressedCommand;
    /// YES while *we* hid the host's playback-speed button in the play-mode row.
    BOOL _rateButtonHiddenByUs;
    /// YES while we ask the host to re-run its own play-mode rule (undoing our hide): the hook's
    /// callback from that run must not hide the button again.
    BOOL _recomputingPlayModes;
}

#pragma mark - Association

+ (instancetype)customizerForViewController:(UIViewController *)viewController create:(BOOL)create {
    if (![viewController isKindOfClass:UIViewController.class]) return nil;
    if (!NSThread.isMainThread) {
        CLLogError(@"[ui] customizerForViewController: called off the main thread; ignoring");
        return nil;
    }
    CLLayoutCustomizer *existing = objc_getAssociatedObject(viewController, CLLayoutCustomizerAssociationKey);
    if ([existing isKindOfClass:CLLayoutCustomizer.class]) return existing;
    if (!create) return nil;

    CLLayoutCustomizer *customizer = [[CLLayoutCustomizer alloc] init];
    if (!customizer) return nil;
    objc_setAssociatedObject(viewController, CLLayoutCustomizerAssociationKey, customizer,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [customizer attachToViewController:viewController];
    return customizer;
}

+ (void)detachFromViewController:(UIViewController *)viewController {
    if (![viewController isKindOfClass:UIViewController.class]) return;
    CLLayoutCustomizer *existing = objc_getAssociatedObject(viewController, CLLayoutCustomizerAssociationKey);
    if ([existing isKindOfClass:CLLayoutCustomizer.class]) [existing detach];
    objc_setAssociatedObject(viewController, CLLayoutCustomizerAssociationKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Lifecycle

- (instancetype)init {
    self = [super init];
    if (self) {
        _savedLabelColors = [NSMapTable weakToStrongObjectsMapTable];
        _hiddenBarItems = [NSMutableArray array];
        _screenMatchedNowPlaying = YES;
        _pressedCommand = -1;
        [self cl_readPrefs];
    }
    return self;
}

- (void)dealloc {
    // The view controller may already be mid-dealloc here (associated objects are released before
    // weak references are cleared), so nothing in this method may message it or its views.
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_controllerToken) [CLLyricsController.sharedController removeObserver:_controllerToken];
    _controllerToken = nil;
    // Give the display count back even if -detach never ran (the host released the controller
    // without a viewWillDisappear:). Messaging the shared controller is safe here; messaging the
    // view controller or its views is not.
    if (_countedAsActiveDisplay) {
        _countedAsActiveDisplay = NO;
        [CLLyricsController.sharedController displayDidResignActive];
    }
}

- (void)attachToViewController:(UIViewController *)viewController {
    CLUIRunOnMain(^{
        CLUISafePerform(@"attachToViewController:", ^{ [self cl_attachOnMain:viewController]; });
    });
}

- (void)cl_attachOnMain:(UIViewController *)viewController {
    if (![viewController isKindOfClass:UIViewController.class]) return;
    if (_attached && _viewController == viewController) {
        [self applyPrefs];
        return;
    }
    if (_attached) [self cl_detachOnMain];
    _viewController = viewController;
    _attached = YES;
    [self cl_subscribe];
    [self cl_setDisplayActive:!_paused];
    CLLogDebug(@"[ui] attached to %@", NSStringFromClass(viewController.class));
    [self applyPrefs];
}

- (void)detach {
    CLUIRunOnMain(^{
        CLUISafePerform(@"detach", ^{ [self cl_detachOnMain]; });
    });
}

- (BOOL)isPaused {
    return _paused;
}

- (void)setPaused:(BOOL)paused {
    CLUIRunOnMain(^{
        CLUISafePerform(@"setPaused:", ^{ [self cl_setPausedOnMain:paused]; });
    });
}

/// Balanced bookkeeping for CLLyricsController's active-display count, which decides whether the
/// sync engine ticks at 10 Hz or at 1 Hz. One BOOL, so attach/pause/resume/detach/dealloc can be
/// called in any order and any number of times and still hand back exactly what they took: two
/// customizers briefly overlap whenever the host swaps its Now Playing view controller, and an
/// unbalanced call there would leave the engine slow (or awake) for the rest of the drive.
- (void)cl_setDisplayActive:(BOOL)active {
    if (_countedAsActiveDisplay == active) return;
    _countedAsActiveDisplay = active;
    if (active) [CLLyricsController.sharedController displayDidBecomeActive];
    else [CLLyricsController.sharedController displayDidResignActive];
}

- (void)cl_setPausedOnMain:(BOOL)paused {
    if (_paused == paused) return;
    _paused = paused;
    if (paused) {
        // Nothing reads the line index behind an offscreen screen, so stop asking the engine to
        // produce one ten times a second on the host's main thread.
        [self cl_setDisplayActive:NO];
        CLLogDebug(@"[ui] paused (Now Playing screen offscreen)");
        return;
    }
    CLLogDebug(@"[ui] resumed");
    if (!_attached) return;
    [self cl_setDisplayActive:YES];
    [self cl_updateEffectiveMode];
    [self cl_requestHostColumnPassIfStale];      // playback may have changed apps while offscreen
    // Whatever moved while we were not watching: re-place everything, then show the line the
    // sync engine is on now. animated:NO — this is a jump, not a transition.
    _placementSignature = nil;
    [self cl_relayoutOnMain];
    CLLyricsController *controller = CLLyricsController.sharedController;
    [self cl_pushLyrics:controller.currentLyrics
              lineIndex:controller.currentLineIndex
               animated:NO];
}

- (void)cl_detachOnMain {
    if (!_attached) return;
    [self cl_setDisplayActive:NO];
    [self cl_unsubscribe];
    [self cl_restoreHostChanges];
    [self cl_destroyLyricsViews];
    [self cl_teardownColumn];
    _accentSourceImage = nil;
    _accentColorCache = nil;
    _attached = NO;
    _viewController = nil;
    _nowPlayingView = nil;
    _songDetailsView = nil;
    _progressView = nil;
    _transportControlView = nil;
    _artworkBrick = nil;
    _backgroundArtworkView = nil;
    _backgroundEffectView = nil;
    _queueBarItem = nil;
    _rateBarItem = nil;
    CLLogDebug(@"[ui] detached");
}

- (void)cl_subscribe {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center removeObserver:self];
    [center addObserver:self selector:@selector(cl_prefsChanged:) name:CLPrefsDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(cl_prefsChanged:) name:CLPrefsResetNotification object:nil];

    if (!_controllerToken) {
        __weak typeof(self) weakSelf = self;
        _controllerToken = [CLLyricsController.sharedController addObserver:^(CLLyricsController *controller,
                                                                             CLLyricsControllerChange change) {
            [weakSelf cl_controllerDidChange:change controller:controller];
        }];
    }
}

- (void)cl_unsubscribe {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_controllerToken) {
        [CLLyricsController.sharedController removeObserver:_controllerToken];
        _controllerToken = nil;
    }
}

/// NSNotificationCenter calls this straight out of CLPrefs' own dispatch_async block, with no
/// exception handler anywhere above it — see CLUISafePerform.
- (void)cl_prefsChanged:(NSNotification *)notification {
    CLUISafePerform(@"prefs changed", ^{ [self applyPrefs]; });
}

#pragma mark - Preferences

- (void)cl_readPrefs {
    CLPrefs *prefs = CLPrefs.shared;
    _prefEnabled = prefs.enabled;
    // CLPrefs already normalises both; done again here so a stale snapshot can never hand the
    // layout code a mode or a style it has no branch for.
    _lyricsMode = CLLayoutModeNormalize(prefs.lyricsMode);
    _effectiveMode = CLLayoutPlanMake(_lyricsMode, CGRectZero, CLLayoutDefaultSideArtworkRatio, NO).effectiveMode;
    _artworkCornerRadius = MAX(0.0, MIN(200.0, prefs.artworkCornerRadius));
    _backdropStyle = MAX((NSInteger)0, MIN((NSInteger)1, prefs.backdropStyle));
    _backdropOpacity = MAX(0.0, MIN(1.0, prefs.backdropOpacity));
    _tintFromArtwork = prefs.tintFromArtwork;
    _accentColorHex = [(prefs.accentColorHex ?: @"") copy];
    _showAlbum = prefs.showAlbum;
    NSInteger progressStyle = MAX((NSInteger)0, MIN((NSInteger)2, prefs.progressBarStyle));
    _progressBarStyle = (progressStyle == 1) ? 0 : progressStyle;   // 1 was the thin bar (0.5.0)
    _hidePlaybackRateButton = prefs.hidePlaybackRateButton;
    _hideQueueButton = prefs.hideQueueButton;
    _showLyricsButton = prefs.showLyricsButton;
    _lyricsSide = MAX((NSInteger)0, MIN((NSInteger)1, prefs.lyricsSide));
}

- (void)applyPrefs {
    CLUIRunOnMain(^{
        CLUISafePerform(@"applyPrefs", ^{ [self cl_applyPrefsOnMain]; });
    });
}

- (void)cl_applyPrefsOnMain {
    if (!_attached) return;
    [self cl_readPrefs];
    [self cl_updateEffectiveMode];
    [self cl_requestHostColumnPassIfStale];
    [self cl_syncLyricsViews];
    [_panelView applyPrefs];
    [_fullScreenView applyPrefs];
    _placementSignature = nil;                  // the mode may have moved things
    [self relayout];
    CLLyricsController *controller = CLLyricsController.sharedController;
    [self cl_pushLyrics:controller.currentLyrics
              lineIndex:controller.currentLineIndex
               animated:NO];
}

#pragma mark - Per-pass cache

- (void)cl_beginPassCache {
    _passCacheActive = YES;
    _passLabels = nil;
    _passArtworkImage = nil;
    _passArtworkResolved = NO;
}

- (void)cl_endPassCache {
    _passCacheActive = NO;
    _passLabels = nil;
    _passArtworkImage = nil;
    _passArtworkResolved = NO;
}

/// The song-details labels, walked at most once per layout pass. Pre-order depth first, so the
/// title stays at index 0, the artist at 1 and (the hypothesis) the album at 2.
- (NSArray<UILabel *> *)cl_songDetailsLabels {
    if (_passCacheActive && _passLabels) return _passLabels;
    NSArray<UILabel *> *labels = CLLabelsIn(_songDetailsView, 8);
    if (_passCacheActive) _passLabels = labels;
    return labels;
}

/// The artwork image, resolved at most once per layout pass (the backdrop and the accent colour
/// both want it, and resolving it can end in a subview walk).
- (UIImage *)cl_passArtworkImage {
    if (_passCacheActive && _passArtworkResolved) return _passArtworkImage;
    UIImage *image = [self cl_currentArtworkImage];
    if (_passCacheActive) {
        _passArtworkImage = image;
        _passArtworkResolved = YES;
    }
    return image;
}

#pragma mark - Host view resolution

- (void)cl_resolveAnchors {
    UIViewController *viewController = _viewController;
    UIView *root = viewController.viewIfLoaded;
    UIView *previousDetails = _songDetailsView;
    if (!root) return;

    UIView *nowPlayingView = CLViewOrNil(CLIvar(viewController, @"_nowPlayingView"));
    if (!nowPlayingView) nowPlayingView = CLViewOrNil(CLFindSubview(root, @"CPUINowPlayingView"));
    _nowPlayingView = nowPlayingView;

    UIView *container = nowPlayingView ?: root;
    UIView *details = CLViewOrNil(CLIvar(container, @"_songDetailsView"));
    if (!details) details = CLViewOrNil(CLFindSubview(root, @"CPUISongDetailsView"));
    _songDetailsView = details;

    _progressView = CLViewOrNil(CLIvar(container, @"_progressView"));
    _transportControlView = CLViewOrNil(CLIvar(container, @"_transportControlView"));

    // Two artwork views, easy to confuse (0.3.0 and earlier did): the square the driver sees is
    // the Now Playing view's _artworkViewBrick; the controller's own _artworkView is the full-bleed
    // image behind everything, blurred by _artworkVisualEffectView. Hiding the latter "removed the
    // background" and left the artwork square where it was.
    UIView *brick = CLViewOrNil(CLIvar(container, @"_artworkViewBrick"));
    if (!brick) brick = CLViewOrNil(CLFindSubview(nowPlayingView ?: root, @"CPUIShadowImageView"));
    _artworkBrick = brick;
    _backgroundArtworkView = CLViewOrNil(CLIvar(viewController, @"_artworkView"));
    _backgroundEffectView = CLViewOrNil(CLIvar(viewController, @"_artworkVisualEffectView"));

    // A new anchor is a new screen as far as the per-pass cache goes.
    if (previousDetails != _songDetailsView) _passLabels = nil;

    _queueBarItem = CLBarItemOrNil(CLIvar(viewController, @"_playbackQueueBarButtonItem"));
    // The top bar's right-title label (-setRightTitle:, which nothing in CarPlaySupport calls):
    // kept only to name it in the debug log. The playback-speed control is a play-mode button.
    _rateBarItem = CLBarItemOrNil(CLIvar(viewController, @"_rightTitleLabelBarButtonItem"));
}

- (BOOL)cl_canConstrain:(UIView *)view to:(UIView *)other {
    return view != nil && other != nil && CLNearestCommonAncestor(view, other) != nil;
}

#pragma mark - Lyrics views

- (UIView *)cl_activeLyricsView {
    if (_effectiveMode == 4 || _effectiveMode == 5) return _panelView;
    return nil;
}

- (void)cl_syncLyricsViews {
    BOOL wantsPanel = _prefEnabled && (_effectiveMode == 4 || _effectiveMode == 5);
    BOOL wantsStatus = wantsPanel;

    if (wantsPanel && !_panelView) {
        _panelView = [[CLLyricsPanelView alloc] initWithFrame:CGRectZero];
        _panelView.translatesAutoresizingMaskIntoConstraints = NO;
        _panelView.delegate = self;
        _panelView.hidden = YES;
        // Seed it with what the controller already has. For modes 2 and 4 the panel is born on
        // the first layout pass (the plan is Off while the safe area is empty), after the lyrics
        // may have loaded and after the observer's initial callback may already have fired;
        // without this it would sit empty, with no status text, until the next track.
        CLLyricsController *controller = CLLyricsController.sharedController;
        [_panelView setLyrics:controller.currentLyrics];
        [_panelView setCurrentLineIndex:controller.currentLineIndex animated:NO];
    } else if (!wantsPanel && _panelView) {
        [self cl_deactivatePlacementConstraints];
        _panelView.delegate = nil;
        [_panelView removeFromSuperview];
        _panelView = nil;
    }

    if (wantsStatus && !_columnStatusLabel) {
        _columnStatusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _columnStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _columnStatusLabel.userInteractionEnabled = NO;
        _columnStatusLabel.textAlignment = NSTextAlignmentCenter;
        _columnStatusLabel.numberOfLines = 2;
        _columnStatusLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightSemibold];
        _columnStatusLabel.textColor = UIColor.secondaryLabelColor;
        _columnStatusLabel.hidden = YES;
    } else if (!wantsStatus && _columnStatusLabel) {
        [self cl_deactivatePlacementConstraints];
        [_columnStatusLabel removeFromSuperview];
        _columnStatusLabel = nil;
    }

    if (!wantsPanel) _placementSignature = nil;
}

- (void)cl_destroyLyricsViews {
    [self cl_deactivatePlacementConstraints];
    [_columnStatusLabel removeFromSuperview];
    _columnStatusLabel = nil;
    _panelView.delegate = nil;
    [_panelView removeFromSuperview];
    _panelView = nil;
    _placementSignature = nil;
}

- (void)cl_deactivatePlacementConstraints {
    if (_placementConstraints.count > 0) {
        [NSLayoutConstraint deactivateConstraints:_placementConstraints];
    }
    _placementConstraints = nil;
    _placementSignature = nil;
}

- (void)cl_placeLyricsViewIfNeeded {
    UIView *view = [self cl_activeLyricsView];
    if (!view) {
        if (_placementConstraints.count > 0) [self cl_deactivatePlacementConstraints];
        return;
    }
    UIViewController *viewController = _viewController;
    UIView *root = viewController.viewIfLoaded;
    if (!root) return;

    NSString *signature = [NSString stringWithFormat:@"%ld/%ld/%ld/%ld/%p/%p",
                           (long)_effectiveMode, (long)lround(self.playerColumnWidth),
                           (long)lround(self.playerStripHeight), (long)_lyricsSide, (void *)_nowPlayingView, (void *)root];
    if (view.superview != nil && [signature isEqualToString:_placementSignature]) return;

    [self cl_deactivatePlacementConstraints];

    // The panel lives beside the host's player column / above its strip, in the controller's root
    // view, since the host's Now Playing view is now the player.
    UIView *host = root;
    if (view.superview != host) {
        [view removeFromSuperview];
        [host addSubview:view];
    }
    [host bringSubviewToFront:view];
    view.translatesAutoresizingMaskIntoConstraints = NO;

    NSArray<NSLayoutConstraint *> *constraints = [self cl_constraintsForLyricsView:view inRoot:root];
    if (constraints.count == 0) {
        if (!_loggedPlacementFailure) {
            _loggedPlacementFailure = YES;
            CLLogError(@"[ui] could not build any placement constraint for the lyrics view "
                       @"(host %@ is not in the controller's hierarchy)", NSStringFromClass(host.class));
        }
        return;
    }
    UILabel *status = _columnStatusLabel;
    if (status) {
        // The status line sits where the lyrics would, centred in the same area.
        if (status.superview != host) {
            [status removeFromSuperview];
            [host addSubview:status];
        }
        constraints = [constraints arrayByAddingObjectsFromArray:@[
            [status.centerYAnchor constraintEqualToAnchor:view.centerYAnchor],
            [status.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:CLLayoutPanelTextInset],
            [view.trailingAnchor constraintEqualToAnchor:status.trailingAnchor constant:CLLayoutPanelTextInset],
        ]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
    _placementConstraints = constraints;
    _placementSignature = signature;
    if (CLLogDebugEnabled() && !_scheduledEdgeProbe) {
        // Once per screen, after the lyrics had time to arrive and the host to settle.
        _scheduledEdgeProbe = YES;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            CLUISafePerform(@"edge probe", ^{ [weakSelf cl_logPanelEdgeProbe]; });
        });
    }
    CLLogDebug(@"[ui] placed lyrics view (mode %ld of %ld, column %.0f, strip %.0f) in %@",
               (long)_effectiveMode, (long)_lyricsMode, self.playerColumnWidth, self.playerStripHeight,
               NSStringFromClass(host.class));
}

/// Exactly three placements: beside the player column (4, and 5 on short screens), above the strip
/// (5), and the safe-area fallback when the anchor a mode needs is not on screen.
- (NSArray<NSLayoutConstraint *> *)cl_constraintsForLyricsView:(UIView *)view inRoot:(UIView *)root {
    UILayoutGuide *safeArea = [self cl_canConstrain:view to:root] ? root.safeAreaLayoutGuide : nil;
    UIView *nowPlaying = _nowPlayingView;

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray array];
    CGFloat column = self.playerColumnWidth;
    CGFloat strip = self.playerStripHeight;

    if (column > 0.0 && safeArea && _lyricsSide == CLLayoutLyricsSideLeft) {
        // Lyrics on the left: everything left of a player column at the trailing edge (mirrored).
        [constraints addObject:[view.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor
                                                                  constant:CLLayoutPanelSideInset]];
        [constraints addObject:[safeArea.trailingAnchor constraintEqualToAnchor:view.trailingAnchor
                                                                       constant:column + CLLayoutColumnGap]];
        [constraints addObject:[view.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:CLLayoutPanelTopGap]];
        [constraints addObject:[safeArea.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:CLLayoutPanelTopGap]];
    } else if (column > 0.0 && safeArea) {
        // Side by side, and the short-screen full panel: everything right of the player column,
        // inside the safe area.
        [constraints addObject:[view.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor
                                                                  constant:column + CLLayoutColumnGap]];
        [constraints addObject:[safeArea.trailingAnchor constraintEqualToAnchor:view.trailingAnchor
                                                                       constant:CLLayoutPanelSideInset]];
        [constraints addObject:[view.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:CLLayoutPanelTopGap]];
        [constraints addObject:[safeArea.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:CLLayoutPanelTopGap]];
    } else if (strip > 0.0 && safeArea) {
        // Full panel: the whole safe area above the host's bottom strip. The text inset is 11 so
        // the lyric text (16 pt of label padding) starts at the title's x (the host's 27 pt margin).
        [constraints addObject:[view.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:CLLayoutFullPanelGap]];
        [constraints addObject:[view.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor
                                                                  constant:CLLayoutFullPanelLyricsInset]];
        [constraints addObject:[safeArea.trailingAnchor constraintEqualToAnchor:view.trailingAnchor
                                                                       constant:CLLayoutFullPanelLyricsInset]];
        if ([self cl_canConstrain:view to:nowPlaying]) {
            [constraints addObject:[nowPlaying.topAnchor constraintEqualToAnchor:view.bottomAnchor
                                                                        constant:CLLayoutFullPanelGap]];
        } else {
            [constraints addObject:[safeArea.bottomAnchor constraintEqualToAnchor:view.bottomAnchor
                                                                         constant:strip + CLLayoutFullPanelGap]];
        }
    }

    if (constraints.count == 0) {
        // Nothing we recognise is on screen: sit inside the safe area and say so, once.
        CGFloat inset = CLLayoutPanelSideInset;
        if (safeArea) {
            [constraints addObject:[view.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:inset]];
            [constraints addObject:[safeArea.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:inset]];
            [constraints addObject:[view.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:inset]];
            [constraints addObject:[safeArea.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:inset]];
        }
        if (!_loggedAnchorFallback) {
            _loggedAnchorFallback = YES;
            CLLogInfo(@"[ui] layout anchors missing (mode %ld, column %.0f, strip %.0f, nowPlaying:%d) — "
                      @"pinning the lyrics view to the safe area instead",
                      (long)_effectiveMode, column, strip, nowPlaying != nil);
        }
    }
    return constraints;
}

/// See CLLogViewsAtPoint: what is drawn 22 pt inside the panel's trailing edge, half way down.
- (void)cl_logPanelEdgeProbe {
    CLLyricsPanelView *panel = _panelView;
    UIWindow *window = panel.window;
    if (!_attached || !window) return;
    CGPoint point = [panel convertPoint:CGPointMake(CGRectGetMaxX(panel.bounds) - 22.0, CGRectGetMidY(panel.bounds))
                                 toView:window];
    CLLogDebug(@"[ui] edge probe: panel %@ hidden=%d, point %@ (window %@)",
               NSStringFromCGRect([panel convertRect:panel.bounds toView:window]), panel.isHidden,
               NSStringFromCGPoint(point), NSStringFromCGRect(window.bounds));
    CLLogViewsAtPoint(window, point);
}

#pragma mark - Full-screen lyrics (0.7.0)

/// Whether this screen offers the microphone: the tweak and the Lyrics Button on, an app lyrics are
/// on for, and that app is the one playing. Independent of the layout — Layout Off included since
/// 0.8.2: Off keeps CarPlay's own screen, and the microphone is the only lyrics left on it.
- (BOOL)cl_microphoneAllowed {
    if (!_attached || !_prefEnabled || !_showLyricsButton) return NO;
    NSString *bundleIdentifier = CLScreenBundleIdentifier(_viewController);
    if (![CLLyricsController.sharedController isBundleEnabled:bundleIdentifier]) return NO;
    return [self cl_screenMatchesNowPlaying];
}

- (UIButton *)microphoneButton {
    return _micButton;
}

/// -[CPUIPlayModeControlView _updateButtonLayouts] (verified, iOS 17.3): every visible arranged
/// subview of its stack gets width == buttonWidth and height == 26, and the stack's width becomes
/// count x buttonWidth + (count - 1) x buttonSpacing. So a button of ours in that stack is laid
/// out exactly like the host's own, with no constraint of ours to fight it.
static void CLUpdatePlayModeLayout(UIView *playMode) {
    SEL selector = NSSelectorFromString(@"_updateButtonLayouts");
    if (!playMode || ![playMode respondsToSelector:selector]) return;
    ((void (*)(id, SEL))objc_msgSend)(playMode, selector);
}

/// Adds (or keeps, last and visible) our microphone in the host's play-mode row, or takes it out.
- (void)cl_applyMicrophoneButton {
    UIView *playMode = CLViewOrNil(CLIvar(_nowPlayingView, @"_playModeControlView"));
    id stackValue = CLIvar(playMode, @"_stackView");
    UIStackView *stack = [stackValue isKindOfClass:UIStackView.class] ? (UIStackView *)stackValue : nil;
    BOOL usable = stack != nil && [playMode respondsToSelector:NSSelectorFromString(@"_updateButtonLayouts")];
    if (!usable || ![self cl_microphoneAllowed]) {
        [self cl_removeMicrophoneButton];
        return;
    }
    if (!_micButton) {
        // CarPlay's own button class, like the host's play-mode buttons; never UIButtonTypeSystem,
        // which CarPlay draws on a dark platter.
        UIButton *button = CLMakeHostStyleButton(NO);
        button.accessibilityLabel = @"Lyrics";
        [button addTarget:self action:@selector(cl_microphoneTapped:) forControlEvents:UIControlEventTouchUpInside];
        _micButton = button;
    }
    UIButton *button = _micButton;
    UIImage *glyph = [self cl_microphoneImageMatchingStack:stack];
    if (glyph && [button imageForState:UIControlStateNormal] != glyph) [button setImage:glyph forState:UIControlStateNormal];
    BOOL changed = NO;
    if (_micStack != stack || ![stack.arrangedSubviews containsObject:button]) {
        [self cl_removeMicrophoneButton];
        [stack addArrangedSubview:button];
        changed = YES;
    } else if (stack.arrangedSubviews.lastObject != button) {
        // The host appends new template buttons (-setMediaButtons:); ours stays at the end.
        [stack removeArrangedSubview:button];
        [stack addArrangedSubview:button];
    }
    if (button.isHidden) {
        button.hidden = NO;
        changed = YES;
    }
    _micStack = stack;
    _micPlayModeView = playMode;
    if (changed) CLUpdatePlayModeLayout(playMode);
}

/// The microphone glyph at the height of the host's own play-mode icons (the first visible host
/// button in the row with an image), in the regular weight of CarPlay's outline icons. Cached per
/// height; 18 pt tall when the row has nothing to measure.
- (UIImage *)cl_microphoneImageMatchingStack:(UIStackView *)stack {
    CGFloat target = 0.0;
    for (UIView *view in stack.arrangedSubviews) {
        if (view == _micButton || view.isHidden || ![view isKindOfClass:UIButton.class]) continue;
        UIImage *image = [(UIButton *)view imageForState:UIControlStateNormal] ?: ((UIButton *)view).currentImage;
        if (image.size.height >= 8.0 && image.size.height <= 60.0) {
            target = image.size.height;
            break;
        }
    }
    if (target <= 0.0) target = 18.0;
    if (_micImage && fabs(_micImageHeight - target) < 0.5) return _micImage;

    UIImage *probe = [UIImage systemImageNamed:@"mic"
                             withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17.0
                                                                                              weight:UIImageSymbolWeightRegular]];
    CGFloat probeHeight = probe.size.height > 1.0 ? probe.size.height : 20.0;
    CGFloat pointSize = MAX(8.0, MIN(40.0, 17.0 * target / probeHeight));
    UIImage *image = [UIImage systemImageNamed:@"mic"
                             withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:pointSize
                                                                                              weight:UIImageSymbolWeightRegular]];
    _micImage = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    _micImageHeight = target;
    CLLogDebug(@"[ui] microphone glyph %.1f pt tall (host icons %.1f pt, point size %.1f)",
               _micImage.size.height, target, pointSize);
    return _micImage;
}

- (void)cl_removeMicrophoneButton {
    UIButton *button = _micButton;
    if (!button.superview) return;
    UIStackView *stack = _micStack;
    UIView *playMode = _micPlayModeView;
    if (stack) [stack removeArrangedSubview:button];
    [button removeFromSuperview];
    _micStack = nil;
    _micPlayModeView = nil;
    CLUpdatePlayModeLayout(playMode);
}

/// The playback-speed ("1×") button in the play-mode row. -[CPUINowPlayingViewController
/// _updatePlayModesState] shows it whenever the app can change the rate (podcasts, audiobooks) and
/// then lays the row out (verified, iOS 17.3); the hook calls this right after, and so does every
/// pass. Undoing it asks the host to run its own rule again.
- (void)cl_applyPlaybackRateButton {
    UIView *playMode = CLViewOrNil(CLIvar(_nowPlayingView, @"_playModeControlView"));
    id value = CLIvar(playMode, @"_playbackRateButton");
    UIButton *rate = [value isKindOfClass:UIButton.class] ? (UIButton *)value : nil;
    if (_prefEnabled && _hidePlaybackRateButton) {
        if (rate && !rate.isHidden) {
            rate.hidden = YES;
            _rateButtonHiddenByUs = YES;
            CLUpdatePlayModeLayout(playMode);
        }
        return;
    }
    [self cl_restorePlaybackRateButton];
}

- (void)cl_restorePlaybackRateButton {
    if (!_rateButtonHiddenByUs) return;
    _rateButtonHiddenByUs = NO;
    SEL recompute = NSSelectorFromString(@"_updatePlayModesState");
    UIViewController *viewController = _viewController;
    if ([viewController respondsToSelector:recompute]) {
        _recomputingPlayModes = YES;
        @try {
            ((void (*)(id, SEL))objc_msgSend)(viewController, recompute);
        } @finally {
            _recomputingPlayModes = NO;
        }
    }
}

- (void)cl_microphoneTapped:(id)sender {
    // UIKit calls this straight from the touch handler, outside every hook.
    CLUISafePerform(@"microphone", ^{ [self setFullScreen:YES]; });
}

- (BOOL)isFullScreen {
    return _fullScreen;
}

- (void)setFullScreen:(BOOL)fullScreen {
    CLUIRunOnMain(^{
        CLUISafePerform(@"setFullScreen:", ^{ [self cl_setFullScreenOnMain:fullScreen]; });
    });
}

- (void)cl_setFullScreenOnMain:(BOOL)fullScreen {
    if (fullScreen && ![self cl_microphoneAllowed]) fullScreen = NO;
    if (_fullScreen == fullScreen) return;
    _fullScreen = fullScreen;
    CLLogDebug(@"[ui] full-screen lyrics %@", fullScreen ? @"on" : @"off");
    _placementSignature = nil;
    [self relayout];
    // The host's controls just appeared or disappeared under the knob.
    UIViewController *viewController = _viewController;
    [viewController setNeedsFocusUpdate];
    [viewController updateFocusIfNeeded];
}

/// Part of every layout pass: puts the full-screen view up (over the safe area, the host's Now
/// Playing view hidden under it) or takes it down and gives the host its view back.
- (void)cl_applyFullScreen {
    if (_fullScreen && ![self cl_microphoneAllowed]) _fullScreen = NO;   // e.g. another app took over
    UIViewController *viewController = _viewController;
    UIView *root = viewController.viewIfLoaded;
    UIView *nowPlaying = _nowPlayingView;
    if (!_fullScreen || !root) {
        [self cl_takeDownFullScreen];
        return;
    }

    if (!_fullScreenView) {
        CLLyricsFullScreenView *view = [[CLLyricsFullScreenView alloc] initWithFrame:CGRectZero];
        view.translatesAutoresizingMaskIntoConstraints = NO;
        view.delegate = self;
        CLLyricsController *controller = CLLyricsController.sharedController;
        [view.panelView setLyrics:controller.currentLyrics];
        [view.panelView setCurrentLineIndex:controller.currentLineIndex animated:NO];
        _fullScreenView = view;
    }
    CLLyricsFullScreenView *view = _fullScreenView;
    if (view.superview != root) {
        [NSLayoutConstraint deactivateConstraints:_fullScreenConstraints ?: @[]];
        [view removeFromSuperview];
        [root addSubview:view];
        UILayoutGuide *safe = root.safeAreaLayoutGuide;
        _fullScreenConstraints = @[
            [view.topAnchor constraintEqualToAnchor:safe.topAnchor],
            [view.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
            [view.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
            [view.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        ];
        [NSLayoutConstraint activateConstraints:_fullScreenConstraints];
    }
    [root bringSubviewToFront:view];

    if (nowPlaying) {
        if (!_nowPlayingHiddenByUs) {
            _savedNowPlayingHidden = nowPlaying.isHidden;
            _nowPlayingHiddenByUs = YES;
        }
        if (!nowPlaying.isHidden) nowPlaying.hidden = YES;
    }
}

- (void)cl_takeDownFullScreen {
    if (_pressedCommand >= 0) {
        // A skip held down as the view goes: finish the press on the host, or it waits forever.
        UIButton *hostButton = [self cl_hostTransportButtonForCommand:(CLPlaybackCommand)_pressedCommand];
        _pressedCommand = -1;
        [hostButton sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
    if (_fullScreenView) {
        [NSLayoutConstraint deactivateConstraints:_fullScreenConstraints ?: @[]];
        _fullScreenConstraints = nil;
        _fullScreenView.delegate = nil;
        [_fullScreenView removeFromSuperview];
        _fullScreenView = nil;
    }
    if (_nowPlayingHiddenByUs) {
        _nowPlayingHiddenByUs = NO;
        UIView *nowPlaying = _nowPlayingView;
        if (nowPlaying && nowPlaying.isHidden != _savedNowPlayingHidden) nowPlaying.hidden = _savedNowPlayingHidden;
    }
}

/// The host's transport button for a command: CPUITransportControlView's _leftButton,
/// _playPauseButton or _fastForwardButton (verified, iOS 17.3), nil when absent.
- (UIButton *)cl_hostTransportButtonForCommand:(CLPlaybackCommand)command {
    NSString *name = (command == CLPlaybackCommandPreviousTrack) ? @"_leftButton"
                   : (command == CLPlaybackCommandNextTrack) ? @"_fastForwardButton" : @"_playPauseButton";
    id value = CLIvar(_transportControlView, name);
    return [value isKindOfClass:UIButton.class] ? (UIButton *)value : nil;
}

/// What the host's (hidden) transport row shows right now, handed to the full-screen view: the same
/// glyphs at the same size, so play/pause, podcast skips and disabled states always match CarPlay.
- (void)cl_syncFullScreenTransport {
    CLLyricsFullScreenView *view = _fullScreenView;
    if (!view) return;
    UIImage *(^imageOf)(UIButton *) = ^UIImage *(UIButton *button) {
        return [button imageForState:UIControlStateNormal] ?: button.currentImage;
    };
    UIButton *previous = [self cl_hostTransportButtonForCommand:CLPlaybackCommandPreviousTrack];
    UIButton *playPause = [self cl_hostTransportButtonForCommand:CLPlaybackCommandTogglePlayPause];
    UIButton *next = [self cl_hostTransportButtonForCommand:CLPlaybackCommandNextTrack];
    NSNumber *height = CLNumberForGetter(_transportControlView, @"buttonHeight");
    [view setPreviousImage:imageOf(previous) playPauseImage:imageOf(playPause) nextImage:imageOf(next)
              buttonHeight:height.doubleValue];
    if (_micImage) [view setMicrophoneImage:_micImage];
}

/// Title, artist, play state and the "why is it empty" line of the full-screen view.
- (void)cl_updateFullScreenContentWithStatus:(CLLyricsControllerStatus)status {
    CLLyricsFullScreenView *view = _fullScreenView;
    if (!view) return;
    CLPlaybackState *state = CLLyricsController.sharedController.currentState;
    [view setTitle:state.title artist:state.artist];
    [view setPlaying:state.isPlaying];
    [view setPlaybackState:state];
    // The player's settings mean the same thing here: Progress Bar Hide hides this line too, and
    // the accent tints its fill and the artist name like the player's.
    [view setProgressHidden:(_progressBarStyle == 2)];
    [view setAccentColor:[self cl_accentColor]];
    [self cl_syncFullScreenTransport];
    BOOL hasContent = view.panelView.hasVisibleContent;
    if (view.panelView.isHidden == hasContent) view.panelView.hidden = !hasContent;
    [view setStatusText:hasContent ? nil : CLFullScreenStatusText(status, CLLyricsController.sharedController.currentLyrics)];
}

/// Our transport buttons drive the host's own: the same touch-down / touch-up pair its controller
/// listens for (-_playPauseButtonTouchDown: / -…TouchUp:, events 0x1 and 0x1c0, iOS 17.3), so a tap,
/// a held skip and Spotify's podcast skips behave exactly as on CarPlay's player. Without a host
/// button, a MediaRemote command on touch up.
- (void)lyricsFullScreenView:(CLLyricsFullScreenView *)view didSendEvents:(UIControlEvents)events
                  forCommand:(CLPlaybackCommand)command {
    UIButton *hostButton = [self cl_hostTransportButtonForCommand:command];
    BOOL touchUp = (events & UIControlEventTouchUpInside) != 0;
    if (hostButton) {
        [hostButton sendActionsForControlEvents:events];
    } else if (touchUp) {
        [CLNowPlayingSource.sharedSource sendCommand:command];
    }
    _pressedCommand = touchUp ? -1 : (NSInteger)command;
    if (!touchUp) return;
    // The host swaps its play/pause glyph once the app confirms; pick it up when it does.
    __weak typeof(self) weakSelf = self;
    for (NSNumber *delay in @[ @0.3, @1.0 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            CLUISafePerform(@"transport glyph sync", ^{ [weakSelf cl_syncFullScreenTransport]; });
        });
    }
}

- (void)lyricsFullScreenViewDidRequestClose:(CLLyricsFullScreenView *)view {
    [self setFullScreen:NO];
}

#pragma mark - Controller wiring

/// Called from CLLyricsController's observer list, which the sync engine's 10 Hz timer drives —
/// another path with no exception handler above it (see CLUISafePerform).
- (void)cl_controllerDidChange:(CLLyricsControllerChange)change controller:(CLLyricsController *)controller {
    CLUISafePerform(@"controller change", ^{
        [self cl_applyControllerChange:change controller:controller];
    });
}

- (void)cl_applyControllerChange:(CLLyricsControllerChange)change controller:(CLLyricsController *)controller {
    // Paused: -setPaused:NO pushes whatever the controller ended up on, so dropping these costs
    // nothing but the animation work behind an invisible screen.
    if (!_attached || _paused) return;
    if ((change & CLLyricsControllerChangePlayback) && [self cl_screenMatchesNowPlaying] != _screenMatchedNowPlaying) {
        // Another app took over playback (or this one came back): the split layout and the lyrics
        // follow. One host pass moves the player area; -relayout re-places the panel.
        [self cl_updateEffectiveMode];
        [self cl_requestHostColumnPassIfStale];
        [self relayout];
    }
    // A track change arrives as a burst (loading -> lines -> loaded), so the render path is
    // idempotent and only a plain line change animates.
    BOOL lyricsChanged = (change & CLLyricsControllerChangeLyrics) != 0;
    if (lyricsChanged) [_panelView setLyrics:controller.currentLyrics];
    [_panelView setCurrentLineIndex:controller.currentLineIndex animated:!lyricsChanged];
    if (_fullScreenView) {
        if (lyricsChanged) [_fullScreenView.panelView setLyrics:controller.currentLyrics];
        [_fullScreenView.panelView setCurrentLineIndex:controller.currentLineIndex animated:!lyricsChanged];
    }
    [self cl_updateLyricsVisibility];
}

- (void)cl_pushLyrics:(CLLyrics *)lyrics lineIndex:(NSInteger)lineIndex animated:(BOOL)animated {
    [_panelView setLyrics:lyrics];
    [_panelView setCurrentLineIndex:lineIndex animated:animated];
    [_fullScreenView.panelView setLyrics:lyrics];
    [_fullScreenView.panelView setCurrentLineIndex:lineIndex animated:animated];
    [self cl_updateLyricsVisibility];
}

- (void)cl_updateLyricsVisibility {
    CLLyricsControllerStatus status = CLLyricsController.sharedController.status;
    // Lyrics belong to whatever is playing system-wide; this screen belongs to one app. Another
    // app's lyrics never show on it.
    BOOL allowed = _prefEnabled && _effectiveMode != 0 && status != CLLyricsControllerStatusDisabled &&
                   [self cl_screenMatchesNowPlaying];

    // Full screen covers the split: its own panel and status line say everything.
    BOOL panelVisible = allowed && !_fullScreen && _panelView.hasVisibleContent;
    if (_panelView && _panelView.isHidden == panelVisible) _panelView.hidden = !panelVisible;
    [self cl_updateFullScreenContentWithStatus:status];

    // The layout stays put whatever the lyrics do (a screen that rearranges itself on every track
    // change is worse than a quiet line), so an empty lyrics area says why it is empty.
    UILabel *statusLabel = _columnStatusLabel;
    if (statusLabel) {
        NSString *text = nil;
        if (allowed && !_fullScreen && !panelVisible) text = CLLyricsStatusText(status);
        if (!CLStringsEqualOrNil(statusLabel.text, text)) statusLabel.text = text;
        BOOL statusHidden = (text.length == 0);
        if (statusLabel.isHidden != statusHidden) statusLabel.hidden = statusHidden;
    }
}

- (void)lyricsPanel:(CLLyricsPanelView *)panel didSelectLineAtIndex:(NSInteger)index {
    // UIKit calls this straight from the touch handler, outside every hook.
    CLUISafePerform(@"panel tap", ^{
        CLLogDebug(@"[ui] lyrics panel tapped line %ld", (long)index);
        [CLLyricsController.sharedController seekToLineAtIndex:index];
    });
}

#pragma mark - Applying the layout

- (void)relayout {
    CLUIRunOnMain(^{
        CLUISafePerform(@"relayout", ^{ [self cl_relayoutOnMain]; });
    });
}

- (void)cl_relayoutOnMain {
    if (!_attached || _applying) return;
    // -setPaused:NO relayouts from a cleared placement signature, so a layout pass that happens
    // while the screen is offscreen is caught up rather than lost.
    if (_paused) return;
    UIViewController *viewController = _viewController;
    if (!viewController.viewIfLoaded) return;

    // _applying is both the re-entrancy guard and the "a pass is running" flag the per-pass
    // caches key off, so it is cleared in a @finally: one raise inside the apply chain must not
    // leave the guard set forever, which would freeze the screen half-modified for the rest of
    // the drive (nothing below can then relayout, restore or even detach cleanly).
    _applying = YES;
    [self cl_beginPassCache];
    @try {
        [self cl_resolveAnchors];

        if (!_prefEnabled) {
            [self cl_restoreHostChanges];
            [self cl_destroyLyricsViews];
            return;
        }

        [self cl_updateEffectiveMode];
        [self cl_syncLyricsViews];
        [self cl_placeLyricsViewIfNeeded];
        [self cl_applyArtworkAppearance];
        [self cl_applyBackdrop];
        [self cl_applyAccentTint];
        [self cl_applyAlbumVisibility];
        [self cl_applyProgressStyle];
        [self cl_applyBarButtonVisibility];
        [self cl_applyPanelFit];
        [self cl_applyMicrophoneButton];
        [self cl_applyPlaybackRateButton];
        [self cl_applyFullScreen];
        [self cl_updateLyricsVisibility];
    } @finally {
        _applying = NO;
        [self cl_endPassCache];
    }
}

- (void)artworkDidChange {
    CLUIRunOnMain(^{
        CLUISafePerform(@"artworkDidChange", ^{
            if (!self->_attached) return;
            self->_accentSourceImage = nil;
            self->_accentColorCache = nil;
            [self cl_beginPassCache];
            @try {
                [self cl_applyAccentTint];
            } @finally {
                [self cl_endPassCache];
            }
        });
    });
}

#pragma mark - Artwork

- (UIImage *)cl_currentArtworkImage {
    UIViewController *viewController = _viewController;
    id image = CLIvar(viewController, @"_artworkImage");
    if ([image isKindOfClass:UIImage.class]) return (UIImage *)image;

    UIView *artwork = _artworkBrick;
    if ([artwork isKindOfClass:UIImageView.class]) {
        UIImage *direct = ((UIImageView *)artwork).image;
        if (direct) return direct;
    }
    id byKey = CLValueForKey(artwork, @"image");
    if ([byKey isKindOfClass:UIImage.class]) return (UIImage *)byKey;

    id imageView = CLFindSubview(artwork, @"UIImageView");
    if ([imageView isKindOfClass:UIImageView.class]) {
        UIImage *nested = ((UIImageView *)imageView).image;
        if (nested) return nested;
    }
    return nil;
}

- (void)cl_saveArtworkStateIfNeeded:(UIView *)artwork {
    if (_artworkStateSaved || !artwork) return;
    _savedArtworkCornerRadius = artwork.layer.cornerRadius;
    _savedArtworkMasksToBounds = artwork.layer.masksToBounds;
    _artworkStateSaved = YES;
}

/// Corner radius (and the clipping it needs) on the artwork square. Nothing else: the host owns
/// the square's size and position.
- (void)cl_applyArtworkAppearance {
    UIView *artwork = _artworkBrick;
    if (!artwork) return;
    [self cl_saveArtworkStateIfNeeded:artwork];

    CGFloat radius = (CGFloat)_artworkCornerRadius;
    if (fabs(artwork.layer.cornerRadius - radius) > 0.01) artwork.layer.cornerRadius = radius;
    // Deliberately no cornerCurve: kCACornerCurve* are QuartzCore symbols and this dylib links
    // UIKit only (see docs/HANDOFF.md) — circular corners need no extra framework.
    if (radius > 0.0) {
        if (!artwork.layer.masksToBounds) artwork.layer.masksToBounds = YES;
    } else if (artwork.layer.masksToBounds != _savedArtworkMasksToBounds) {
        artwork.layer.masksToBounds = _savedArtworkMasksToBounds;
    }
}

/// The panel's font-fit rule: a column of lyrics (beside either player column) reads as a column;
/// the strip's full-width panel uses the three-row rule.
- (void)cl_applyPanelFit {
    CLLyricsPanelView *panel = _panelView;
    if (!panel) return;
    CLLayoutPanelFit fit = (self.playerColumnWidth > 0.0) ? CLLayoutPanelFitColumn : CLLayoutPanelFitRows;
    if (panel.fit != fit) panel.fit = fit;
}

#pragma mark - Backdrop

/// The host's own full-bleed artwork backdrop (a UIImageView under a blur effect view, both pinned
/// across the controller's view in -viewDidLoad): "plain" hides both so the host's dark table
/// background shows, otherwise the image's opacity follows the preference. 0.3.0 and earlier
/// added a second blurred copy *behind* the host's, which nobody could see.
- (void)cl_applyBackdrop {
    UIView *image = _backgroundArtworkView;
    UIView *effect = _backgroundEffectView;
    if (!image && !effect) return;
    if (!_backgroundStateSaved) {
        _savedBackgroundHidden = image.isHidden;
        _savedBackgroundAlpha = image ? image.alpha : 1.0;
        _savedBackgroundEffectHidden = effect.isHidden;
        _backgroundStateSaved = YES;
    }
    BOOL plain = (_backdropStyle == 1);
    BOOL imageHidden = plain ? YES : _savedBackgroundHidden;
    BOOL effectHidden = plain ? YES : _savedBackgroundEffectHidden;
    CGFloat alpha = plain ? _savedBackgroundAlpha : (CGFloat)_backdropOpacity;
    if (image && image.isHidden != imageHidden) image.hidden = imageHidden;
    if (image && fabs(image.alpha - alpha) > 0.01) image.alpha = alpha;
    if (effect && effect.isHidden != effectHidden) effect.hidden = effectHidden;
}

- (void)cl_restoreBackdrop {
    if (!_backgroundStateSaved) return;
    UIView *image = _backgroundArtworkView;
    UIView *effect = _backgroundEffectView;
    if (image) {
        image.hidden = _savedBackgroundHidden;
        image.alpha = _savedBackgroundAlpha;
    }
    if (effect) effect.hidden = _savedBackgroundEffectHidden;
    _backgroundStateSaved = NO;
}

#pragma mark - Accent tint

- (UIColor *)cl_accentColor {
    if (_tintFromArtwork) {
        UIImage *image = [self cl_passArtworkImage];
        if (image) {
            if (image == _accentSourceImage && _accentColorCache) return _accentColorCache;
            UIColor *computed = CLAverageArtworkColor(image);
            if (computed) {
                _accentSourceImage = image;
                _accentColorCache = computed;
                return computed;
            }
        }
    }
    return CLColorFromHexOrNil(_accentColorHex);
}

- (void)cl_applyAccentTint {
    UIColor *accent = _prefEnabled ? [self cl_accentColor] : nil;
    UIView *progress = _progressView;
    UIView *nowPlayingView = _nowPlayingView;

    if (!accent) {
        [self cl_restoreAccentTint];
        return;
    }

    if (!_tintStateSaved) {
        _savedProgressTintColor = progress.tintColor;
        _savedNowPlayingTintColor = nowPlayingView.tintColor;
        _tintStateSaved = YES;
    }

    if (progress) {
        if (progress.tintColor != accent) progress.tintColor = accent;
        // CLResponds only proves a setter exists, not that it takes a UIColor, and KVC raises
        // when it does not — from a notification callback that would abort the host.
        if (CLResponds(progress, @"setProgressTintColor:")) {
            CLSetValueForKey(progress, @"progressTintColor", accent);
        }
    }
    if (nowPlayingView && nowPlayingView.tintColor != accent) nowPlayingView.tintColor = accent;

    // The artist/album lines take the accent; the title stays at the host's colour so it is always
    // the most legible thing on screen.
    NSArray<UILabel *> *labels = [self cl_songDetailsLabels];
    for (NSUInteger i = 1; i < labels.count && i < 3; i++) {
        UILabel *label = labels[i];
        if (![_savedLabelColors objectForKey:label]) {
            [_savedLabelColors setObject:(label.textColor ?: UIColor.labelColor) forKey:label];
        }
        if (label.textColor != accent) label.textColor = accent;
    }
}

- (void)cl_restoreAccentTint {
    if (!_tintStateSaved) return;
    UIView *progress = _progressView;
    if (progress) {
        progress.tintColor = _savedProgressTintColor;
        // _savedProgressTintColor is legitimately nil when _progressView was unresolved at the
        // moment the state was saved; CLSetValueForKey refuses a nil value rather than hand it to
        // a setter that may not take one.
        if (_savedProgressTintColor && CLResponds(progress, @"setProgressTintColor:")) {
            CLSetValueForKey(progress, @"progressTintColor", _savedProgressTintColor);
        }
    }
    _nowPlayingView.tintColor = _savedNowPlayingTintColor;
    for (UILabel *label in [[_savedLabelColors keyEnumerator] allObjects]) {
        UIColor *original = [_savedLabelColors objectForKey:label];
        if (original) label.textColor = original;
    }
    [_savedLabelColors removeAllObjects];
    _savedProgressTintColor = nil;
    _savedNowPlayingTintColor = nil;
    _tintStateSaved = NO;
}

#pragma mark - Album label

- (void)cl_applyAlbumVisibility {
    UIView *details = _songDetailsView;
    if (!details) return;

    NSArray<UILabel *> *labels = [self cl_songDetailsLabels];
    if (!_loggedLabelProbe && labels.count > 0) {
        _loggedLabelProbe = YES;
        NSMutableArray<NSString *> *described = [NSMutableArray array];
        for (NSUInteger i = 0; i < labels.count; i++) {
            [described addObject:[NSString stringWithFormat:@"%lu:%@(%.0fpt)",
                                  (unsigned long)i, labels[i].text ?: @"(nil)", labels[i].font.pointSize]];
        }
        CLLogDebug(@"[ui] song details labels: %@", [described componentsJoinedByString:@", "]);
    }

    UILabel *album = (labels.count >= 3) ? labels[2] : nil;
    if (_showAlbum || !album) {
        UILabel *previous = _hiddenAlbumLabel;
        if (previous) {
            if (previous.isHidden != _savedAlbumLabelHidden) previous.hidden = _savedAlbumLabelHidden;
            _hiddenAlbumLabel = nil;
        }
        return;
    }
    if (_hiddenAlbumLabel != album) {
        UILabel *previous = _hiddenAlbumLabel;
        if (previous && previous.isHidden != _savedAlbumLabelHidden) previous.hidden = _savedAlbumLabelHidden;
        _savedAlbumLabelHidden = album.isHidden;
        _hiddenAlbumLabel = album;
    }
    if (!album.isHidden) album.hidden = YES;
}

#pragma mark - Progress bar

/// Show (0) or hide (2). The thin bar (1) is gone: a half-height CPUIProgressBarView in the host's
/// fixed 10 pt slot beside unscaled time labels read as a bug.
///
/// Show leaves the bar to the host. -[CPUINowPlayingView recalculateLayout:allowsAlbumArt:
/// hasDataSource:…] sets it, the transport row and one more view to hidden = !hasDataSource (17.3
/// disassembly), so a screen that appears before its playback data — Apple Music's, every time —
/// starts with the bar hidden and shows it a moment later. Up to 0.8.1 this saved that first state
/// and re-applied it on every pass, which kept Apple Music's bar hidden for good.
- (void)cl_applyProgressStyle {
    UIView *progress = _progressView;
    if (!progress) return;
    if (_progressBarStyle == 2) {
        _hidingProgress = YES;
        if (!progress.isHidden) progress.hidden = YES;
    } else if (_hidingProgress) {
        [self cl_returnProgressToHost];
    }
}

/// Stops hiding the bar and gives it the state the host wants now: the transport row's, which the
/// host sets from the same hasDataSource flag.
- (void)cl_returnProgressToHost {
    _hidingProgress = NO;
    UIView *progress = _progressView;
    if (!progress) return;
    UIView *transport = _transportControlView;
    BOOL hidden = transport ? transport.isHidden : NO;
    if (progress.isHidden != hidden) progress.hidden = hidden;
}

#pragma mark - Bar buttons

/// Only the queue ("Queue & Jam" on Spotify, the host's up-next item) lives in the top bar. The
/// playback-speed control is a play-mode button (-cl_applyPlaybackRateButton); 0.2 – 0.7.3 took
/// the top bar's right-title label for it, which nothing in CarPlaySupport ever fills.
- (BOOL)cl_shouldHideBarItem:(UIBarButtonItem *)item {
    return item && _hideQueueButton && _queueBarItem && item == _queueBarItem;
}

- (void)cl_applyBarButtonVisibility {
    UIViewController *viewController = _viewController;
    UINavigationItem *navigationItem = viewController.navigationItem;
    if (!navigationItem) return;

    NSArray<UIBarButtonItem *> *current = navigationItem.rightBarButtonItems;
    if (!current) {
        UIBarButtonItem *single = navigationItem.rightBarButtonItem;
        current = single ? @[ single ] : @[];
    }

    if (!_loggedBarItemProbe && current.count > 0) {
        _loggedBarItemProbe = YES;
        NSMutableArray<NSString *> *described = [NSMutableArray array];
        for (NSUInteger i = 0; i < current.count; i++) {
            UIBarButtonItem *item = current[i];
            [described addObject:[NSString stringWithFormat:@"%lu:%@/%@%@", (unsigned long)i,
                                  item.title ?: @"(no title)", item.accessibilityLabel ?: @"(no a11y)",
                                  (item == _queueBarItem) ? @"[queue]" : ((item == _rateBarItem) ? @"[rightTitle]" : @"")]];
        }
        CLLogDebug(@"[ui] right bar items: %@", [described componentsJoinedByString:@", "]);
    }

    BOOL hidingEnabled = _prefEnabled && _hideQueueButton;
    [self cl_updateCanonicalBarItemsFrom:current];

    NSMutableArray<UIBarButtonItem *> *desired = [NSMutableArray array];
    [_hiddenBarItems removeAllObjects];
    for (UIBarButtonItem *item in _canonicalBarItems) {
        if (hidingEnabled && [self cl_shouldHideBarItem:item]) {
            [_hiddenBarItems addObject:item];
        } else {
            [desired addObject:item];
        }
    }

    // Only touch the navigation item when something actually differs: this runs on every relayout.
    if (![desired isEqualToArray:current]) navigationItem.rightBarButtonItems = desired;
}

/// Keeps `_canonicalBarItems` in sync with what the host shows: items it removed by itself are
/// forgotten, new items are spliced in where the host put them, and the ones we hid stay in place.
- (void)cl_updateCanonicalBarItemsFrom:(NSArray<UIBarButtonItem *> *)current {
    NSMutableArray<UIBarButtonItem *> *canonical = [(_canonicalBarItems ?: @[]) mutableCopy];

    for (NSInteger i = (NSInteger)canonical.count - 1; i >= 0; i--) {
        UIBarButtonItem *item = canonical[(NSUInteger)i];
        if (![current containsObject:item] && ![_hiddenBarItems containsObject:item]) {
            [canonical removeObjectAtIndex:(NSUInteger)i];
        }
    }

    NSUInteger insertAt = 0;
    for (UIBarButtonItem *item in current) {
        NSUInteger existing = [canonical indexOfObject:item];
        if (existing == NSNotFound) {
            NSUInteger index = MIN(insertAt, canonical.count);
            [canonical insertObject:item atIndex:index];
            insertAt = index + 1;
        } else {
            insertAt = existing + 1;
        }
    }
    _canonicalBarItems = [canonical copy];
}

- (void)cl_restoreBarButtons {
    NSArray<UIBarButtonItem *> *canonical = _canonicalBarItems;
    _canonicalBarItems = nil;
    if (_hiddenBarItems.count == 0) return;
    [_hiddenBarItems removeAllObjects];
    if (canonical.count == 0) return;

    UIViewController *viewController = _viewController;
    UINavigationItem *navigationItem = viewController.navigationItem;
    if (!navigationItem) return;
    if (![canonical isEqualToArray:(navigationItem.rightBarButtonItems ?: @[])]) {
        navigationItem.rightBarButtonItems = canonical;
    }
}

#pragma mark - Restoring

/// Every host mutation this class makes, put back: the brick's corner radius and clipping; the
/// backdrop; the progress view's hidden flag; the tint colours; the album label;
/// the right bar items. The player-area override and the size-constraint swap are undone by
/// -cl_teardownColumn.
- (void)cl_restoreHostChanges {
    UIView *artwork = _artworkBrick;
    if (_artworkStateSaved && artwork) {
        artwork.layer.cornerRadius = _savedArtworkCornerRadius;
        artwork.layer.masksToBounds = _savedArtworkMasksToBounds;
    }
    _artworkStateSaved = NO;
    [self cl_restoreBackdrop];

    if (_hidingProgress) [self cl_returnProgressToHost];

    [self cl_restoreAccentTint];

    UILabel *album = _hiddenAlbumLabel;
    if (album && album.isHidden != _savedAlbumLabelHidden) album.hidden = _savedAlbumLabelHidden;
    _hiddenAlbumLabel = nil;

    [self cl_restoreBarButtons];

    _fullScreen = NO;
    [self cl_takeDownFullScreen];
    [self cl_removeMicrophoneButton];
    [self cl_restorePlaybackRateButton];
}

#pragma mark - Debugging

- (NSString *)debugDescription {
    return [NSString stringWithFormat:
            @"<CLLayoutCustomizer attached:%d vc:%@ nowPlaying:%d details:%d progress:%d transport:%d "
            @"artworkBrick:%d backdrop:%d/%d mode:%ld/%ld column:%.0f strip:%.0f panel:%d>",
            _attached, NSStringFromClass(_viewController.class) ?: @"(nil)",
            _nowPlayingView != nil, _songDetailsView != nil, _progressView != nil,
            _transportControlView != nil, _artworkBrick != nil, _backgroundArtworkView != nil,
            _backgroundEffectView != nil, (long)_lyricsMode, (long)_effectiveMode,
            self.playerColumnWidth, self.playerStripHeight, _panelView != nil];
}

#pragma mark - Driving the host's layout

+ (BOOL)hostColumnHooksInstalled {
    return sHostColumnHooksInstalled;
}

+ (void)setHostColumnHooksInstalled:(BOOL)installed {
    sHostColumnHooksInstalled = installed;
}

- (CGFloat)playerColumnWidth {
    CLLayoutPlan plan = [self cl_layoutPlan];
    return (plan.playerArea == CLLayoutPlayerAreaLeadingColumn) ? plan.playerWidth : 0.0;
}

- (CGFloat)playerStripHeight {
    CLLayoutPlan plan = [self cl_layoutPlan];
    return (plan.playerArea == CLLayoutPlayerAreaBottomStrip) ? plan.playerHeight : 0.0;
}

/// Whether this screen may drive the host's layout at all: the hooks are in, it is one of the
/// apps lyrics are on for, and its app is the one playing (otherwise a split or a strip would sit
/// beside nothing, or beside another app's lyrics). The safe area is not part of this answer —
/// CLLayoutPlanMake handles an empty one itself.
- (BOOL)cl_hostLayoutUsable {
    if (!_attached || !_prefEnabled || !sHostColumnHooksInstalled) return NO;
    UIViewController *viewController = _viewController;
    if (!viewController.viewIfLoaded) return NO;
    NSString *bundleIdentifier = CLScreenBundleIdentifier(viewController);
    if (![CLLyricsController.sharedController isBundleEnabled:bundleIdentifier]) return NO;
    return [self cl_screenMatchesNowPlaying];
}

/// The effective mode for this screen and what it asks of the host (UI/CLLayoutGeometry.h): a
/// player column, a bottom strip without artwork, or nothing. A pure function of the preferences,
/// the screen and what is playing, so the recalculation hooks and every layout pass agree without
/// sharing state — and the settings preview computes the same thing.
- (CLLayoutPlan)cl_layoutPlan {
    UIViewController *viewController = _viewController;
    UIView *root = viewController.viewIfLoaded;
    CGRect safe = root ? root.safeAreaLayoutGuide.layoutFrame : CGRectZero;
    CLLayoutPlan plan = CLLayoutPlanMake(_lyricsMode, safe, CLSideArtworkMinAspectRatio(), [self cl_hostLayoutUsable]);
    return CLLayoutPlanPlacingLyrics(plan, _lyricsSide);
}

/// The override the host should lay out for right now, or nil when it should be left alone (or
/// when any dimension it would be handed is not positive).
- (CLHostLayoutOverride *)cl_hostLayoutOverrideForRoot:(UIView *)root {
    if (!root) return nil;
    CLLayoutPlan plan = [self cl_layoutPlan];
    if (plan.playerArea == CLLayoutPlayerAreaNone) return nil;
    // Same coordinate spaces the host uses: viewArea is the controller view's frame, safeArea its
    // safe-area layout frame.
    CGRect safe = root.safeAreaLayoutGuide.layoutFrame;
    CGRect frame = root.frame;
    CGRect areaSafe = CGRectZero, areaView = CGRectZero;
    if (plan.playerArea == CLLayoutPlayerAreaLeadingColumn) {
        // The player column starts at the safe area's leading edge, full height, and its shape
        // alone decides stacked vs. side layout (CLLayoutPlayerColumnWidth). The view area is only
        // data for the host's size rules; its height is trimmed where the full height would give
        // the column bigger transport buttons than the whole screen gets (36 -> 44 on 1920x720 @3x).
        CGFloat viewHeight = CLLayoutPlayerViewAreaHeight(frame.size, plan.playerWidth, CGRectGetHeight(safe),
                                                          root.traitCollection.displayScale);
        areaSafe = CLLayoutPlayerRect(plan, safe);        // leading, or trailing with the lyrics on the left
        areaView = CGRectMake(CGRectGetMinX(frame) + CGRectGetMinX(areaSafe), CGRectGetMinY(frame),
                              plan.playerWidth, viewHeight);
    } else {
        // The bottom strip spans the safe area's width; its view area runs on down through the
        // bottom safe-area inset, like the host's own full-screen view area does.
        CGFloat height = plan.playerHeight;
        areaSafe = CGRectMake(CGRectGetMinX(safe), CGRectGetMaxY(safe) - height, CGRectGetWidth(safe), height);
        areaView = CGRectMake(CGRectGetMinX(frame) + CGRectGetMinX(safe),
                              CGRectGetMinY(frame) + CGRectGetMaxY(safe) - height,
                              CGRectGetWidth(safe), height + MAX(0.0, CGRectGetHeight(frame) - CGRectGetMaxY(safe)));
    }
    if (CGRectGetWidth(areaSafe) < 1.0 || CGRectGetHeight(areaSafe) < 1.0 ||
        CGRectGetWidth(areaView) < 1.0 || CGRectGetHeight(areaView) < 1.0) {
        return nil;
    }
    return [[CLHostLayoutOverride alloc] initWithPlayerArea:plan.playerArea
                                                   viewArea:areaView
                                                   safeArea:areaSafe
                                               hidesArtwork:plan.hidesArtwork
                                             onTrailingEdge:plan.playerOnTrailing];
}

static BOOL CLHostLayoutOverridesEqual(CLHostLayoutOverride *a, CLHostLayoutOverride *b) {
    if (a == b) return YES;
    if (!a || !b) return NO;
    return a.playerArea == b.playerArea && a.hidesArtwork == b.hidesArtwork && a.onTrailingEdge == b.onTrailingEdge &&
           (!a.hasPlayerArea || (CGRectEqualToRect(a.viewArea, b.viewArea) && CGRectEqualToRect(a.safeArea, b.safeArea)));
}

/// YES when the app playing system-wide is this Now Playing screen's app, or when either is not
/// known yet (nothing has played, or the host never set _bundleIdentifier): then there is nothing
/// to contradict, and the screen behaves as it did before playback was known.
- (BOOL)cl_screenMatchesNowPlaying {
    NSString *screen = CLScreenBundleIdentifier(_viewController);
    NSString *playing = CLLyricsController.sharedController.currentState.bundleIdentifier;
    if (screen.length == 0 || playing.length == 0) return YES;
    return [screen isEqualToString:playing];
}

- (void)cl_updateEffectiveMode {
    _screenMatchedNowPlaying = [self cl_screenMatchesNowPlaying];
    _effectiveMode = [self cl_layoutPlan].effectiveMode;
}

+ (void)hostPlayModeRowDidChangeForViewController:(UIViewController *)viewController {
    if (!NSThread.isMainThread) return;
    CLLayoutCustomizer *customizer = [self customizerForViewController:viewController create:NO];
    // Inside our own pass the row is handled anyway; outside it the host just re-added Spotify's
    // buttons after the microphone (-setMediaButtons: appends), so put it back at the end.
    if (!customizer || !customizer->_attached || customizer->_applying) return;
    [customizer cl_applyMicrophoneButton];
}

+ (void)hostPlayModesDidUpdateForViewController:(UIViewController *)viewController {
    if (!NSThread.isMainThread) return;
    CLLayoutCustomizer *customizer = [self customizerForViewController:viewController create:NO];
    if (!customizer || !customizer->_attached || customizer->_applying || customizer->_recomputingPlayModes) return;
    // The host just showed or hid its play-mode buttons by its own rules.
    customizer->_rateButtonHiddenByUs = NO;
    [customizer cl_applyPlaybackRateButton];
}

+ (void)hostTransportDidUpdateForViewController:(UIViewController *)viewController {
    if (!NSThread.isMainThread) return;
    CLLayoutCustomizer *customizer = [self customizerForViewController:viewController create:NO];
    [customizer cl_syncFullScreenTransport];
}

+ (NSArray<id<UIFocusEnvironment>> *)focusEnvironmentsForViewController:(UIViewController *)viewController {
    if (!NSThread.isMainThread) return nil;
    CLLayoutCustomizer *customizer = [self customizerForViewController:viewController create:NO];
    CLLyricsFullScreenView *view = customizer->_fullScreenView;
    if (!customizer->_fullScreen || !view.window || view.isHidden) return nil;
    return view.preferredFocusEnvironments;
}

+ (void)hostWillRecalculateLayoutForViewController:(UIViewController *)viewController {
    if (!NSThread.isMainThread || ![viewController isKindOfClass:UIViewController.class]) return;
    UIView *nowPlayingView = CLViewOrNil(CLIvar(viewController, @"_nowPlayingView"));
    if (!nowPlayingView) return;
    CLLayoutCustomizer *customizer = [self customizerForViewController:viewController create:NO];
    // nil without a customizer: the host lays out for the whole screen.
    CLSetHostLayoutOverride(nowPlayingView, [customizer cl_hostLayoutOverrideForRoot:viewController.viewIfLoaded]);
}

+ (void)hostDidRecalculateLayoutForViewController:(UIViewController *)viewController {
    if (!NSThread.isMainThread || ![viewController isKindOfClass:UIViewController.class]) return;
    CLLayoutCustomizer *customizer = [self customizerForViewController:viewController create:NO];
    [customizer cl_applyPlayerAreaSizeConstraints];
    [customizer cl_logHostLayoutIfChanged];
}

/// One debug line whenever the host's layout choice changes: which layout class it picked, with or
/// without artwork, for which area, which title tier and button size it chose, and how many spacer
/// guides it built. This is the line to look for when a layout "still looks like the stock
/// screen" in the car. Expected on an 800x480 unit in the full panel, then on a 1920x720 @3x unit
/// (safe area 595x196 at {45, 44}) in the full panel and side by side:
///   CPUINowPlayingLayoutStacked art=0 brickHidden=1 area={{0, 280}, {800, 200}} artworkOff=1 tier=0 buttons=36 guides=3 mode=5
///   CPUINowPlayingLayoutStacked art=0 brickHidden=1 area={{45, 44}, {240, 196}} artworkOff=1 tier=0 buttons=36 guides=3 mode=5
///   CPUINowPlayingLayoutLeftArtwork art=1 brickHidden=0 area={{45, 44}, {285, 196}} artworkOff=0 tier=0 buttons=36 guides=4 mode=4
- (void)cl_logHostLayoutIfChanged {
    if (!CLLogDebugEnabled()) return;
    UIViewController *viewController = _viewController;
    UIView *nowPlayingView = CLViewOrNil(CLIvar(viewController, @"_nowPlayingView"));
    if (!nowPlayingView) return;
    id layout = CLIvar(nowPlayingView, @"_nowPlayingLayout");
    NSNumber *showsArtwork = CLNumberForGetter(layout, @"showsArtwork");
    NSNumber *tier = CLNumberForGetter(layout, @"trackInfoFontStyle");
    NSNumber *buttons = CLNumberForGetter(layout, @"transportControlButtonHeight");
    UIView *brick = _artworkBrick;
    CLHostLayoutOverride *override = CLHostLayoutOverrideFor(nowPlayingView);
    NSString *signature = [NSString stringWithFormat:@"%@ art=%@ brickHidden=%d area=%@ artworkOff=%d tier=%@ buttons=%@ guides=%lu mode=%ld",
                           layout ? NSStringFromClass([layout class]) : @"(no layout)",
                           showsArtwork ? showsArtwork.stringValue : @"?", brick.isHidden,
                           override.hasPlayerArea ? NSStringFromCGRect(override.safeArea) : @"screen",
                           override.hidesArtwork, tier ? tier.stringValue : @"?",
                           buttons ? [NSString stringWithFormat:@"%.0f", buttons.doubleValue] : @"?",
                           (unsigned long)CLHostSpacerGuideCount(nowPlayingView), (long)_effectiveMode];
    if ([signature isEqualToString:_hostLayoutSignature]) return;
    _hostLayoutSignature = signature;
    CLLogDebug(@"[ui] host layout: %@", signature);
}

/// Right after the host rebuilt _nowPlayingSizeConstraints for the whole screen: take them down
/// and pin its Now Playing view to the player area instead — the column (top/bottom like the
/// host's, leading, plus a width) or the bottom strip (top at the safe area's bottom minus the
/// strip height, bottom like the host's, leading, plus a width). The new array goes back into
/// the host's ivar, so its next recalculation deactivates ours exactly like it deactivates its
/// own — one set of size constraints is active at any time, and leaving a mode needs no cleanup
/// here. Invariant either way: one width constraint and one edge pin (leading, or trailing for a
/// column at the trailing edge), never both.
- (void)cl_applyPlayerAreaSizeConstraints {
    UIViewController *viewController = _viewController;
    UIView *root = viewController.viewIfLoaded;
    UIView *nowPlayingView = CLViewOrNil(CLIvar(viewController, @"_nowPlayingView"));
    CGRect viewArea = CGRectZero, safeArea = CGRectZero;
    if (!root || nowPlayingView.superview != root ||
        !CLPlayerColumnRects(nowPlayingView, &viewArea, &safeArea)) {
        _playerAreaSizeConstraints = nil;
        return;
    }
    id current = CLIvar(viewController, @"_nowPlayingSizeConstraints");
    // The host only rebuilds them when it ran its own recalculation; still ours means no swap.
    if (current != nil && current == _playerAreaSizeConstraints) return;
    SEL setter = NSSelectorFromString(@"setNowPlayingSizeConstraints:");
    if (![viewController respondsToSelector:setter]) return;

    if ([current isKindOfClass:NSArray.class]) {
        NSMutableArray<NSLayoutConstraint *> *hostConstraints = [NSMutableArray array];
        for (id constraint in (NSArray *)current) {
            if ([constraint isKindOfClass:NSLayoutConstraint.class]) [hostConstraints addObject:constraint];
        }
        [NSLayoutConstraint deactivateConstraints:hostConstraints];
    }
    CLHostLayoutOverride *override = CLHostLayoutOverrideFor(nowPlayingView);
    BOOL strip = (override.playerArea == CLLayoutPlayerAreaBottomStrip);
    UILayoutGuide *safe = root.safeAreaLayoutGuide;
    NSLayoutConstraint *top = strip
        ? [nowPlayingView.topAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-CGRectGetHeight(safeArea)]
        : [nowPlayingView.topAnchor constraintEqualToAnchor:root.topAnchor];
    // The column's own edge of the safe area: leading, or trailing with the lyrics on the left.
    NSLayoutConstraint *edge = override.onTrailingEdge
        ? [nowPlayingView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor]
        : [nowPlayingView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor];
    NSArray<NSLayoutConstraint *> *area = @[
        top,
        [nowPlayingView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        edge,
        [nowPlayingView.widthAnchor constraintEqualToConstant:CGRectGetWidth(safeArea)],
    ];
    [NSLayoutConstraint activateConstraints:area];
    ((void (*)(id, SEL, id))objc_msgSend)(viewController, setter, area);
    _playerAreaSizeConstraints = area;

    if (!_loggedPlayerArea) {
        _loggedPlayerArea = YES;
        CLLogDebug(@"[ui] host player area %.0fx%.0f at %@%@, safe area %@, view area %@",
                   CGRectGetWidth(safeArea), CGRectGetHeight(safeArea), strip ? @"bottom" : @"leading",
                   override.hidesArtwork ? @" without artwork" : @"",
                   NSStringFromCGRect(safe.layoutFrame), NSStringFromCGRect(viewArea));
    }
}

/// The override is applied inside the host's own recalculation (see the hooks), so entering or
/// leaving a mode — a preference change, or the first attach — needs one host layout pass rather
/// than any change made here. Deliberately not called from -relayout: a host that never ran its
/// recalculation would leave this stale forever and turn it into a layout loop.
- (void)cl_requestHostColumnPassIfStale {
    UIViewController *viewController = _viewController;
    UIView *root = viewController.viewIfLoaded;
    UIView *nowPlayingView = CLViewOrNil(CLIvar(viewController, @"_nowPlayingView"));
    if (!nowPlayingView) return;
    CLHostLayoutOverride *current = CLHostLayoutOverrideFor(nowPlayingView);
    CLHostLayoutOverride *wanted = [self cl_hostLayoutOverrideForRoot:root];
    if (CLHostLayoutOverridesEqual(current, wanted)) return;
    [self cl_clearColumnIfUnused];
    [root setNeedsLayout];
}

/// Clears the override when the host should be left alone again. The host's next recalculation
/// then lays the Now Playing view out for the whole screen and replaces our size constraints on
/// its own.
- (void)cl_clearColumnIfUnused {
    UIViewController *viewController = _viewController;
    if ([self cl_hostLayoutOverrideForRoot:viewController.viewIfLoaded]) return;
    UIView *nowPlayingView = CLViewOrNil(CLIvar(viewController, @"_nowPlayingView"));
    CLSetHostLayoutOverride(nowPlayingView, nil);
    _playerAreaSizeConstraints = nil;
}

- (void)cl_teardownColumn {
    UIViewController *viewController = _viewController;
    UIView *nowPlayingView = CLViewOrNil(CLIvar(viewController, @"_nowPlayingView"));
    BOOL hadOverride = CLHostLayoutOverrideFor(nowPlayingView) != nil || _playerAreaSizeConstraints != nil;
    CLSetHostLayoutOverride(nowPlayingView, nil);
    _playerAreaSizeConstraints = nil;
    _loggedPlayerArea = NO;
    _hostLayoutSignature = nil;
    if (hadOverride) [viewController.viewIfLoaded setNeedsLayout];
}

@end
