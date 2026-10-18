// The Music app's recent now-playing items (CLMusicItemInfo), as the MRNowPlayingPlayerClient hook
// sees them. The providers ask it "what are the store / library ids of this track?" by title and
// artist, because MediaRemote's now-playing dictionary (which CLTrack is built from) does not
// export lyricsAdamID or the lyrics flag. Thread-safe, Foundation only.
//
// Outside the Music process nothing ever records into it (`live` stays NO), and the providers
// answer "no match" straight away instead of waiting.
#import <Foundation/Foundation.h>
#import "Core/CLMusicItemInfo.h"

NS_ASSUME_NONNULL_BEGIN

@interface CLMusicItemRegistry : NSObject

+ (instancetype)sharedRegistry;

/// YES once the Music-process hook is installed. Providers only wait for an item while this is on.
@property (atomic, getter=isLive) BOOL live;

/// Remembers `info` as the newest item. An older entry for the same title/artist is replaced; at
/// most the eight newest distinct items are kept. Returns NO when `info` is equivalent to the
/// newest entry already (nothing changed), so the hook can log only real changes.
- (BOOL)recordInfo:(CLMusicItemInfo *)info;

/// Newest recorded item that describes `track`, or nil.
- (nullable CLMusicItemInfo *)infoForTrack:(nullable CLTrack *)track;

/// Like -infoForTrack:, but when nothing matches yet and the registry is live, looks again every
/// 250 ms for up to `timeout` seconds: the provider chain can run a moment before the hook has seen
/// the new content item. `completion` runs exactly once on `queue`, with nil after the timeout or
/// straight away when the registry is not live.
- (void)infoForTrack:(CLTrack *)track
         waitingUpTo:(NSTimeInterval)timeout
               queue:(dispatch_queue_t)queue
          completion:(void (^)(CLMusicItemInfo *_Nullable info))completion;

/// Forgets every item (tests; the cache-clear action does not need it).
- (void)removeAllInfos;

@end

NS_ASSUME_NONNULL_END
