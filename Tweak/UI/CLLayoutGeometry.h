// Header-only layout arithmetic shared by the tweak (CLLayoutCustomizer, inside
// CarPlayTemplateUIHost) and the settings bundle's preview (Prefs/CLLayoutPreviewView, inside
// Settings). Pure C over CoreGraphics types: no UIKit, no CLPrefs, no host classes, so the preview
// on the phone and the layout in the car are computed by the very same code.
//
// The numbers here come from docs/research/CarPlayUI-17.3-layout.md (verified by disassembly of
// the iOS 17.3 shared cache): the host's own layout chooser stacks the artwork above the controls
// when a safe area is narrower than CPUINowPlayingLayoutSideArtworkMinAspectRatio (1.35) and
// otherwise puts it beside them; its stacked vertical chain needs roughly 260 pt of height before
// the title and the artist start drawing on top of each other; without artwork the chain is
// 182 pt tall in the host's small title tier with 36 pt transport buttons, which is what the Full
// Panel's bottom strip is sized for. Short, wide screens (a 1920x720 @3x unit is 640x240 pt with a
// 595x196 safe area) are laid out from the side layouts' own numbers (see "Short screens" in the
// research note): the art is albumArtWidthMultiplier x the area's width, and three transport
// buttons need 3 x 36 + 2 x 10 pt beside it.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#pragma mark - Modes

/// The `lyricsMode` preference ("Layout" in Settings).
typedef NS_ENUM(NSInteger, CLLayoutMode) {
    CLLayoutModeOff = 0,
    /* 1 was the two-line overlay (removed in 0.5.0); CLLayoutModeNormalize maps it to 4 */
    CLLayoutModeFullPanel = 2,        ///< "No Artwork" in Settings: CarPlay's compact player without the
                                      ///< cover, below the lyrics (strip) or beside them (short screens)
    /* 3 was Replace Artwork (removed in 0.6.0); CLLayoutModeNormalize maps it to 4 */
    CLLayoutModeSideBySide = 4,       ///< player column left, scrolling lyrics right
};

/// What a screen actually shows for a preference (a preference degrades to a different effective
/// mode where the screen is the wrong shape, and to Off where the host cannot be driven).
typedef NS_ENUM(NSInteger, CLLayoutEffectiveMode) {
    CLLayoutEffectiveOff = 0,              ///< the stock screen, no lyrics
    CLLayoutEffectiveSideBySide = 4,       ///< host in a leading column, panel beside it
    CLLayoutEffectiveFullPanel = 5,        ///< host without artwork in a bottom strip (panel above) or, on
                                           ///< short screens, in a leading column (panel beside it)
};
/* Effective 1, 2 and 3 no longer exist anywhere. */

/// The part of the safe area the host is asked to lay its Now Playing view out for.
typedef NS_ENUM(NSInteger, CLLayoutPlayerArea) {
    CLLayoutPlayerAreaNone = 0,          ///< the host keeps the whole screen
    CLLayoutPlayerAreaLeadingColumn = 1, ///< a full-height column (safe.minX, safe.minY, playerWidth, safe.height), with or
                                         ///< without artwork; at the trailing edge instead when playerOnTrailing (0.7.5)
    CLLayoutPlayerAreaBottomStrip = 2,   ///< (safe.minX, safe.maxY - playerHeight, safe.width, playerHeight)
};

/// The stored `lyricsMode`, made valid: 1 (the removed overlay) and 3 (the removed Replace Artwork)
/// read as 4; anything outside 0…4 clamps to the nearest end.
static inline NSInteger CLLayoutModeNormalize(NSInteger mode) {
    if (mode == 1 || mode == 3) return CLLayoutModeSideBySide;
    if (mode < CLLayoutModeOff) return CLLayoutModeOff;
    if (mode > CLLayoutModeSideBySide) return CLLayoutModeSideBySide;
    return mode;
}

#pragma mark - Host constants (iOS 17.3, verified by disassembly)

/// CPUINowPlayingLayoutSideArtworkMinAspectRatio on iOS 17.3. The tweak reads the live value from
/// the host; the preview uses this.
static const CGFloat CLLayoutDefaultSideArtworkRatio = 1.35;
/// -[CPUINowPlayingLayoutStacked layoutMargins] on small screens: top 2, left/right 27, bottom 12.
static const CGFloat CLLayoutHostMarginTop = 2.0, CLLayoutHostMarginSide = 27.0, CLLayoutHostMarginBottom = 12.0;
/// +[CPUISongDetailsView maximumHeightForTrackInfoFontStyle:]: style 0 (small) 72, style 1 (large) 106.
/// The host pins the song-details block to exactly this height.
static const CGFloat CLLayoutHostDetailsHeightSmall = 72.0, CLLayoutHostDetailsHeightLarge = 106.0;
/// -[_CPUINowPlayingLayout transportControlButtonHeight]: 36 or 44 (see CLLayoutHostTransportButtonHeight).
static const CGFloat CLLayoutHostTransportSmall = 36.0, CLLayoutHostTransportLarge = 44.0;
/// Below this scaled height (px) a view area narrower than CLLayoutHostWideScaledWidth gets 36 pt buttons.
static const CGFloat CLLayoutHostSmallButtonsMaxScaledHeight = 624.0;     // px
/// At or above this scaled width (px) the buttons are 44 pt only above CLLayoutHostWideTallScaledHeight.
static const CGFloat CLLayoutHostWideScaledWidth = 1400.0, CLLayoutHostWideTallScaledHeight = 720.0;  // px
/// _CPUIStandardCarPlayProgressViewHeight, _CPUIPlayModeControlViewHeight, CPUINowPlayingMinimumVerticalPadding.
static const CGFloat CLLayoutHostProgressHeight = 10.0, CLLayoutHostPlayModeHeight = 26.0, CLLayoutHostMinimumSpacer = 8.0;
/// The fixed part of -[CPUINowPlayingLayoutStacked maximumTitleViewSize]'s height: (26 + 10) + 24.
static const CGFloat CLLayoutHostTitleChainFixed = 60.0;
/// -[CPUINowPlayingLayoutStacked trackInfoFontStyle] is 1 (large) iff the title area is at least this big.
static const CGFloat CLLayoutHostLargeTierTitleHeight = 106.0, CLLayoutHostLargeTierTitleWidth = 300.0;
/// CPUINowPlayingMaximumNoArtworkSize: the artwork-less stacked layout's maximumNowPlayingSize cap.
static const CGSize  CLLayoutHostNoArtworkMaximum = {500.0, 480.0};

#pragma mark - Host behaviour (what the host *will* do for a rect)

/// -[_CPUINowPlayingLayout transportControlButtonHeight]: 44 iff (w < 1400 px && h >= 624 px) or
/// (w >= 1400 px && h > 720 px), where w/h = viewArea (points) x displayScale; else 36.
static inline CGFloat CLLayoutHostTransportButtonHeight(CGSize viewAreaPoints, CGFloat displayScale) {
    CGFloat scale = (displayScale > 0.0) ? displayScale : 1.0;
    CGFloat w = viewAreaPoints.width * scale, h = viewAreaPoints.height * scale;
    if (w < CLLayoutHostWideScaledWidth) {
        return (h >= CLLayoutHostSmallButtonsMaxScaledHeight) ? CLLayoutHostTransportLarge : CLLayoutHostTransportSmall;
    }
    return (h > CLLayoutHostWideTallScaledHeight) ? CLLayoutHostTransportLarge : CLLayoutHostTransportSmall;
}

/// The densest CarPlay display scale; rules that must hold whatever the scale assume it.
static const CGFloat CLLayoutDensestCarPlayScale = 3.0;
/// The tallest safe area a player column can have and still be handed the host's small (36 pt)
/// transport buttons at every scale up to @3x (see CLLayoutPlayerViewAreaHeight): 207 pt.
static const CGFloat CLLayoutSmallButtonsMaximumSafeHeight = 207.0;   // floor(623 / 3)

/// The view-area height to hand the host with a player column `areaWidth` points wide on a screen
/// of `screen` points. The host sizes its transport buttons from the view area alone, so a column
/// as tall as a 1920x720 @3x screen (720 px, but under 1400 px wide) would get 44 pt buttons where
/// the full screen gets 36. Returns the screen's height, or, when that gives 44 pt buttons and a
/// shorter view area (under 624 px, never below the column's safe height) gives 36, that height:
/// a short column gets the host's small buttons, like the stock screen of a short unit.
///   640x240 @3x, 285 pt column, 196 pt safe: 207 (621 px -> 36 pt).  800x480 @2x: 480 (44 either way).
static inline CGFloat CLLayoutPlayerViewAreaHeight(CGSize screen, CGFloat areaWidth, CGFloat areaSafeHeight, CGFloat displayScale) {
    CGFloat scale = (displayScale > 0.0) ? displayScale : 1.0;
    CGFloat height = screen.height;
    if (CLLayoutHostTransportButtonHeight(CGSizeMake(areaWidth, height), scale) <= CLLayoutHostTransportSmall) return height;
    CGFloat capped = floor((CLLayoutHostSmallButtonsMaxScaledHeight - 1.0) / scale);
    if (capped < areaSafeHeight || capped >= height) return height;
    return capped;
}

/// -[CPUINowPlayingLayoutStacked maximumTitleViewSize]. artWidth = effective album-art width in points
/// (ignored when showsArtwork is NO). width = round(safe.w) - 54;
/// height = (showsArtwork ? round(safe.h) : MIN(round(safe.h), 480)) - 14 - 60 - transport - (showsArtwork ? 8 + artWidth : 0).
static inline CGSize CLLayoutHostTitleAreaSize(CGRect safeArea, BOOL showsArtwork, CGFloat artWidth, CGFloat transport) {
    CGFloat width = round(CGRectGetWidth(safeArea)) - 2.0 * CLLayoutHostMarginSide;
    CGFloat available = round(CGRectGetHeight(safeArea));
    if (!showsArtwork) available = MIN(available, CLLayoutHostNoArtworkMaximum.height);
    CGFloat height = available - (CLLayoutHostMarginTop + CLLayoutHostMarginBottom) - CLLayoutHostTitleChainFixed - transport;
    if (showsArtwork) height -= CLLayoutHostMinimumSpacer + artWidth;
    return CGSizeMake(width, height);
}

/// Stacked trackInfoFontStyle == 1 (large) iff titleArea.height >= 106 && titleArea.width >= 300.
static inline BOOL CLLayoutHostUsesLargeTier(CGSize titleArea) {
    return titleArea.height >= CLLayoutHostLargeTierTitleHeight && titleArea.width >= CLLayoutHostLargeTierTitleWidth;
}

/// Natural height of the artwork-less stacked chain (all three spacers at 8):
/// 2 + (large ? 106 : 72) + 24 + transport + 10 + 26 + 12  ->  182 (small/36) … 216 (large/36).
static inline CGFloat CLLayoutHostStackedChainHeight(BOOL largeTier, CGFloat transport) {
    return CLLayoutHostMarginTop + (largeTier ? CLLayoutHostDetailsHeightLarge : CLLayoutHostDetailsHeightSmall) +
           3.0 * CLLayoutHostMinimumSpacer + transport + CLLayoutHostProgressHeight + CLLayoutHostPlayModeHeight +
           CLLayoutHostMarginBottom;
}

#pragma mark - Side by Side constants (unchanged since 0.2.1)

/// Space between the player column and the lyrics (side by side).
static const CGFloat CLLayoutColumnGap = 16.0;
/// The narrowest lyrics area worth showing beside a stacked player column.
static const CGFloat CLLayoutMinimumLyricsWidth = 240.0;
static const CGFloat CLLayoutMinimumColumnWidth = 200.0;
/// A stacked column with art is narrower than 900 px at every CarPlay scale, where the host's
/// play-mode buttons are 40 pt with 16 pt gaps: five (Spotify's four and the microphone) are
/// 5 x 40 + 4 x 16 = 264 pt, and the column is never narrower, or the row spills past it.
static const CGFloat CLLayoutStackedColumnPlayModeWidth = 264.0;
/// The host's stacked chain is fixed-height (song details >= a minimum, progress, play-mode row
/// and bottom guide at constants); below this safe-area height it squashes the song details.
static const CGFloat CLLayoutStackedMinimumHeight = 260.0;
/// The narrowest lyrics area a short screen may be left with next to a side-layout player.
static const CGFloat CLLayoutMinimumSideLyricsWidth = 200.0;
/// A short screen's side-layout player is at least (side-artwork ratio + this) x the safe height:
/// the narrowest area the host's chooser still lays out with the art beside the controls (285 pt
/// on a 196 pt safe area). 0.2.1 – 0.5.0 used 1.8 x the height (353 pt), which left the lyrics 210 pt.
static const CGFloat CLLayoutSidePlayerRatioMargin = 0.1;

/// The side layouts' own numbers for the areas a short-screen column produces (800 – 1115 px wide,
/// verified by disassembly, docs/research "Short screens"): the art is albumArtWidthMultiplier x the
/// width, 0.32 at most there (0.27 below 800 px); the margins are 12 below 900 px, else 16; the
/// transport row runs from about 22 pt right of the art to 23 pt before the edge (195 -> 375 on a
/// 353 pt column: the width minus a 16 pt margin, the art and 45 pt), and holds three buttons with
/// 10 pt gaps.
static const CGFloat CLLayoutHostSideArtMultiplier = 0.32;
static const CGFloat CLLayoutHostSideArtMultiplierNarrow = 0.27;      // below 800 px wide
static const CGFloat CLLayoutHostSideNarrowScaledWidth = 800.0;       // px
static const CGFloat CLLayoutHostSideSmallMarginScaledWidth = 900.0;  // px: margins 12 below, 16 from here
static const CGFloat CLLayoutHostSideBandMaxScaledWidth = 1116.0;     // px: the numbers above hold below this
static const CGFloat CLLayoutHostSideControlsChrome = 61.0;           // 16 pt margin + 22 + 23 around the row
static const CGFloat CLLayoutHostSideButtonSpacing = 10.0;

/// The narrowest side-layout player whose transport row holds its three `transport`-point buttons,
/// counting the largest art and margin the band can give: 278 pt for 36 pt buttons, 314 for 44.
static inline CGFloat CLLayoutSidePlayerMinimumWidth(CGFloat transport) {
    return ceil((3.0 * transport + 2.0 * CLLayoutHostSideButtonSpacing + CLLayoutHostSideControlsChrome) /
                (1.0 - CLLayoutHostSideArtMultiplier));
}

#pragma mark - Full Panel constants

/// The bottom strip's height: > 182 (the chain, small tier, 36 pt buttons); < 208 (keeps 36 pt
/// buttons at @3x: 624 px); < 216 (keeps the small title tier: title area < 106).
static const CGFloat CLLayoutFullPanelStripHeight = 200.0;
/// The least the lyrics panel above the strip may get (~3 rows at 24 pt); below that no strip.
static const CGFloat CLLayoutFullPanelMinimumLyricsHeight = 120.0;
/// The play-mode row's buttons the layouts are sized for: Spotify's four (add, shuffle, repeat,
/// connect) and carLy's microphone (0.7.0).
static const NSInteger CLLayoutPlayModeButtonCount = 5;
/// Where the strip does not fit, the Full Panel's player is a leading column this wide without
/// artwork (the host's artwork-less stacked layout). Its rows sit between 27 pt margins; the
/// transport row (3 x 44 + 2 x 16 = 164 pt) fits, and the play-mode row's stack view is a fixed
/// count x 44 + (count - 1) x 16 wide, anchored only by centre x and bottom (verified), so it may
/// spill into the margins without a constraint conflict. 5 x 44 + 4 x 16 = 284 keeps all five
/// buttons inside the column. (0.5.1 – 0.6.1: 240, sized for four.)
static const CGFloat CLLayoutFullPanelColumnWidth = 284.0;
/// safe.top -> panel.top, and panel.bottom -> strip.top.
static const CGFloat CLLayoutFullPanelGap = 8.0;
/// CLLyricsPanelView's horizontal label padding inside the panel.
static const CGFloat CLLayoutPanelTextInset = 16.0;
/// Full Panel: the panel's side inset, 27 - 16, so the lyric text starts at the title's x.
static const CGFloat CLLayoutFullPanelLyricsInset = 11.0;
/// Side by Side: the panel's trailing inset.
static const CGFloat CLLayoutPanelSideInset = 16.0;
/// Side by Side: the panel's top/bottom gap.
static const CGFloat CLLayoutPanelTopGap = 8.0;

#pragma mark - Full-screen lyrics (CLLyricsFullScreenView in the car, CLLayoutPreviewView in Settings)

/// The row at the bottom (title/artist, previous / play-pause / next, the microphone): 44 pt tall,
/// 8 pt above the safe area's bottom, from the host's 27 pt title margin to 12 pt before the edge.
static const CGFloat CLLayoutFullScreenRowHeight = 44.0, CLLayoutFullScreenRowBottom = 8.0;
static const CGFloat CLLayoutFullScreenRowLeading = 27.0, CLLayoutFullScreenRowTrailing = 12.0;
/// The progress line: 14 pt tall, 2 pt above the row, as wide as the row; its bar is 3 pt thick.
static const CGFloat CLLayoutFullScreenProgressHeight = 14.0, CLLayoutFullScreenProgressGap = 2.0;
static const CGFloat CLLayoutFullScreenProgressThickness = 3.0;
/// The lyrics: 8 pt under the safe area's top, 4 pt above the progress line, the full panel's inset.
static const CGFloat CLLayoutFullScreenLyricsTop = 8.0, CLLayoutFullScreenLyricsGap = 4.0;
/// Narrower than this, the row drops the title and artist.
static const CGFloat CLLayoutFullScreenMinimumWidthForText = 380.0;

/// The rects of the full-screen view for a safe area (the view covers exactly the safe area).
static inline CGRect CLLayoutFullScreenRowRect(CGRect safe) {
    return CGRectMake(CGRectGetMinX(safe) + CLLayoutFullScreenRowLeading,
                      CGRectGetMaxY(safe) - CLLayoutFullScreenRowBottom - CLLayoutFullScreenRowHeight,
                      CGRectGetWidth(safe) - CLLayoutFullScreenRowLeading - CLLayoutFullScreenRowTrailing,
                      CLLayoutFullScreenRowHeight);
}
static inline CGRect CLLayoutFullScreenProgressRect(CGRect safe) {
    CGRect row = CLLayoutFullScreenRowRect(safe);
    return CGRectMake(CGRectGetMinX(row), CGRectGetMinY(row) - CLLayoutFullScreenProgressGap - CLLayoutFullScreenProgressHeight,
                      CGRectGetWidth(row), CLLayoutFullScreenProgressHeight);
}
static inline CGRect CLLayoutFullScreenLyricsRect(CGRect safe) {
    CGRect progress = CLLayoutFullScreenProgressRect(safe);
    CGFloat top = CGRectGetMinY(safe) + CLLayoutFullScreenLyricsTop;
    return CGRectMake(CGRectGetMinX(safe) + CLLayoutFullPanelLyricsInset, top,
                      CGRectGetWidth(safe) - 2.0 * CLLayoutFullPanelLyricsInset,
                      MAX(0.0, CGRectGetMinY(progress) - CLLayoutFullScreenLyricsGap - top));
}

#pragma mark - Panel font fit (CLLyricsPanelView in the car, CLLayoutPreviewView in Settings)

/// How the lyrics panel caps its row font to its size (lyricsFontSize is the ceiling either way).
typedef NS_ENUM(NSInteger, CLLayoutPanelFit) {
    /// Side by side: min(pref, max(16, floor(h / 8)), max(16, floor(w / 11))) — about seven lines
    /// and a dozen characters before wrapping, so a narrow column reads as a column.
    CLLayoutPanelFitColumn = 0,
    /// The strip's full-width panel: min(pref, max(16, floor((h - 24) / 3.6))) — shrink only
    /// when three rows cannot fit; long lines wrap instead of shrinking the font.
    CLLayoutPanelFitRows = 1,
};

/// The fitted font never goes below this, however small the panel.
static const CGFloat CLLayoutPanelMinimumFontSize = 16.0;

/// The row font for a panel of `panel` points under `fit`, from the preferred size (24 when the
/// preference is missing). A dimension under 1 pt (nothing laid out yet) adds no cap.
///   Column: a 210x180 pt panel gets 19 pt; 278x180 (Side by Side on a 1920x720 @3x display) and
///           323x180 (its Full Panel) get 22; a 400x420 pt one keeps 24.
///   Rows:   a 216–320 pt artwork square keeps 24 pt, a 300x80 pt panel gets 16.
static inline CGFloat CLLayoutPanelFontSize(CGSize panel, CLLayoutPanelFit fit, CGFloat preferred) {
    CGFloat size = preferred > 0.0 ? preferred : 24.0;
    CGFloat height = panel.height, width = panel.width;
    if (fit == CLLayoutPanelFitRows) {
        if (height >= 1.0) size = MIN(size, MAX(CLLayoutPanelMinimumFontSize, floor((height - 24.0) / 3.6)));
        return size;
    }
    if (height >= 1.0) size = MIN(size, MAX(CLLayoutPanelMinimumFontSize, floor(height / 8.0)));
    if (width >= 1.0) size = MIN(size, MAX(CLLayoutPanelMinimumFontSize, floor(width / 11.0)));
    return size;
}

#pragma mark - Plan

/// What a screen actually shows for a preference, and what that asks of the host's own layout.
typedef struct {
    NSInteger effectiveMode;        ///< CLLayoutEffectiveMode: 0, 3, 4, 5
    CLLayoutPlayerArea playerArea;  ///< None for 0 and 3; LeadingColumn for 4; BottomStrip or LeadingColumn for 5
    CGFloat playerWidth;            ///< LeadingColumn only, else 0
    CGFloat playerHeight;           ///< BottomStrip only (== CLLayoutFullPanelStripHeight), else 0
    BOOL hidesArtwork;              ///< YES only for 5 (allowsAlbumArt:NO)
    BOOL playerOnTrailing;          ///< a column at the trailing edge, lyrics on the leading side (Lyrics Side: Left)
} CLLayoutPlan;

/// YES when the host itself would stack the artwork above the controls for this safe area.
static inline BOOL CLLayoutHostStacksSafeArea(CGRect safeArea, CGFloat sideRatio) {
    CGFloat width = CGRectGetWidth(safeArea), height = CGRectGetHeight(safeArea);
    if (width < 1.0 || height < 1.0) return YES;
    return width / height < sideRatio;
}

/// The side-by-side player area's width for a safe area, or 0 when the screen is one the host
/// stacks by itself or too small to leave the lyrics a readable width.
///
/// Its shape picks the host layout inside it, through the host's own chooser: an area narrower
/// than the side-artwork ratio gets the stacked layout (art above title and controls), a wider one
/// gets a side layout — LeftArtwork, since the view hook reports right-hand drive — with the art
/// on the left and the controls beside it. Either way the art is on the left, lyrics on the right.
static inline CGFloat CLLayoutPlayerColumnWidth(CGRect safeArea, CGFloat sideRatio) {
    CGFloat width = CGRectGetWidth(safeArea);
    CGFloat height = CGRectGetHeight(safeArea);
    if (width < 1.0 || height < 1.0) return 0.0;
    if (width / height < sideRatio) return 0.0;

    if (height >= CLLayoutStackedMinimumHeight) {
        // Stacked column, roughly a portrait phone's proportions, never more than 45% of the screen.
        CGFloat column = round(height * 0.8);
        column = MIN(column, round(width * 0.45));
        // Clearly under the side-artwork ratio, or the chooser would pick a side layout instead.
        column = MIN(column, floor(height * (sideRatio - 0.1)));
        column = MAX(column, CLLayoutMinimumColumnWidth);
        column = MAX(column, CLLayoutStackedColumnPlayModeWidth);
        if (width - column - CLLayoutColumnGap < CLLayoutMinimumLyricsWidth) return 0.0;
        return column;
    }

    // Short and wide: art square on the left, title and controls beside it, lyrics after that. As
    // narrow as the host's side layout allows, so the lyrics get the rest: past the chooser's
    // ratio, and wide enough for the transport row beside the art. A column at most 207 pt tall
    // gets 36 pt buttons at any scale (CLLayoutPlayerViewAreaHeight); a taller one may get 44.
    // (The 0.001 keeps float noise in the ratio from rounding a whole number up: 240 x 1.45.)
    CGFloat column = ceil(height * (sideRatio + CLLayoutSidePlayerRatioMargin) - 0.001);
    CGFloat transport = (height <= CLLayoutSmallButtonsMaximumSafeHeight) ? CLLayoutHostTransportSmall
                                                                          : CLLayoutHostTransportLarge;
    column = MAX(column, CLLayoutSidePlayerMinimumWidth(transport));
    if (width - column - CLLayoutColumnGap < CLLayoutMinimumSideLyricsWidth) return 0.0;
    return column;
}

/// YES when a Full Panel strip fits: the strip, its two gaps and at least the minimum lyrics height.
static inline BOOL CLLayoutFullPanelStripFits(CGRect safeArea) {
    if (CGRectGetWidth(safeArea) < 1.0) return NO;
    return CGRectGetHeight(safeArea) >= CLLayoutFullPanelStripHeight + 2.0 * CLLayoutFullPanelGap +
                                        CLLayoutFullPanelMinimumLyricsHeight;
}

/// YES when the Full Panel's artwork-less player column fits: the host's artwork-less stacked chain
/// (190 pt with 44 pt buttons, the tallest it builds in the small tier) in the height, and the
/// column, its gap, the panel's inset and a readable lyrics width across.
static inline BOOL CLLayoutFullPanelColumnFits(CGRect safeArea) {
    if (CGRectGetHeight(safeArea) < CLLayoutHostStackedChainHeight(NO, CLLayoutHostTransportLarge)) return NO;
    return CGRectGetWidth(safeArea) - CLLayoutFullPanelColumnWidth - CLLayoutColumnGap - CLLayoutPanelSideInset >=
           CLLayoutMinimumLyricsWidth;
}

/// The plan for a `lyricsMode` on a screen with `safeArea`. mode = the preference (raw; normalised
/// inside). safeArea = the controller view's safe-area layout frame (may be empty before the first
/// layout). sideRatio = the host's chooser ratio (1.35). hostUsable = hooks installed && app enabled
/// && screen is the playing app; without it every mode is Off (the stock screen).
///
/// Rules, in order (no other path exists):
///   1. m = CLLayoutModeNormalize(mode).
///   2. m == 0 -> Off.
///   3. Safe area empty (w < 1 || h < 1) -> Off for this pass (nothing is laid out yet).
///   4. !hostUsable -> Off (the stock screen).
///   5. m == 4: a column fits -> 4. Else the strip fits -> 5 (strip), else -> Off.
///   6. m == 2: the strip fits -> 5 (strip). Else the artwork-less column fits -> 5 (column, no art).
///      Else a column with art fits -> 4, else -> Off.
static inline CLLayoutPlan CLLayoutPlanMake(NSInteger mode, CGRect safeArea, CGFloat sideRatio, BOOL hostUsable) {
    CLLayoutPlan plan;
    plan.effectiveMode = CLLayoutEffectiveOff;
    plan.playerArea = CLLayoutPlayerAreaNone;
    plan.playerWidth = 0.0;
    plan.playerHeight = 0.0;
    plan.hidesArtwork = NO;
    plan.playerOnTrailing = NO;

    NSInteger m = CLLayoutModeNormalize(mode);
    if (m == CLLayoutModeOff) return plan;
    if (CGRectGetWidth(safeArea) < 1.0 || CGRectGetHeight(safeArea) < 1.0) return plan;
    if (!hostUsable) return plan;

    BOOL stripFits = CLLayoutFullPanelStripFits(safeArea);
    if (m == CLLayoutModeFullPanel && !stripFits && CLLayoutFullPanelColumnFits(safeArea)) {
        plan.effectiveMode = CLLayoutEffectiveFullPanel;
        plan.playerArea = CLLayoutPlayerAreaLeadingColumn;
        plan.playerWidth = CLLayoutFullPanelColumnWidth;
        plan.hidesArtwork = YES;
        return plan;
    }
    CGFloat column = CLLayoutPlayerColumnWidth(safeArea, sideRatio);
    BOOL wantsColumn = (m == CLLayoutModeSideBySide) ? (column > 0.0) : (!stripFits && column > 0.0);
    if (wantsColumn) {
        plan.effectiveMode = CLLayoutEffectiveSideBySide;
        plan.playerArea = CLLayoutPlayerAreaLeadingColumn;
        plan.playerWidth = column;
        return plan;
    }
    if (stripFits) {
        plan.effectiveMode = CLLayoutEffectiveFullPanel;
        plan.playerArea = CLLayoutPlayerAreaBottomStrip;
        plan.playerHeight = CLLayoutFullPanelStripHeight;
        plan.hidesArtwork = YES;
        return plan;
    }
    return plan;
}

/// `lyricsSide` (Layout > Lyrics Side): 0 lyrics on the right (the default; the player column at
/// the leading edge), 1 lyrics on the left.
typedef NS_ENUM(NSInteger, CLLayoutLyricsSide) {
    CLLayoutLyricsSideRight = 0,
    CLLayoutLyricsSideLeft = 1,
};

/// A plan with its player column moved to the trailing edge when the lyrics go on the left. Only a
/// column moves: the bottom strip spans the width and full screen has no player area.
static inline CLLayoutPlan CLLayoutPlanPlacingLyrics(CLLayoutPlan plan, NSInteger lyricsSide) {
    plan.playerOnTrailing = (lyricsSide == CLLayoutLyricsSideLeft && plan.playerArea == CLLayoutPlayerAreaLeadingColumn);
    return plan;
}

static inline BOOL CLLayoutPlanEqual(CLLayoutPlan a, CLLayoutPlan b) {
    return a.effectiveMode == b.effectiveMode && a.playerArea == b.playerArea &&
           fabs(a.playerWidth - b.playerWidth) < 0.5 && fabs(a.playerHeight - b.playerHeight) < 0.5 &&
           a.hidesArtwork == b.hidesArtwork && a.playerOnTrailing == b.playerOnTrailing;
}

/// The rect the host lays its Now Playing view out for, in safe-area coordinates; CGRectNull when
/// playerArea is None.
static inline CGRect CLLayoutPlayerRect(CLLayoutPlan plan, CGRect safeArea) {
    switch (plan.playerArea) {
        case CLLayoutPlayerAreaLeadingColumn: {
            CGFloat x = plan.playerOnTrailing ? CGRectGetMaxX(safeArea) - plan.playerWidth : CGRectGetMinX(safeArea);
            return CGRectMake(x, CGRectGetMinY(safeArea), plan.playerWidth, CGRectGetHeight(safeArea));
        }
        case CLLayoutPlayerAreaBottomStrip:
            return CGRectMake(CGRectGetMinX(safeArea), CGRectGetMaxY(safeArea) - plan.playerHeight,
                              CGRectGetWidth(safeArea), plan.playerHeight);
        case CLLayoutPlayerAreaNone:
        default:
            return CGRectNull;
    }
}

/// Where the lyrics panel goes in root coordinates for effective 4 and 5; CGRectNull for 0. It
/// follows the player area, not the mode:
///   column (4, and 5 on short screens): (safe.minX + W + 16, safe.minY + 8, safe.width - W - 32, safe.height - 16),
///                                       or mirrored to (safe.minX + 16, …) when the player is at the trailing edge
///   strip (5):                          (safe.minX + 11, safe.minY + 8, safe.width - 22, safe.height - 200 - 16)
static inline CGRect CLLayoutLyricsRect(CLLayoutPlan plan, CGRect safeArea) {
    switch (plan.playerArea) {
        case CLLayoutPlayerAreaLeadingColumn:
            if (plan.playerOnTrailing) {
                return CGRectMake(CGRectGetMinX(safeArea) + CLLayoutPanelSideInset, CGRectGetMinY(safeArea) + CLLayoutPanelTopGap,
                                  CGRectGetWidth(safeArea) - plan.playerWidth - CLLayoutColumnGap - CLLayoutPanelSideInset,
                                  CGRectGetHeight(safeArea) - 2.0 * CLLayoutPanelTopGap);
            }
            return CGRectMake(CGRectGetMinX(safeArea) + plan.playerWidth + CLLayoutColumnGap,
                              CGRectGetMinY(safeArea) + CLLayoutPanelTopGap,
                              CGRectGetWidth(safeArea) - plan.playerWidth - CLLayoutColumnGap - CLLayoutPanelSideInset,
                              CGRectGetHeight(safeArea) - 2.0 * CLLayoutPanelTopGap);
        case CLLayoutPlayerAreaBottomStrip:
            return CGRectMake(CGRectGetMinX(safeArea) + CLLayoutFullPanelLyricsInset,
                              CGRectGetMinY(safeArea) + CLLayoutFullPanelGap,
                              CGRectGetWidth(safeArea) - 2.0 * CLLayoutFullPanelLyricsInset,
                              CGRectGetHeight(safeArea) - plan.playerHeight - 2.0 * CLLayoutFullPanelGap);
        default:
            return CGRectNull;
    }
}
