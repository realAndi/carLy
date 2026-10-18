// Apple Music's own time-synced lyrics for catalog songs the Music app is playing: the TTML the
// Music app's lyrics view shows, fetched through MediaPlayer's lyrics operation
// (CLStoreLyricsFetcher) with the signed-in account, parsed by CLTTMLParser. Evidence and the
// DateLyrics comparison: docs/research/apple-music-lyrics.md.
//
//   1. The Music hook has recorded the now-playing item (CLMusicItemRegistry): lyricsAdamID /
//      subscription / store id and Apple's "lyrics available" flag.
//   2. Flag says no, or no id (a local file) -> no match.
//   3. Fetch the TTML -> line-synced lyrics (or the plain transcript Apple marks untimed).
// Anything other than a com.apple.Music track is answered "no match" at once. A failed request is
// an error, never a miss, so the controller does not negative-cache it.
#import "CLLyricsTypes.h"

@class CLMusicItemRegistry;

NS_ASSUME_NONNULL_BEGIN

/// Fetches the TTML for an adam id; must call back exactly once, on any queue.
typedef void (^CLTTMLFetch)(long long adamID, void (^completion)(NSString *_Nullable ttml, NSError *_Nullable error));

extern NSString *const CLAppleMusicProviderIdentifier;   // "apple-music"

@interface CLAppleMusicProvider : NSObject <CLLyricsProvider>

/// The real thing: the shared registry and CLStoreLyricsFetcher.
- (instancetype)init;
/// Test seam.
- (instancetype)initWithRegistry:(CLMusicItemRegistry *)registry
                           fetch:(CLTTMLFetch)fetch
                    itemWaitTime:(NSTimeInterval)itemWaitTime NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly) NSString *identifier;

- (void)fetchLyricsForTrack:(CLTrack *)track completion:(CLLyricsCompletion)completion;

@end

NS_ASSUME_NONNULL_END
