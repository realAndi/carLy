// Immutable snapshot of "what is playing right now", as reported by MediaRemote or fed in by a
// host hook. Foundation only (no UIKit) so it stays testable from the on-device tool target.
#import <Foundation/Foundation.h>
#import "Lyrics/CLLyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// Where a snapshot came from. Used when deciding whether a poorer update may replace a richer one.
typedef NS_ENUM(NSInteger, CLPlaybackStateOrigin) {
    CLPlaybackStateOriginUnknown = 0,
    CLPlaybackStateOriginMediaRemote,   ///< MRMediaRemoteGetNowPlayingInfo
    CLPlaybackStateOriginExternal,      ///< CPUINowPlayingSnapshot fed in by a hook
    CLPlaybackStateOriginMerged,        ///< a MediaRemote state with gaps filled from an external one
};

@interface CLPlaybackState : NSObject <NSCopying>

- (instancetype)initWithTitle:(nullable NSString *)title
                       artist:(nullable NSString *)artist
                        album:(nullable NSString *)album
                     duration:(NSTimeInterval)duration
                  elapsedTime:(NSTimeInterval)elapsedTime
                    timestamp:(nullable NSDate *)timestamp
                 playbackRate:(double)playbackRate
             bundleIdentifier:(nullable NSString *)bundleIdentifier
            contentIdentifier:(nullable NSString *)contentIdentifier
                    isPlaying:(BOOL)isPlaying
              isAdvertisement:(BOOL)isAdvertisement
                       origin:(CLPlaybackStateOrigin)origin NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Metadata-only snapshot (no elapsed sample), e.g. from a Now Playing snapshot delivered to a hook.
+ (instancetype)stateWithTitle:(nullable NSString *)title
                        artist:(nullable NSString *)artist
                         album:(nullable NSString *)album
                      duration:(NSTimeInterval)duration
              bundleIdentifier:(nullable NSString *)bundleIdentifier
             contentIdentifier:(nullable NSString *)contentIdentifier
                        origin:(CLPlaybackStateOrigin)origin;
/// Nothing is playing / nothing is known.
+ (instancetype)emptyState;

@property (nonatomic, readonly, copy, nullable) NSString *title;
@property (nonatomic, readonly, copy, nullable) NSString *artist;
@property (nonatomic, readonly, copy, nullable) NSString *album;
@property (nonatomic, readonly) NSTimeInterval duration;       ///< seconds, 0 when unknown
@property (nonatomic, readonly) NSTimeInterval elapsedTime;    ///< seconds at -timestamp
@property (nonatomic, readonly, copy, nullable) NSDate *timestamp;  ///< when elapsedTime was sampled
@property (nonatomic, readonly) double playbackRate;           ///< 0 while paused, 1 at normal speed
@property (nonatomic, readonly, copy, nullable) NSString *bundleIdentifier;
@property (nonatomic, readonly, copy, nullable) NSString *contentIdentifier;  ///< "spotify:track:<id>#<uuid>"
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) BOOL isAdvertisement;
@property (nonatomic, readonly) CLPlaybackStateOrigin origin;

/// playbackRate when non-zero, else 1 while isPlaying (some clients report a rate of 0 while
/// playing), else 0. This is what -elapsedNow extrapolates with.
@property (nonatomic, readonly) double effectiveRate;
/// YES when there is at least a title: the minimum needed to look lyrics up.
@property (nonatomic, readonly) BOOL hasTrackInfo;
/// Rough "how much do we know" score, used to keep a richer state from being replaced by a poorer one.
@property (nonatomic, readonly) NSInteger informationScore;
/// Spotify-style content identity with the per-play "#<uuid>" suffix removed, nil when unknown.
@property (nonatomic, readonly, copy, nullable) NSString *contentIdentity;

/// elapsedTime + (now - timestamp) * effectiveRate, floored at 0 and capped at duration when known.
- (NSTimeInterval)elapsedNow;
/// The lyrics-lookup description of this song, or nil when there is no title.
- (nullable CLTrack *)track;
/// Same song? Content identity when both sides have one, else title/artist/duration (±2 s).
- (BOOL)isSameSongAs:(nullable CLPlaybackState *)other;
- (BOOL)isEqualToPlaybackState:(nullable CLPlaybackState *)other;

/// Copy of self with every empty field filled in from `other` (never overwrites what self knows).
/// Returns self when nothing changed.
- (instancetype)stateByFillingGapsFrom:(nullable CLPlaybackState *)other;
/// Copy of self carrying a new elapsed sample.
- (instancetype)stateByUpdatingElapsedTime:(NSTimeInterval)elapsedTime
                                 timestamp:(nullable NSDate *)timestamp
                              playbackRate:(double)playbackRate
                                 isPlaying:(BOOL)isPlaying;
/// Copy of self carrying a different now-playing app. Returns self when unchanged.
- (instancetype)stateBySettingBundleIdentifier:(nullable NSString *)bundleIdentifier;

@end

NS_ASSUME_NONNULL_END
