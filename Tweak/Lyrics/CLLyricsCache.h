// Contract: implemented by the lyrics-core slice in CLLyricsCache.m. Memory + disk JSON cache.
//
// Storage root: <NSCachesDirectory>/carLy/lyrics, or <CARLY_CACHE_DIR>/lyrics when that
// environment variable holds an absolute path. The override is a test hook (tests/ runs in this
// user's real caches directory otherwise); nothing sets it in CarPlayTemplateUIHost.
#import "CLLyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface CLLyricsCache : NSObject
+ (instancetype)sharedCache;
/// Negative results (kind == none) expire after this many seconds. Default 24 h.
@property (nonatomic) NSTimeInterval negativeTTL;
/// Synchronous and fast: memory first, then one small disk read. Returns nil on miss or expired negative.
- (nullable CLLyrics *)lyricsForTrack:(CLTrack *)track;
/// Stores in memory immediately and on disk asynchronously (<NSCachesDirectory>/carLy/lyrics/<cacheKey>.json).
- (void)storeLyrics:(CLLyrics *)lyrics forTrack:(CLTrack *)track;
/// Empties the memory cache, then walks the directory and unlinks every entry — **synchronously**,
/// on the calling thread. Fine from the tests tool; never call it from the CarPlay host's main
/// thread (CLAUDE.md: never block the main thread on disk). Use -clearWithCompletion: there.
- (void)clear;
/// Asynchronous clear. The memory cache is empty by the time this returns; the directory walk and
/// the unlinks run on the cache's own serial queue, and `completion` (optional) is called on the
/// main queue afterwards with the number of files removed.
- (void)clearWithCompletion:(nullable void (^)(NSUInteger removedCount))completion;
/// Synchronous, like -clear: a maintenance call for the tests tool, not for the playback path.
- (NSUInteger)diskEntryCount;
@end

NS_ASSUME_NONNULL_END
