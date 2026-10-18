#import "Lyrics/CLAppleMusicProvider.h"
#import "Lyrics/CLStoreLyricsFetcher.h"
#import "Lyrics/CLTTMLParser.h"
#import "Core/CLMusicItemRegistry.h"
#import "Util/CLLog.h"

NSString *const CLAppleMusicProviderIdentifier = @"apple-music";
static NSString *const kCLAppleMusicBundleIdentifier = @"com.apple.Music";
static const NSTimeInterval kCLAppleMusicItemWait = 1.5;
/// Apple answers in a second or two; a stalled request must not hold LRCLIB up for long.
static const NSTimeInterval kCLAppleMusicFetchTimeout = 8.0;

@implementation CLAppleMusicProvider {
    CLMusicItemRegistry *_registry;
    CLTTMLFetch _fetch;
    NSTimeInterval _itemWaitTime;
    dispatch_queue_t _queue;
}

- (instancetype)init {
    return [self initWithRegistry:[CLMusicItemRegistry sharedRegistry]
                            fetch:^(long long adamID, void (^completion)(NSString *, NSError *)) {
                                [CLStoreLyricsFetcher fetchTTMLForAdamID:adamID
                                                                 timeout:kCLAppleMusicFetchTimeout
                                                              completion:completion];
                            }
                     itemWaitTime:kCLAppleMusicItemWait];
}

- (instancetype)initWithRegistry:(CLMusicItemRegistry *)registry
                           fetch:(CLTTMLFetch)fetch
                    itemWaitTime:(NSTimeInterval)itemWaitTime {
    self = [super init];
    if (!self) return nil;
    _registry = registry;
    _fetch = [fetch copy];
    _itemWaitTime = itemWaitTime;
    _queue = dispatch_queue_create("com.andi.carly.apple-music", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (NSString *)identifier {
    return CLAppleMusicProviderIdentifier;
}

- (void)fetchLyricsForTrack:(CLTrack *)track completion:(CLLyricsCompletion)completion {
    if (!completion) return;
    if (![track.bundleIdentifier isEqualToString:kCLAppleMusicBundleIdentifier] || !_fetch) {
        completion(nil, nil);
        return;
    }
    CLMusicItemRegistry *registry = _registry;
    BOOL live = registry.isLive;
    [registry infoForTrack:track waitingUpTo:_itemWaitTime queue:_queue completion:^(CLMusicItemInfo *info) {
        if (!info) {
            if (!live) {
                completion(nil, nil);
                return;
            }
            completion(nil, [NSError errorWithDomain:@"CLAppleMusicProvider" code:1
                                            userInfo:@{ NSLocalizedDescriptionKey:
                                                            @"Apple Music has not reported this song yet" }]);
            return;
        }
        [self fetchForTrack:track info:info completion:completion];
    }];
}

/// Runs on _queue.
- (void)fetchForTrack:(CLTrack *)track info:(CLMusicItemInfo *)info completion:(CLLyricsCompletion)completion {
    if (info.lyricsAvailability == CLMusicLyricsAvailabilityNone) {
        CLLogDebug(@"[apple-music] \"%@\": Apple Music has no lyrics for it", track.title);
        completion(nil, nil);
        return;
    }
    long long adamID = info.preferredLyricsIdentifier;
    if (adamID <= 0) {
        CLLogDebug(@"[apple-music] \"%@\": not a catalog song", track.title);
        completion(nil, nil);
        return;
    }

    CLLogDebug(@"[apple-music] \"%@\": requesting lyrics for adam id %lld", track.title, adamID);
    dispatch_queue_t queue = _queue;
    _fetch(adamID, ^(NSString *ttml, NSError *error) {
        dispatch_async(queue, ^{
            if (!ttml) {
                completion(nil, error ?: [NSError errorWithDomain:@"CLAppleMusicProvider" code:2
                                                          userInfo:@{ NSLocalizedDescriptionKey: @"no TTML" }]);
                return;
            }
            CLLyrics *lyrics = [CLTTMLParser lyricsFromTTML:ttml source:CLAppleMusicProviderIdentifier];
            if (lyrics.kind == CLLyricsKindNone) lyrics = nil;
            CLLogDebug(@"[apple-music] \"%@\": %lu chars of TTML -> kind=%ld lines=%lu", track.title,
                       (unsigned long)ttml.length, (long)lyrics.kind, (unsigned long)lyrics.lines.count);
            completion(lyrics, nil);
        });
    });
}

@end
