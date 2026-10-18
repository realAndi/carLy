// Owned by the ui slice. The full-screen lyrics view the microphone button in the host's play-mode
// row opens (0.7.0): the lyrics across the whole safe area, and one row under them with the song's
// title and artist on the left and previous / play-pause / next / close on the right. It covers the
// host's Now Playing view (the customizer hides that while it is up), so it fits every screen shape,
// including the ones where no split layout fits (the CarPlay Simulator's "Minimum").
//
// Pure UIKit. Main thread only. The lyrics panel inside stays display-only (never a focus target);
// the four buttons are ordinary UIButtons, so the knob and touch both reach them.
#import <UIKit/UIKit.h>
#import "Core/CLNowPlayingSource.h"
#import "UI/CLLyricsPanelView.h"

NS_ASSUME_NONNULL_BEGIN

@class CLLyricsFullScreenView;

@protocol CLLyricsFullScreenViewDelegate <NSObject>
/// Previous, play/pause or next saw `events`: UIControlEventTouchDown when a touch starts, then
/// UIControlEventTouchUpInside once it ends (inside, outside or cancelled). The customizer forwards
/// both to the host's own transport button, which is exactly how CarPlay's player tells a tap from
/// a held skip (seek).
- (void)lyricsFullScreenView:(CLLyricsFullScreenView *)view didSendEvents:(UIControlEvents)events
                  forCommand:(CLPlaybackCommand)command;
/// The microphone in the view's own row was tapped: leave full screen.
- (void)lyricsFullScreenViewDidRequestClose:(CLLyricsFullScreenView *)view;
@end

/// The host's CPUIModernButton (the class CarPlay's own transport and play-mode buttons are) when
/// it exists, set up the way CarPlayUI sets up its buttons; a custom-type UIButton otherwise.
/// Never UIButtonTypeSystem: on CarPlay that draws a dark platter behind the glyph.
FOUNDATION_EXPORT UIButton *CLMakeHostStyleButton(BOOL prefersWhite);

@interface CLLyricsFullScreenView : UIView

@property (nonatomic, weak, nullable) id<CLLyricsFullScreenViewDelegate> delegate;
/// The lyrics, sized with the three-row fit (CLLayoutPanelFitRows).
@property (nonatomic, readonly) CLLyricsPanelView *panelView;
/// Previous, play/pause, next, close — in that order (tests and focus logging).
@property (nonatomic, readonly) NSArray<UIButton *> *controlButtons;

/// The row's song line. Empty strings and nil hide the respective label.
- (void)setTitle:(nullable NSString *)title artist:(nullable NSString *)artist;
/// Shows pause while playing, play otherwise (only used while no host images were handed over).
- (void)setPlaying:(BOOL)playing;
/// The host's own transport images (what its hidden player shows right now) and its button height;
/// nil images keep the SF Symbol fallbacks.
- (void)setPreviousImage:(nullable UIImage *)previous playPauseImage:(nullable UIImage *)playPause
               nextImage:(nullable UIImage *)next buttonHeight:(CGFloat)buttonHeight;
/// The microphone glyph, sized like the host's play-mode icons (nil keeps the fallback).
- (void)setMicrophoneImage:(nullable UIImage *)image;
/// What plays now: drives the thin progress line above the controls (elapsed, bar, remaining),
/// which interpolates between samples twice a second and hides while the length is unknown.
- (void)setPlaybackState:(nullable CLPlaybackState *)state;
/// The progress line (tests).
@property (nonatomic, readonly) UIView *progressView;
/// Layout > Progress Bar: Hide hides this line as well as the player's.
- (void)setProgressHidden:(BOOL)hidden;
/// Layout > Accent (album colors or a fixed color): the progress fill and the artist name, like
/// the player's; nil keeps CarPlay's white and secondary grey.
- (void)setAccentColor:(nullable UIColor *)color;
/// "Looking for lyrics…" / "No lyrics for this song" where the lyrics would be; nil hides it.
- (void)setStatusText:(nullable NSString *)text;
/// Re-reads the panel's visual preferences.
- (void)applyPrefs;

@end

NS_ASSUME_NONNULL_END
