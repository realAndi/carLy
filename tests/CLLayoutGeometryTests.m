// Tests for the header-only UI/CLLayoutGeometry.h: the plan a screen gets for a lyricsMode, the
// host's own thresholds (transport button height, title tier, chain height) and the rects both
// the tweak and the settings preview derive from a plan. Every number here is from
// docs/research/CarPlayUI-17.3-layout.md (verified by disassembly); the harness in tests/ui
// checks the same rects against a fake host laid out with Auto Layout.
//
// Foundation + CoreGraphics only: no UIKit, no CLPrefs, no host classes.
#import "CLLayoutGeometryTests.h"
#import "CLTestCase.h"
#import "UI/CLLayoutGeometry.h"

/// Rects are asserted to ±0.5, the tolerance the tweak and the preview agree on.
#define CL_ASSERT_RECT(actual, x, y, w, h) do { \
    CGRect cl_r = (actual); \
    CL_ASSERT_NEAR(CGRectGetMinX(cl_r), (x), 0.5); \
    CL_ASSERT_NEAR(CGRectGetMinY(cl_r), (y), 0.5); \
    CL_ASSERT_NEAR(CGRectGetWidth(cl_r), (w), 0.5); \
    CL_ASSERT_NEAR(CGRectGetHeight(cl_r), (h), 0.5); \
} while (0)

static const CGFloat kRatio = CLLayoutDefaultSideArtworkRatio;

/// One row of the worked-numbers table: the plan for `mode` on `safe`, its player rect (in safe
/// coordinates) and its lyrics rect (in root coordinates). Pass CGRectNull for "no rect".
static void CLAssertPlan(NSInteger mode, CGRect safe, NSInteger effective, CLLayoutPlayerArea area,
                         CGFloat width, CGFloat height, BOOL hidesArtwork, CGRect player, CGRect lyrics) {
    CLLayoutPlan plan = CLLayoutPlanMake(mode, safe, kRatio, YES);
    CL_ASSERT_EQ((long)plan.effectiveMode, (long)effective);
    CL_ASSERT_EQ((long)plan.playerArea, (long)area);
    CL_ASSERT_NEAR(plan.playerWidth, width, 0.5);
    CL_ASSERT_NEAR(plan.playerHeight, height, 0.5);
    CL_ASSERT_EQ((long)plan.hidesArtwork, (long)hidesArtwork);

    CGRect actualPlayer = CLLayoutPlayerRect(plan, safe);
    CGRect actualLyrics = CLLayoutLyricsRect(plan, safe);
    if (CGRectIsNull(player)) {
        CL_ASSERT_TRUE(CGRectIsNull(actualPlayer));
    } else {
        CL_ASSERT_RECT(actualPlayer, CGRectGetMinX(player), CGRectGetMinY(player), CGRectGetWidth(player), CGRectGetHeight(player));
    }
    if (CGRectIsNull(lyrics)) {
        CL_ASSERT_TRUE(CGRectIsNull(actualLyrics));
    } else {
        CL_ASSERT_RECT(actualLyrics, CGRectGetMinX(lyrics), CGRectGetMinY(lyrics), CGRectGetWidth(lyrics), CGRectGetHeight(lyrics));
    }
}

static void CLTestModeNormalize(void) {
    CL_ASSERT_EQ((long)CLLayoutModeNormalize(1), (long)4);
    CL_ASSERT_EQ((long)CLLayoutModeNormalize(-3), (long)0);
    CL_ASSERT_EQ((long)CLLayoutModeNormalize(9), (long)4);
    CL_ASSERT_EQ((long)CLLayoutModeNormalize(0), (long)0);
    CL_ASSERT_EQ((long)CLLayoutModeNormalize(2), (long)2);
    CL_ASSERT_EQ((long)CLLayoutModeNormalize(3), (long)4);      // Replace Artwork, removed in 0.6.0
    CL_ASSERT_EQ((long)CLLayoutModeNormalize(4), (long)4);
}

static void CLTestColumnWidths(void) {
    // Stacked columns (safe height >= 260) are unchanged since 0.2.1.
    CL_ASSERT_NEAR(CLLayoutPlayerColumnWidth(CGRectMake(0, 44, 800, 436), kRatio), 349.0, 0.5);
    CL_ASSERT_NEAR(CLLayoutPlayerColumnWidth(CGRectMake(0, 0, 800, 480), kRatio), 360.0, 0.5);
    CL_ASSERT_NEAR(CLLayoutPlayerColumnWidth(CGRectMake(0, 44, 600, 556), kRatio), 0.0, 0.5);
    // Short screens get the narrowest side layout, ceil(h x 1.45): 0.5.1. (0.5.0: 424 and 353.)
    CL_ASSERT_NEAR(CLLayoutPlayerColumnWidth(CGRectMake(0, 0, 640, 240), kRatio), 348.0, 0.5);
    CL_ASSERT_NEAR(CLLayoutPlayerColumnWidth(CGRectMake(45, 44, 595, 196), kRatio), 285.0, 0.5);
    // The host's own ratio is a float (1.350000023841858); it must not round a column up either.
    CL_ASSERT_NEAR(CLLayoutPlayerColumnWidth(CGRectMake(0, 0, 640, 240), 1.350000023841858), 348.0, 0.5);
    CL_ASSERT_NEAR(CLLayoutPlayerColumnWidth(CGRectMake(45, 44, 595, 196), 1.350000023841858), 285.0, 0.5);
    // The side layout's column stays on the host's side of the chooser's ratio.
    CL_ASSERT_TRUE(285.0 / 196.0 >= kRatio);
    // ...but never narrower than its transport row needs beside the art: 278 pt with 36 pt buttons
    // (safe height <= 207), 314 with 44. At 170 pt 1.45 x h alone would give 247 (a 123 pt row for
    // 128 pt of buttons), at 210 pt 305 (146 for 152).
    CL_ASSERT_NEAR(CLLayoutSidePlayerMinimumWidth(36.0), 278.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutSidePlayerMinimumWidth(44.0), 314.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutPlayerColumnWidth(CGRectMake(45, 44, 595, 170), kRatio), 278.0, 0.5);
    CL_ASSERT_NEAR(CLLayoutPlayerColumnWidth(CGRectMake(0, 0, 640, 210), kRatio), 314.0, 0.5);
    CL_ASSERT_NEAR(CLLayoutPlayerColumnWidth(CGRectMake(0, 0, 640, 207), kRatio), 301.0, 0.5);
    // The row at 285 pt on the 1920x720 unit: 285 - 16 - 0.32 x 285 - 45 = 132.8 >= 3 x 36 + 20.
    CL_ASSERT_TRUE(285.0 - CLLayoutHostSideControlsChrome - CLLayoutHostSideArtMultiplier * 285.0 >=
                   3.0 * CLLayoutHostTransportSmall + 2.0 * CLLayoutHostSideButtonSpacing);
    // Too narrow to leave the lyrics 200 pt beside a short-screen player: no column.
    CL_ASSERT_NEAR(CLLayoutPlayerColumnWidth(CGRectMake(0, 0, 500, 196), kRatio), 0.0, 0.5);
    CL_ASSERT_NEAR(CLLayoutPlayerColumnWidth(CGRectMake(0, 0, 501, 196), kRatio), 285.0, 0.5);
    CL_ASSERT_NEAR(CLLayoutPlayerColumnWidth(CGRectZero, kRatio), 0.0, 0.5);
    CL_ASSERT_TRUE(CLLayoutHostStacksSafeArea(CGRectMake(0, 44, 600, 556), kRatio));
    CL_ASSERT_FALSE(CLLayoutHostStacksSafeArea(CGRectMake(0, 0, 800, 480), kRatio));
    CL_ASSERT_TRUE(CLLayoutHostStacksSafeArea(CGRectZero, kRatio));
}

static void CLTestHostThresholds(void) {
    // -[_CPUINowPlayingLayout transportControlButtonHeight].
    CL_ASSERT_NEAR(CLLayoutHostTransportButtonHeight(CGSizeMake(800, 200), 2.0), 36.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutHostTransportButtonHeight(CGSizeMake(800, 312), 2.0), 36.0, 0.01);   // 1600 px wide needs > 720 px
    CL_ASSERT_NEAR(CLLayoutHostTransportButtonHeight(CGSizeMake(600, 312), 2.0), 44.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutHostTransportButtonHeight(CGSizeMake(640, 208), 3.0), 36.0, 0.01);   // 1920 px wide needs > 720 px
    CL_ASSERT_NEAR(CLLayoutHostTransportButtonHeight(CGSizeMake(400, 208), 3.0), 44.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutHostTransportButtonHeight(CGSizeMake(400, 207), 3.0), 36.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutHostTransportButtonHeight(CGSizeMake(800, 200), 3.0), 36.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutHostTransportButtonHeight(CGSizeMake(800, 480), 2.0), 44.0, 0.01);   // the stock 800x480 screen
    CL_ASSERT_NEAR(CLLayoutHostTransportButtonHeight(CGSizeMake(640, 240), 3.0), 36.0, 0.01);   // a 1920x720 unit

    // -[CPUINowPlayingLayoutStacked maximumTitleViewSize] and trackInfoFontStyle.
    CGSize strip = CLLayoutHostTitleAreaSize(CGRectMake(0, 280, 800, 200), NO, 0.0, 36.0);
    CL_ASSERT_NEAR(strip.width, 746.0, 0.01);
    CL_ASSERT_NEAR(strip.height, 90.0, 0.01);
    CL_ASSERT_FALSE(CLLayoutHostUsesLargeTier(strip));
    CGSize strip215 = CLLayoutHostTitleAreaSize(CGRectMake(0, 265, 800, 215), NO, 0.0, 36.0);
    CL_ASSERT_NEAR(strip215.height, 105.0, 0.01);
    CL_ASSERT_FALSE(CLLayoutHostUsesLargeTier(strip215));
    CGSize strip216 = CLLayoutHostTitleAreaSize(CGRectMake(0, 264, 800, 216), NO, 0.0, 36.0);
    CL_ASSERT_NEAR(strip216.height, 106.0, 0.01);
    CL_ASSERT_TRUE(CLLayoutHostUsesLargeTier(strip216));
    // Wide enough in height but too narrow for the large tier.
    CL_ASSERT_FALSE(CLLayoutHostUsesLargeTier(CGSizeMake(299.0, 200.0)));
    // With artwork the art's height and its 8 pt gap come out of the title area; without artwork
    // the height is capped at 480 (CPUINowPlayingMaximumNoArtworkSize).
    CGSize withArt = CLLayoutHostTitleAreaSize(CGRectMake(0, 0, 360, 480), YES, 216.0, 44.0);
    CL_ASSERT_NEAR(withArt.height, 480.0 - 14.0 - 60.0 - 44.0 - 8.0 - 216.0, 0.01);
    CGSize tall = CLLayoutHostTitleAreaSize(CGRectMake(0, 0, 600, 756), NO, 0.0, 44.0);
    CL_ASSERT_NEAR(tall.height, 480.0 - 14.0 - 60.0 - 44.0, 0.01);

    // The artwork-less stacked chain: 2 + details + 3 x 8 + transport + 10 + 26 + 12.
    CL_ASSERT_NEAR(CLLayoutHostStackedChainHeight(NO, 36.0), 182.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutHostStackedChainHeight(NO, 44.0), 190.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutHostStackedChainHeight(YES, 36.0), 216.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutHostStackedChainHeight(YES, 44.0), 224.0, 0.01);
    // The strip must hold the chain the host builds for it (small tier, 36 pt buttons).
    CL_ASSERT_TRUE(CLLayoutHostStackedChainHeight(NO, 36.0) <= CLLayoutFullPanelStripHeight);
    CL_ASSERT_TRUE(CLLayoutHostStackedChainHeight(NO, 44.0) <= CLLayoutFullPanelStripHeight);
    // ...and stay under both host thresholds: 36 pt buttons at @3x (< 208) and the small tier (< 216).
    CL_ASSERT_TRUE(CLLayoutFullPanelStripHeight * 3.0 < CLLayoutHostSmallButtonsMaxScaledHeight);
    CL_ASSERT_TRUE(CLLayoutFullPanelStripHeight < 216.0);

    // The view area a player column is handed: trimmed only where the full height would give it
    // bigger transport buttons than the whole screen gets (1920x720 @3x: 36 there, 44 in a column).
    CL_ASSERT_NEAR(CLLayoutPlayerViewAreaHeight(CGSizeMake(640, 240), 285.0, 196.0, 3.0), 207.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutHostTransportButtonHeight(CGSizeMake(285, 207), 3.0), 36.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutPlayerViewAreaHeight(CGSizeMake(640, 240), 240.0, 196.0, 3.0), 207.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutPlayerViewAreaHeight(CGSizeMake(800, 480), 360.0, 480.0, 2.0), 480.0, 0.01);   // 44 either way
    CL_ASSERT_NEAR(CLLayoutPlayerViewAreaHeight(CGSizeMake(800, 480), 349.0, 436.0, 2.0), 480.0, 0.01);
    // No trim below the area's safe height: the harness's 640x240 has no bars (safe 240 > 207).
    CL_ASSERT_NEAR(CLLayoutPlayerViewAreaHeight(CGSizeMake(640, 240), 348.0, 240.0, 3.0), 240.0, 0.01);
    // A missing scale reads as 1.
    CL_ASSERT_NEAR(CLLayoutPlayerViewAreaHeight(CGSizeMake(640, 240), 285.0, 196.0, 0.0), 240.0, 0.01);
    // A short column gets the small buttons even where the full screen has 44 (780 px tall).
    CL_ASSERT_NEAR(CLLayoutHostTransportButtonHeight(CGSizeMake(640, 260), 3.0), 44.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutPlayerViewAreaHeight(CGSizeMake(640, 260), 290.0, 200.0, 3.0), 207.0, 0.01);
    // Every column at most CLLayoutSmallButtonsMaximumSafeHeight tall can be trimmed at @2x and @3x.
    CL_ASSERT_NEAR(floor((CLLayoutHostSmallButtonsMaxScaledHeight - 1.0) / CLLayoutDensestCarPlayScale),
                   CLLayoutSmallButtonsMaximumSafeHeight, 0.01);
    CL_ASSERT_NEAR(CLLayoutPlayerViewAreaHeight(CGSizeMake(640, 240), 301.0, 207.0, 3.0), 207.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutPlayerViewAreaHeight(CGSizeMake(640, 240), 301.0, 207.0, 2.0), 240.0, 0.01);   // 36 already

    // The Full Panel's cover-less column: the 190 pt chain in the height, 284 + 16 + 16 + 240 across.
    CL_ASSERT_TRUE(CLLayoutFullPanelColumnFits(CGRectMake(45, 44, 595, 196)));
    CL_ASSERT_TRUE(CLLayoutFullPanelColumnFits(CGRectMake(0, 0, 556, 190)));
    CL_ASSERT_FALSE(CLLayoutFullPanelColumnFits(CGRectMake(0, 0, 555, 300)));
    CL_ASSERT_FALSE(CLLayoutFullPanelColumnFits(CGRectMake(0, 0, 800, 189)));
    // Its play-mode row (Spotify's four buttons and the microphone: 5 x 44 + 4 x 16) stays inside the
    // column, and its transport row (3 x 44 + 2 x 16) fits between the 27 pt margins.
    CL_ASSERT_EQ((long)CLLayoutPlayModeButtonCount, 5L);
    CL_ASSERT_TRUE(CLLayoutPlayModeButtonCount * 44.0 + (CLLayoutPlayModeButtonCount - 1) * 16.0 <= CLLayoutFullPanelColumnWidth);
    CL_ASSERT_TRUE(3.0 * 44.0 + 2.0 * 16.0 <= CLLayoutFullPanelColumnWidth - 2.0 * CLLayoutHostMarginSide);

    // The strip fits from 336 pt of safe height (200 + 2 x 8 + 120).
    CL_ASSERT_TRUE(CLLayoutFullPanelStripFits(CGRectMake(0, 0, 800, 336)));
    CL_ASSERT_FALSE(CLLayoutFullPanelStripFits(CGRectMake(0, 0, 800, 335)));
    CL_ASSERT_FALSE(CLLayoutFullPanelStripFits(CGRectMake(0, 0, 0, 480)));
}

static void CLTestWorkedNumbers(void) {
    // Real units (44 pt navigation bar), pref 2 and 4.
    CLAssertPlan(2, CGRectMake(0, 44, 800, 436), 5, CLLayoutPlayerAreaBottomStrip, 0, 200, YES,
                 CGRectMake(0, 280, 800, 200), CGRectMake(11, 52, 778, 220));
    CLAssertPlan(4, CGRectMake(0, 44, 800, 436), 4, CLLayoutPlayerAreaLeadingColumn, 349, 0, NO,
                 CGRectMake(0, 44, 349, 436), CGRectMake(365, 52, 419, 420));
    // A 1920x720 @3x unit (the CarPlay Simulator's Widescreen): Full Panel is the cover-less
    // column, Side by Side the narrowest side layout. (0.5.0: both 353 pt with art, lyrics 210;
    // 0.5.1 – 0.6.1: a 240 pt column, before the microphone joined the play-mode row.)
    CLAssertPlan(2, CGRectMake(45, 44, 595, 196), 5, CLLayoutPlayerAreaLeadingColumn, 284, 0, YES,
                 CGRectMake(45, 44, 284, 196), CGRectMake(345, 52, 279, 180));
    CLAssertPlan(4, CGRectMake(45, 44, 595, 196), 4, CLLayoutPlayerAreaLeadingColumn, 285, 0, NO,
                 CGRectMake(45, 44, 285, 196), CGRectMake(346, 52, 278, 180));
    CLAssertPlan(2, CGRectMake(0, 44, 600, 756), 5, CLLayoutPlayerAreaBottomStrip, 0, 200, YES,
                 CGRectMake(0, 600, 600, 200), CGRectMake(11, 52, 578, 540));
    CLAssertPlan(4, CGRectMake(0, 44, 600, 756), 5, CLLayoutPlayerAreaBottomStrip, 0, 200, YES,
                 CGRectMake(0, 600, 600, 200), CGRectMake(11, 52, 578, 540));

    // Harness screens (no navigation bar).
    CLAssertPlan(2, CGRectMake(0, 0, 800, 480), 5, CLLayoutPlayerAreaBottomStrip, 0, 200, YES,
                 CGRectMake(0, 280, 800, 200), CGRectMake(11, 8, 778, 264));
    CLAssertPlan(4, CGRectMake(0, 0, 800, 480), 4, CLLayoutPlayerAreaLeadingColumn, 360, 0, NO,
                 CGRectMake(0, 0, 360, 480), CGRectMake(376, 8, 408, 464));
    CLAssertPlan(2, CGRectMake(0, 0, 640, 240), 5, CLLayoutPlayerAreaLeadingColumn, 284, 0, YES,
                 CGRectMake(0, 0, 284, 240), CGRectMake(300, 8, 324, 224));
    CLAssertPlan(4, CGRectMake(0, 0, 640, 240), 4, CLLayoutPlayerAreaLeadingColumn, 348, 0, NO,
                 CGRectMake(0, 0, 348, 240), CGRectMake(364, 8, 260, 224));
    CLAssertPlan(4, CGRectMake(0, 0, 600, 600), 5, CLLayoutPlayerAreaBottomStrip, 0, 200, YES,
                 CGRectMake(0, 400, 600, 200), CGRectMake(11, 8, 578, 384));
    CLAssertPlan(2, CGRectMake(0, 0, 600, 300), 5, CLLayoutPlayerAreaLeadingColumn, 284, 0, YES,
                 CGRectMake(0, 0, 284, 300), CGRectMake(300, 8, 284, 284));
    CLAssertPlan(2, CGRectMake(0, 0, 300, 300), 0, CLLayoutPlayerAreaNone, 0, 0, NO, CGRectNull, CGRectNull);
    CLAssertPlan(4, CGRectMake(0, 0, 300, 300), 0, CLLayoutPlayerAreaNone, 0, 0, NO, CGRectNull, CGRectNull);
    CLAssertPlan(2, CGRectMake(0, 0, 800, 336), 5, CLLayoutPlayerAreaBottomStrip, 0, 200, YES,
                 CGRectMake(0, 136, 800, 200), CGRectMake(11, 8, 778, 120));
    CLAssertPlan(2, CGRectMake(0, 0, 800, 335), 5, CLLayoutPlayerAreaLeadingColumn, 284, 0, YES,
                 CGRectMake(0, 0, 284, 335), CGRectMake(300, 8, 484, 319));
    // Too narrow for either column once the play-mode row holds five buttons (0.7.0: a 264 pt
    // stacked column leaves 200 pt of lyrics): CarPlay's own screen, and the microphone.
    CLAssertPlan(2, CGRectMake(0, 0, 480, 272), 0, CLLayoutPlayerAreaNone, 0, 0, NO, CGRectNull, CGRectNull);
    CLAssertPlan(4, CGRectMake(0, 0, 480, 272), 0, CLLayoutPlayerAreaNone, 0, 0, NO, CGRectNull, CGRectNull);
    // No Artwork's column does not fit 540 wide (224 pt of lyrics), the stacked split does.
    CLAssertPlan(2, CGRectMake(0, 0, 540, 300), 4, CLLayoutPlayerAreaLeadingColumn, 264, 0, NO,
                 CGRectMake(0, 0, 264, 300), CGRectMake(280, 8, 244, 284));
    // A 1280x720 @2x unit (640x360 pt, safe 595x316): the stacked column grows from 253 to the
    // 264 pt the five-button row needs.
    CLAssertPlan(4, CGRectMake(45, 44, 595, 316), 4, CLLayoutPlayerAreaLeadingColumn, 264, 0, NO,
                 CGRectMake(45, 44, 264, 316), CGRectMake(325, 52, 299, 300));

    // Off never touches the host, whatever the screen.
    CLAssertPlan(0, CGRectMake(0, 0, 800, 480), 0, CLLayoutPlayerAreaNone, 0, 0, NO, CGRectNull, CGRectNull);
    // The removed overlay (1) and Replace Artwork (3) read as side by side; out-of-range values clamp.
    CLAssertPlan(3, CGRectMake(0, 0, 800, 480), 4, CLLayoutPlayerAreaLeadingColumn, 360, 0, NO,
                 CGRectMake(0, 0, 360, 480), CGRectMake(376, 8, 408, 464));
    CLAssertPlan(3, CGRectMake(45, 44, 595, 196), 4, CLLayoutPlayerAreaLeadingColumn, 285, 0, NO,
                 CGRectMake(45, 44, 285, 196), CGRectMake(346, 52, 278, 180));
    CLAssertPlan(1, CGRectMake(0, 0, 800, 480), 4, CLLayoutPlayerAreaLeadingColumn, 360, 0, NO,
                 CGRectMake(0, 0, 360, 480), CGRectMake(376, 8, 408, 464));
    CLAssertPlan(9, CGRectMake(0, 0, 800, 480), 4, CLLayoutPlayerAreaLeadingColumn, 360, 0, NO,
                 CGRectMake(0, 0, 360, 480), CGRectMake(376, 8, 408, 464));
    CLAssertPlan(-1, CGRectMake(0, 0, 800, 480), 0, CLLayoutPlayerAreaNone, 0, 0, NO, CGRectNull, CGRectNull);
}

/// Layout > Lyrics Side: Left (0.7.5) mirrors a player column to the trailing edge and the lyrics to
/// the leading side; the strip and plans without a player area are untouched.
static void CLTestLyricsSide(void) {
    CGRect widescreen = CGRectMake(45, 44, 595, 196);
    CLLayoutPlan side = CLLayoutPlanPlacingLyrics(CLLayoutPlanMake(4, widescreen, kRatio, YES), CLLayoutLyricsSideLeft);
    CL_ASSERT_TRUE(side.playerOnTrailing);
    CL_ASSERT_RECT(CLLayoutPlayerRect(side, widescreen), 355, 44, 285, 196);
    CL_ASSERT_RECT(CLLayoutLyricsRect(side, widescreen), 61, 52, 278, 180);
    CLLayoutPlan column = CLLayoutPlanPlacingLyrics(CLLayoutPlanMake(2, widescreen, kRatio, YES), CLLayoutLyricsSideLeft);
    CL_ASSERT_TRUE(column.playerOnTrailing && column.hidesArtwork);
    CL_ASSERT_RECT(CLLayoutPlayerRect(column, widescreen), 356, 44, 284, 196);
    CL_ASSERT_RECT(CLLayoutLyricsRect(column, widescreen), 61, 52, 279, 180);
    // Right is the default and changes nothing.
    CLLayoutPlan right = CLLayoutPlanPlacingLyrics(CLLayoutPlanMake(4, widescreen, kRatio, YES), CLLayoutLyricsSideRight);
    CL_ASSERT_TRUE(CLLayoutPlanEqual(right, CLLayoutPlanMake(4, widescreen, kRatio, YES)));
    CL_ASSERT_FALSE(CLLayoutPlanEqual(right, side));
    // The strip spans the width, Off has no player: neither moves.
    CGRect wide = CGRectMake(0, 44, 800, 436);
    CLLayoutPlan strip = CLLayoutPlanPlacingLyrics(CLLayoutPlanMake(2, wide, kRatio, YES), CLLayoutLyricsSideLeft);
    CL_ASSERT_FALSE(strip.playerOnTrailing);
    CL_ASSERT_RECT(CLLayoutPlayerRect(strip, wide), 0, 280, 800, 200);
    CL_ASSERT_FALSE(CLLayoutPlanPlacingLyrics(CLLayoutPlanMake(0, wide, kRatio, YES), CLLayoutLyricsSideLeft).playerOnTrailing);
    // A stacked column mirrors as well (800x480: 360 pt at the right).
    CLLayoutPlan stacked = CLLayoutPlanPlacingLyrics(CLLayoutPlanMake(4, CGRectMake(0, 0, 800, 480), kRatio, YES), CLLayoutLyricsSideLeft);
    CL_ASSERT_RECT(CLLayoutPlayerRect(stacked, CGRectMake(0, 0, 800, 480)), 440, 0, 360, 480);
    CL_ASSERT_RECT(CLLayoutLyricsRect(stacked, CGRectMake(0, 0, 800, 480)), 16, 8, 408, 464);
}

static void CLTestDegradedPlans(void) {
    CGRect wide = CGRectMake(0, 0, 800, 480);
    // The host cannot be driven (hooks missing, app not enabled, another app playing): every mode
    // shows the stock screen.
    for (NSInteger mode = 0; mode <= 4; mode++) {
        CLLayoutPlan plan = CLLayoutPlanMake(mode, wide, kRatio, NO);
        CL_ASSERT_EQ((long)plan.effectiveMode, (long)CLLayoutEffectiveOff);
        CL_ASSERT_EQ((long)plan.playerArea, (long)CLLayoutPlayerAreaNone);
        CL_ASSERT_FALSE(plan.hidesArtwork);
    }
    // An empty safe area (nothing laid out yet) is Off for that pass.
    CL_ASSERT_EQ((long)CLLayoutPlanMake(2, CGRectZero, kRatio, YES).effectiveMode, (long)0);
    CL_ASSERT_EQ((long)CLLayoutPlanMake(4, CGRectZero, kRatio, YES).effectiveMode, (long)0);
    CL_ASSERT_EQ((long)CLLayoutPlanMake(2, CGRectMake(0, 0, 800, 0.5), kRatio, YES).effectiveMode, (long)0);
    CL_ASSERT_EQ((long)CLLayoutPlanMake(3, CGRectZero, kRatio, YES).effectiveMode, (long)0);
    CL_ASSERT_EQ((long)CLLayoutPlanMake(0, CGRectZero, kRatio, NO).effectiveMode, (long)0);
}

/// The panel's font-fit rule: the six cases tests/ui's TestPanelFit measures on a real
/// CLLyricsPanelView, here on the shared function the settings preview draws with, so the two
/// can never drift.
static void CLTestPanelFit(void) {
    CL_ASSERT_NEAR(CLLayoutPanelFontSize(CGSizeMake(250, 250), CLLayoutPanelFitRows, 24.0), 24.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutPanelFontSize(CGSizeMake(216, 216), CLLayoutPanelFitRows, 24.0), 24.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutPanelFontSize(CGSizeMake(300, 80), CLLayoutPanelFitRows, 24.0), 16.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutPanelFontSize(CGSizeMake(184, 196), CLLayoutPanelFitColumn, 24.0), 16.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutPanelFontSize(CGSizeMake(210, 180), CLLayoutPanelFitColumn, 24.0), 19.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutPanelFontSize(CGSizeMake(420, 420), CLLayoutPanelFitColumn, 24.0), 24.0, 0.01);
    // The preference is the ceiling; Rows has no width term; a missing preference reads as 24.
    CL_ASSERT_NEAR(CLLayoutPanelFontSize(CGSizeMake(420, 420), CLLayoutPanelFitColumn, 30.0), 30.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutPanelFontSize(CGSizeMake(60, 400), CLLayoutPanelFitRows, 24.0), 24.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutPanelFontSize(CGSizeMake(60, 400), CLLayoutPanelFitColumn, 24.0), 16.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutPanelFontSize(CGSizeMake(420, 420), CLLayoutPanelFitColumn, 0.0), 24.0, 0.01);
    // Nothing laid out yet: no cap.
    CL_ASSERT_NEAR(CLLayoutPanelFontSize(CGSizeZero, CLLayoutPanelFitColumn, 24.0), 24.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutPanelFontSize(CGSizeZero, CLLayoutPanelFitRows, 24.0), 24.0, 0.01);
    CL_ASSERT_NEAR(CLLayoutPanelMinimumFontSize, 16.0, 0.01);
}

static void CLTestPlanEquality(void) {
    CGRect wide = CGRectMake(0, 0, 800, 480);
    CLLayoutPlan a = CLLayoutPlanMake(4, wide, kRatio, YES);
    CLLayoutPlan b = CLLayoutPlanMake(1, wide, kRatio, YES);      // 1 reads as 4
    CL_ASSERT_TRUE(CLLayoutPlanEqual(a, b));
    CL_ASSERT_TRUE(CLLayoutPlanEqual(a, a));
    CLLayoutPlan strip = CLLayoutPlanMake(2, wide, kRatio, YES);
    CL_ASSERT_FALSE(CLLayoutPlanEqual(a, strip));
    // A plan carries no rect: the same strip on any screen is the same plan.
    CL_ASSERT_TRUE(CLLayoutPlanEqual(strip, CLLayoutPlanMake(4, CGRectMake(0, 0, 600, 600), kRatio, YES)));
    CLLayoutPlan nearlySame = a;
    nearlySame.playerWidth += 0.4;
    CL_ASSERT_TRUE(CLLayoutPlanEqual(a, nearlySame));
    nearlySame.playerWidth += 0.2;
    CL_ASSERT_FALSE(CLLayoutPlanEqual(a, nearlySame));
    CLLayoutPlan off = CLLayoutPlanMake(0, wide, kRatio, YES);
    CL_ASSERT_TRUE(CLLayoutPlanEqual(off, CLLayoutPlanMake(2, CGRectZero, kRatio, YES)));
    CL_ASSERT_FALSE(CLLayoutPlanEqual(off, CLLayoutPlanMake(3, wide, kRatio, YES)));   // 3 reads as 4
    // The Full Panel's two players are different plans: strip vs. cover-less column.
    CLLayoutPlan shortPanel = CLLayoutPlanMake(2, CGRectMake(45, 44, 595, 196), kRatio, YES);
    CL_ASSERT_EQ((long)shortPanel.effectiveMode, (long)strip.effectiveMode);
    CL_ASSERT_FALSE(CLLayoutPlanEqual(shortPanel, strip));
}

void CLRunLayoutGeometryTests(void) {
    CLTestBeginSuite("CLLayoutGeometry");
    CLTestModeNormalize();
    CLTestColumnWidths();
    CLTestHostThresholds();
    CLTestWorkedNumbers();
    CLTestDegradedPlans();
    CLTestLyricsSide();
    CLTestPanelFit();
    CLTestPlanEquality();
}
