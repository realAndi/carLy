#import "UI/CLLyricsFullScreenView.h"
#import "UI/CLLayoutGeometry.h"
#import "UI/CLLyricsStyle.h"

#import <objc/message.h>

// Every measure of this view is in UI/CLLayoutGeometry.h (CLLayoutFullScreen*), shared with the
// settings preview. Only the button metrics below are this view's own.
static const CGFloat kCLFullScreenRowHeight = CLLayoutFullScreenRowHeight;
static const CGFloat kCLFullScreenRowLeading = CLLayoutFullScreenRowLeading;
static const CGFloat kCLFullScreenRowTrailing = CLLayoutFullScreenRowTrailing;
static const CGFloat kCLFullScreenRowBottom = CLLayoutFullScreenRowBottom;
static const CGFloat kCLFullScreenLyricsTop = CLLayoutFullScreenLyricsTop;
static const CGFloat kCLFullScreenLyricsBottomGap = CLLayoutFullScreenLyricsGap;
static const CGFloat kCLFullScreenMinimumWidthForText = CLLayoutFullScreenMinimumWidthForText;
static const CGFloat kCLFullScreenProgressHeight = CLLayoutFullScreenProgressHeight;
static const CGFloat kCLFullScreenProgressBarThickness = CLLayoutFullScreenProgressThickness;
static const CGFloat kCLFullScreenProgressGap = CLLayoutFullScreenProgressGap;
static const CGFloat kCLFullScreenButtonSpacing = 8.0;
/// The transport buttons are the host's height (36 or 44) and this much wider, like its own row.
static const CGFloat kCLFullScreenTransportExtraWidth = 20.0;
/// Between the transport buttons and the microphone.
static const CGFloat kCLFullScreenMicrophoneGap = 12.0;
/// The progress line's time labels and their gap to the bar.
static const CGFloat kCLFullScreenTimeWidth = 40.0;
static const CGFloat kCLFullScreenTimeGap = 8.0;
static const NSTimeInterval kCLFullScreenProgressTick = 0.5;

@implementation CLLyricsFullScreenView {
    CLLyricsPanelView *_panelView;
    UILabel *_statusLabel;
    UILabel *_titleLabel;
    UILabel *_artistLabel;
    UIButton *_previousButton;
    UIButton *_playButton;
    UIButton *_nextButton;
    UIButton *_closeButton;
    BOOL _playing;
    /// YES once the host's own play/pause image was handed over; -setPlaying: then stays out of it.
    BOOL _hasHostPlayImage;
    CGFloat _buttonHeight;
    NSArray<NSLayoutConstraint *> *_transportSizeConstraints;
    UIStackView *_textStack;
    // Progress (display only).
    UIView *_progressRow;
    UIView *_progressTrack;
    UIView *_progressFill;
    UILabel *_elapsedLabel;
    UILabel *_remainingLabel;
    CLPlaybackState *_playbackState;
    CGFloat _progressFraction;
    NSTimer *_progressTimer;
    BOOL _progressHiddenByPreference;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) [self cl_build];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self cl_build];
    return self;
}

- (CLLyricsPanelView *)panelView {
    return _panelView;
}

- (NSArray<UIButton *> *)controlButtons {
    return @[ _previousButton, _playButton, _nextButton, _closeButton ];
}

#pragma mark - Building

UIButton *CLMakeHostStyleButton(BOOL prefersWhite) {
    Class modern = NSClassFromString(@"CPUIModernButton");
    UIButton *button = nil;
    if (modern && [modern isSubclassOfClass:UIButton.class]) {
        // -[CPUIPlayModeControlView initWithFrame:] / -[CPUITransportControlView initWithFrame:]
        // (iOS 17.3): +buttonWithType:0, an image, and for the transport row prefersWhite.
        button = [modern buttonWithType:UIButtonTypeCustom];
        SEL white = NSSelectorFromString(@"setPrefersWhiteInDefaultState:");
        if (prefersWhite && [button respondsToSelector:white]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(button, white, YES);
        }
    }
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.tintColor = UIColor.labelColor;
    }
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.contentMode = UIViewContentModeCenter;
    button.imageView.contentMode = UIViewContentModeCenter;
    return button;
}

/// Equal strings, or both empty/nil.
static BOOL CLSameText(NSString *a, NSString *b) {
    if (a.length == 0 && b.length == 0) return YES;
    return [a isEqualToString:b];
}

static UIImage *CLSymbol(NSString *name, CGFloat pointSize, UIImageSymbolWeight weight) {
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:weight];
    return [[UIImage systemImageNamed:name withConfiguration:configuration] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (UIButton *)cl_transportButtonWithSymbol:(NSString *)symbol label:(NSString *)label {
    UIButton *button = CLMakeHostStyleButton(YES);
    [button setImage:CLSymbol(symbol, 22.0, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
    button.accessibilityLabel = label;
    [button addTarget:self action:@selector(cl_transportTouchDown:) forControlEvents:UIControlEventTouchDown];
    [button addTarget:self action:@selector(cl_transportTouchUp:)
     forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    return button;
}

- (void)cl_build {
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;

    _panelView = [[CLLyricsPanelView alloc] initWithFrame:CGRectZero];
    _panelView.translatesAutoresizingMaskIntoConstraints = NO;
    _panelView.fit = CLLayoutPanelFitRows;
    _panelView.hidden = YES;
    [self addSubview:_panelView];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.userInteractionEnabled = NO;
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 2;
    _statusLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightSemibold];
    _statusLabel.textColor = UIColor.secondaryLabelColor;
    _statusLabel.hidden = YES;
    [self addSubview:_statusLabel];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    _titleLabel.textColor = UIColor.labelColor;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _artistLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _artistLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    _artistLabel.textColor = UIColor.secondaryLabelColor;
    _artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[ _titleLabel, _artistLabel ]];
    text.translatesAutoresizingMaskIntoConstraints = NO;
    text.axis = UILayoutConstraintAxisVertical;
    text.alignment = UIStackViewAlignmentLeading;
    text.spacing = 1.0;
    text.userInteractionEnabled = NO;
    [text setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [self addSubview:text];
    _textStack = text;
    [self cl_buildProgressRow];

    // The transport row: CarPlay's own button class, glyphs and height (the host's images replace
    // these fallbacks as soon as the customizer hands them over).
    _previousButton = [self cl_transportButtonWithSymbol:@"backward.fill" label:@"Previous"];
    _playButton = [self cl_transportButtonWithSymbol:@"play.fill" label:@"Play"];
    _nextButton = [self cl_transportButtonWithSymbol:@"forward.fill" label:@"Next"];
    _buttonHeight = CLLayoutHostTransportSmall;
    NSMutableArray<NSLayoutConstraint *> *sizes = [NSMutableArray array];
    for (UIButton *button in @[ _previousButton, _playButton, _nextButton ]) {
        NSLayoutConstraint *width = [button.widthAnchor constraintEqualToConstant:_buttonHeight + kCLFullScreenTransportExtraWidth];
        NSLayoutConstraint *height = [button.heightAnchor constraintEqualToConstant:_buttonHeight];
        [sizes addObjectsFromArray:@[ width, height ]];
    }
    _transportSizeConstraints = sizes;

    // The microphone is "on" here, drawn like the host's selected play-mode buttons (repeat on).
    _closeButton = CLMakeHostStyleButton(NO);
    [_closeButton setImage:CLSymbol(@"mic", 15.0, UIImageSymbolWeightRegular) forState:UIControlStateNormal];
    _closeButton.accessibilityLabel = @"Hide Lyrics";
    SEL staySelected = NSSelectorFromString(@"setShouldStaySelected:");
    if ([_closeButton respondsToSelector:staySelected]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(_closeButton, staySelected, YES);
    }
    _closeButton.selected = YES;
    if (!NSClassFromString(@"CPUIModernButton")) {
        _closeButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.22];
        _closeButton.layer.cornerRadius = 8.0;
    }
    [_closeButton addTarget:self action:@selector(cl_closeTapped:) forControlEvents:UIControlEventTouchUpInside];
    [sizes addObjectsFromArray:@[
        [_closeButton.widthAnchor constraintEqualToConstant:CLLayoutHostTransportLarge],
        [_closeButton.heightAnchor constraintEqualToConstant:CLLayoutHostPlayModeHeight],
    ]];
    [NSLayoutConstraint activateConstraints:sizes];

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[ _previousButton, _playButton, _nextButton ]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.alignment = UIStackViewAlignmentCenter;
    buttons.spacing = kCLFullScreenButtonSpacing;
    [buttons setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self addSubview:buttons];
    [self addSubview:_closeButton];

    [NSLayoutConstraint activateConstraints:@[
        [_panelView.topAnchor constraintEqualToAnchor:self.topAnchor constant:kCLFullScreenLyricsTop],
        [_panelView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:CLLayoutFullPanelLyricsInset],
        [self.trailingAnchor constraintEqualToAnchor:_panelView.trailingAnchor constant:CLLayoutFullPanelLyricsInset],

        [_statusLabel.centerYAnchor constraintEqualToAnchor:_panelView.centerYAnchor],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:_panelView.leadingAnchor constant:CLLayoutPanelTextInset],
        [_panelView.trailingAnchor constraintEqualToAnchor:_statusLabel.trailingAnchor constant:CLLayoutPanelTextInset],

        // One row, kCLFullScreenRowHeight tall, at the bottom: text, transport, microphone; the
        // progress line right above it; the lyrics above that.
        [self.bottomAnchor constraintEqualToAnchor:buttons.centerYAnchor constant:kCLFullScreenRowBottom + kCLFullScreenRowHeight / 2.0],
        [_progressRow.heightAnchor constraintEqualToConstant:kCLFullScreenProgressHeight],
        [_progressRow.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                                  constant:-(kCLFullScreenRowBottom + kCLFullScreenRowHeight + kCLFullScreenProgressGap)],
        [_progressRow.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:kCLFullScreenRowLeading],
        [self.trailingAnchor constraintEqualToAnchor:_progressRow.trailingAnchor constant:kCLFullScreenRowTrailing],
        [_panelView.bottomAnchor constraintEqualToAnchor:_progressRow.topAnchor constant:-kCLFullScreenLyricsBottomGap],
        [_closeButton.centerYAnchor constraintEqualToAnchor:buttons.centerYAnchor],
        [self.trailingAnchor constraintEqualToAnchor:_closeButton.trailingAnchor constant:kCLFullScreenRowTrailing],
        [_closeButton.leadingAnchor constraintEqualToAnchor:buttons.trailingAnchor constant:kCLFullScreenMicrophoneGap],

        [text.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:kCLFullScreenRowLeading],
        [text.centerYAnchor constraintEqualToAnchor:buttons.centerYAnchor],
        [buttons.leadingAnchor constraintGreaterThanOrEqualToAnchor:text.trailingAnchor constant:12.0],
    ]];
    [self setPlaying:NO];
}

- (void)cl_buildProgressRow {
    _progressRow = [[UIView alloc] initWithFrame:CGRectZero];
    _progressRow.translatesAutoresizingMaskIntoConstraints = NO;
    _progressRow.userInteractionEnabled = NO;
    _progressRow.hidden = YES;
    [self addSubview:_progressRow];

    UILabel *(^timeLabel)(NSTextAlignment) = ^UILabel *(NSTextAlignment alignment) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightMedium];
        label.textColor = UIColor.secondaryLabelColor;
        label.textAlignment = alignment;
        return label;
    };
    _elapsedLabel = timeLabel(NSTextAlignmentLeft);
    _remainingLabel = timeLabel(NSTextAlignmentRight);
    _progressTrack = [[UIView alloc] initWithFrame:CGRectZero];
    _progressTrack.translatesAutoresizingMaskIntoConstraints = NO;
    _progressTrack.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.25];
    _progressTrack.layer.cornerRadius = kCLFullScreenProgressBarThickness / 2.0;
    _progressTrack.clipsToBounds = YES;
    // The fill is laid out by hand (a width that changes twice a second is not a constraint).
    _progressFill = [[UIView alloc] initWithFrame:CGRectZero];
    _progressFill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.9];
    _progressFill.layer.cornerRadius = kCLFullScreenProgressBarThickness / 2.0;
    [_progressTrack addSubview:_progressFill];
    for (UIView *view in @[ _elapsedLabel, _progressTrack, _remainingLabel ]) [_progressRow addSubview:view];

    [NSLayoutConstraint activateConstraints:@[
        [_elapsedLabel.leadingAnchor constraintEqualToAnchor:_progressRow.leadingAnchor],
        [_elapsedLabel.widthAnchor constraintEqualToConstant:kCLFullScreenTimeWidth],
        [_elapsedLabel.centerYAnchor constraintEqualToAnchor:_progressRow.centerYAnchor],
        [_progressRow.trailingAnchor constraintEqualToAnchor:_remainingLabel.trailingAnchor],
        [_remainingLabel.widthAnchor constraintEqualToConstant:kCLFullScreenTimeWidth],
        [_remainingLabel.centerYAnchor constraintEqualToAnchor:_progressRow.centerYAnchor],
        [_progressTrack.leadingAnchor constraintEqualToAnchor:_elapsedLabel.trailingAnchor constant:kCLFullScreenTimeGap],
        [_remainingLabel.leadingAnchor constraintEqualToAnchor:_progressTrack.trailingAnchor constant:kCLFullScreenTimeGap],
        [_progressTrack.heightAnchor constraintEqualToConstant:kCLFullScreenProgressBarThickness],
        [_progressTrack.centerYAnchor constraintEqualToAnchor:_progressRow.centerYAnchor],
    ]];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    BOOL narrow = CGRectGetWidth(self.bounds) < kCLFullScreenMinimumWidthForText;
    if (_textStack.isHidden != narrow) _textStack.hidden = narrow;
    [self cl_layoutProgressFill];
}

- (void)cl_layoutProgressFill {
    CGRect track = _progressTrack.bounds;
    CGRect fill = CGRectMake(0.0, 0.0, round(CGRectGetWidth(track) * _progressFraction), CGRectGetHeight(track));
    if (!CGRectEqualToRect(_progressFill.frame, fill)) _progressFill.frame = fill;
}

/// "3:07" / "1:02:07".
static NSString *CLTimeText(NSTimeInterval seconds) {
    NSInteger total = (NSInteger)floor(MAX(0.0, seconds));
    NSInteger hours = total / 3600, minutes = (total / 60) % 60, rest = total % 60;
    if (hours > 0) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours, (long)minutes, (long)rest];
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)rest];
}

/// Where the song is now (interpolated from the last MediaRemote sample), on the bar and in the
/// two times; hidden while the length is unknown (radio, some ads).
- (void)cl_updateProgress {
    CLPlaybackState *state = _playbackState;
    NSTimeInterval duration = state.duration;
    BOOL known = duration > 0.0 && isfinite(duration);
    BOOL shown = known && !_progressHiddenByPreference;
    if (_progressRow.isHidden == shown) _progressRow.hidden = !shown;
    if (!shown) return;
    NSTimeInterval elapsed = MIN(duration, MAX(0.0, [state elapsedNow]));
    _progressFraction = (CGFloat)(elapsed / duration);
    NSString *elapsedText = CLTimeText(elapsed);
    NSString *remainingText = [@"-" stringByAppendingString:CLTimeText(duration - elapsed)];
    if (![_elapsedLabel.text isEqualToString:elapsedText]) _elapsedLabel.text = elapsedText;
    if (![_remainingLabel.text isEqualToString:remainingText]) _remainingLabel.text = remainingText;
    [self cl_layoutProgressFill];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [_progressTimer invalidate];
    _progressTimer = nil;
    if (!self.window) return;
    // A block timer holding self weakly: the view can go away without anyone stopping it first.
    __weak typeof(self) weakSelf = self;
    _progressTimer = [NSTimer timerWithTimeInterval:kCLFullScreenProgressTick repeats:YES block:^(NSTimer *timer) {
        CLUISafePerform(@"full screen progress", ^{ [weakSelf cl_updateProgress]; });
    }];
    [NSRunLoop.mainRunLoop addTimer:_progressTimer forMode:NSRunLoopCommonModes];
    [self cl_updateProgress];
}

- (void)dealloc {
    [_progressTimer invalidate];
}

/// Knob focus lands on play/pause first (like CarPlay's own player), the microphone next.
- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return @[ _playButton, _closeButton ];
}

#pragma mark - Public API

- (void)setTitle:(NSString *)title artist:(NSString *)artist {
    NSString *titleText = title.length ? title : nil;
    NSString *artistText = artist.length ? artist : nil;
    if (!CLSameText(_titleLabel.text, titleText)) _titleLabel.text = titleText;
    if (!CLSameText(_artistLabel.text, artistText)) _artistLabel.text = artistText;
    if (_titleLabel.isHidden != (titleText == nil)) _titleLabel.hidden = (titleText == nil);
    if (_artistLabel.isHidden != (artistText == nil)) _artistLabel.hidden = (artistText == nil);
}

- (void)setPlaying:(BOOL)playing {
    _playing = playing;
    _playButton.accessibilityLabel = playing ? @"Pause" : @"Play";
    if (_hasHostPlayImage) return;
    [_playButton setImage:CLSymbol(playing ? @"pause.fill" : @"play.fill", 22.0, UIImageSymbolWeightSemibold)
                 forState:UIControlStateNormal];
}

- (void)setPreviousImage:(UIImage *)previous playPauseImage:(UIImage *)playPause
               nextImage:(UIImage *)next buttonHeight:(CGFloat)buttonHeight {
    if (previous && [_previousButton imageForState:UIControlStateNormal] != previous) {
        [_previousButton setImage:previous forState:UIControlStateNormal];
    }
    if (next && [_nextButton imageForState:UIControlStateNormal] != next) {
        [_nextButton setImage:next forState:UIControlStateNormal];
    }
    if (playPause) {
        _hasHostPlayImage = YES;
        if ([_playButton imageForState:UIControlStateNormal] != playPause) {
            [_playButton setImage:playPause forState:UIControlStateNormal];
        }
    }
    // The row is 44 pt tall: the host's two sizes (36, 44) fit, anything else keeps the last one.
    if (buttonHeight >= 20.0 && buttonHeight <= kCLFullScreenRowHeight && fabs(buttonHeight - _buttonHeight) > 0.5) {
        _buttonHeight = buttonHeight;
        for (NSLayoutConstraint *constraint in _transportSizeConstraints) {
            if (constraint.firstAttribute == NSLayoutAttributeWidth) constraint.constant = buttonHeight + kCLFullScreenTransportExtraWidth;
            if (constraint.firstAttribute == NSLayoutAttributeHeight) constraint.constant = buttonHeight;
        }
    }
}

- (void)setMicrophoneImage:(UIImage *)image {
    if (image && [_closeButton imageForState:UIControlStateNormal] != image) {
        [_closeButton setImage:image forState:UIControlStateNormal];
    }
}

- (void)setPlaybackState:(CLPlaybackState *)state {
    _playbackState = state;
    [self cl_updateProgress];
}

- (UIView *)progressView {
    return _progressRow;
}

- (void)setProgressHidden:(BOOL)hidden {
    if (_progressHiddenByPreference == hidden) return;
    _progressHiddenByPreference = hidden;
    [self cl_updateProgress];
}

- (void)setAccentColor:(UIColor *)color {
    UIColor *fill = color ?: [UIColor colorWithWhite:1.0 alpha:0.9];
    UIColor *artist = color ?: UIColor.secondaryLabelColor;
    if (![_progressFill.backgroundColor isEqual:fill]) _progressFill.backgroundColor = fill;
    if (![_artistLabel.textColor isEqual:artist]) _artistLabel.textColor = artist;
}

- (void)setStatusText:(NSString *)text {
    NSString *value = text.length ? text : nil;
    if (!((value == nil && _statusLabel.text == nil) || [_statusLabel.text isEqualToString:value])) _statusLabel.text = value;
    BOOL hidden = (value == nil);
    if (_statusLabel.isHidden != hidden) _statusLabel.hidden = hidden;
}

- (void)applyPrefs {
    [_panelView applyPrefs];
}

#pragma mark - Actions

// UIKit calls these straight from the touch handler, outside every hook: nothing below may raise.

- (CLPlaybackCommand)cl_commandForButton:(id)sender {
    if (sender == _previousButton) return CLPlaybackCommandPreviousTrack;
    if (sender == _nextButton) return CLPlaybackCommandNextTrack;
    return CLPlaybackCommandTogglePlayPause;
}

- (void)cl_transportTouchDown:(id)sender {
    CLUISafePerform(@"full screen transport down", ^{
        [self.delegate lyricsFullScreenView:self didSendEvents:UIControlEventTouchDown forCommand:[self cl_commandForButton:sender]];
    });
}

- (void)cl_transportTouchUp:(id)sender {
    CLUISafePerform(@"full screen transport up", ^{
        [self.delegate lyricsFullScreenView:self didSendEvents:UIControlEventTouchUpInside
                                 forCommand:[self cl_commandForButton:sender]];
    });
}

- (void)cl_closeTapped:(id)sender {
    CLUISafePerform(@"full screen close", ^{
        [self.delegate lyricsFullScreenViewDidRequestClose:self];
    });
}

@end
