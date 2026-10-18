// Turns a playback clock into "which lyric line is showing right now".
// Foundation only, main queue only. Nothing here touches the network, disk or UIKit.
#import <Foundation/Foundation.h>
#import "Core/CLPlaybackState.h"
#import "Lyrics/CLLyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// No line is active yet (playback is before the first timestamp).
extern const NSInteger CLLyricsNoLine;   // -1

/// Fired on the main queue only when the active line actually changes.
typedef void (^CLLyricsSyncLineChangedBlock)(NSInteger lineIndex);

@interface CLLyricsSyncEngine : NSObject

/// Synced lines. Copied, sorted ascending by time and filtered; nil or empty disables the engine.
@property (nonatomic, copy, nullable) NSArray<CLLyricLine *> *lines;
/// Seconds added to the playback position before looking a line up: positive shows lines earlier
/// in the song (lyrics run "ahead"), negative delays them. Range is clamped to ±30 s.
@property (nonatomic) NSTimeInterval offset;
/// Tick period while playing. Default 0.1 s, clamped to [0.02, 1.0].
@property (nonatomic) NSTimeInterval tickInterval;
/// Assumed on-screen time of the final line when the track duration is unknown. Default 5 s.
@property (nonatomic) NSTimeInterval finalLineDuration;

@property (nonatomic, copy, nullable) CLLyricsSyncLineChangedBlock onLineChanged;

/// Active line, or CLLyricsNoLine.
@property (nonatomic, readonly) NSInteger currentLineIndex;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly, nullable) CLPlaybackState *playbackState;

/// Feeds a new playback state: re-evaluates the line immediately (so seeks and track changes are
/// instant) and starts or stops the tick timer to match `state.isPlaying`. Pass nil to stop.
- (void)updateWithPlaybackState:(nullable CLPlaybackState *)state;
/// Stops the timer and forgets the playback state. The line index is reset to CLLyricsNoLine.
- (void)stop;
/// Re-evaluates now without changing the playback state (after an offset or lines change).
- (void)reevaluate;

/// Binary search: index of the last line whose time <= elapsed, or CLLyricsNoLine. Pure function
/// of `lines`; `elapsed` is a raw playback position (the offset is applied internally).
- (NSInteger)lineIndexForElapsed:(NSTimeInterval)elapsed;
/// 0...1 through the current line, for progress animations. 0 when there is no current line.
- (NSTimeInterval)progressWithinCurrentLine;
/// Playback position to seek to so that `index` becomes the current line (offset compensated).
/// Returns -1 when the index is out of range.
- (NSTimeInterval)playbackTimeForLineAtIndex:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
