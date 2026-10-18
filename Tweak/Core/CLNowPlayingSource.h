// The single place that knows what is playing. Wraps MediaRemote (resolved with dlopen/dlsym —
// the SDK has no stub library for it) and accepts metadata pushed in by host hooks.
// Foundation only. Every callback is delivered on the main queue.
#import <Foundation/Foundation.h>
#import "Core/CLPlaybackState.h"

NS_ASSUME_NONNULL_BEGIN

/// The transport commands the full-screen lyrics view sends to the now-playing app.
typedef NS_ENUM(NSInteger, CLPlaybackCommand) {
    CLPlaybackCommandTogglePlayPause = 0,
    CLPlaybackCommandNextTrack = 1,
    CLPlaybackCommandPreviousTrack = 2,
};

/// Called on the main queue whenever the published state changes.
typedef void (^CLNowPlayingObserverBlock)(CLPlaybackState *state);

@interface CLNowPlayingSource : NSObject

+ (instancetype)sharedSource;
- (instancetype)init NS_UNAVAILABLE;

/// YES when MediaRemote could be loaded and the functions we need were found.
@property (nonatomic, readonly) BOOL mediaRemoteAvailable;
/// YES between -start and -stop.
@property (nonatomic, readonly, getter=isRunning) BOOL running;
/// Last published state. Never nil after -start; safe to read from any thread.
@property (nonatomic, readonly) CLPlaybackState *currentState;

/// Registers for MediaRemote notifications and publishes an initial state. Idempotent.
/// Note: MediaRemote's per-process notification registration is never undone (unregistering
/// would also silence the host's own now-playing consumers), -stop only detaches our observers.
- (void)start;
- (void)stop;
/// Ask MediaRemote for a fresh reading (throttled, never blocks the caller).
- (void)refresh;

/// Adds a block observer, returns an opaque token, and delivers the current state immediately
/// (asynchronously on the main queue). Safe to call from any thread.
- (id)addObserver:(CLNowPlayingObserverBlock)observer;
- (void)removeObserver:(nullable id)token;

/// Metadata seen by a hook (e.g. CPUINowPlayingSnapshot) for when MediaRemote yields nothing in
/// the host. Merged into the published state; a richer MediaRemote reading is never replaced by
/// a poorer one. Safe to call from any thread.
- (void)ingestExternalTitle:(nullable NSString *)title
                     artist:(nullable NSString *)artist
                      album:(nullable NSString *)album
                   duration:(NSTimeInterval)duration
           bundleIdentifier:(nullable NSString *)bundleIdentifier
          contentIdentifier:(nullable NSString *)contentIdentifier;

/// YES when MRMediaRemoteSetElapsedTime was found; -seekToTime: is a no-op otherwise.
@property (nonatomic, readonly) BOOL canSeek;
/// Seeks the now-playing app, clamped to [0, duration]. Safe to call from any thread.
- (void)seekToTime:(NSTimeInterval)time;

/// YES when MRMediaRemoteSendCommand was found; -sendCommand: is a no-op otherwise.
@property (nonatomic, readonly) BOOL canSendCommands;
/// Sends a transport command to the now-playing app (the host holds
/// com.apple.mediaremote.send-commands). Safe to call from any thread.
- (void)sendCommand:(CLPlaybackCommand)command;

/// Keys of the last raw MediaRemote dictionary plus loader status, for probe logging.
- (NSString *)debugDescription;

@end

NS_ASSUME_NONNULL_END
