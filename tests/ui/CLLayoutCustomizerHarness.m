// CLLayoutCustomizerHarness.m — the only coverage Tweak/UI has. Not part of the tweak, and
// deliberately NOT part of the cltests target (see the warning below).
//
// It declares fake CPUINowPlayingView / CPUINowPlayingViewController classes carrying the *real*
// private ivar names, so CLLayoutCustomizer's ivar resolution, placement, pref application,
// pause/resume, host-restore and the host-driven layouts (the side-by-side column and the full
// panel's bottom strip) all run with no car, no CarPlayUI and no Theos. The `hostChain` variant
// of the fake controller lays its Now Playing view out the way CarPlayUI 17.3 does (the numbers
// in docs/research/CarPlayUI-17.3-layout.md, through UI/CLLayoutGeometry.h), so the tier and
// button-size thresholds the full panel relies on are exercised here.
//
//   Run it:  scripts/test-mac.sh   (or bash tests/ui/run.sh on the phone)
//
// It writes preferences, so it must never write the real `com.andi.carly` domain:
// that would wipe a configured install's settings. CLPrefsActiveDomain() (CARLY_PREFS_DOMAIN,
// the CFPreferences counterpart of CLLyricsCache's CARLY_CACHE_DIR) is pointed at a scratch
// domain by the runner scripts and deleted afterwards, and everything here writes whatever
// CLPrefsActiveDomain() resolves to.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "UI/CLLyricsFullScreenView.h"
#import "UI/CLLyricsPanelView.h"
#import "UI/CLLayoutCustomizer.h"
#import "UI/CLLayoutGeometry.h"
#import "UI/CLLyricsStyle.h"
#import "Util/CLPrefs.h"
#import "Util/CLPrefsKeys.h"
#import "Lyrics/CLLyricsTypes.h"
#import "Core/CLLyricsController.h"
#import "Core/CLPlaybackState.h"

static int gPass = 0, gFail = 0;
#define EXPECT(cond, fmt, ...) do { \
    if (cond) { gPass++; } else { gFail++; printf("FAIL line %d: " fmt "\n", __LINE__, ##__VA_ARGS__); } \
} while (0)

static UIImage *TestArtworkForward(void);

#pragma mark - Fake host

/// Stands in for the two NowPlayingHooks.x side-by-side hooks, which are not linked into the
/// harness: when YES the fake host calls CLLayoutCustomizer around its recalculation and lays its
/// Now Playing view out for the player-area rects, exactly where the real hooks do.
static BOOL gSimulateColumnHooks = NO;
/// The display scale the fake host sizes its transport buttons with (the real host uses the CarPlay
/// screen's). @2x everywhere except the 1920x720 @3x test.
static CGFloat gHostDisplayScale = 2.0;
/// Whether the fake app offers playback rates (a podcast): -_updatePlayModesState shows "1×" then.
static BOOL gRateSupported = NO;
/// Stands in for CLRequestRelayout's re-entrancy guard in the controller hook.
static BOOL gInRelayout = NO;

/// CarPlayUI's play-mode row, as far as the customizer's microphone relies on it (verified on
/// iOS 17.3): a UIStackView of buttons anchored by centre x and bottom, and -_updateButtonLayouts,
/// which gives every visible arranged subview width == 44 and height == 26 and the stack
/// count x 44 + (count - 1) x 16. Starts with Spotify's four buttons.
@interface CPUIPlayModeControlView : UIView {
@public
    UIStackView *_stackView;
    UIButton *_playbackRateButton;       // the host's "1×": in the row, hidden unless the app has rates
    NSArray<NSLayoutConstraint *> *_activeButtonLayoutConstraints;
    NSUInteger _layoutUpdates;
}
- (UIStackView *)stackView;
- (void)_updateButtonLayouts;
@end

@implementation CPUIPlayModeControlView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _stackView = [[UIStackView alloc] initWithFrame:CGRectZero];
        _stackView.translatesAutoresizingMaskIntoConstraints = NO;
        _stackView.axis = UILayoutConstraintAxisHorizontal;
        _stackView.distribution = UIStackViewDistributionEqualSpacing;
        _stackView.alignment = UIStackViewAlignmentCenter;
        [self addSubview:_stackView];
        [NSLayoutConstraint activateConstraints:@[
            [_stackView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_stackView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];
        for (NSInteger i = 0; i < 4; i++) [_stackView addArrangedSubview:[UIButton buttonWithType:UIButtonTypeSystem]];
        _playbackRateButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _playbackRateButton.hidden = YES;
        [_stackView addArrangedSubview:_playbackRateButton];
        [self _updateButtonLayouts];
    }
    return self;
}
- (UIStackView *)stackView { return _stackView; }
- (void)layoutSubviews { [super layoutSubviews]; [self _updateButtonLayouts]; }
- (void)_updateButtonLayouts {
    _layoutUpdates++;
    if (_activeButtonLayoutConstraints.count) [NSLayoutConstraint deactivateConstraints:_activeButtonLayoutConstraints];
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray array];
    NSUInteger visible = 0;
    for (UIView *button in _stackView.arrangedSubviews) {
        if (button.isHidden) continue;
        visible++;
        [constraints addObject:[button.widthAnchor constraintEqualToConstant:44.0]];
        [constraints addObject:[button.heightAnchor constraintEqualToConstant:26.0]];
    }
    CGFloat width = visible * 44.0 + (visible ? visible - 1 : 0) * 16.0;
    [constraints addObject:[_stackView.widthAnchor constraintEqualToConstant:width]];
    [NSLayoutConstraint activateConstraints:constraints];
    _activeButtonLayoutConstraints = constraints;
}
@end

@interface CPUINowPlayingView : UIView {
@public
    CGRect _lastViewArea;      // what the last recalculation was told to lay out for
    CGRect _lastSafeArea;
    BOOL _lastHidesArtwork;    // ...and whether it was told to leave the artwork out
    CGFloat _lastTransportHeight;   // hostChain only: what the host's thresholds picked for it
    BOOL _lastTitleLarge;
    NSUInteger _recalculations;
    NSArray<UILayoutGuide *> *_verticalSpacerLayoutGuides;   // hostChain only, like the real view
    NSArray<NSLayoutConstraint *> *_chainConstraints;
    BOOL _chainBuilt;
    CGRect _chainSafeArea;
    CGRect _chainViewArea;
    BOOL _chainWithoutArtwork;
    UIView *_songDetailsView;
    UIView *_progressView;
    UIView *_transportControlView;
    UIView *_playModeControlView;
    UIView *_artworkViewBrick;
    NSLayoutConstraint *_songDetailsViewHeightConstraint;
}
@end
@implementation CPUINowPlayingView
@end

@interface CPUINowPlayingViewController : UIViewController {
@public
    NSString *_bundleIdentifier;
    NSArray<NSLayoutConstraint *> *_nowPlayingSizeConstraints;
    UIView *_nowPlayingView;
    /// The full-bleed background artwork under everything, and the blur over it — what the real
    /// controller installs in -viewDidLoad. Not the artwork square (that is npv->_artworkViewBrick).
    UIImageView *_artworkView;
    UIVisualEffectView *_artworkVisualEffectView;
    UIImage *_artworkImage;
    UIBarButtonItem *_playbackQueueBarButtonItem;
    UIBarButtonItem *_rightTitleLabelBarButtonItem;
}
@property (nonatomic) BOOL barren;   // build nothing: exercises the "no anchors" fallback
/// Lay the Now Playing view out the way CarPlayUI 17.3 does (docs/research, through the constants
/// and threshold functions in UI/CLLayoutGeometry.h): margins 2/27/12; song details pinned to the
/// tier's height (72 small / 106 large, from the title area the safe area leaves); three spacer
/// guides >= 8 and all as tall as the first; transport at the button height the view area's
/// scaled size picks (36 / 44); progress 10; play-mode row 26; artwork above it all unless the
/// layout has none. Rebuilt, with new guides, whenever the safe rect, view rect or artwork flag
/// differs from the last build — the host's own -[_CPUINowPlayingLayout isEqual:] rule.
@property (nonatomic) BOOL hostChain;
/// hostChain: the artwork square's side, in points (the real host derives it from the view area).
@property (nonatomic) CGFloat hostChainArtSide;
@property (nonatomic, copy) NSArray<NSLayoutConstraint *> *nowPlayingSizeConstraints;
- (void)_updatePlayModesState;
@end

@implementation CPUINowPlayingViewController

@synthesize nowPlayingSizeConstraints = _nowPlayingSizeConstraints;

- (instancetype)initWithNibName:(NSString *)nibName bundle:(NSBundle *)bundle {
    self = [super initWithNibName:nibName bundle:bundle];
    if (self) _hostChainArtSide = 100.0;
    return self;
}

/// What CarPlayUI 17.3 does on every layout pass (docs/research/CarPlayUI-17.3-layout.md): hand
/// the Now Playing view the controller view's frame and safe area, then throw away and rebuild
/// the size constraints that pin it across the whole safe area.
/// -[CPUINowPlayingViewController _updatePlayModesState] as far as the speed button goes (verified,
/// iOS 17.3): shown iff the app can change the rate, then the row laid out; the hook follows.
- (void)_updatePlayModesState {
    CPUINowPlayingView *npv = (CPUINowPlayingView *)_nowPlayingView;
    if (![npv->_playModeControlView isKindOfClass:CPUIPlayModeControlView.class]) return;
    CPUIPlayModeControlView *playMode = (CPUIPlayModeControlView *)npv->_playModeControlView;
    playMode->_playbackRateButton.hidden = !gRateSupported;
    [playMode layoutSubviews];
    if (gSimulateColumnHooks) [CLLayoutCustomizer hostPlayModesDidUpdateForViewController:self];
}

- (void)_recalculateLayout:(BOOL)force {
    CPUINowPlayingView *npv = (CPUINowPlayingView *)_nowPlayingView;
    if (!npv) return;
    if (gSimulateColumnHooks) [CLLayoutCustomizer hostWillRecalculateLayoutForViewController:self];

    CGRect viewArea = self.view.frame;
    CGRect safeArea = self.view.safeAreaLayoutGuide.layoutFrame;
    if (gSimulateColumnHooks) CLPlayerColumnRects(npv, &viewArea, &safeArea);   // the view hook
    BOOL hidesArtwork = gSimulateColumnHooks && CLHostLayoutHidesArtwork(npv);
    npv->_lastViewArea = viewArea;
    npv->_lastSafeArea = safeArea;
    npv->_lastHidesArtwork = hidesArtwork;
    npv->_recalculations++;
    if (self.hostChain && (!npv->_chainBuilt || npv->_chainWithoutArtwork != hidesArtwork ||
                           !CGRectEqualToRect(npv->_chainSafeArea, safeArea) ||
                           !CGRectEqualToRect(npv->_chainViewArea, viewArea))) {
        [self cl_buildHostChainForSafeArea:safeArea viewArea:viewArea withoutArtwork:hidesArtwork];
    }

    if (_nowPlayingSizeConstraints.count) [NSLayoutConstraint deactivateConstraints:_nowPlayingSizeConstraints];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    _nowPlayingSizeConstraints = @[
        [npv.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [npv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [npv.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [npv.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
    ];
    [NSLayoutConstraint activateConstraints:_nowPlayingSizeConstraints];

    if (gSimulateColumnHooks) [CLLayoutCustomizer hostDidRecalculateLayoutForViewController:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self _recalculateLayout:NO];
    // The controller hook's CLRequestRelayout: the customizer re-places itself on every one of
    // the host's layout passes, behind the same re-entrancy guard.
    if (gInRelayout) return;
    CLLayoutCustomizer *customizer = [CLLayoutCustomizer customizerForViewController:self create:NO];
    if (!customizer) return;
    gInRelayout = YES;
    [customizer relayout];
    gInRelayout = NO;
}

- (void)cl_buildHostChainForSafeArea:(CGRect)safeArea viewArea:(CGRect)viewArea withoutArtwork:(BOOL)withoutArtwork {
    CPUINowPlayingView *npv = (CPUINowPlayingView *)_nowPlayingView;
    if (npv->_chainConstraints.count) [NSLayoutConstraint deactivateConstraints:npv->_chainConstraints];
    for (UILayoutGuide *guide in npv->_verticalSpacerLayoutGuides) [npv removeLayoutGuide:guide];

    UIView *details = npv->_songDetailsView, *transport = npv->_transportControlView;
    UIView *progress = npv->_progressView, *playMode = npv->_playModeControlView, *art = npv->_artworkViewBrick;
    BOOL showsArtwork = !withoutArtwork;
    art.hidden = withoutArtwork;

    CGFloat artSide = self.hostChainArtSide;
    CGFloat transportHeight = CLLayoutHostTransportButtonHeight(viewArea.size, gHostDisplayScale);
    BOOL large = CLLayoutHostUsesLargeTier(CLLayoutHostTitleAreaSize(safeArea, showsArtwork, artSide, transportHeight));
    CGFloat detailsHeight = large ? CLLayoutHostDetailsHeightLarge : CLLayoutHostDetailsHeightSmall;
    npv->_lastTransportHeight = transportHeight;
    npv->_lastTitleLarge = large;

    // Stacked (art above the chain), or — when the area is wide enough for the host's side layout
    // — the art on the left with the chain beside it, so the vertical chain always fits the areas
    // the tests use, as it does in the real host.
    BOOL sideLayout = showsArtwork && !CLLayoutHostStacksSafeArea(safeArea, CLLayoutDefaultSideArtworkRatio);
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray array];
    NSLayoutXAxisAnchor *chainLeading = npv.leadingAnchor;
    CGFloat chainLeadingInset = CLLayoutHostMarginSide;
    if (showsArtwork) {
        CGFloat side = sideLayout ? MIN(artSide, CGRectGetHeight(safeArea) - CLLayoutHostMarginTop - CLLayoutHostMarginBottom) : artSide;
        [constraints addObjectsFromArray:@[
            [art.widthAnchor constraintEqualToConstant:side],
            [art.heightAnchor constraintEqualToConstant:side],
        ]];
        if (sideLayout) {
            [constraints addObjectsFromArray:@[
                [art.leadingAnchor constraintEqualToAnchor:npv.leadingAnchor constant:CLLayoutHostMarginSide],
                [art.centerYAnchor constraintEqualToAnchor:npv.centerYAnchor],
                [details.topAnchor constraintEqualToAnchor:npv.topAnchor constant:CLLayoutHostMarginTop],
            ]];
            chainLeading = art.trailingAnchor;
        } else {
            [constraints addObjectsFromArray:@[
                [art.topAnchor constraintEqualToAnchor:npv.topAnchor constant:CLLayoutHostMarginTop],
                [art.centerXAnchor constraintEqualToAnchor:npv.centerXAnchor],
                [details.topAnchor constraintEqualToAnchor:art.bottomAnchor constant:CLLayoutHostMinimumSpacer],
            ]];
        }
    } else {
        [constraints addObject:[details.topAnchor constraintEqualToAnchor:npv.topAnchor constant:CLLayoutHostMarginTop]];
    }
    for (UIView *view in @[ details, transport, progress, playMode ]) {
        [constraints addObject:[view.leadingAnchor constraintEqualToAnchor:chainLeading constant:chainLeadingInset]];
        [constraints addObject:[npv.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:CLLayoutHostMarginSide]];
    }
    // The real host installs both `height >= maximum` and `height == maximum` for the tier.
    NSLayoutConstraint *detailsHeightConstraint = [details.heightAnchor constraintEqualToConstant:detailsHeight];
    npv->_songDetailsViewHeightConstraint = detailsHeightConstraint;
    [constraints addObjectsFromArray:@[
        [details.heightAnchor constraintGreaterThanOrEqualToConstant:detailsHeight], detailsHeightConstraint,
        [transport.heightAnchor constraintEqualToConstant:transportHeight],
        [progress.heightAnchor constraintEqualToConstant:CLLayoutHostProgressHeight],
        [playMode.heightAnchor constraintEqualToConstant:CLLayoutHostPlayModeHeight],
        [npv.bottomAnchor constraintEqualToAnchor:playMode.bottomAnchor constant:CLLayoutHostMarginBottom],
    ]];
    NSArray<UIView *> *chain = @[ details, transport, progress, playMode ];
    NSMutableArray<UILayoutGuide *> *guides = [NSMutableArray array];
    for (NSUInteger i = 0; i + 1 < chain.count; i++) {
        UILayoutGuide *guide = [UILayoutGuide new];
        [npv addLayoutGuide:guide];
        [guides addObject:guide];
        [constraints addObjectsFromArray:@[
            [guide.topAnchor constraintEqualToAnchor:chain[i].bottomAnchor],
            [chain[i + 1].topAnchor constraintEqualToAnchor:guide.bottomAnchor],
            [guide.heightAnchor constraintGreaterThanOrEqualToConstant:CLLayoutHostMinimumSpacer],
        ]];
        if (i > 0) [constraints addObject:[guide.heightAnchor constraintEqualToAnchor:guides[0].heightAnchor]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
    npv->_chainConstraints = constraints;
    npv->_verticalSpacerLayoutGuides = guides;
    npv->_chainBuilt = YES;
    npv->_chainSafeArea = safeArea;
    npv->_chainViewArea = viewArea;
    npv->_chainWithoutArtwork = withoutArtwork;
}

- (void)cl_installBackgroundArtwork {
    // What the real -viewDidLoad does: an aspect-fill image view pinned across the whole view,
    // below everything, with a blur effect view over it.
    _artworkView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _artworkView.translatesAutoresizingMaskIntoConstraints = NO;
    _artworkView.contentMode = UIViewContentModeScaleAspectFill;
    [self.view insertSubview:_artworkView atIndex:0];
    _artworkVisualEffectView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    _artworkVisualEffectView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view insertSubview:_artworkVisualEffectView atIndex:1];
    for (UIView *view in @[ _artworkView, _artworkVisualEffectView ]) {
        [NSLayoutConstraint activateConstraints:@[
            [view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
            [view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        ]];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.frame = CGRectMake(0, 0, 800, 480);
    self.view.backgroundColor = UIColor.blackColor;
    _bundleIdentifier = @"com.spotify.client";
    if (self.barren) return;
    if (self.hostChain) {
        CPUINowPlayingView *npv = [[CPUINowPlayingView alloc] initWithFrame:self.view.bounds];
        npv.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:npv];
        _nowPlayingView = npv;
        UIView *details = [UIView new];
        UILabel *title = [UILabel new];
        title.text = @"Song Title";
        [details addSubview:title];
        npv->_songDetailsView = details;
        npv->_transportControlView = [UIView new];
        npv->_progressView = [UIView new];
        npv->_playModeControlView = [[CPUIPlayModeControlView alloc] initWithFrame:CGRectZero];
        npv->_artworkViewBrick = [[UIImageView alloc] initWithImage:TestArtworkForward()];
        for (UIView *view in @[ details, npv->_transportControlView, npv->_progressView,
                                npv->_playModeControlView, npv->_artworkViewBrick ]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [npv addSubview:view];
        }
        [self cl_installBackgroundArtwork];
        [self _recalculateLayout:YES];
        return;
    }

    CPUINowPlayingView *npv = [[CPUINowPlayingView alloc] initWithFrame:self.view.bounds];
    npv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:npv];
    _nowPlayingView = npv;
    [self cl_installBackgroundArtwork];

    UIView *details = [UIView new];
    details.translatesAutoresizingMaskIntoConstraints = NO;
    [npv addSubview:details];
    npv->_songDetailsView = details;

    NSArray<NSString *> *texts = @[ @"Song Title", @"Artist Name", @"Album Name" ];
    UIView *previous = nil;
    for (NSString *text in texts) {
        UILabel *label = [UILabel new];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.text = text;
        label.textColor = UIColor.whiteColor;
        [details addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:details.leadingAnchor],
            [label.topAnchor constraintEqualToAnchor:(previous ? previous.bottomAnchor : details.topAnchor)],
        ]];
        previous = label;
    }

    UIImageView *badge = [[UIImageView alloc] initWithFrame:CGRectZero];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.image = TestArtworkForward();
    [details addSubview:badge];
    [NSLayoutConstraint activateConstraints:@[
        [badge.trailingAnchor constraintEqualToAnchor:details.trailingAnchor],
        [badge.topAnchor constraintEqualToAnchor:details.topAnchor],
        [badge.widthAnchor constraintEqualToConstant:24.0],
        [badge.heightAnchor constraintEqualToConstant:24.0],
    ]];

    UIProgressView *progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    progress.translatesAutoresizingMaskIntoConstraints = NO;
    [npv addSubview:progress];
    npv->_progressView = progress;

    UIView *transport = [UIView new];
    transport.translatesAutoresizingMaskIntoConstraints = NO;
    [npv addSubview:transport];
    npv->_transportControlView = transport;

    // The artwork square, inside the Now Playing view like the real _artworkViewBrick.
    UIImageView *artwork = [[UIImageView alloc] initWithFrame:CGRectZero];
    artwork.translatesAutoresizingMaskIntoConstraints = NO;
    [npv addSubview:artwork];
    npv->_artworkViewBrick = artwork;

    NSLayoutConstraint *detailsHeight = [details.heightAnchor constraintEqualToConstant:100.0];
    npv->_songDetailsViewHeightConstraint = detailsHeight;

    [self _recalculateLayout:YES];   // the host pins its Now Playing view the same way
    [NSLayoutConstraint activateConstraints:@[
        [artwork.leadingAnchor constraintEqualToAnchor:npv.leadingAnchor constant:20.0],
        [artwork.topAnchor constraintEqualToAnchor:npv.topAnchor constant:20.0],
        [artwork.widthAnchor constraintEqualToConstant:300.0],
        [artwork.heightAnchor constraintEqualToConstant:300.0],

        [details.leadingAnchor constraintEqualToAnchor:artwork.trailingAnchor constant:20.0],
        [details.trailingAnchor constraintEqualToAnchor:npv.trailingAnchor constant:-20.0],
        [details.topAnchor constraintEqualToAnchor:npv.topAnchor constant:40.0],
        detailsHeight,

        [progress.leadingAnchor constraintEqualToAnchor:details.leadingAnchor],
        [progress.trailingAnchor constraintEqualToAnchor:details.trailingAnchor],
        [progress.bottomAnchor constraintEqualToAnchor:npv.bottomAnchor constant:-80.0],

        [transport.leadingAnchor constraintEqualToAnchor:npv.leadingAnchor],
        [transport.trailingAnchor constraintEqualToAnchor:npv.trailingAnchor],
        [transport.bottomAnchor constraintEqualToAnchor:npv.bottomAnchor],
        [transport.heightAnchor constraintEqualToConstant:60.0],
    ]];

    _playbackQueueBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Queue" style:UIBarButtonItemStylePlain target:nil action:NULL];
    _rightTitleLabelBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"1x" style:UIBarButtonItemStylePlain target:nil action:NULL];
    self.navigationItem.rightBarButtonItems = @[ _playbackQueueBarButtonItem, _rightTitleLabelBarButtonItem ];
}

@end

#pragma mark - Helpers

static UIImage *TestArtwork(void);
static UIImage *TestArtworkForward(void) { return TestArtwork(); }

static UIImage *TestArtwork(void) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(64, 64) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIColor colorWithRed:0.1 green:0.4 blue:0.9 alpha:1.0] setFill];
        UIRectFill(CGRectMake(0, 0, 64, 64));
    }];
}

static void CollectViews(UIView *root, Class cls, NSMutableArray *out) {
    for (UIView *sub in root.subviews) {
        if ([sub isKindOfClass:cls]) [out addObject:sub];
        CollectViews(sub, cls, out);
    }
}

static NSArray<UILabel *> *LabelsIn(UIView *root) {
    NSMutableArray *out = [NSMutableArray array];
    CollectViews(root, UILabel.class, out);
    return out;
}

/// The lyrics panels inside `root` (there must never be more than one).
static NSArray<CLLyricsPanelView *> *PanelsIn(UIView *root) {
    NSMutableArray *out = [NSMutableArray array];
    CollectViews(root, CLLyricsPanelView.class, out);
    return out;
}

/// Every view of ours inside `root`: the panels, plus anything else that is not UIKit's or the fake
/// host's. Used to prove that "no view other than one CLLyricsPanelView" is ever installed.
static NSUInteger ForeignViewCount(UIView *root) {
    NSMutableArray *all = [NSMutableArray array];
    CollectViews(root, UIView.class, all);
    NSUInteger count = 0;
    for (UIView *view in all) {
        NSString *name = NSStringFromClass(view.class);
        if ([name hasPrefix:@"CL"] && ![view isKindOfClass:CLLyricsPanelView.class]) count++;
    }
    return count;
}

/// The first lyric row label with text inside a panel's table, after a layout pass.
static UILabel *FirstRowLabel(CLLyricsPanelView *panel) {
    NSMutableArray *tables = [NSMutableArray array];
    CollectViews(panel, UITableView.class, tables);
    for (UILabel *label in LabelsIn(tables.firstObject)) {
        if (label.text.length) return label;
    }
    return nil;
}

/// A touch-up-inside on `control`: every target/action it registered, called directly. The harness
/// runs without a UIApplication, which -sendActionsForControlEvents: needs to deliver anything.
static void Tap(UIControl *control) {
    for (id target in control.allTargets) {
        for (NSString *action in [control actionsForTarget:target forControlEvent:UIControlEventTouchUpInside]) {
            ((void (*)(id, SEL, id))objc_msgSend)(target, NSSelectorFromString(action), control);
        }
    }
}

static CLLyrics *SyncedLyrics(void) {
    NSArray<CLLyricLine *> *lines = @[
        [CLLyricLine lineWithTime:0.0 text:@"first line"],
        [CLLyricLine lineWithTime:5.0 text:@"second line"],
        [CLLyricLine lineWithTime:10.0 text:@""],            // instrumental gap
        [CLLyricLine lineWithTime:15.0 text:@"fourth line"],
        [CLLyricLine lineWithTime:20.0 text:@""],            // Spotify's end marker
    ];
    return [CLLyrics syncedWithLines:lines source:@"test"];
}

static void SetPref(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)CLPrefsActiveDomain());
    CFPreferencesAppSynchronize((__bridge CFStringRef)CLPrefsActiveDomain());
    [CLPrefs.shared reloadNow];
}

static void ClearPref(NSString *key) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, (__bridge CFStringRef)CLPrefsActiveDomain());
    CFPreferencesAppSynchronize((__bridge CFStringRef)CLPrefsActiveDomain());
    [CLPrefs.shared reloadNow];
}

static void Pump(void) {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}

static void Layout(UIViewController *vc) {
    [vc.view setNeedsLayout];
    [vc.view layoutIfNeeded];
}

/// A view's frame in the controller view's coordinates.
static CGRect RootFrame(UIView *view, UIViewController *vc) {
    return [view.superview convertRect:view.frame toView:vc.view];
}

static BOOL RectNear(CGRect actual, CGRect expected) {
    return fabs(CGRectGetMinX(actual) - CGRectGetMinX(expected)) < 0.5 &&
           fabs(CGRectGetMinY(actual) - CGRectGetMinY(expected)) < 0.5 &&
           fabs(CGRectGetWidth(actual) - CGRectGetWidth(expected)) < 0.5 &&
           fabs(CGRectGetHeight(actual) - CGRectGetHeight(expected)) < 0.5;
}

#pragma mark - Tests

/// The two font-fit rules on a standalone panel, and the label inset both rules share.
static void TestPanelFit(void) {
    struct { CLLayoutPanelFit fit; CGFloat w, h, expected; } cases[] = {
        { CLLayoutPanelFitRows, 250, 250, 24 },
        { CLLayoutPanelFitRows, 216, 216, 24 },
        { CLLayoutPanelFitRows, 300, 80, 16 },
        { CLLayoutPanelFitColumn, 184, 196, 16 },
        { CLLayoutPanelFitColumn, 210, 180, 19 },
        { CLLayoutPanelFitColumn, 420, 420, 24 },
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        CLLyricsPanelView *panel = [[CLLyricsPanelView alloc] initWithFrame:CGRectMake(0, 0, cases[i].w, cases[i].h)];
        panel.fit = cases[i].fit;
        [panel setLyrics:SyncedLyrics()];
        [panel layoutIfNeeded];
        UILabel *row = FirstRowLabel(panel);
        EXPECT(row && fabs(row.font.pointSize - cases[i].expected) < 0.01,
               "panel fit %s %.0fx%.0f -> %.0f pt (got %.1f)", cases[i].fit == CLLayoutPanelFitRows ? "rows" : "column",
               cases[i].w, cases[i].h, cases[i].expected, row.font.pointSize);
        if (i == 0) {
            UIView *contentView = row.superview;
            EXPECT(fabs(CGRectGetMinX(row.frame) - CLLayoutPanelTextInset) < 0.5,
                   "row label leading inset is CLLayoutPanelTextInset (%.1f in %s)", CGRectGetMinX(row.frame),
                   NSStringFromClass(contentView.class).UTF8String);
        }
    }
    // Switching the rule on a live panel re-measures.
    CLLyricsPanelView *panel = [[CLLyricsPanelView alloc] initWithFrame:CGRectMake(0, 0, 184, 196)];
    [panel setLyrics:SyncedLyrics()];
    [panel layoutIfNeeded];
    EXPECT(fabs(FirstRowLabel(panel).font.pointSize - 16.0) < 0.01, "column rule by default (%.1f)", FirstRowLabel(panel).font.pointSize);
    panel.fit = CLLayoutPanelFitRows;
    [panel layoutIfNeeded];
    EXPECT(fabs(FirstRowLabel(panel).font.pointSize - 24.0) < 0.01, "rows rule after switching (%.1f)", FirstRowLabel(panel).font.pointSize);
}

/// Every row's text, straight from the panel's data source.
static NSArray<NSString *> *RowTexts(CLLyricsPanelView *panel) {
    NSMutableArray *tables = [NSMutableArray array];
    CollectViews(panel, UITableView.class, tables);
    UITableView *table = tables.firstObject;
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    NSInteger rows = [table numberOfRowsInSection:0];
    for (NSInteger row = 0; row < rows; row++) {
        UITableViewCell *cell = [table.dataSource tableView:table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
        NSString *text = @"";
        for (UILabel *label in LabelsIn(cell)) {
            if (label.text) text = label.text;
        }
        [texts addObject:text];
    }
    return texts;
}

/// Spotify writes "♪" as the words of an instrumental break; those are gaps like an empty line, so
/// "Show a Note During Gaps" decides whether any note shows (0.9.0, user report).
static void TestNoteLinesAreGaps(void) {
    CLLyrics *spotify = [CLLyrics syncedWithLines:@[
        [CLLyricLine lineWithTime:0.0 text:@"first line"],
        [CLLyricLine lineWithTime:4.0 text:@"♪"],
        [CLLyricLine lineWithTime:8.0 text:@" ♫ ♪ "],
        [CLLyricLine lineWithTime:12.0 text:@"🎵"],
        [CLLyricLine lineWithTime:16.0 text:@"♪ la la ♪"],   // words: a lyric, not a gap
        [CLLyricLine lineWithTime:20.0 text:@""],            // Spotify's end marker
    ] source:@"spotify"];
    CLLyrics *plain = [CLLyrics plainWithText:@"verse one\n♪\n\nverse two" source:@"spotify"];

    SetPref(CLPrefKeyLyricsShowNoteOnGap, @YES);
    CLLyricsPanelView *panel = [[CLLyricsPanelView alloc] initWithFrame:CGRectMake(0, 0, 400, 300)];
    [panel setLyrics:spotify];
    [panel layoutIfNeeded];
    NSArray *on = @[ @"first line", @"♪", @"♪", @"♪", @"♪ la la ♪", @"♪" ];
    EXPECT([RowTexts(panel) isEqualToArray:on], "note on: every gap shows one note (%s)",
           [RowTexts(panel) componentsJoinedByString:@"|"].UTF8String);

    SetPref(CLPrefKeyLyricsShowNoteOnGap, @NO);
    [panel applyPrefs];
    [panel layoutIfNeeded];
    NSArray *off = @[ @"first line", @"", @"", @"", @"♪ la la ♪", @"" ];
    EXPECT([RowTexts(panel) isEqualToArray:off], "note off: Spotify's notes are blank too (%s)",
           [RowTexts(panel) componentsJoinedByString:@"|"].UTF8String);

    [panel setLyrics:plain];
    [panel layoutIfNeeded];
    EXPECT([RowTexts(panel) isEqualToArray:(@[ @"verse one", @"", @"", @"verse two" ])],
           "note off, plain text: a line of notes is blank (%s)", [RowTexts(panel) componentsJoinedByString:@"|"].UTF8String);
    ClearPref(CLPrefKeyLyricsShowNoteOnGap);

    EXPECT(CLLyricsTextIsGap(nil) && CLLyricsTextIsGap(@"") && CLLyricsTextIsGap(@"♬") && CLLyricsTextIsGap(@"🎶️"),
           "empty and note-only text are gaps");
    EXPECT(!CLLyricsTextIsGap(@"la") && !CLLyricsTextIsGap(@"♪ oh"), "anything with a word is not a gap");
}

static void TestPanel(void) {
    CLLyricsPanelView *panel = [[CLLyricsPanelView alloc] initWithFrame:CGRectMake(0, 0, 400, 300)];
    EXPECT(!panel.hasVisibleContent, "fresh panel has no content");
    EXPECT(panel.fit == CLLayoutPanelFitColumn, "fresh panel uses the column rule");

    [panel setLyrics:SyncedLyrics()];
    [panel layoutIfNeeded];
    NSMutableArray *tables = [NSMutableArray array];
    CollectViews(panel, UITableView.class, tables);
    EXPECT(tables.count == 1, "panel owns exactly one table view");
    UITableView *table = tables.firstObject;
    EXPECT([table numberOfRowsInSection:0] == 5, "5 rows for 5 lines, got %ld", (long)[table numberOfRowsInSection:0]);

    [panel setCurrentLineIndex:3 animated:NO];
    [panel layoutIfNeeded];
    EXPECT(panel.currentLineIndex == 3, "current index tracked");
    EXPECT(table.contentInset.top > 100.0, "inset centres the first line (%.1f)", table.contentInset.top);

    // Out-of-range indexes must be harmless.
    [panel setCurrentLineIndex:999 animated:YES];
    [panel setCurrentLineIndex:-1 animated:YES];

    [panel setLyrics:[CLLyrics plainWithText:@"one\ntwo\nthree" source:@"test"]];
    [panel layoutIfNeeded];
    EXPECT([table numberOfRowsInSection:0] == 3, "plain text rows, got %ld", (long)[table numberOfRowsInSection:0]);
    EXPECT([(id<UITableViewDelegate>)panel tableView:table shouldHighlightRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]] == NO,
           "plain rows are not tappable");

    [panel setLyrics:SyncedLyrics()];
    [panel layoutIfNeeded];
    EXPECT([(id<UITableViewDelegate>)panel tableView:table shouldHighlightRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]] == YES,
           "timed rows are tappable");

    // A tap with no delegate must not crash.
    [(id<UITableViewDelegate>)panel tableView:table didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:0]];

    // Dragging suspends auto-scroll.
    [(id<UIScrollViewDelegate>)panel scrollViewWillBeginDragging:table];
    [panel setCurrentLineIndex:0 animated:NO];
    [(id<UIScrollViewDelegate>)panel scrollViewDidEndDragging:table willDecelerate:NO];
    [panel setLyrics:nil];
    EXPECT(!panel.hasVisibleContent, "nil lyrics clears the panel");

    TestPanelFit();
}

/// Without the column hooks the default (side by side) cannot be laid out, so the screen stays
/// CarPlay's own: no lyrics view at all, while the artwork and backdrop preferences still apply.
static void TestCustomizerDefaults(CPUINowPlayingViewController *vc) {
    CLLayoutCustomizer *customizer = [CLLayoutCustomizer customizerForViewController:vc create:YES];
    EXPECT(customizer != nil, "customizer created");
    EXPECT(customizer.isAttached, "customizer attached");
    EXPECT([CLLayoutCustomizer customizerForViewController:vc create:NO] == customizer, "association is stable");
    Layout(vc);

    NSArray<CLLyricsPanelView *> *panels = PanelsIn(vc.view);
    EXPECT(panels.count == 0 && ForeignViewCount(vc.view) == 0,
           "default mode 4 without the column hooks: the stock screen, no lyrics view (%lu/%lu)",
           (unsigned long)panels.count, (unsigned long)ForeignViewCount(vc.view));
    CPUINowPlayingView *npv = (CPUINowPlayingView *)vc->_nowPlayingView;
    UIView *brick = npv->_artworkViewBrick;
    EXPECT(!brick.isHidden, "the artwork square stays");

    EXPECT(fabs(brick.layer.cornerRadius - 12.0) < 0.01,
           "default corner radius applied to the artwork square (%.1f)", brick.layer.cornerRadius);
    EXPECT(CGAffineTransformIsIdentity(brick.transform), "the artwork square is never transformed");
    EXPECT(fabs(vc->_artworkView.layer.cornerRadius) < 0.01 && !vc->_artworkView.isHidden,
           "the host's background artwork is left alone by default");
    EXPECT(vc.navigationItem.rightBarButtonItems.count == 2, "no bar items hidden by default");
    UIView *details = npv->_songDetailsView;
    NSMutableArray *badges = [NSMutableArray array];
    CollectViews(details, UIImageView.class, badges);
    EXPECT(badges.count == 1 && ![(UIImageView *)badges.firstObject isHidden], "app badge visible by default");
    EXPECT(LabelsIn(details).count == 3 && !LabelsIn(details)[2].isHidden, "album label visible by default");
    EXPECT(!npv->_progressView.isHidden, "progress bar visible by default");
}

static void TestCustomizerPrefs(CPUINowPlayingViewController *vc) {
    CLLayoutCustomizer *customizer = [CLLayoutCustomizer customizerForViewController:vc create:NO];
    CPUINowPlayingView *npv = (CPUINowPlayingView *)vc->_nowPlayingView;

    // --- Layout knobs
    SetPref(CLPrefKeyArtworkCornerRadius, @(30));
    SetPref(CLPrefKeyShowAlbum, @NO);
    SetPref(CLPrefKeyProgressBarStyle, @(2));
    SetPref(CLPrefKeyHideQueueButton, @YES);
    SetPref(CLPrefKeyBackdropOpacity, @(0.4));
    SetPref(CLPrefKeyTintFromArtwork, @YES);
    vc->_artworkImage = TestArtwork();
    Pump();
    Layout(vc);

    UIView *brick = npv->_artworkViewBrick;
    EXPECT(CGAffineTransformIsIdentity(brick.transform), "no artwork scale any more (%.3f)", brick.transform.a);
    EXPECT(fabs(brick.layer.cornerRadius - 30.0) < 0.01, "corner radius applied to the square");
    EXPECT(brick.layer.masksToBounds, "corner radius clips");
    EXPECT(CGAffineTransformIsIdentity(vc->_artworkView.transform) && fabs(vc->_artworkView.layer.cornerRadius) < 0.01,
           "the artwork prefs never touch the host's background artwork");
    EXPECT(fabs(vc->_artworkView.alpha - 0.4) < 0.01 && !vc->_artworkView.isHidden && !vc->_artworkVisualEffectView.isHidden,
           "backdrop opacity dims the host's background image (%.2f)", vc->_artworkView.alpha);
    EXPECT(LabelsIn(npv->_songDetailsView)[2].isHidden, "album label hidden");
    EXPECT(npv->_progressView.isHidden, "progress bar hidden");
    EXPECT(CGAffineTransformIsIdentity(npv->_progressView.transform), "the progress view is never transformed");
    EXPECT(vc.navigationItem.rightBarButtonItems.count == 1, "queue button removed (%lu left)",
           (unsigned long)vc.navigationItem.rightBarButtonItems.count);
    EXPECT(vc.navigationItem.rightBarButtonItems.firstObject == vc->_rightTitleLabelBarButtonItem, "the right item stayed");
    EXPECT(fabs(npv->_songDetailsViewHeightConstraint.constant - 100.0) < 0.5,
           "the song-details height is the host's own (%.1f)", npv->_songDetailsViewHeightConstraint.constant);
    EXPECT([npv->_progressView.tintColor isEqual:UIColor.clearColor] == NO, "progress tinted from artwork");
    // relayout must be idempotent.
    for (int i = 0; i < 5; i++) { [customizer relayout]; Layout(vc); }
    EXPECT(fabs(brick.layer.cornerRadius - 30.0) < 0.01, "corner radius stable across relayouts");
    EXPECT(vc.navigationItem.rightBarButtonItems.count == 1, "bar items stable across relayouts");
    EXPECT(npv->_progressView.isHidden, "progress bar stays hidden across relayouts");

    // A plain backdrop hides the host's background image and its blur; the system look comes back.
    SetPref(CLPrefKeyBackdropStyle, @(1));
    Pump(); Layout(vc);
    EXPECT(vc->_artworkView.isHidden && vc->_artworkVisualEffectView.isHidden, "plain backdrop hides the host's backdrop");
    SetPref(CLPrefKeyBackdropStyle, @(0));
    SetPref(CLPrefKeyBackdropOpacity, @(1.0));
    Pump(); Layout(vc);
    EXPECT(!vc->_artworkView.isHidden && !vc->_artworkVisualEffectView.isHidden && fabs(vc->_artworkView.alpha - 1.0) < 0.01,
           "system backdrop restored (%.2f)", vc->_artworkView.alpha);

    // The speed switch is about the play-mode row (0.7.4), never the top bar: only the queue goes.
    SetPref(CLPrefKeyHidePlaybackRateButton, @YES);
    Pump(); Layout(vc);
    EXPECT(vc.navigationItem.rightBarButtonItems.count == 1 &&
           vc.navigationItem.rightBarButtonItems.firstObject == vc->_rightTitleLabelBarButtonItem,
           "the speed switch leaves the top bar alone (%lu)", (unsigned long)vc.navigationItem.rightBarButtonItems.count);
    SetPref(CLPrefKeyHideQueueButton, @NO);
    Pump(); Layout(vc);
    EXPECT(vc.navigationItem.rightBarButtonItems.count == 2, "queue restored, original order kept");
    EXPECT(vc.navigationItem.rightBarButtonItems.firstObject == vc->_playbackQueueBarButtonItem, "order preserved");
    SetPref(CLPrefKeyHidePlaybackRateButton, @NO);
    Pump(); Layout(vc);

    // Show the progress bar again: 0 shows, and so does the removed thin style (1).
    SetPref(CLPrefKeyProgressBarStyle, @(1));
    Pump(); Layout(vc);
    EXPECT(CLPrefs.shared.progressBarStyle == 0, "progress style 1 reads as 0 (%ld)", (long)CLPrefs.shared.progressBarStyle);
    EXPECT(!npv->_progressView.isHidden && CGAffineTransformIsIdentity(npv->_progressView.transform),
           "the progress bar is back, untransformed");

    // The title font and the app badge are the host's business now.
    UILabel *titleLabel = LabelsIn(npv->_songDetailsView).firstObject;
    CGFloat originalTitleSize = titleLabel.font.pointSize;
    for (int i = 0; i < 4; i++) { [customizer relayout]; Layout(vc); }
    EXPECT(fabs(titleLabel.font.pointSize - originalTitleSize) < 0.01, "the title font is never touched (%.1f)",
           titleLabel.font.pointSize);

    // --- Lyrics modes (no hooks: every mode is the stock screen here)
    for (NSNumber *mode in @[ @2, @3, @0, @1 ]) {
        SetPref(CLPrefKeyLyricsMode, mode);
        Pump(); Layout(vc);
        EXPECT(PanelsIn(vc.view).count == 0 && ForeignViewCount(vc.view) == 0 && !brick.isHidden,
               "mode %ld without hooks: the stock screen (%lu panels)", (long)mode.integerValue,
               (unsigned long)PanelsIn(vc.view).count);
        EXPECT(fabs(brick.layer.cornerRadius - 30.0) < 0.01, "mode %ld keeps the corner radius (not a lyrics setting)",
               (long)mode.integerValue);
    }
    SetPref(CLPrefKeyLyricsMode, @(1));
    Pump();
    EXPECT(CLPrefs.shared.lyricsMode == 4, "legacy mode 1 reads as 4 (%ld)", (long)CLPrefs.shared.lyricsMode);
    SetPref(CLPrefKeyLyricsMode, @(3));
    Pump();
    EXPECT(CLPrefs.shared.lyricsMode == 4, "removed mode 3 reads as 4 (%ld)", (long)CLPrefs.shared.lyricsMode);

    // --- Master switch
    SetPref(CLPrefKeyEnabled, @NO);
    Pump(); Layout(vc);
    EXPECT(PanelsIn(vc.view).count == 0 && ForeignViewCount(vc.view) == 0, "disabling the tweak removes our views");
    EXPECT(fabs(brick.layer.cornerRadius) < 0.01, "disabling restores the corner radius (%.1f)", brick.layer.cornerRadius);
    EXPECT(!brick.isHidden, "disabling restores the artwork square");
    EXPECT(vc.navigationItem.rightBarButtonItems.count == 2, "disabling restores the bar items");
    EXPECT(!LabelsIn(npv->_songDetailsView)[2].isHidden, "disabling restores the album label");
    EXPECT(!npv->_progressView.isHidden, "disabling restores the progress bar");
    EXPECT(fabs(npv->_songDetailsViewHeightConstraint.constant - 100.0) < 0.5,
           "the details height is untouched (%.1f)", npv->_songDetailsViewHeightConstraint.constant);

    SetPref(CLPrefKeyEnabled, @YES);
    Pump(); Layout(vc);
    EXPECT(PanelsIn(vc.view).count == 0, "re-enabling without hooks: still the stock screen");
    EXPECT(fabs(brick.layer.cornerRadius - 30.0) < 0.01, "re-enabling re-applies the corner radius");
}

static void TestDetach(CPUINowPlayingViewController *vc) {
    CPUINowPlayingView *npv = (CPUINowPlayingView *)vc->_nowPlayingView;
    UIView *brick = npv->_artworkViewBrick;
    CGFloat radiusBefore = brick.layer.cornerRadius;
    EXPECT(radiusBefore > 0.0, "sanity: a radius was applied before detaching");
    SetPref(CLPrefKeyBackdropStyle, @(1));
    SetPref(CLPrefKeyProgressBarStyle, @(2));
    SetPref(CLPrefKeyShowAlbum, @NO);
    SetPref(CLPrefKeyHideQueueButton, @YES);
    SetPref(CLPrefKeyAccentColor, @"#FF0000");
    Pump(); Layout(vc);
    EXPECT(vc->_artworkView.isHidden, "sanity: the host's backdrop was hidden before detaching");
    [[CLLayoutCustomizer customizerForViewController:vc create:NO] relayout];
    Layout(vc);
    EXPECT(npv->_progressView.isHidden, "sanity: the progress bar was hidden before detaching");
    EXPECT(vc.navigationItem.rightBarButtonItems.count == 1, "sanity: a bar item was hidden before detaching");

    [CLLayoutCustomizer detachFromViewController:vc];
    Pump();
    Layout(vc);

    EXPECT(PanelsIn(vc.view).count == 0 && ForeignViewCount(vc.view) == 0, "detach removes every view we added");
    EXPECT(CGAffineTransformIsIdentity(brick.transform), "the artwork transform is still identity");
    EXPECT(fabs(brick.layer.cornerRadius) < 0.01, "detach restores the corner radius (%.1f)",
           brick.layer.cornerRadius);
    EXPECT(!brick.layer.masksToBounds, "detach restores the square's clipping");
    EXPECT(!brick.isHidden, "detach unhides the artwork square");
    EXPECT(!vc->_artworkView.isHidden && !vc->_artworkVisualEffectView.isHidden && fabs(vc->_artworkView.alpha - 1.0) < 0.01,
           "detach restores the host's backdrop");
    EXPECT(CGAffineTransformIsIdentity(npv->_progressView.transform), "the progress transform is still identity");
    EXPECT(!npv->_progressView.isHidden, "detach unhides the progress view");
    EXPECT(vc.navigationItem.rightBarButtonItems.count == 2, "detach restores the bar items");
    EXPECT(!LabelsIn(npv->_songDetailsView)[2].isHidden, "detach restores the album label");
    EXPECT(![LabelsIn(npv->_songDetailsView)[1].textColor isEqual:[UIColor redColor]], "detach restores the artist label's colour");
    NSMutableArray *detachBadges = [NSMutableArray array];
    CollectViews(npv->_songDetailsView, UIImageView.class, detachBadges);
    EXPECT(![(UIImageView *)detachBadges.firstObject isHidden], "the app badge was never touched");
    EXPECT(fabs(npv->_songDetailsViewHeightConstraint.constant - 100.0) < 0.5, "the details height was never touched");
    EXPECT([CLLayoutCustomizer customizerForViewController:vc create:NO] == nil, "association cleared");
    EXPECT(CLLyricsController.sharedController.activeDisplayCount == 0,
           "detach gives the active-display count back (%ld)",
           (long)CLLyricsController.sharedController.activeDisplayCount);
    SetPref(CLPrefKeyBackdropStyle, @(0));
    SetPref(CLPrefKeyProgressBarStyle, @(0));
    SetPref(CLPrefKeyShowAlbum, @YES);
    SetPref(CLPrefKeyHideQueueButton, @NO);
    ClearPref(CLPrefKeyAccentColor);
}

static void TestBarrenController(void) {
    CLLayoutCustomizer.hostColumnHooksInstalled = YES;
    CPUINowPlayingViewController *vc = [[CPUINowPlayingViewController alloc] init];
    vc.barren = YES;
    vc.view.frame = CGRectMake(0, 0, 800, 480);
    CLLayoutCustomizer *customizer = [CLLayoutCustomizer customizerForViewController:vc create:YES];
    EXPECT(customizer.isAttached, "attaches even with nothing to anchor to");
    Layout(vc);
    NSArray<CLLyricsPanelView *> *panels = PanelsIn(vc.view);
    EXPECT(panels.count == 1, "no host views: the panel is still installed (%lu)", (unsigned long)panels.count);
    CLLyricsPanelView *panel = panels.firstObject;
    [panel setLyrics:SyncedLyrics()];
    [panel setCurrentLineIndex:0 animated:NO];
    [customizer relayout];
    Layout(vc);
    EXPECT(CGRectGetWidth(panel.frame) > 100.0 && CGRectGetHeight(panel.frame) > 100.0,
           "fallback panel is laid out inside the safe area (%s)", NSStringFromCGRect(panel.frame).UTF8String);
    for (int i = 0; i < 3; i++) { [customizer relayout]; Layout(vc); }
    [customizer detach];
    Pump();
    CLLayoutCustomizer.hostColumnHooksInstalled = NO;
    EXPECT(!customizer.isAttached, "barren controller detaches cleanly");
    // Nil / wrong-type arguments must be inert.
    EXPECT([CLLayoutCustomizer customizerForViewController:nil create:YES] == nil, "nil controller -> nil");
    [CLLayoutCustomizer detachFromViewController:nil];
    [customizer attachToViewController:nil];
    [customizer relayout];
    [customizer applyPrefs];
    [customizer artworkDidChange];
}

/// The riskiest path in the whole slice: the associated object is released *during* the view
/// controller's dealloc, before weak references to it are cleared, so -dealloc must not message it.
static void TestControllerDealloc(void) {
    __weak CLLayoutCustomizer *weakCustomizer = nil;
    __weak CPUINowPlayingViewController *weakController = nil;
    @autoreleasepool {
        CPUINowPlayingViewController *vc = [[CPUINowPlayingViewController alloc] init];
        (void)vc.view;
        CLLayoutCustomizer *customizer = [CLLayoutCustomizer customizerForViewController:vc create:YES];
        Layout(vc);
        [PanelsIn(vc.view).firstObject setLyrics:SyncedLyrics()];
        [customizer relayout];
        Layout(vc);
        weakCustomizer = customizer;
        weakController = vc;
    }
    Pump();
    EXPECT(weakController == nil, "the view controller deallocates while attached");
    EXPECT(weakCustomizer == nil, "the customizer goes with it (no leak, no crash)");
}

/// Prefs flipping under a relayout storm, the way a passenger poking Settings while driving looks.
static void TestStress(CPUINowPlayingViewController *vc) {
    CLLayoutCustomizer *customizer = [CLLayoutCustomizer customizerForViewController:vc create:YES];
    NSArray *modes = @[ @0, @2, @3, @4, @1, @2, @4 ];   // 1 on purpose: it must read as 4
    for (NSUInteger i = 0; i < 24; i++) {
        SetPref(CLPrefKeyLyricsMode, modes[i % modes.count]);
        SetPref(CLPrefKeyProgressBarStyle, @(i % 3));
        SetPref(CLPrefKeyArtworkCornerRadius, @((double)(i % 4) * 10.0));
        SetPref(CLPrefKeyLyricsBackground, @(i % 3));
        SetPref(CLPrefKeyLyricsAnimations, @(i % 2 == 0));
        SetPref(CLPrefKeyShowAlbum, @(i % 2 == 1));
        Pump();
        [customizer relayout];
        Layout(vc);
        NSArray<CLLyricsPanelView *> *views = PanelsIn(vc.view);
        for (CLLyricsPanelView *view in views) {
            [view setLyrics:SyncedLyrics()];
            [view setCurrentLineIndex:(NSInteger)(i % 5) animated:YES];
        }
        Layout(vc);
        EXPECT(views.count <= 1 && ForeignViewCount(vc.view) == 0, "never more than one lyrics view at a time (%lu at step %lu)",
               (unsigned long)views.count, (unsigned long)i);
        EXPECT(CLPrefs.shared.lyricsMode != 1 && CLPrefs.shared.progressBarStyle != 1,
               "removed values never surface (%ld/%ld)", (long)CLPrefs.shared.lyricsMode, (long)CLPrefs.shared.progressBarStyle);
    }
    // The host rebuilding its own bar items mid-flight must not confuse the bookkeeping.
    SetPref(CLPrefKeyHideQueueButton, @YES);
    Pump(); Layout(vc);
    UIBarButtonItem *extra = [[UIBarButtonItem alloc] initWithTitle:@"New" style:UIBarButtonItemStylePlain target:nil action:NULL];
    vc.navigationItem.rightBarButtonItems = @[ extra, vc->_rightTitleLabelBarButtonItem ];
    [customizer relayout];
    Layout(vc);
    EXPECT(vc.navigationItem.rightBarButtonItems.count == 2, "host-added items survive (%lu)",
           (unsigned long)vc.navigationItem.rightBarButtonItems.count);
    SetPref(CLPrefKeyHideQueueButton, @NO);
    Pump(); Layout(vc);
    EXPECT([vc.navigationItem.rightBarButtonItems containsObject:extra], "the host's new item is still there");
    [CLLayoutCustomizer detachFromViewController:vc];
    Pump();
}

/// The six keys 0.5.0 dropped. Never written by the tests except in TestLegacyPrefs, but cleared
/// here too so a stale scratch domain cannot leak them into another run.
static NSArray<NSString *> *LegacyKeys(void) {
    return @[ @"lyricsPosition", @"lyricsMaxLines", @"artworkScale", @"titleFontSize", @"compactMode", @"hideAppBadge" ];
}

static void ResetPrefs(void) {
    NSArray<NSString *> *keys = [@[
        CLPrefKeyEnabled, CLPrefKeyLyricsMode,
        CLPrefKeyArtworkCornerRadius, CLPrefKeyShowAlbum, CLPrefKeyProgressBarStyle,
        CLPrefKeyHideQueueButton, CLPrefKeyHidePlaybackRateButton,
        CLPrefKeyBackdropStyle, CLPrefKeyBackdropOpacity, CLPrefKeyTintFromArtwork, CLPrefKeyAccentColor,
        CLPrefKeyLyricsBackground, CLPrefKeyLyricsAnimations, CLPrefKeyLyricsFontSize,
    ] arrayByAddingObjectsFromArray:LegacyKeys()];
    // Removing a key and reading the domain back in the same breath is not reliable the first
    // time cfprefsd sees a domain (the scratch domain the runner sets up is new on a fresh
    // phone), and a reset that silently did not take shows up much later as a confusing failure
    // in whatever test runs next. Clear, re-read, and retry a few times until the values that
    // matter are actually back at their documented defaults.
    for (NSUInteger attempt = 0; attempt < 5; attempt++) {
        for (NSString *key in keys) {
            CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL,
                                     (__bridge CFStringRef)CLPrefsActiveDomain());
        }
        CFPreferencesAppSynchronize((__bridge CFStringRef)CLPrefsActiveDomain());
        [CLPrefs.shared reloadNow];
        if (CLPrefs.shared.enabled && CLPrefs.shared.lyricsMode == 4 && CLPrefs.shared.progressBarStyle == 0 &&
            fabs(CLPrefs.shared.artworkCornerRadius - 12.0) < 0.01) {
            return;
        }
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    printf("FAIL ResetPrefs: preferences did not return to their defaults (mode %ld, enabled %d)\n",
           (long)CLPrefs.shared.lyricsMode, (int)CLPrefs.shared.enabled);
    gFail++;
}


/// Regression (fix wave): a preference key removed from cfprefsd must not come back from the
/// domain's plist on disk. cfprefsd flushes a domain to its file lazily, so the file can still
/// hold a value that has already been removed; CLPrefs used to consult it per missing key, which
/// resurrected the old value and made "Reset to Defaults" look as though it had not worked. The
/// file is now a bootstrap only — once cfprefsd has answered anything, it is the sole authority.
/// 0.8.2: Apple Music's screen appears before its playback data, so the host has the progress bar
/// (and the transport row) hidden when the customizer attaches and shows them a moment later. With
/// Progress Bar Show the customizer must leave that to the host.
static void TestProgressFollowsHost(void) {
    ResetPrefs();
    CPUINowPlayingViewController *vc = [[CPUINowPlayingViewController alloc] init];
    vc.view.frame = CGRectMake(0, 0, 800, 480);
    CPUINowPlayingView *npv = (CPUINowPlayingView *)vc->_nowPlayingView;
    UIView *progress = npv->_progressView, *transport = npv->_transportControlView;
    progress.hidden = YES;       // no data source yet
    transport.hidden = YES;
    CLLayoutCustomizer *customizer = [CLLayoutCustomizer customizerForViewController:vc create:YES];
    Pump(); Layout(vc);
    EXPECT(progress.isHidden, "progress: hidden while the host has no data");

    progress.hidden = NO;        // the data arrived
    transport.hidden = NO;
    for (int i = 0; i < 3; i++) { [customizer relayout]; Layout(vc); }
    EXPECT(!progress.isHidden, "progress: Show leaves the bar to the host once it has data");

    SetPref(CLPrefKeyProgressBarStyle, @(2));
    Pump(); Layout(vc);
    EXPECT(progress.isHidden, "progress: Hide hides it");
    SetPref(CLPrefKeyProgressBarStyle, @(0));
    Pump(); Layout(vc);
    EXPECT(!progress.isHidden, "progress: Show gives it back");

    // Hidden by us while the host lost its data: Show hands back the host's state (the transport row's).
    SetPref(CLPrefKeyProgressBarStyle, @(2));
    Pump(); Layout(vc);
    transport.hidden = YES;
    SetPref(CLPrefKeyProgressBarStyle, @(0));
    Pump(); Layout(vc);
    EXPECT(progress.isHidden, "progress: back to the host's no-data state, not forced visible");
    transport.hidden = NO;
    progress.hidden = NO;
    [CLLayoutCustomizer detachFromViewController:vc];
    Pump();
    EXPECT(!progress.isHidden, "progress: detaching leaves the host's visible bar alone");
}

static void TestClearedKeyDoesNotComeBack(void) {
    ResetPrefs();
    CFStringRef domain = (__bridge CFStringRef)CLPrefsActiveDomain();

    SetPref(CLPrefKeyLyricsMode, @(2));
    EXPECT(CLPrefs.shared.lyricsMode == 2, "prefs: a written key is read back (%ld)",
           (long)CLPrefs.shared.lyricsMode);

    // Push it out to the plist on disk, then take the key away again.
    CFPreferencesAppSynchronize(domain);
    Pump();
    CFPreferencesSetAppValue((__bridge CFStringRef)CLPrefKeyLyricsMode, NULL, domain);
    CFPreferencesAppSynchronize(domain);
    [CLPrefs.shared reloadNow];
    EXPECT(CLPrefs.shared.lyricsMode == 4,
           "prefs: a cleared key falls back to its default, not to the stale plist (%ld)",
           (long)CLPrefs.shared.lyricsMode);
    ResetPrefs();
}

/// Added by the integrate wave together with -setPaused: (hooks asked the ui slice for it).
/// A paused customizer stays attached and keeps its views; resuming re-places everything and
/// pushes the current line without animating.
static void TestPauseResume(void) {
    ResetPrefs();
    CLLayoutCustomizer.hostColumnHooksInstalled = YES;
    gSimulateColumnHooks = YES;
    CPUINowPlayingViewController *vc = [[CPUINowPlayingViewController alloc] init];
    vc.view.frame = CGRectMake(0, 0, 800, 480);
    CLLayoutCustomizer *customizer = [CLLayoutCustomizer customizerForViewController:vc create:YES];
    Pump();
    Layout(vc);
    EXPECT(customizer.isAttached, "pause: attached to start with");
    EXPECT(!customizer.isPaused, "pause: a fresh customizer is not paused");

    NSArray<CLLyricsPanelView *> *panels = PanelsIn(vc.view);
    EXPECT(panels.count == 1, "pause: one panel before pausing (%lu)", (unsigned long)panels.count);
    CLLyricsPanelView *panel = panels.firstObject;
    [panel setLyrics:SyncedLyrics()];
    [panel setCurrentLineIndex:0 animated:NO];
    [customizer relayout];
    Layout(vc);
    CGRect frameBeforePause = panel.frame;

    EXPECT(CLLyricsController.sharedController.activeDisplayCount == 1,
           "pause: an attached customizer counts as one active display (%ld)",
           (long)CLLyricsController.sharedController.activeDisplayCount);

    [customizer setPaused:YES];
    Pump();
    EXPECT(customizer.isPaused, "pause: reports paused");
    EXPECT(customizer.isAttached, "pause: stays attached while paused");
    EXPECT(CLLyricsController.sharedController.activeDisplayCount == 0,
           "pause: hands the active-display count back so the sync tick can slow down (%ld)",
           (long)CLLyricsController.sharedController.activeDisplayCount);

    // Prefs changing and the host laying out while offscreen must not throw and must not install
    // a second lyrics view.
    SetPref(CLPrefKeyLyricsMode, @(2));
    [customizer relayout];
    Layout(vc);
    Pump();
    EXPECT(PanelsIn(vc.view).count <= 1 && ForeignViewCount(vc.view) == 0, "pause: never two lyrics views while paused (%lu)",
           (unsigned long)PanelsIn(vc.view).count);

    [customizer setPaused:NO];
    Pump();
    Layout(vc);
    EXPECT(!customizer.isPaused, "pause: reports resumed");
    EXPECT(customizer.isAttached, "pause: still attached after resuming");
    EXPECT(CLLyricsController.sharedController.activeDisplayCount == 1,
           "pause: resuming takes the active display back (%ld)",
           (long)CLLyricsController.sharedController.activeDisplayCount);
    NSArray<CLLyricsPanelView *> *afterResume = PanelsIn(vc.view);
    EXPECT(afterResume.count == 1, "pause: the pref change taken while paused is applied on resume (%lu)",
           (unsigned long)afterResume.count);
    UIView *resumedView = afterResume.firstObject;
    EXPECT(!CGRectIsEmpty(resumedView.frame), "pause: the resumed view is placed");
    (void)frameBeforePause;

    // Idempotent in both directions, and a redundant call changes nothing.
    [customizer setPaused:NO];
    [customizer setPaused:YES];
    [customizer setPaused:YES];
    [customizer setPaused:NO];
    Pump();
    Layout(vc);
    EXPECT(!customizer.isPaused, "pause: repeated set calls settle on the last value");
    EXPECT(CLLyricsController.sharedController.activeDisplayCount == 1,
           "pause: repeated set calls leave exactly one active display (%ld)",
           (long)CLLyricsController.sharedController.activeDisplayCount);

    [CLLayoutCustomizer detachFromViewController:vc];
    Pump();
    EXPECT(!customizer.isAttached, "pause: detaches cleanly after a pause cycle");
    gSimulateColumnHooks = NO;
    CLLayoutCustomizer.hostColumnHooksInstalled = NO;
    EXPECT(CLLyricsController.sharedController.activeDisplayCount == 0,
           "pause: detaching after a pause cycle leaves no active display (%ld)",
           (long)CLLyricsController.sharedController.activeDisplayCount);

    // Two customizers overlap whenever the host swaps its Now Playing view controller: the new
    // one attaches before the old one is torn down. Whatever the order, the count must come back
    // to zero — a leak there would pin the engine at 10 Hz, a double-release would pin it at 1 Hz.
    CPUINowPlayingViewController *outgoing = [[CPUINowPlayingViewController alloc] init];
    (void)outgoing.view;
    CLLayoutCustomizer *outgoingCustomizer = [CLLayoutCustomizer customizerForViewController:outgoing create:YES];
    CPUINowPlayingViewController *incoming = [[CPUINowPlayingViewController alloc] init];
    (void)incoming.view;
    CLLayoutCustomizer *incomingCustomizer = [CLLayoutCustomizer customizerForViewController:incoming create:YES];
    Pump();
    EXPECT(CLLyricsController.sharedController.activeDisplayCount == 2,
           "pause: two overlapping customizers count as two displays (%ld)",
           (long)CLLyricsController.sharedController.activeDisplayCount);
    [incomingCustomizer setPaused:NO];              // the new screen appears first...
    [outgoingCustomizer setPaused:YES];             // ...then the old one goes away
    Pump();
    EXPECT(CLLyricsController.sharedController.activeDisplayCount == 1,
           "pause: the surviving screen keeps one active display (%ld)",
           (long)CLLyricsController.sharedController.activeDisplayCount);
    [CLLayoutCustomizer detachFromViewController:outgoing];
    [CLLayoutCustomizer detachFromViewController:incoming];
    Pump();
    EXPECT(CLLyricsController.sharedController.activeDisplayCount == 0,
           "pause: tearing both down leaves no active display (%ld)",
           (long)CLLyricsController.sharedController.activeDisplayCount);

    ResetPrefs();
}

static CLPlaybackState *PlayingIn(NSString *bundleIdentifier, NSString *title) {
    return [[CLPlaybackState alloc] initWithTitle:title
                                           artist:@"Artist"
                                            album:nil
                                         duration:200.0
                                      elapsedTime:1.0
                                        timestamp:[NSDate date]
                                     playbackRate:1.0
                                 bundleIdentifier:bundleIdentifier
                                contentIdentifier:nil
                                        isPlaying:YES
                                  isAdvertisement:NO
                                           origin:CLPlaybackStateOriginMediaRemote];
}

/// Active constraints on `view`'s own width/leading/trailing, i.e. the ones that size it in `root`.
static NSUInteger SizeConstraintCount(UIView *view, UIView *root, NSLayoutAttribute attribute) {
    NSUInteger count = 0;
    for (NSLayoutConstraint *constraint in root.constraints) {
        if (!constraint.isActive) continue;
        if ((constraint.firstItem == view && constraint.firstAttribute == attribute) ||
            (constraint.secondItem == view && constraint.secondAttribute == attribute)) count++;
    }
    for (NSLayoutConstraint *constraint in view.constraints) {
        if (constraint.isActive && constraint.firstItem == view && constraint.secondItem == nil &&
            constraint.firstAttribute == attribute) count++;
    }
    return count;
}

/// lyricsMode 4: the host's Now Playing view becomes a left-hand column the host lays out itself
/// (stacked, because the column is narrower than the side-artwork ratio), the lyrics panel takes
/// the rest, and every way out of the mode gives the host its whole screen back.
static void TestSideBySide(void) {
    ResetPrefs();
    CLLayoutCustomizer.hostColumnHooksInstalled = YES;
    gSimulateColumnHooks = YES;

    CPUINowPlayingViewController *vc = [[CPUINowPlayingViewController alloc] init];
    (void)vc.view;
    CPUINowPlayingView *npv = (CPUINowPlayingView *)vc->_nowPlayingView;
    CLLayoutCustomizer *customizer = [CLLayoutCustomizer customizerForViewController:vc create:YES];
    Pump(); Layout(vc); Layout(vc);

    // 800x480: column = min(480*0.8, 800*0.45) = 360, lyrics get the remaining 424.
    EXPECT(fabs(customizer.playerColumnWidth - 360.0) < 0.5, "side by side: column width (%.1f)",
           customizer.playerColumnWidth);
    EXPECT(customizer.playerStripHeight == 0.0, "side by side: no strip (%.1f)", customizer.playerStripHeight);
    EXPECT(fabs(CGRectGetWidth(npv.frame) - 360.0) < 0.5 && fabs(CGRectGetMinX(npv.frame)) < 0.5,
           "side by side: the host's Now Playing view is the left column (%s)",
           NSStringFromCGRect(npv.frame).UTF8String);
    EXPECT(fabs(CGRectGetWidth(npv->_lastSafeArea) - 360.0) < 0.5 &&
           fabs(CGRectGetHeight(npv->_lastSafeArea) - 480.0) < 0.5 &&
           fabs(CGRectGetWidth(npv->_lastViewArea) - 360.0) < 0.5,
           "side by side: the host lays itself out for the column (safe %s, view %s)",
           NSStringFromCGRect(npv->_lastSafeArea).UTF8String, NSStringFromCGRect(npv->_lastViewArea).UTF8String);
    EXPECT(CGRectGetWidth(npv->_lastSafeArea) / CGRectGetHeight(npv->_lastSafeArea) < 1.35,
           "side by side: the column is narrow enough for the host's stacked layout");

    NSArray<CLLyricsPanelView *> *panels = PanelsIn(vc.view);
    EXPECT(panels.count == 1 && ForeignViewCount(vc.view) == 0, "side by side: one panel, no other view of ours (%lu/%lu)",
           (unsigned long)panels.count, (unsigned long)ForeignViewCount(vc.view));
    CLLyricsPanelView *panel = panels.firstObject;
    EXPECT(panel.superview == vc.view, "side by side: the panel is beside the Now Playing view, not in it");
    [panel setLyrics:SyncedLyrics()];
    [customizer relayout];
    Layout(vc);
    EXPECT(!panel.isHidden, "side by side: the panel shows once it has lyrics");
    EXPECT(CGRectGetMinX(panel.frame) >= CGRectGetMaxX(npv.frame) + 15.5 &&
           CGRectGetMaxX(panel.frame) <= 800.0 - 15.5 && CGRectGetWidth(panel.frame) > 380.0 &&
           CGRectGetHeight(panel.frame) > 400.0,
           "side by side: the panel fills the right-hand side (%s)", NSStringFromCGRect(panel.frame).UTF8String);
    EXPECT(RectNear(panel.frame, CGRectMake(376, 8, 408, 464)), "side by side: the panel is where CLLayoutLyricsRect says (%s)",
           NSStringFromCGRect(panel.frame).UTF8String);
    EXPECT(panel.fit == CLLayoutPanelFitColumn, "side by side: the column fit");
    EXPECT(fabs(panel.layer.cornerRadius) < 0.01, "side by side: no corner radius on the panel");

    // Every row in one font, never focusable (the knob and touchpad belong to the player).
    NSMutableArray *tables = [NSMutableArray array];
    CollectViews(panel, UITableView.class, tables);
    UITableView *table = tables.firstObject;
    NSMutableSet<NSString *> *fonts = [NSMutableSet set];
    for (UILabel *label in LabelsIn(table)) {
        if (label.text.length) [fonts addObject:[NSString stringWithFormat:@"%@ %.1f", label.font.fontName, label.font.pointSize]];
    }
    EXPECT(fonts.count == 1, "side by side: every lyric row uses the same font (%s)",
           [[fonts.allObjects componentsJoinedByString:@", "] UTF8String]);
    EXPECT(![(id<UITableViewDelegate>)panel tableView:table canFocusRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]],
           "side by side: lyric rows never take focus");
    // CarPlay makes the controller's content scroll view a preferred focus environment; a panel
    // that takes no interaction can never be focused, so the knob stays on the player.
    EXPECT(!panel.isUserInteractionEnabled && !table.isUserInteractionEnabled && !table.canBecomeFocused,
           "side by side: the lyrics are display-only and never a focus target");

    // Many passes later there is still exactly one set of size constraints on the column: the
    // host takes ours back out on every recalculation, we swap again, nothing piles up.
    NSUInteger before = npv->_recalculations;
    for (int i = 0; i < 5; i++) { [vc.view setNeedsLayout]; Layout(vc); }
    EXPECT(npv->_recalculations > before, "side by side: the host kept recalculating (%lu)",
           (unsigned long)(npv->_recalculations - before));
    EXPECT(SizeConstraintCount(npv, vc.view, NSLayoutAttributeWidth) == 1 &&
           SizeConstraintCount(npv, vc.view, NSLayoutAttributeTrailing) == 0,
           "side by side: one width constraint, no trailing pin (%lu/%lu)",
           (unsigned long)SizeConstraintCount(npv, vc.view, NSLayoutAttributeWidth),
           (unsigned long)SizeConstraintCount(npv, vc.view, NSLayoutAttributeTrailing));
    EXPECT(fabs(CGRectGetWidth(npv.frame) - 360.0) < 0.5, "side by side: still the column after the passes");

    // Another app takes over playback while Spotify's Now Playing screen is up: that screen goes
    // back to the host's own layout with no lyrics on it, and gets the split back with Spotify.
    [CLLyricsController.sharedController ingestPlaybackState:PlayingIn(@"com.apple.Music", @"Elsewhere")];
    Pump(); Layout(vc); Layout(vc);
    EXPECT(customizer.playerColumnWidth == 0.0, "other app playing: no column (%.1f)", customizer.playerColumnWidth);
    EXPECT(fabs(CGRectGetWidth(npv.frame) - 800.0) < 0.5, "other app playing: the host gets its whole screen (%s)",
           NSStringFromCGRect(npv.frame).UTF8String);
    BOOL anyLyricsVisible = NO;
    for (UIView *lyricsView in PanelsIn(vc.view)) anyLyricsVisible = anyLyricsVisible || !lyricsView.isHidden;
    EXPECT(!anyLyricsVisible, "other app playing: no lyrics on this screen");

    [CLLyricsController.sharedController ingestPlaybackState:PlayingIn(@"com.spotify.client", @"Back Home")];
    Pump(); Layout(vc); Layout(vc);
    EXPECT(fabs(CGRectGetWidth(npv.frame) - 360.0) < 0.5, "own app playing again: the column is back (%s)",
           NSStringFromCGRect(npv.frame).UTF8String);
    panel = PanelsIn(vc.view).firstObject;

    // Short and wide (a 1920x720 @3x display is 640x240 pt): too short for the stacked chain, so
    // the player area is the narrowest the host's art-left side layout takes (h x 1.45), lyrics
    // beside it.
    vc.view.frame = CGRectMake(0, 0, 640, 240);
    [customizer applyPrefs];
    Pump(); Layout(vc); Layout(vc);
    CGFloat shortColumn = customizer.playerColumnWidth;
    EXPECT(fabs(shortColumn - 348.0) < 0.5, "short screen: side-layout player width (%.1f)", shortColumn);
    EXPECT(CGRectGetWidth(npv->_lastSafeArea) / CGRectGetHeight(npv->_lastSafeArea) >= 1.45,
           "short screen: the player area is wide enough for the side layout (%s)",
           NSStringFromCGRect(npv->_lastSafeArea).UTF8String);
    panel = PanelsIn(vc.view).firstObject;
    EXPECT(panel && CGRectGetMinX(panel.frame) >= shortColumn + 15.5 && CGRectGetWidth(panel.frame) >= 259.5,
           "short screen: lyrics to the right of the player (%s)", NSStringFromCGRect(panel.frame).UTF8String);
    [panel setLyrics:SyncedLyrics()];
    [customizer relayout];
    Layout(vc);
    UILabel *row = FirstRowLabel(panel);
    EXPECT(row && fabs(row.font.pointSize - 23.0) < 0.01,
           "short screen: the lyrics font fits the 260 pt panel (%.1f)", row.font.pointSize);

    // A screen too narrow to split (under 1.35:1) becomes the full panel: the host's own layout
    // without artwork in a full-width strip at the bottom, the lyrics above it.
    vc.view.frame = CGRectMake(0, 0, 600, 600);
    [customizer applyPrefs];
    Pump(); Layout(vc); Layout(vc);
    EXPECT(customizer.playerColumnWidth == 0.0, "narrow screen: no column (%.1f)", customizer.playerColumnWidth);
    EXPECT(fabs(customizer.playerStripHeight - 200.0) < 0.5, "narrow screen: the strip (%.1f)", customizer.playerStripHeight);
    EXPECT(fabs(CGRectGetWidth(npv.frame) - 600.0) < 0.5, "narrow screen: the host gets the whole width (%s)",
           NSStringFromCGRect(npv.frame).UTF8String);
    EXPECT(RectNear(npv.frame, CGRectMake(0, 400, 600, 200)), "narrow screen: the host is the bottom strip (%s)",
           NSStringFromCGRect(npv.frame).UTF8String);
    EXPECT(fabs(CGRectGetWidth(npv->_lastSafeArea) - 600.0) < 0.5, "narrow screen: the host lays out for the screen");
    EXPECT(npv->_lastHidesArtwork, "narrow screen: side by side falls back to the full panel (no artwork)");
    EXPECT(PanelsIn(vc.view).count == 1 && ForeignViewCount(vc.view) == 0, "narrow screen: the lyrics panel, nothing else (%lu)",
           (unsigned long)PanelsIn(vc.view).count);

    // Back to wide, then out of mode 4 through the preference.
    vc.view.frame = CGRectMake(0, 0, 800, 480);
    [customizer applyPrefs];
    Pump(); Layout(vc); Layout(vc);
    EXPECT(fabs(CGRectGetWidth(npv.frame) - 360.0) < 0.5, "wide again: the column is back (%s)",
           NSStringFromCGRect(npv.frame).UTF8String);
    SetPref(CLPrefKeyLyricsMode, @(0));
    Pump(); Layout(vc); Layout(vc);
    EXPECT(fabs(CGRectGetWidth(npv.frame) - 800.0) < 0.5, "mode 0: the host gets its whole screen back (%s)",
           NSStringFromCGRect(npv.frame).UTF8String);
    EXPECT(!CLPlayerColumnRects(npv, NULL, NULL), "mode 0: no player-area rects left on the view");
    EXPECT(PanelsIn(vc.view).count == 0, "mode 0: no panel");

    // Detaching while side by side restores the host too.
    SetPref(CLPrefKeyLyricsMode, @(4));
    Pump(); Layout(vc); Layout(vc);
    EXPECT(fabs(CGRectGetWidth(npv.frame) - 360.0) < 0.5, "mode 4 again: column (%s)",
           NSStringFromCGRect(npv.frame).UTF8String);
    [CLLayoutCustomizer detachFromViewController:vc];
    Pump(); Layout(vc); Layout(vc);
    EXPECT(fabs(CGRectGetWidth(npv.frame) - 800.0) < 0.5, "detach: the host gets its whole screen back (%s)",
           NSStringFromCGRect(npv.frame).UTF8String);
    EXPECT(PanelsIn(vc.view).count == 0, "detach: the panel is gone");

    // Without the hooks mode 4 is the stock screen, whatever the screen.
    CLLayoutCustomizer.hostColumnHooksInstalled = NO;
    CPUINowPlayingViewController *unhooked = [[CPUINowPlayingViewController alloc] init];
    (void)unhooked.view;
    CPUINowPlayingView *unhookedNPV = (CPUINowPlayingView *)unhooked->_nowPlayingView;
    CLLayoutCustomizer *plain = [CLLayoutCustomizer customizerForViewController:unhooked create:YES];
    Pump(); Layout(unhooked);
    EXPECT(plain.playerColumnWidth == 0.0, "no hooks: no column");
    EXPECT(plain.playerStripHeight == 0.0, "no hooks: no strip");
    panels = PanelsIn(unhooked.view);
    EXPECT(panels.count == 0 && ForeignViewCount(unhooked.view) == 0 && !unhookedNPV->_artworkViewBrick.isHidden,
           "no hooks: mode 4 leaves the stock screen alone (%lu panels)", (unsigned long)panels.count);
    [CLLayoutCustomizer detachFromViewController:unhooked];

    gSimulateColumnHooks = NO;
    [CLLyricsController.sharedController ingestPlaybackState:CLPlaybackState.emptyState];
    ResetPrefs();
    Pump();
}

/// Active height-equality constraints between the first spacer guide and the later ones.
static NSUInteger SpacerEqualityCount(UIView *npv, NSArray<UILayoutGuide *> *guides) {
    NSUInteger count = 0;
    for (NSLayoutConstraint *constraint in npv.constraints) {
        if (!constraint.isActive || constraint.firstAttribute != NSLayoutAttributeHeight ||
            constraint.secondAttribute != NSLayoutAttributeHeight) continue;
        if (constraint.secondItem == guides.firstObject && constraint.firstItem != guides.firstObject &&
            [guides indexOfObjectIdenticalTo:constraint.firstItem] != NSNotFound) count++;
    }
    return count;
}

/// The status label of modes 4 and 5: a UILabel directly in the controller's view.
static UILabel *StatusLabelIn(UIViewController *vc) {
    for (UIView *view in vc.view.subviews) {
        if ([view isKindOfClass:UILabel.class]) return (UILabel *)view;
    }
    return nil;
}

/// lyricsMode 2 against a host that lays out like CarPlayUI: the host's Now Playing view becomes a
/// 200 pt full-width strip at the bottom without artwork, whose height alone makes the host pick
/// its small title tier (72 pt details) and 36 pt buttons; the lyrics take everything above it.
static void TestFullPanel(void) {
    ResetPrefs();
    CLLayoutCustomizer.hostColumnHooksInstalled = YES;
    gSimulateColumnHooks = YES;
    SetPref(CLPrefKeyLyricsMode, @(2));

    CPUINowPlayingViewController *vc = [[CPUINowPlayingViewController alloc] init];
    vc.hostChain = YES;
    (void)vc.view;
    CPUINowPlayingView *npv = (CPUINowPlayingView *)vc->_nowPlayingView;
    CLLayoutCustomizer *customizer = [CLLayoutCustomizer customizerForViewController:vc create:YES];
    Pump(); Layout(vc); Layout(vc);

    EXPECT(fabs(customizer.playerStripHeight - 200.0) < 0.5 && customizer.playerColumnWidth == 0.0,
           "full panel: strip 200, no column (%.1f/%.1f)", customizer.playerStripHeight, customizer.playerColumnWidth);
    EXPECT(RectNear(npv.frame, CGRectMake(0, 280, 800, 200)), "full panel: the host's view is the bottom strip (%s)",
           NSStringFromCGRect(npv.frame).UTF8String);
    EXPECT(RectNear(npv->_lastSafeArea, CGRectMake(0, 280, 800, 200)), "full panel: the host lays out for the strip's safe area (%s)",
           NSStringFromCGRect(npv->_lastSafeArea).UTF8String);
    EXPECT(RectNear(npv->_lastViewArea, CGRectMake(0, 280, 800, 200)), "full panel: ...and view area (%s)",
           NSStringFromCGRect(npv->_lastViewArea).UTF8String);
    EXPECT(npv->_lastHidesArtwork && npv->_artworkViewBrick.isHidden, "full panel: the host leaves the artwork out");
    EXPECT(fabs(npv->_lastTransportHeight - 36.0) < 0.01, "full panel: 36 pt buttons (%.0f)", npv->_lastTransportHeight);
    EXPECT(!npv->_lastTitleLarge, "full panel: the small title tier");
    EXPECT(fabs(CGRectGetHeight(npv->_songDetailsView.frame) - 72.0) < 0.5, "full panel: 72 pt song details (%.1f)",
           CGRectGetHeight(npv->_songDetailsView.frame));
    CGRect detailsFrame = RootFrame(npv->_songDetailsView, vc);
    CGRect playModeFrame = RootFrame(npv->_playModeControlView, vc);
    EXPECT(fabs(CGRectGetMinY(detailsFrame) - 282.0) < 0.5, "full panel: the title sits 2 pt into the strip (%.1f)",
           CGRectGetMinY(detailsFrame));
    EXPECT(fabs(CGRectGetMaxY(playModeFrame) - 468.0) < 0.5, "full panel: the play-mode row ends 12 pt above the bottom (%.1f)",
           CGRectGetMaxY(playModeFrame));
    NSArray<UILayoutGuide *> *guides = npv->_verticalSpacerLayoutGuides;
    EXPECT(guides.count == 3 && SpacerEqualityCount(npv, guides) == 2, "full panel: the host's own three equal spacers (%lu/%lu)",
           (unsigned long)guides.count, (unsigned long)SpacerEqualityCount(npv, guides));
    for (UILayoutGuide *guide in guides) {
        EXPECT(fabs(guide.layoutFrame.size.height - 14.0) < 0.5, "full panel: the 18 pt of slack spread over the spacers (%.1f)",
               guide.layoutFrame.size.height);
    }
    EXPECT(!npv.hasAmbiguousLayout, "full panel: the strip is fully determined");
    EXPECT(SizeConstraintCount(npv, vc.view, NSLayoutAttributeWidth) == 1 &&
           SizeConstraintCount(npv, vc.view, NSLayoutAttributeTrailing) == 0,
           "full panel: one width constraint, no trailing pin (%lu/%lu)",
           (unsigned long)SizeConstraintCount(npv, vc.view, NSLayoutAttributeWidth),
           (unsigned long)SizeConstraintCount(npv, vc.view, NSLayoutAttributeTrailing));

    // Stable over many passes: nothing re-added, nothing fighting, the same guides.
    for (int i = 0; i < 5; i++) { [vc.view setNeedsLayout]; Layout(vc); }
    EXPECT(npv->_verticalSpacerLayoutGuides == guides && RectNear(npv.frame, CGRectMake(0, 280, 800, 200)),
           "full panel: stable over repeated passes (%s)", NSStringFromCGRect(npv.frame).UTF8String);

    NSArray<CLLyricsPanelView *> *panels = PanelsIn(vc.view);
    EXPECT(panels.count == 1 && ForeignViewCount(vc.view) == 0, "full panel: one panel, nothing else (%lu)",
           (unsigned long)panels.count);
    CLLyricsPanelView *panel = panels.firstObject;
    EXPECT(panel.superview == vc.view, "full panel: the panel lives in the controller's view");
    [panel setLyrics:SyncedLyrics()];
    [customizer relayout];
    Layout(vc);
    EXPECT(!panel.isHidden && RectNear(panel.frame, CGRectMake(11, 8, 778, 264)),
           "full panel: the lyrics fill the screen above the strip (%s)", NSStringFromCGRect(panel.frame).UTF8String);
    EXPECT(CGRectGetMaxY(panel.frame) <= CGRectGetMinY(npv.frame) - 7.5, "full panel: 8 pt between the lyrics and the strip");
    UILabel *row = FirstRowLabel(panel);
    EXPECT(row && fabs(row.font.pointSize - 24.0) < 0.01, "full panel: the lyrics keep the preferred size (%.1f)", row.font.pointSize);
    EXPECT(fabs(CGRectGetMinX(RootFrame(row, vc)) - 27.0) < 0.5, "full panel: lyric text starts at the title's x (%.1f)",
           CGRectGetMinX(RootFrame(row, vc)));
    EXPECT(panel.fit == CLLayoutPanelFitRows, "full panel: the rows fit");
    EXPECT(fabs(panel.layer.cornerRadius) < 0.01, "full panel: no corner radius on the panel");
    UILabel *status = StatusLabelIn(vc);
    EXPECT(status && fabs(CGRectGetMidY(status.frame) - CGRectGetMidY(panel.frame)) < 1.0 &&
           fabs(CGRectGetMidX(status.frame) - CGRectGetMidX(panel.frame)) < 1.0,
           "full panel: the status label is centred in the panel (%s in %s)",
           NSStringFromCGRect(status.frame).UTF8String, NSStringFromCGRect(panel.frame).UTF8String);

    // Off: the host rebuilds with artwork (new guides) across the whole screen, no panel.
    SetPref(CLPrefKeyLyricsMode, @(0));
    Pump(); Layout(vc); Layout(vc);
    EXPECT(fabs(CGRectGetWidth(npv.frame) - 800.0) < 0.5 && fabs(CGRectGetHeight(npv.frame) - 480.0) < 0.5,
           "mode 0: the host's view covers the screen again (%s)", NSStringFromCGRect(npv.frame).UTF8String);
    EXPECT(!npv->_lastHidesArtwork && npv->_verticalSpacerLayoutGuides != guides, "mode 0: the artwork is back (new guides)");
    EXPECT(!CLPlayerColumnRects(npv, NULL, NULL), "mode 0: no player-area rects left on the view");
    EXPECT(PanelsIn(vc.view).count == 0 && !npv->_artworkViewBrick.isHidden, "mode 0: no panel, the cover shows");

    // Side by side: the column.
    SetPref(CLPrefKeyLyricsMode, @(4));
    Pump(); Layout(vc); Layout(vc);
    EXPECT(fabs(customizer.playerColumnWidth - 360.0) < 0.5 && RectNear(npv.frame, CGRectMake(0, 0, 360, 480)),
           "mode 4: the column (%s)", NSStringFromCGRect(npv.frame).UTF8String);
    EXPECT(!npv->_lastHidesArtwork && !npv->_artworkViewBrick.isHidden, "mode 4: the host keeps its artwork");

    // And the strip again, then a detach in the full panel gives the host its layout back.
    SetPref(CLPrefKeyLyricsMode, @(2));
    Pump(); Layout(vc); Layout(vc);
    EXPECT(npv->_lastHidesArtwork && RectNear(npv.frame, CGRectMake(0, 280, 800, 200)), "mode 2 again: the strip (%s)",
           NSStringFromCGRect(npv.frame).UTF8String);
    [CLLayoutCustomizer detachFromViewController:vc];
    Pump(); Layout(vc); Layout(vc);
    EXPECT(!npv->_lastHidesArtwork && !npv->_artworkViewBrick.isHidden &&
           fabs(CGRectGetWidth(npv.frame) - 800.0) < 0.5 && fabs(CGRectGetHeight(npv.frame) - 480.0) < 0.5 &&
           SpacerEqualityCount(npv, npv->_verticalSpacerLayoutGuides) == 2,
           "detach: the host's layout with artwork is back (%s)", NSStringFromCGRect(npv.frame).UTF8String);
    EXPECT(PanelsIn(vc.view).count == 0 && ForeignViewCount(vc.view) == 0, "detach: no panel left");

    gSimulateColumnHooks = NO;
    CLLayoutCustomizer.hostColumnHooksInstalled = NO;
    ResetPrefs();
    Pump();
}

/// The CarPlay Simulator's Widescreen unit as the host sees it: 640x240 pt @3x with a 44 pt top bar
/// and a 45 pt dock (safe area 595x196 at {45, 44}). Side by Side gets the 285 pt side-layout
/// column, Full Panel the 240 pt cover-less one, and both hand the host a view area trimmed to
/// 207 pt so it picks 36 pt buttons, stable across passes.
static void TestWidescreenUnit(void) {
    ResetPrefs();
    CLLayoutCustomizer.hostColumnHooksInstalled = YES;
    gSimulateColumnHooks = YES;
    gHostDisplayScale = 3.0;
    SetPref(CLPrefKeyLyricsMode, @(4));

    CPUINowPlayingViewController *vc = [[CPUINowPlayingViewController alloc] init];
    vc.hostChain = YES;
    if (@available(iOS 17.0, *)) vc.traitOverrides.displayScale = 3.0;   // the suites run on iOS 17
    // Safe-area insets only reach a view that is in a window, and a scene-less window inherits the
    // simulated iPhone's own (status bar, home indicator): the additional insets make up the rest.
    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 640, 240)];
    window.rootViewController = vc;
    window.hidden = NO;
    UIEdgeInsets inherited = window.safeAreaInsets;
    vc.additionalSafeAreaInsets = UIEdgeInsetsMake(44.0 - inherited.top, 45.0 - inherited.left,
                                                   -inherited.bottom, -inherited.right);
    vc.view.frame = CGRectMake(0, 0, 640, 240);
    CPUINowPlayingView *npv = (CPUINowPlayingView *)vc->_nowPlayingView;
    CLLayoutCustomizer *customizer = [CLLayoutCustomizer customizerForViewController:vc create:YES];
    [customizer applyPrefs];
    Pump(); Layout(vc); Layout(vc);

    CGRect safe = vc.view.safeAreaLayoutGuide.layoutFrame;
    EXPECT(RectNear(safe, CGRectMake(45, 44, 595, 196)), "widescreen: the safe area (%s)", NSStringFromCGRect(safe).UTF8String);
    EXPECT(fabs(vc.view.traitCollection.displayScale - 3.0) < 0.01, "widescreen: @3x (%.1f)", vc.view.traitCollection.displayScale);
    EXPECT(fabs(customizer.playerColumnWidth - 285.0) < 0.5, "widescreen side by side: 285 pt player (%.1f)", customizer.playerColumnWidth);
    EXPECT(RectNear(npv->_lastSafeArea, CGRectMake(45, 44, 285, 196)), "widescreen side by side: the host's safe area (%s)",
           NSStringFromCGRect(npv->_lastSafeArea).UTF8String);
    EXPECT(RectNear(npv->_lastViewArea, CGRectMake(45, 0, 285, 207)), "widescreen side by side: the trimmed view area (%s)",
           NSStringFromCGRect(npv->_lastViewArea).UTF8String);
    EXPECT(fabs(npv->_lastTransportHeight - 36.0) < 0.01, "widescreen side by side: 36 pt buttons (%.0f)", npv->_lastTransportHeight);
    EXPECT(!npv->_lastHidesArtwork, "widescreen side by side: with artwork");
    NSUInteger recalculations = npv->_recalculations;
    CGRect firstViewArea = npv->_lastViewArea;
    Layout(vc); Layout(vc);
    EXPECT(RectNear(npv->_lastViewArea, firstViewArea), "widescreen side by side: the view area is stable (%s)",
           NSStringFromCGRect(npv->_lastViewArea).UTF8String);
    EXPECT(npv->_recalculations - recalculations <= 4, "widescreen side by side: no layout loop (%lu passes for two layouts)",
           (unsigned long)(npv->_recalculations - recalculations));
    CLLyricsPanelView *panel = PanelsIn(vc.view).firstObject;
    EXPECT(panel && RectNear(panel.frame, CGRectMake(346, 52, 278, 180)), "widescreen side by side: the lyrics (%s)",
           NSStringFromCGRect(panel.frame).UTF8String);

    SetPref(CLPrefKeyLyricsMode, @(2));
    [customizer applyPrefs];
    Pump(); Layout(vc); Layout(vc);
    EXPECT(fabs(customizer.playerColumnWidth - 284.0) < 0.5 && customizer.playerStripHeight == 0.0,
           "widescreen full panel: the 284 pt column (%.1f)", customizer.playerColumnWidth);
    EXPECT(RectNear(npv->_lastViewArea, CGRectMake(45, 0, 284, 207)), "widescreen full panel: the trimmed view area (%s)",
           NSStringFromCGRect(npv->_lastViewArea).UTF8String);
    EXPECT(npv->_lastHidesArtwork && npv->_artworkViewBrick.isHidden, "widescreen full panel: without artwork");
    EXPECT(fabs(npv->_lastTransportHeight - 36.0) < 0.01 && !npv->_lastTitleLarge, "widescreen full panel: small tier, 36 pt buttons");
    EXPECT(RectNear(npv.frame, CGRectMake(45, 0, 284, 240)), "widescreen full panel: the host's view is the column (%s)",
           NSStringFromCGRect(npv.frame).UTF8String);
    EXPECT(!npv.hasAmbiguousLayout, "widescreen full panel: the column is fully determined");
    panel = PanelsIn(vc.view).firstObject;
    EXPECT(panel && RectNear(panel.frame, CGRectMake(345, 52, 279, 180)), "widescreen full panel: the lyrics (%s)",
           NSStringFromCGRect(panel.frame).UTF8String);

    // Lyrics Side: Left (0.7.5): the same split mirrored, the host at the trailing edge with its art
    // on the right (the view hook reports left-hand drive), the lyrics on the left.
    SetPref(CLPrefKeyLyricsMode, @(4));
    SetPref(CLPrefKeyLyricsSide, @(1));
    Pump(); Layout(vc); Layout(vc);
    EXPECT(RectNear(npv->_lastSafeArea, CGRectMake(355, 44, 285, 196)) && RectNear(npv->_lastViewArea, CGRectMake(355, 0, 285, 207)),
           "lyrics left: the host lays out for the trailing column (%s, %s)", NSStringFromCGRect(npv->_lastSafeArea).UTF8String,
           NSStringFromCGRect(npv->_lastViewArea).UTF8String);
    EXPECT(RectNear(npv.frame, CGRectMake(355, 0, 285, 240)), "lyrics left: the host's view is at the trailing edge (%s)",
           NSStringFromCGRect(npv.frame).UTF8String);
    EXPECT(!CLHostLayoutArtworkOnLeft(npv), "lyrics left: the view hook asks for the art on the right");
    EXPECT(SizeConstraintCount(npv, vc.view, NSLayoutAttributeTrailing) == 1 &&
           SizeConstraintCount(npv, vc.view, NSLayoutAttributeLeading) == 0 &&
           SizeConstraintCount(npv, vc.view, NSLayoutAttributeWidth) == 1,
           "lyrics left: one trailing pin and a width, no leading pin");
    panel = PanelsIn(vc.view).firstObject;
    EXPECT(panel && RectNear(panel.frame, CGRectMake(61, 52, 278, 180)), "lyrics left: the lyrics on the left (%s)",
           NSStringFromCGRect(panel.frame).UTF8String);
    SetPref(CLPrefKeyLyricsSide, @(0));
    Pump(); Layout(vc); Layout(vc);
    EXPECT(RectNear(npv.frame, CGRectMake(45, 0, 285, 240)) && CLHostLayoutArtworkOnLeft(npv),
           "lyrics right again: back at the leading edge (%s)", NSStringFromCGRect(npv.frame).UTF8String);

    [CLLayoutCustomizer detachFromViewController:vc];
    Pump(); Layout(vc);
    EXPECT(RectNear(npv.frame, CGRectMake(45, 0, 595, 240)) && !npv->_lastHidesArtwork, "widescreen: detach restores the host (%s)",
           NSStringFromCGRect(npv.frame).UTF8String);

    window.hidden = YES;
    window.rootViewController = nil;
    gHostDisplayScale = 2.0;
    gSimulateColumnHooks = NO;
    CLLayoutCustomizer.hostColumnHooksInstalled = NO;
    ResetPrefs();
    Pump();
}

/// lyricsMode 2 on screens where the strip does not fit: the host without artwork in a 240 pt
/// leading column where that fits, the side-by-side split (with artwork) where only that fits,
/// replace artwork where neither does. Right at the threshold too.
static void TestFullPanelFallbacks(void) {
    ResetPrefs();
    CLLayoutCustomizer.hostColumnHooksInstalled = YES;
    gSimulateColumnHooks = YES;
    SetPref(CLPrefKeyLyricsMode, @(2));

    CPUINowPlayingViewController *vc = [[CPUINowPlayingViewController alloc] init];
    vc.hostChain = YES;
    (void)vc.view;
    CPUINowPlayingView *npv = (CPUINowPlayingView *)vc->_nowPlayingView;
    CLLayoutCustomizer *customizer = [CLLayoutCustomizer customizerForViewController:vc create:YES];

    // 640x240 (a 1920x720 unit): too short for the strip -> the host without artwork in a 240 pt
    // column, the lyrics beside it.
    vc.view.frame = CGRectMake(0, 0, 640, 240);
    [customizer applyPrefs];
    Pump(); Layout(vc); Layout(vc);
    EXPECT(fabs(customizer.playerColumnWidth - 284.0) < 0.5 && customizer.playerStripHeight == 0.0,
           "640x240: the cover-less column (column %.1f, strip %.1f)", customizer.playerColumnWidth, customizer.playerStripHeight);
    EXPECT(RectNear(npv->_lastSafeArea, CGRectMake(0, 0, 284, 240)), "640x240: the host lays out for the column (%s)",
           NSStringFromCGRect(npv->_lastSafeArea).UTF8String);
    EXPECT(RectNear(npv.frame, CGRectMake(0, 0, 284, 240)), "640x240: the host's view is the column (%s)",
           NSStringFromCGRect(npv.frame).UTF8String);
    EXPECT(npv->_lastHidesArtwork && npv->_artworkViewBrick.isHidden, "640x240: without artwork");
    EXPECT(!npv.hasAmbiguousLayout, "640x240: the column is fully determined");
    CLLyricsPanelView *panel = PanelsIn(vc.view).firstObject;
    EXPECT(panel && panel.superview == vc.view && RectNear(panel.frame, CGRectMake(300, 8, 324, 224)),
           "640x240: the lyrics to the right of the player (%s)", NSStringFromCGRect(panel.frame).UTF8String);
    EXPECT(panel.fit == CLLayoutPanelFitColumn, "640x240: the column fit");

    // 600x600: too narrow to split, tall enough for the strip.
    vc.view.frame = CGRectMake(0, 0, 600, 600);
    [customizer applyPrefs];
    Pump(); Layout(vc); Layout(vc);
    EXPECT(customizer.playerColumnWidth == 0.0 && fabs(customizer.playerStripHeight - 200.0) < 0.5, "600x600: the strip");
    EXPECT(RectNear(npv.frame, CGRectMake(0, 400, 600, 200)) && npv->_lastHidesArtwork, "600x600: the host is the bottom strip (%s)",
           NSStringFromCGRect(npv.frame).UTF8String);
    EXPECT(fabs(npv->_lastTransportHeight - 36.0) < 0.01 && !npv->_lastTitleLarge, "600x600: small tier, 36 pt buttons");
    panel = PanelsIn(vc.view).firstObject;
    EXPECT(panel && RectNear(panel.frame, CGRectMake(11, 8, 578, 384)), "600x600: the lyrics above the strip (%s)",
           NSStringFromCGRect(panel.frame).UTF8String);

    // 600x300: too short for the strip -> the cover-less column.
    vc.view.frame = CGRectMake(0, 0, 600, 300);
    [customizer applyPrefs];
    Pump(); Layout(vc); Layout(vc);
    EXPECT(fabs(customizer.playerColumnWidth - 284.0) < 0.5 && customizer.playerStripHeight == 0.0, "600x300: column 284 (%.1f)",
           customizer.playerColumnWidth);
    EXPECT(RectNear(npv.frame, CGRectMake(0, 0, 284, 300)) && npv->_lastHidesArtwork, "600x300: the host is the column (%s)",
           NSStringFromCGRect(npv.frame).UTF8String);

    // 540x300: too narrow for the cover-less column beside 240 pt of lyrics -> the stacked column
    // with artwork (264 pt, wide enough for the five-button play-mode row), the side-by-side split.
    vc.view.frame = CGRectMake(0, 0, 540, 300);
    [customizer applyPrefs];
    Pump(); Layout(vc); Layout(vc);
    EXPECT(fabs(customizer.playerColumnWidth - 264.0) < 0.5 && RectNear(npv.frame, CGRectMake(0, 0, 264, 300)) &&
           !npv->_lastHidesArtwork, "540x300: the column with artwork (%.1f, %s)", customizer.playerColumnWidth,
           NSStringFromCGRect(npv.frame).UTF8String);

    // 300x300: nothing fits -> the stock screen, host untouched.
    vc.view.frame = CGRectMake(0, 0, 300, 300);
    [customizer applyPrefs];
    Pump(); Layout(vc); Layout(vc);
    EXPECT(customizer.playerColumnWidth == 0.0 && customizer.playerStripHeight == 0.0, "300x300: no column, no strip");
    EXPECT(!CLPlayerColumnRects(npv, NULL, NULL), "300x300: no player-area rects on the view");
    EXPECT(RectNear(npv.frame, CGRectMake(0, 0, 300, 300)) && !npv->_lastHidesArtwork, "300x300: the host keeps the whole screen (%s)",
           NSStringFromCGRect(npv.frame).UTF8String);
    EXPECT(PanelsIn(vc.view).count == 0 && !npv->_artworkViewBrick.isHidden, "300x300: no panel, the cover shows");

    // Right at the threshold: 336 pt of height fits the strip, 335 does not.
    vc.view.frame = CGRectMake(0, 0, 800, 336);
    [customizer applyPrefs];
    Pump(); Layout(vc); Layout(vc);
    EXPECT(fabs(customizer.playerStripHeight - 200.0) < 0.5 && RectNear(npv.frame, CGRectMake(0, 136, 800, 200)),
           "800x336: the strip (%s)", NSStringFromCGRect(npv.frame).UTF8String);
    panel = PanelsIn(vc.view).firstObject;
    EXPECT(panel && RectNear(panel.frame, CGRectMake(11, 8, 778, 120)), "800x336: the minimum lyrics height (%s)",
           NSStringFromCGRect(panel.frame).UTF8String);
    vc.view.frame = CGRectMake(0, 0, 800, 335);
    [customizer applyPrefs];
    Pump(); Layout(vc); Layout(vc);
    EXPECT(fabs(customizer.playerColumnWidth - 284.0) < 0.5 && customizer.playerStripHeight == 0.0 &&
           RectNear(npv.frame, CGRectMake(0, 0, 284, 335)),
           "800x335: the column (%.1f, %s)", customizer.playerColumnWidth, NSStringFromCGRect(npv.frame).UTF8String);
    EXPECT(npv->_lastHidesArtwork, "800x335: without artwork");

    [CLLayoutCustomizer detachFromViewController:vc];
    Pump(); Layout(vc);
    EXPECT(fabs(CGRectGetWidth(npv.frame) - 800.0) < 0.5 && !npv->_lastHidesArtwork, "fallbacks: detach restores the host");

    gSimulateColumnHooks = NO;
    CLLayoutCustomizer.hostColumnHooksInstalled = NO;
    ResetPrefs();
    Pump();
}

/// Layout > Hide Playback Speed Button (0.7.4): the "1×" in the play-mode row, which the host shows
/// for apps with rates (-_updatePlayModesState). Hidden after every host pass while the switch is
/// on; the host's own rule again once it is off, or on detach. The top bar is not involved.
static void TestPlaybackSpeedButton(void) {
    ResetPrefs();
    CLLayoutCustomizer.hostColumnHooksInstalled = YES;
    gSimulateColumnHooks = YES;
    gRateSupported = YES;

    CPUINowPlayingViewController *vc = [[CPUINowPlayingViewController alloc] init];
    vc.hostChain = YES;
    vc.view.frame = CGRectMake(0, 0, 800, 480);
    CPUINowPlayingView *npv = (CPUINowPlayingView *)vc->_nowPlayingView;
    CPUIPlayModeControlView *playMode = (CPUIPlayModeControlView *)npv->_playModeControlView;
    UIButton *rate = playMode->_playbackRateButton;
    CLLayoutCustomizer *customizer = [CLLayoutCustomizer customizerForViewController:vc create:YES];
    [vc _updatePlayModesState];
    Pump(); Layout(vc);
    EXPECT(!rate.isHidden, "speed: the host shows 1x for an app with rates");

    NSUInteger barItems = vc.navigationItem.rightBarButtonItems.count;
    SetPref(CLPrefKeyHidePlaybackRateButton, @YES);
    Pump(); Layout(vc);
    EXPECT(rate.isHidden, "speed: hidden with the switch on");
    [vc _updatePlayModesState];                 // the host shows it again on its next update...
    Pump(); Layout(vc);
    EXPECT(rate.isHidden, "speed: ...and it is hidden again right after");
    EXPECT(vc.navigationItem.rightBarButtonItems.count == barItems, "speed: the top bar is untouched");

    SetPref(CLPrefKeyHidePlaybackRateButton, @NO);
    Pump(); Layout(vc);
    EXPECT(!rate.isHidden, "speed: the switch off gives the host its rule back");

    SetPref(CLPrefKeyHidePlaybackRateButton, @YES);
    Pump(); Layout(vc);
    [CLLayoutCustomizer detachFromViewController:vc];
    Pump();
    EXPECT(!rate.isHidden, "speed: detach gives the host its rule back");
    (void)customizer;

    gRateSupported = NO;
    gSimulateColumnHooks = NO;
    CLLayoutCustomizer.hostColumnHooksInstalled = NO;
    ResetPrefs();
    Pump();
}

/// The microphone (0.7.0): our button joins the host's play-mode row (last, laid out by the host's
/// own -_updateButtonLayouts), survives host passes and new template buttons, leaves with lyrics
/// off; tapping it opens full-screen lyrics over the safe area with the host's view hidden, on any
/// screen — including one no split fits — and the view's own microphone, a detach or turning
/// lyrics off give the host everything back.
static void TestMicrophoneAndFullScreen(void) {
    ResetPrefs();
    CLLayoutCustomizer.hostColumnHooksInstalled = YES;
    gSimulateColumnHooks = YES;

    CPUINowPlayingViewController *vc = [[CPUINowPlayingViewController alloc] init];
    vc.hostChain = YES;
    vc.view.frame = CGRectMake(0, 0, 800, 480);
    CPUINowPlayingView *npv = (CPUINowPlayingView *)vc->_nowPlayingView;
    CPUIPlayModeControlView *playMode = (CPUIPlayModeControlView *)npv->_playModeControlView;
    UIStackView *stack = playMode->_stackView;
    NSUInteger updatesBefore = playMode->_layoutUpdates;
    CLLayoutCustomizer *customizer = [CLLayoutCustomizer customizerForViewController:vc create:YES];
    Pump(); Layout(vc); Layout(vc);

    UIButton *mic = customizer.microphoneButton;
    EXPECT(mic && stack.arrangedSubviews.count == 6 && stack.arrangedSubviews.lastObject == mic && !mic.isHidden,
           "microphone: last in the host's row, five visible (%lu)", (unsigned long)stack.arrangedSubviews.count);
    EXPECT(playMode->_layoutUpdates > updatesBefore, "microphone: the host's own layout sized it");
    Layout(vc);
    EXPECT(fabs(CGRectGetWidth(stack.frame) - 284.0) < 0.5 && fabs(CGRectGetWidth(mic.frame) - 44.0) < 0.5,
           "microphone: the row is 5 x 44 + 4 x 16 (%s, mic %s)", NSStringFromCGRect(stack.frame).UTF8String,
           NSStringFromCGRect(mic.frame).UTF8String);
    for (int i = 0; i < 3; i++) { [customizer relayout]; Layout(vc); }
    EXPECT(stack.arrangedSubviews.count == 6 && stack.arrangedSubviews.lastObject == mic, "microphone: stable over passes");
    // The host appends a template button (-setMediaButtons:): the microphone moves back to the end.
    UIButton *templateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [stack addArrangedSubview:templateButton];
    [playMode _updateButtonLayouts];
    [customizer relayout]; Layout(vc);
    EXPECT(stack.arrangedSubviews.count == 7 && stack.arrangedSubviews.lastObject == mic, "microphone: stays last after a new host button");
    [stack removeArrangedSubview:templateButton];
    [templateButton removeFromSuperview];
    [playMode _updateButtonLayouts];

    // Layout Off (0.8.2): CarPlay's own screen, but the microphone stays and still opens full screen.
    SetPref(CLPrefKeyLyricsMode, @(0));
    Pump(); Layout(vc); Layout(vc);
    EXPECT(customizer.microphoneButton.superview == stack && stack.arrangedSubviews.count == 6 &&
           stack.arrangedSubviews.lastObject == customizer.microphoneButton,
           "microphone: stays with Layout Off (%lu)", (unsigned long)stack.arrangedSubviews.count);
    EXPECT(fabs(CGRectGetWidth(npv.frame) - 800.0) < 0.5 && PanelsIn(vc.view).count == 0,
           "microphone: Layout Off is still the stock screen (%s)", NSStringFromCGRect(npv.frame).UTF8String);
    customizer.fullScreen = YES;
    Pump(); Layout(vc);
    EXPECT(customizer.isFullScreen && npv.isHidden, "microphone: full screen opens with Layout Off");
    customizer.fullScreen = NO;
    Pump(); Layout(vc);
    EXPECT(!customizer.isFullScreen && !npv.isHidden, "microphone: and closes back to the stock screen");
    SetPref(CLPrefKeyLyricsMode, @(4));
    Pump(); Layout(vc); Layout(vc);
    EXPECT(customizer.microphoneButton.superview == stack && stack.arrangedSubviews.count == 6, "microphone: still there with lyrics on");

    // The Lyrics Button switch (0.7.4): off takes the microphone out, on puts it back.
    SetPref(CLPrefKeyShowLyricsButton, @NO);
    Pump(); Layout(vc);
    EXPECT(mic.superview == nil && stack.arrangedSubviews.count == 5, "microphone: gone with the Lyrics Button off");
    customizer.fullScreen = YES;
    Pump(); Layout(vc);
    EXPECT(!customizer.isFullScreen && !npv.isHidden, "microphone: no full screen with the Lyrics Button off");
    SetPref(CLPrefKeyShowLyricsButton, @YES);
    Pump(); Layout(vc); Layout(vc);
    EXPECT(customizer.microphoneButton.superview == stack && stack.arrangedSubviews.count == 6, "microphone: back with the Lyrics Button on");

    // Tap it: full screen over the safe area, the host's view hidden under it.
    Tap(customizer.microphoneButton);
    Pump(); Layout(vc); Layout(vc);
    EXPECT(customizer.isFullScreen, "full screen: the microphone opens it");
    NSMutableArray *fullScreens = [NSMutableArray array];
    CollectViews(vc.view, CLLyricsFullScreenView.class, fullScreens);
    CLLyricsFullScreenView *fullScreen = fullScreens.firstObject;
    EXPECT(fullScreens.count == 1 && fullScreen.superview == vc.view && RectNear(fullScreen.frame, CGRectMake(0, 0, 800, 480)),
           "full screen: one view over the safe area (%lu, %s)", (unsigned long)fullScreens.count,
           NSStringFromCGRect(fullScreen.frame).UTF8String);
    EXPECT(npv.isHidden, "full screen: the host's Now Playing view is hidden under it");
    EXPECT(fullScreen.controlButtons.count == 4 && [fullScreen.controlButtons[1].accessibilityLabel length] > 0,
           "full screen: previous, play/pause, next, close");
    CLLyricsPanelView *sidePanel = nil;
    for (CLLyricsPanelView *candidate in PanelsIn(vc.view)) {
        if (candidate != fullScreen.panelView) sidePanel = candidate;
    }
    EXPECT(!sidePanel || sidePanel.isHidden, "full screen: the split's own panel is hidden");
    [fullScreen.panelView setLyrics:SyncedLyrics()];
    [fullScreen.panelView setCurrentLineIndex:0 animated:NO];
    [customizer relayout]; Layout(vc);
    EXPECT(!fullScreen.panelView.isHidden && CGRectGetWidth(fullScreen.panelView.frame) > 700.0,
           "full screen: the lyrics span the width (%s)", NSStringFromCGRect(fullScreen.panelView.frame).UTF8String);
    EXPECT(fullScreen.panelView.fit == CLLayoutPanelFitRows, "full screen: the rows fit");
    for (UIButton *button in fullScreen.controlButtons) {
        EXPECT(CGRectGetMaxY([button convertRect:button.bounds toView:vc.view]) <= 480.5 &&
               CGRectGetMinY([button convertRect:button.bounds toView:vc.view]) >= CGRectGetMaxY(RootFrame(fullScreen.panelView, vc)),
               "full screen: %s sits under the lyrics", button.accessibilityLabel.UTF8String);
    }

    // The progress line: hidden while nothing with a length plays; with one, a thin row between the
    // lyrics and the controls, as wide as the row under it.
    EXPECT(fullScreen.progressView.isHidden, "full screen: no progress line without a song length");
    CLPlaybackState *playing = [[CLPlaybackState alloc] initWithTitle:@"Song" artist:@"Artist" album:nil duration:200.0
                                                          elapsedTime:50.0 timestamp:[NSDate date] playbackRate:0.0
                                                     bundleIdentifier:nil contentIdentifier:nil isPlaying:NO
                                                      isAdvertisement:NO origin:CLPlaybackStateOriginMediaRemote];
    [fullScreen setPlaybackState:playing];
    [fullScreen layoutIfNeeded];
    CGRect progress = RootFrame(fullScreen.progressView, vc);
    CGRect lyricsFrame = RootFrame(fullScreen.panelView, vc);
    CGFloat rowTop = CGFLOAT_MAX;
    for (UIButton *button in fullScreen.controlButtons) rowTop = MIN(rowTop, CGRectGetMinY(RootFrame(button, vc)));
    EXPECT(!fullScreen.progressView.isHidden && CGRectGetHeight(progress) <= 14.5 && CGRectGetWidth(progress) > 700.0 &&
           CGRectGetMinY(progress) >= CGRectGetMaxY(lyricsFrame) - 0.5 && CGRectGetMaxY(progress) <= rowTop + 0.5,
           "full screen: a thin progress line between the lyrics and the controls (%s, lyrics %s, row top %.1f)",
           NSStringFromCGRect(progress).UTF8String, NSStringFromCGRect(lyricsFrame).UTF8String, rowTop);
    NSArray<UILabel *> *times = LabelsIn(fullScreen.progressView);
    EXPECT(times.count == 2 && [times.firstObject.text isEqualToString:@"0:50"] && [times.lastObject.text isEqualToString:@"-2:30"],
           "full screen: elapsed and remaining (%s / %s)", times.firstObject.text.UTF8String, times.lastObject.text.UTF8String);
    [fullScreen setProgressHidden:YES];
    EXPECT(fullScreen.progressView.isHidden, "full screen: Progress Bar Hide hides the line too");
    [fullScreen setProgressHidden:NO];
    EXPECT(!fullScreen.progressView.isHidden, "full screen: and shows it again");

    // Its own microphone closes it and gives the host its view back.
    Tap(fullScreen.controlButtons.lastObject);
    Pump(); Layout(vc);
    EXPECT(!customizer.isFullScreen && !npv.isHidden && ForeignViewCount(vc.view) == 0,
           "full screen: closing restores the host (%lu foreign)", (unsigned long)ForeignViewCount(vc.view));

    // A screen no split fits (the stock screen, effective 0) still gets the microphone and full screen.
    vc.view.frame = CGRectMake(0, 0, 300, 300);
    [customizer applyPrefs];
    Pump(); Layout(vc); Layout(vc);
    EXPECT(customizer.playerColumnWidth == 0.0 && customizer.playerStripHeight == 0.0 &&
           customizer.microphoneButton.superview == stack, "300x300: no split, but the microphone");
    customizer.fullScreen = YES;
    Pump(); Layout(vc);
    [fullScreens removeAllObjects];
    CollectViews(vc.view, CLLyricsFullScreenView.class, fullScreens);
    EXPECT(customizer.isFullScreen && fullScreens.count == 1 &&
           RectNear([(UIView *)fullScreens.firstObject frame], CGRectMake(0, 0, 300, 300)) && npv.isHidden,
           "300x300: full screen fills the screen");

    // Detaching in full screen restores everything.
    [CLLayoutCustomizer detachFromViewController:vc];
    Pump(); Layout(vc);
    EXPECT(!npv.isHidden && ForeignViewCount(vc.view) == 0 && stack.arrangedSubviews.count == 5 && mic.superview == nil,
           "full screen: detach restores the host view and its row (%lu buttons)", (unsigned long)stack.arrangedSubviews.count);

    gSimulateColumnHooks = NO;
    CLLayoutCustomizer.hostColumnHooksInstalled = NO;
    ResetPrefs();
    Pump();
}

/// lyricsMode 3 (Replace Artwork, removed in 0.6.0) on disk reads as side by side: the column,
/// the lyrics beside it, the cover left alone apart from its corner radius, and never a panel on
/// the artwork square.
static void TestRemovedReplaceArtwork(void) {
    ResetPrefs();
    CLLayoutCustomizer.hostColumnHooksInstalled = YES;
    gSimulateColumnHooks = YES;
    SetPref(CLPrefKeyLyricsMode, @(3));
    SetPref(CLPrefKeyArtworkCornerRadius, @(30));
    EXPECT(CLPrefs.shared.lyricsMode == 4, "removed mode 3 reads as 4 (%ld)", (long)CLPrefs.shared.lyricsMode);

    CPUINowPlayingViewController *vc = [[CPUINowPlayingViewController alloc] init];
    vc.hostChain = YES;
    (void)vc.view;
    CPUINowPlayingView *npv = (CPUINowPlayingView *)vc->_nowPlayingView;
    CLLayoutCustomizer *customizer = [CLLayoutCustomizer customizerForViewController:vc create:YES];
    Pump(); Layout(vc); Layout(vc);

    EXPECT(fabs(customizer.playerColumnWidth - 360.0) < 0.5 && RectNear(npv.frame, CGRectMake(0, 0, 360, 480)),
           "mode 3: the side-by-side column (%.1f, %s)", customizer.playerColumnWidth, NSStringFromCGRect(npv.frame).UTF8String);
    NSArray<CLLyricsPanelView *> *panels = PanelsIn(vc.view);
    EXPECT(panels.count == 1, "mode 3: one panel (%lu)", (unsigned long)panels.count);
    CLLyricsPanelView *panel = panels.firstObject;
    [panel setLyrics:SyncedLyrics()];
    [customizer relayout];
    Layout(vc);
    EXPECT(panel.superview == vc.view && CGRectGetMinX(panel.frame) >= 375.5, "mode 3: the lyrics beside the column (%s)",
           NSStringFromCGRect(panel.frame).UTF8String);
    EXPECT(!npv->_artworkViewBrick.isHidden, "mode 3: the cover is never hidden for the lyrics");
    EXPECT(fabs(panel.layer.cornerRadius) < 0.01, "mode 3: the panel is not rounded (%.1f)", panel.layer.cornerRadius);
    EXPECT(fabs(npv->_artworkViewBrick.layer.cornerRadius - 30.0) < 0.01, "mode 3: the cover's own radius");

    [CLLayoutCustomizer detachFromViewController:vc];
    Pump();
    EXPECT(fabs(npv->_artworkViewBrick.layer.cornerRadius) < 0.01, "mode 3: detach restores the cover's radius");
    gSimulateColumnHooks = NO;
    CLLayoutCustomizer.hostColumnHooksInstalled = NO;
    ResetPrefs();
    Pump();
}

/// Values a 0.4.0 install may still have on disk: lyricsMode 1 (the overlay) reads as side by
/// side, progressBarStyle 1 (thin) as the system bar, and the six removed keys change nothing.
static void TestLegacyPrefs(void) {
    ResetPrefs();
    CLLayoutCustomizer.hostColumnHooksInstalled = YES;
    gSimulateColumnHooks = YES;
    SetPref(CLPrefKeyLyricsMode, @(1));
    SetPref(CLPrefKeyProgressBarStyle, @(1));
    SetPref(@"lyricsPosition", @(1));
    SetPref(@"lyricsMaxLines", @(5));
    SetPref(@"artworkScale", @(0.6));
    SetPref(@"titleFontSize", @(34));
    SetPref(@"compactMode", @YES);
    SetPref(@"hideAppBadge", @YES);
    EXPECT(CLPrefs.shared.lyricsMode == 4, "legacy: lyricsMode 1 reads as 4 (%ld)", (long)CLPrefs.shared.lyricsMode);
    EXPECT(CLPrefs.shared.progressBarStyle == 0, "legacy: progressBarStyle 1 reads as 0 (%ld)", (long)CLPrefs.shared.progressBarStyle);
    EXPECT(CLPrefs.shared.snapshot[@"lyricsPosition"] == nil && CLPrefs.shared.snapshot[@"artworkScale"] == nil &&
           CLPrefs.shared.snapshot[@"compactMode"] == nil, "legacy: the removed keys are not resolved at all");

    CPUINowPlayingViewController *vc = [[CPUINowPlayingViewController alloc] init];
    (void)vc.view;
    CPUINowPlayingView *npv = (CPUINowPlayingView *)vc->_nowPlayingView;
    UILabel *titleLabel = LabelsIn(npv->_songDetailsView).firstObject;
    CGFloat originalTitleSize = titleLabel.font.pointSize;
    CLLayoutCustomizer *customizer = [CLLayoutCustomizer customizerForViewController:vc create:YES];
    Pump(); Layout(vc); Layout(vc);

    EXPECT(fabs(customizer.playerColumnWidth - 360.0) < 0.5, "legacy: mode 1 gives the side-by-side column (%.1f)",
           customizer.playerColumnWidth);
    EXPECT(RectNear(npv.frame, CGRectMake(0, 0, 360, 480)), "legacy: the host is the column (%s)", NSStringFromCGRect(npv.frame).UTF8String);
    EXPECT(!npv->_progressView.isHidden && CGAffineTransformIsIdentity(npv->_progressView.transform),
           "legacy: the progress bar is shown, untransformed");
    EXPECT(CGAffineTransformIsIdentity(npv->_artworkViewBrick.transform), "legacy: artworkScale does nothing");
    EXPECT(fabs(npv->_songDetailsViewHeightConstraint.constant - 100.0) < 0.5, "legacy: compactMode does nothing (%.1f)",
           npv->_songDetailsViewHeightConstraint.constant);
    EXPECT(fabs(titleLabel.font.pointSize - originalTitleSize) < 0.01, "legacy: titleFontSize does nothing (%.1f)",
           titleLabel.font.pointSize);
    NSMutableArray *badges = [NSMutableArray array];
    CollectViews(npv->_songDetailsView, UIImageView.class, badges);
    EXPECT(badges.count == 1 && ![(UIImageView *)badges.firstObject isHidden], "legacy: hideAppBadge does nothing");
    EXPECT(PanelsIn(vc.view).count == 1 && ForeignViewCount(vc.view) == 0, "legacy: one panel, no overlay");

    [CLLayoutCustomizer detachFromViewController:vc];
    Pump();
    gSimulateColumnHooks = NO;
    CLLayoutCustomizer.hostColumnHooksInstalled = NO;
    ResetPrefs();
    Pump();
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        ResetPrefs();
        TestPanel();
        TestNoteLinesAreGaps();

        CPUINowPlayingViewController *vc = [[CPUINowPlayingViewController alloc] init];
        (void)vc.view;
        TestCustomizerDefaults(vc);
        TestCustomizerPrefs(vc);
        TestDetach(vc);
        TestBarrenController();
        TestControllerDealloc();

        CPUINowPlayingViewController *stressController = [[CPUINowPlayingViewController alloc] init];
        (void)stressController.view;
        TestStress(stressController);

        TestClearedKeyDoesNotComeBack();
        TestProgressFollowsHost();
        TestPauseResume();
        TestSideBySide();
        TestFullPanel();
        TestFullPanelFallbacks();
        TestWidescreenUnit();
        TestRemovedReplaceArtwork();
        TestMicrophoneAndFullScreen();
        TestPlaybackSpeedButton();
        TestLegacyPrefs();

        ResetPrefs();
        Pump();
        printf("\n%d passed, %d failed\n", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
