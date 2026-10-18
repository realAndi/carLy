// Minimal forward declarations of private CarPlayUI.framework classes (iOS 17.3).
// Names come from docs/research/CarPlayUI-NowPlaying-{classes,ivars,selectors}.txt. Everything
// here is a hypothesis until a probe log confirms it on a connected head unit: nothing in the
// tweak may reference these types without first resolving the class with CLClass()/
// NSClassFromString and the selector with respondsToSelector:.
//
// Only declarations that the hooks slice actually needs to compile live here. Ivars are listed as
// comments, never as @interface members: their offsets are not ours to assume, so they are read
// with CLIvar() (object_getInstanceVariable) which fails safely when a name is gone.
#import <UIKit/UIKit.h>

@class CPUINowPlayingSnapshot, CPUINowPlayingManager, CPUINowPlayingLayout, CPUINowPlayingView;

/// Metadata for the current item, delivered to the now-playing observers.
/// ivars: _title _artist _album _bundleIdentifier _durationSnapshot _responseItem _state
///        _tracklist _artworkCatalog _song _response _isRadioPlayback
@interface CPUINowPlayingSnapshot : NSObject
@end

/// Owns the snapshot and pushes updates to its observers (CPUINowPlayingObserving).
/// ivars: _snapshot _bundleIdentifier _lastContentItemIdentifier _lastContentItemTitle
///        _metadataThrottle _requestController _stateObservers _throttleBehavior
@interface CPUINowPlayingManager : NSObject
@end

/// Base of CPUINowPlayingLayoutStacked / LeftArtwork / RightArtwork.
@interface CPUINowPlayingLayout : NSObject
@end

/// The view that lays out artwork, song details, progress and transport controls.
/// ivars: _songDetailsView _songDetailsViewHeightConstraint _progressView _transportControlView
///        _playModeControlView _artworkViewBrick _nowPlayingLayout _activeConstraints
///        _verticalSpacerLayoutGuides _controlsFocusContainerGuide _bottomRegionFocusContainerGuide
///        _progressBarToBottomBarGuide _audioSessionRenderingModeView _audioBadgeConstraints
@interface CPUINowPlayingView : UIView
@end

/// The Now Playing screen for CarPlay *template* apps (Spotify, etc.).
/// ivars: _nowPlayingView _artworkView _artworkImage _artworkVisualEffectView
///        _artworkOperationQueue _dataSource _delegate _bundleIdentifier _rightTitleLabel
///        _playbackQueueBarButtonItem _rightTitleLabelBarButtonItem _activityIndicator
///        _activityIndicatorBarButtonItem _nowPlayingSizeConstraints
///
/// The selectors below are declared so hook bodies and probe code can be written against them.
/// They are NOT guaranteed to exist: `nowPlayingManager:didUpdateSnapshot:` in particular is part
/// of the CPUINowPlayingObserving protocol and is only hooked after class_getInstanceMethod()
/// confirms an implementation.
@interface CPUINowPlayingViewController : UIViewController
- (void)nowPlayingManager:(CPUINowPlayingManager *)manager
        didUpdateSnapshot:(CPUINowPlayingSnapshot *)snapshot;
@end

/// Apple Music's Now Playing screen (MusicCarDisplayUI.framework). Out of scope for milestone 1 —
/// declared so the placeholder group has something to hook when the class happens to be loaded.
@interface MCDNowPlayingViewController : UIViewController
@end
