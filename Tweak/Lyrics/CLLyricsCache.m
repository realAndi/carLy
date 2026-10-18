// CLLyricsCache.m — memory + disk cache for resolved lyrics (contract in CLLyricsCache.h).
//
// Layout: <NSCachesDirectory>/carLy/lyrics/<cacheKey>.json, one small JSON document per
// track (the dictionaryRepresentation of CLLyrics). The key is the SHA-1 from CLTrack.cacheKey,
// so file names are always 40 hex characters — validated again here before any path is built.
//
// Threading
//   * The memory map (bounded LRU, 100 entries) is guarded by an os_unfair_lock; every public
//     method is safe to call from any thread.
//   * Writes and deletes go through a serial queue and use atomic file writes, so a reader can
//     never see a half-written document. Reads do NOT go through that queue: lyricsForTrack: is
//     documented as synchronous and must stay fast on the main thread, and atomic writes make an
//     unsynchronised read safe.
//   * clear and diskEntryCount are maintenance calls; they hop onto the disk queue synchronously
//     so the caller can report an accurate result immediately, which makes them unusable from
//     the CarPlay host's main thread. The tweak calls -clearWithCompletion: instead, which empties
//     memory inline and does the walk and the unlinks on the disk queue.
//
// Negative caching: entries of kind None expire after negativeTTL (default 24 h) measured from
// fetchedAt, which keeps a track that had no lyrics yesterday from being re-fetched on every
// song change while still letting LRCLIB catch up within a day. Positive entries never expire;
// clear is the way to drop them.
#import "CLLyricsCache.h"
#import "Util/CLLog.h"
#import <os/lock.h>
#import <stdlib.h>

static const NSUInteger kCLMemoryCapacity = 100;
static const NSTimeInterval kCLDefaultNegativeTTL = 24 * 60 * 60;

/// Where the per-track JSON documents live: <NSCachesDirectory>/carLy/lyrics, unless
/// CARLY_CACHE_DIR names an absolute directory to use as the root instead.
///
/// The override exists for tests/: the test tool runs unsandboxed, shares the real caches
/// directory with anything else running as `mobile`, and wants a scratch root it can fill and
/// delete in isolation. Nothing sets the variable inside CarPlayTemplateUIHost, so the shipped
/// tweak always takes the default branch. Read once, at init.
static NSString *CLCacheDirectory(void) {
    const char *override = getenv("CARLY_CACHE_DIR");
    if (override != NULL && override[0] == '/') {
        NSString *root = [[NSString stringWithUTF8String:override]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        // "/" on its own is not a cache root, and neither is a path we cannot decode.
        if (root.length > 1) return [root stringByAppendingPathComponent:@"lyrics"];
    }

    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                          NSUserDomainMask, YES).firstObject;
    if (caches.length == 0) caches = NSTemporaryDirectory();
    return [[caches stringByAppendingPathComponent:@"carLy"]
            stringByAppendingPathComponent:@"lyrics"];
}

/// Only accept the hex digest shape we generate; never build a path out of anything else.
static BOOL CLIsSafeCacheKey(NSString *key) {
    if (key.length == 0 || key.length > 64) return NO;
    for (NSUInteger i = 0; i < key.length; i++) {
        unichar c = [key characterAtIndex:i];
        BOOL hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        if (!hex) return NO;
    }
    return YES;
}

@implementation CLLyricsCache {
    NSMutableDictionary<NSString *, CLLyrics *> *_memory;
    NSMutableArray<NSString *> *_order;        // least recently used first
    os_unfair_lock _lock;
    dispatch_queue_t _diskQueue;
    NSString *_directory;
}

+ (instancetype)sharedCache {
    static CLLyricsCache *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[CLLyricsCache alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _memory = [NSMutableDictionary dictionaryWithCapacity:kCLMemoryCapacity];
        _order = [NSMutableArray arrayWithCapacity:kCLMemoryCapacity];
        _lock = OS_UNFAIR_LOCK_INIT;
        _negativeTTL = kCLDefaultNegativeTTL;
        _diskQueue = dispatch_queue_create("com.andi.carly.cache",
                                           DISPATCH_QUEUE_SERIAL);

        _directory = CLCacheDirectory();
    }
    return self;
}

#pragma mark - Paths

- (NSString *)pathForKey:(NSString *)key {
    if (!CLIsSafeCacheKey(key)) return nil;
    return [_directory stringByAppendingPathComponent:
            [key stringByAppendingPathExtension:@"json"]];
}

- (NSString *)keyForTrack:(CLTrack *)track {
    if (![track isKindOfClass:[CLTrack class]]) return nil;
    NSString *key = track.cacheKey;
    return CLIsSafeCacheKey(key) ? key : nil;
}

/// Called on the disk queue only.
- (BOOL)ensureDirectory {
    NSFileManager *manager = [NSFileManager defaultManager];
    if ([manager fileExistsAtPath:_directory]) return YES;
    NSError *error = nil;
    BOOL created = [manager createDirectoryAtPath:_directory
                      withIntermediateDirectories:YES
                                       attributes:nil
                                            error:&error];
    if (!created) {
        CLLogError(@"[cache] cannot create %@: %@", _directory, error.localizedDescription);
    }
    return created;
}

#pragma mark - Expiry

- (BOOL)isExpired:(CLLyrics *)lyrics {
    if (lyrics.kind != CLLyricsKindNone) return NO;      // only negatives expire
    NSTimeInterval ttl = self.negativeTTL;
    if (ttl <= 0) return YES;                            // TTL 0 disables negative caching
    NSTimeInterval age = [NSDate date].timeIntervalSince1970 - lyrics.fetchedAt;
    if (age < 0) return NO;                              // clock moved backwards: keep it
    return age > ttl;
}

#pragma mark - Memory

- (CLLyrics *)memoryLyricsForKey:(NSString *)key {
    os_unfair_lock_lock(&_lock);
    CLLyrics *lyrics = _memory[key];
    if (lyrics) {
        [_order removeObject:key];
        [_order addObject:key];
    }
    os_unfair_lock_unlock(&_lock);
    return lyrics;
}

- (void)setMemoryLyrics:(CLLyrics *)lyrics forKey:(NSString *)key {
    os_unfair_lock_lock(&_lock);
    _memory[key] = lyrics;
    [_order removeObject:key];
    [_order addObject:key];
    while (_order.count > kCLMemoryCapacity) {
        NSString *oldest = _order.firstObject;
        if (!oldest) break;
        [_order removeObjectAtIndex:0];
        [_memory removeObjectForKey:oldest];
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)removeMemoryKey:(NSString *)key {
    os_unfair_lock_lock(&_lock);
    [_memory removeObjectForKey:key];
    [_order removeObject:key];
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - CLLyricsCache

- (CLLyrics *)lyricsForTrack:(CLTrack *)track {
    NSString *key = [self keyForTrack:track];
    if (!key) return nil;

    CLLyrics *cached = [self memoryLyricsForKey:key];
    if (cached) {
        if (![self isExpired:cached]) return cached;
        [self removeMemoryKey:key];
        [self removeDiskEntryForKey:key];
        return nil;
    }

    NSString *path = [self pathForKey:key];
    if (!path) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:NULL];
    if (data.length == 0) return nil;

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    CLLyrics *lyrics = [CLLyrics lyricsWithDictionary:json];
    if (!lyrics) {
        CLLogDebug(@"[cache] dropping unreadable entry %@", key);
        [self removeDiskEntryForKey:key];
        return nil;
    }
    if ([self isExpired:lyrics]) {
        [self removeDiskEntryForKey:key];
        return nil;
    }

    [self setMemoryLyrics:lyrics forKey:key];
    return lyrics;
}

- (void)storeLyrics:(CLLyrics *)lyrics forTrack:(CLTrack *)track {
    if (![lyrics isKindOfClass:[CLLyrics class]]) return;
    NSString *key = [self keyForTrack:track];
    if (!key) return;

    if (!(lyrics.fetchedAt > 0)) lyrics.fetchedAt = [NSDate date].timeIntervalSince1970;
    [self setMemoryLyrics:lyrics forKey:key];

    NSString *path = [self pathForKey:key];
    if (!path) return;
    NSDictionary *representation = [lyrics dictionaryRepresentation];
    if (![NSJSONSerialization isValidJSONObject:representation]) {
        CLLogError(@"[cache] refusing to write a non-JSON representation for %@", key);
        return;
    }

    dispatch_async(_diskQueue, ^{
        if (![self ensureDirectory]) return;
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:representation options:0 error:&error];
        if (!data) {
            CLLogError(@"[cache] encode failed for %@: %@", key, error.localizedDescription);
            return;
        }
        if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
            CLLogError(@"[cache] write failed for %@: %@", key, error.localizedDescription);
            return;
        }
        CLLogDebug(@"[cache] stored %@ (%lu bytes)", key, (unsigned long)data.length);
    });
}

- (void)removeDiskEntryForKey:(NSString *)key {
    NSString *path = [self pathForKey:key];
    if (!path) return;
    dispatch_async(_diskQueue, ^{
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    });
}

/// The disk half of a clear. Runs on _diskQueue; returns how many files it unlinked.
- (NSUInteger)clearDiskEntries {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray<NSString *> *names = [manager contentsOfDirectoryAtPath:_directory error:NULL];
    NSUInteger removed = 0;
    for (NSString *name in names) {
        // Only our own entries, and only the ones -diskEntryCount would have counted: the
        // directory is ours by default, but CARLY_CACHE_DIR can point it elsewhere and a
        // cache clear must never turn into "delete everything in that directory".
        if ([name.pathExtension caseInsensitiveCompare:@"json"] != NSOrderedSame) continue;
        if (!CLIsSafeCacheKey(name.stringByDeletingPathExtension)) continue;
        NSString *path = [_directory stringByAppendingPathComponent:name];
        if ([manager removeItemAtPath:path error:NULL]) removed++;
    }
    CLLogInfo(@"[cache] cleared %lu entries", (unsigned long)removed);
    return removed;
}

- (void)clearMemory {
    os_unfair_lock_lock(&_lock);
    [_memory removeAllObjects];
    [_order removeAllObjects];
    os_unfair_lock_unlock(&_lock);
}

- (void)clear {
    [self clearMemory];
    dispatch_sync(_diskQueue, ^{ (void)[self clearDiskEntries]; });
}

- (void)clearWithCompletion:(void (^)(NSUInteger))completion {
    [self clearMemory];
    void (^copied)(NSUInteger) = completion ? [completion copy] : nil;
    // Never dispatch_sync from here: the caller is the CarPlay host's main thread (the Clear
    // Cache action arrives on it), _diskQueue is serial, and the walk plus one unlink per cached
    // track would queue behind any in-flight write and stall the Now Playing screen.
    dispatch_async(_diskQueue, ^{
        NSUInteger removed = [self clearDiskEntries];
        if (!copied) return;
        dispatch_async(dispatch_get_main_queue(), ^{ copied(removed); });
    });
}

- (NSUInteger)diskEntryCount {
    __block NSUInteger count = 0;
    dispatch_sync(_diskQueue, ^{
        NSArray<NSString *> *names =
            [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self->_directory error:NULL];
        for (NSString *name in names) {
            if ([name.pathExtension caseInsensitiveCompare:@"json"] == NSOrderedSame) count++;
        }
    });
    return count;
}

@end
