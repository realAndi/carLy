// Owned by the ui slice. One customizer per CPUINowPlayingViewController, stored on it as an
// associated object. It is the only place in the tweak that touches the host's private view
// hierarchy: it resolves the Now Playing subviews through CLIvar()/CLFindSubview(), places the
// lyrics panel against them, applies every layout preference, and can put all of it back.
//
// Nothing here assumes an ivar exists. Any anchor that cannot be resolved degrades to pinning
// inside the controller's safe area (logged once), and every mutation of a host view is recorded
// so -detach restores it. Main thread only; public methods hop to the main queue themselves.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLLayoutCustomizer : NSObject

/// The customizer associated with `viewController`, creating (and attaching) one when `create` is
/// YES. Returns nil for a nil controller, off the main thread, or when create is NO and none exists.
+ (nullable instancetype)customizerForViewController:(nullable UIViewController *)viewController
                                              create:(BOOL)create;
/// Detaches the customizer for `viewController` (restoring the host's layout) and forgets it.
+ (void)detachFromViewController:(nullable UIViewController *)viewController;

/// Starts observing prefs + CLLyricsController and applies everything. Safe to call repeatedly.
- (void)attachToViewController:(nullable UIViewController *)viewController;
/// Puts every host view back the way it was and removes our views and observers.
- (void)detach;
/// Re-reads CLPrefs and re-applies everything (wired to CLPrefsDidChangeNotification internally,
/// so hooks only need to call it after they change something themselves).
- (void)applyPrefs;
/// Cheap, idempotent re-application of the parts the host resets during its own layout passes
/// (tint, bar buttons, visibility, the panel's placement). Safe to call from a layoutSubviews hook.
- (void)relayout;
/// The artwork image changed: recompute the artwork tint and refresh the blurred backdrop.
- (void)artworkDidChange;

#pragma mark Driving the host's layout (lyricsMode 2 and 4)

// Two layouts ask the host to lay itself out for part of the screen (UI/CLLayoutGeometry.h has
// the exact rules, shared with the settings preview). While a player area is set,
// -[CPUINowPlayingView recalculateLayout:…] is handed the area's rects instead of the whole
// screen, and the host's own layout chooser (CPUINowPlayingLayoutForSafeAreaFrameScaleArtwork)
// picks a layout for that shape; afterwards the host's fresh full-screen size constraints are
// swapped for the area's.
//   * Mode 4 (side by side) gives the host's Now Playing view a leading column and puts the
//     scrolling lyrics panel in the rest of the screen. The column is narrower than
//     CPUINowPlayingLayoutSideArtworkMinAspectRatio, so the chooser stacks art above title,
//     progress and buttons; on short screens the column is just wide enough for the art-left
//     side layout instead. Where the split does not fit, mode 4 shows the full panel.
//   * Mode 2 (full panel) hands the host a full-width bottom strip without artwork
//     (allowsAlbumArt:NO): the chooser returns its artwork-less stacked layout, hides the artwork
//     square itself, and the strip's height alone makes it pick its small title tier and 36 pt
//     buttons. The lyrics panel takes everything above the strip. Where the strip does not fit
//     (short screens), the same artwork-less player goes in a 284 pt leading column with the
//     lyrics beside it; where that does not fit, side by side; where nothing fits, the stock screen.
//     Settings calls mode 2 "No Artwork".
//   * The panel follows the player area (column: beside it; strip: above it), not the mode.
// Mode 3 (Replace Artwork, lyrics on the artwork square) was removed in 0.6.0 and reads as 4.

/// Set by the hooks once both host methods that side by side needs are hooked. While NO, every
/// mode shows the stock screen. Main thread only.
@property (class, nonatomic) BOOL hostColumnHooksInstalled;

/// The player column's width for this screen (side by side, or the full panel on a short screen),
/// or 0 when the host is not in a column (another layout, an app that is not enabled, a screen too
/// narrow, the hooks missing). A pure function of the preferences and the controller view's safe
/// area, so the hooks can ask before a layout pass.
@property (nonatomic, readonly) CGFloat playerColumnWidth;
/// The bottom strip's height for this screen (CLLayoutFullPanelStripHeight), or 0 when the host is
/// not in the strip (including the full panel's short-screen column).
@property (nonatomic, readonly) CGFloat playerStripHeight;

/// Full-screen lyrics (0.7.0): the lyrics across the whole safe area with a compact title and
/// previous / play-pause / next row under them, over the host's Now Playing view (hidden while it
/// is up). The microphone the customizer adds to the host's play-mode row sets it; the view's own
/// microphone clears it. Only takes effect while the microphone is offered (lyrics on, the app
/// enabled and playing). Main thread; setting it from elsewhere hops there.
@property (nonatomic, getter=isFullScreen) BOOL fullScreen;
/// Our microphone button in the host's play-mode row, nil until it was first placed.
@property (nonatomic, readonly, nullable) UIButton *microphoneButton;

/// The hooks' calls for full screen: the host re-filled its play-mode row (-setMediaButtons:),
/// updated its play/pause glyph (-[CPUITransportControlView _updatePlayPauseButton]), or asks
/// where knob focus should go (nil: the host's own answer; while full screen, our buttons —
/// the host's own choice, its play/pause button, is hidden then).
+ (void)hostPlayModeRowDidChangeForViewController:(UIViewController *)viewController;
+ (void)hostTransportDidUpdateForViewController:(UIViewController *)viewController;
/// The host re-applied its play-mode buttons' visibility (-_updatePlayModesState): the playback-speed
/// button may need hiding again.
+ (void)hostPlayModesDidUpdateForViewController:(UIViewController *)viewController;
+ (nullable NSArray<id<UIFocusEnvironment>> *)focusEnvironmentsForViewController:(UIViewController *)viewController;

/// Called by the hooks around -[CPUINowPlayingViewController _recalculateLayout:], for every
/// controller (with or without a customizer). Before: records or clears the player-area rects the
/// Now Playing view lays itself out for. After: swaps the host's freshly built full-screen size
/// constraints for the area's, and hands them to the host so its next pass removes them again.
+ (void)hostWillRecalculateLayoutForViewController:(nullable UIViewController *)viewController;
+ (void)hostDidRecalculateLayoutForViewController:(nullable UIViewController *)viewController;

/// Stops (YES) or resumes (NO) the per-line render work while the Now Playing screen is offscreen.
/// A paused customizer stays attached and keeps every host change in place — it just ignores the
/// lyrics controller's ~10 Hz line callbacks and the host's layout passes, so nothing animates
/// behind a screen nobody is looking at. Resuming re-applies the layout and pushes the current
/// line without animating, so no update is lost. It also hands the lyrics controller's
/// active-display count back while paused (-[CLLyricsController displayDidResignActive]), which
/// slows the sync engine's main-queue tick from 10 Hz to 1 Hz for as long as nothing is watching.
/// Idempotent; safe from any thread.
- (void)setPaused:(BOOL)paused;

@property (nonatomic, weak, readonly, nullable) UIViewController *viewController;
@property (nonatomic, readonly, getter=isAttached) BOOL attached;
@property (nonatomic, readonly, getter=isPaused) BOOL paused;

/// One line naming which host views were resolved and which features are on. Probe logging.
- (NSString *)debugDescription;

@end

/// The rects -[CPUINowPlayingView recalculateLayout:…] should use instead of the ones the host
/// passes (a leading column or a bottom strip), or NO when `nowPlayingView` has no player-area
/// override. Main thread only.
FOUNDATION_EXPORT BOOL CLPlayerColumnRects(UIView *_Nullable nowPlayingView, CGRect *_Nullable viewArea,
                                           CGRect *_Nullable safeArea);
/// YES when the override asks the host to leave the artwork out (the full panel's strip): the hook
/// passes allowsAlbumArt:NO, and the host's chooser returns its stacked layout without artwork.
FOUNDATION_EXPORT BOOL CLHostLayoutHidesArtwork(UIView *_Nullable nowPlayingView);
/// NO when the override's column sits at the trailing edge (Lyrics Side: Left): the view hook then
/// reports left-hand drive so a side layout puts the art on the right, at the outer edge.
FOUNDATION_EXPORT BOOL CLHostLayoutArtworkOnLeft(UIView *_Nullable nowPlayingView);

NS_ASSUME_NONNULL_END
