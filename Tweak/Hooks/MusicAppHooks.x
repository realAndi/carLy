// Apple Music app hooks (com.apple.Music only).
//
// Apple Music's CarPlay UI runs in the Music app itself (PLAN.md §2), so carLy loads there
// too; the CarPlayUI hooks in NowPlayingHooks.x handle its Now Playing screen exactly as they do in
// CarPlayTemplateUIHost. What only exists here is the Music app's own now-playing content item,
// which knows what MediaRemote's now-playing dictionary does not export: Apple's lyrics id, the
// "lyrics available" flag and the library persistent id. One hook reads it on every content-item
// change and records it in CLMusicItemRegistry for the Apple Music and embedded lyrics providers.
// This is the hook DateLyrics uses for the same purpose (docs/research/apple-music-lyrics.md).
//
// Same rules as every other hook: %orig first, runtime checks before every private call, nothing
// that can throw, and the master switch turns the body into a plain %orig. The hook runs on
// whichever thread MediaRemote calls it on, so it only reads scalars and strings and hands them
// to the (thread-safe) registry.

#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <string.h>

#import "CLHooks.h"
#import "Core/CLMusicItemRegistry.h"
#import "Util/CLLog.h"
#import "Util/CLRuntime.h"

@interface MRNowPlayingPlayerClient : NSObject
- (void)sendContentItemChanges:(NSArray *)changes;
@end

/// Mirrors the `enabled` preference; read off the main thread, hence atomic.
static atomic_bool gMusicHooksActive = false;
/// The player client that last sent a content item, so the item can be read again when CarPlay
/// connects in the middle of a song (no change would be sent until the next track).
static __weak id gLastPlayerClient;

#pragma mark - Reading MRContentItemMetadata (types from the 17.3 class-dump)

static id CLMetadataObject(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static long long CLMetadataLongLong(id metadata, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!metadata || ![metadata respondsToSelector:selector]) return 0;
    return ((long long (*)(id, SEL))objc_msgSend)(metadata, selector);
}

static BOOL CLMetadataBool(id metadata, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!metadata || ![metadata respondsToSelector:selector]) return NO;
    return ((bool (*)(id, SEL))objc_msgSend)(metadata, selector) ? YES : NO;
}

static double CLMetadataDouble(id metadata, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!metadata || ![metadata respondsToSelector:selector]) return 0;
    return ((double (*)(id, SEL))objc_msgSend)(metadata, selector);
}

static NSString *CLMetadataString(id metadata, NSString *selectorName) {
    id value = CLMetadataObject(metadata, selectorName);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

/// Reads the client's current content item into the registry. Any thread.
static void CLRecordNowPlayingItem(id client) {
    id item = CLMetadataObject(client, @"nowPlayingContentItem");
    id metadata = CLMetadataObject(item, @"metadata");
    if (!metadata) return;

    CLMusicLyricsAvailability availability = CLMusicLyricsAvailabilityUnknown;
    if (CLMetadataBool(metadata, @"hasLyricsAvailable")) {
        availability = CLMetadataBool(metadata, @"lyricsAvailable") ? CLMusicLyricsAvailabilityAvailable
                                                                    : CLMusicLyricsAvailabilityNone;
    }
    long long lyricsIdentifier = CLMetadataBool(metadata, @"hasLyricsAdamID")
        ? CLMetadataLongLong(metadata, @"lyricsAdamID") : 0;

    CLMusicItemInfo *info = [[CLMusicItemInfo alloc]
                initWithTitle:CLMetadataString(metadata, @"title")
                       artist:CLMetadataString(metadata, @"trackArtistName")
                     duration:CLMetadataDouble(metadata, @"duration")
              storeIdentifier:CLMetadataLongLong(metadata, @"iTunesStoreIdentifier")
       subscriptionIdentifier:CLMetadataLongLong(metadata, @"iTunesStoreSubscriptionIdentifier")
             lyricsIdentifier:lyricsIdentifier
           lyricsAvailability:availability
          libraryPersistentID:(unsigned long long)CLMetadataLongLong(metadata, @"legacyUniqueIdentifier")];
    if ([[CLMusicItemRegistry sharedRegistry] recordInfo:info]) {
        CLLogDebug(@"[music] now playing %@", info);
    }
}

#pragma mark - Hooks

%group CLGroupMusicPlayerClient

%hook MRNowPlayingPlayerClient

- (void)sendContentItemChanges:(NSArray *)changes {
    %orig;
    if (!atomic_load(&gMusicHooksActive)) return;
    gLastPlayerClient = self;
    CLSafePerform(@"sendContentItemChanges:", ^{ CLRecordNowPlayingItem(self); });
}

%end

%end  // CLGroupMusicPlayerClient

#pragma mark - Public entry points (CLHooks.h)

void CLMusicAppHooksSetActive(BOOL active) {
    atomic_store(&gMusicHooksActive, active ? true : false);
}

void CLMusicAppRecordNowPlaying(void) {
    if (!atomic_load(&gMusicHooksActive)) return;
    id client = gLastPlayerClient;
    if (!client) return;
    CLSafePerform(@"record now playing", ^{ CLRecordNowPlayingItem(client); });
}

void CLInstallMusicAppHooks(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class clientClass = CLClass(@"MRNowPlayingPlayerClient");
    SEL send = NSSelectorFromString(@"sendContentItemChanges:");
    SEL current = NSSelectorFromString(@"nowPlayingContentItem");
    if (!clientClass || ![clientClass instancesRespondToSelector:send] ||
        ![clientClass instancesRespondToSelector:current]) {
        static BOOL reported = NO;   // install is retried; say it once
        if (!reported) CLLogInfo(@"[music] MRNowPlayingPlayerClient not found (yet); Apple Music and embedded lyrics wait for it");
        reported = YES;
        return;
    }
    // "v@:@" once the frame offsets are dropped: one object argument, as declared above.
    const char *encoding = method_getTypeEncoding(class_getInstanceMethod(clientClass, send));
    char shape[16] = {0};
    size_t out = 0;
    for (const char *c = encoding; c && *c && out + 1 < sizeof(shape); c++) {
        if (*c < '0' || *c > '9') shape[out++] = *c;
    }
    if (strcmp(shape, "v@:@") != 0) {
        CLLogInfo(@"[music] sendContentItemChanges: has signature '%s', expected 'v@:@' — not hooking it",
                  encoding ?: "(unknown)");
        return;
    }
    installed = YES;
    %init(CLGroupMusicPlayerClient);
    [CLMusicItemRegistry sharedRegistry].live = YES;
    CLLogInfo(@"[music] installed MRNowPlayingPlayerClient sendContentItemChanges:");
}
