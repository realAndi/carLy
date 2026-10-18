#import "Core/CLMusicItemRegistry.h"
#import <os/lock.h>

static const NSUInteger kCLMusicItemRegistryCapacity = 8;
static const NSTimeInterval kCLMusicItemRegistryPollInterval = 0.25;

@implementation CLMusicItemRegistry {
    os_unfair_lock _lock;
    NSMutableArray<CLMusicItemInfo *> *_infos;   // newest first
}

+ (instancetype)sharedRegistry {
    static CLMusicItemRegistry *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _lock = OS_UNFAIR_LOCK_INIT;
    _infos = [NSMutableArray arrayWithCapacity:kCLMusicItemRegistryCapacity];
    return self;
}

- (BOOL)recordInfo:(CLMusicItemInfo *)info {
    if (![info isKindOfClass:[CLMusicItemInfo class]] || !info.title) return NO;
    os_unfair_lock_lock(&_lock);
    BOOL unchanged = [_infos.firstObject isEquivalentToInfo:info];
    if (!unchanged) {
        NSIndexSet *same = [_infos indexesOfObjectsPassingTest:^BOOL(CLMusicItemInfo *old, NSUInteger idx, BOOL *stop) {
            return [old.title caseInsensitiveCompare:info.title] == NSOrderedSame &&
                   [(old.artist ?: @"") caseInsensitiveCompare:(info.artist ?: @"")] == NSOrderedSame;
        }];
        [_infos removeObjectsAtIndexes:same];
        [_infos insertObject:info atIndex:0];
        while (_infos.count > kCLMusicItemRegistryCapacity) [_infos removeLastObject];
    }
    os_unfair_lock_unlock(&_lock);
    return !unchanged;
}

- (CLMusicItemInfo *)infoForTrack:(CLTrack *)track {
    if (!track) return nil;
    CLMusicItemInfo *match = nil;
    os_unfair_lock_lock(&_lock);
    for (CLMusicItemInfo *info in _infos) {
        if ([info describesTrack:track]) {
            match = info;
            break;
        }
    }
    os_unfair_lock_unlock(&_lock);
    return match;
}

- (void)infoForTrack:(CLTrack *)track
         waitingUpTo:(NSTimeInterval)timeout
               queue:(dispatch_queue_t)queue
          completion:(void (^)(CLMusicItemInfo *))completion {
    if (!completion) return;
    dispatch_queue_t target = queue ?: dispatch_get_main_queue();
    CLMusicItemInfo *now = [self infoForTrack:track];
    if (now || !self.isLive || !(timeout > 0)) {
        dispatch_async(target, ^{ completion(now); });
        return;
    }
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    [self pollForTrack:track deadline:deadline queue:target completion:completion];
}

- (void)pollForTrack:(CLTrack *)track
            deadline:(CFAbsoluteTime)deadline
               queue:(dispatch_queue_t)queue
          completion:(void (^)(CLMusicItemInfo *))completion {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCLMusicItemRegistryPollInterval * NSEC_PER_SEC)),
                   queue, ^{
        CLMusicItemRegistry *strongSelf = weakSelf;
        CLMusicItemInfo *info = [strongSelf infoForTrack:track];
        if (info || !strongSelf || CFAbsoluteTimeGetCurrent() >= deadline) {
            completion(info);
            return;
        }
        [strongSelf pollForTrack:track deadline:deadline queue:queue completion:completion];
    });
}

- (void)removeAllInfos {
    os_unfair_lock_lock(&_lock);
    [_infos removeAllObjects];
    os_unfair_lock_unlock(&_lock);
}

@end
