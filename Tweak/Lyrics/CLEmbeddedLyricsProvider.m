#import "Lyrics/CLEmbeddedLyricsProvider.h"
#import "Lyrics/CLEmbeddedLyricsReader.h"
#import "Lyrics/CLMusicLibrary.h"
#import "Core/CLMusicItemRegistry.h"
#import "Util/CLLog.h"

NSString *const CLEmbeddedLyricsProviderIdentifier = @"embedded";
static NSString *const kCLAppleMusicBundleIdentifier = @"com.apple.Music";
static const NSTimeInterval kCLEmbeddedItemWait = 1.5;

static BOOL CLTitlesMatch(NSString *lhs, NSString *rhs) {
    NSCharacterSet *space = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *left = [lhs stringByTrimmingCharactersInSet:space] ?: @"";
    NSString *right = [rhs stringByTrimmingCharactersInSet:space] ?: @"";
    return left.length > 0 && [left caseInsensitiveCompare:right] == NSOrderedSame;
}

@implementation CLEmbeddedLyricsProvider {
    CLMusicItemRegistry *_registry;
    CLMusicLibraryLookup _lookup;
    CLEmbeddedFileReader _fileReader;
    NSTimeInterval _itemWaitTime;
    dispatch_queue_t _queue;
}

- (instancetype)init {
    return [self initWithRegistry:[CLMusicItemRegistry sharedRegistry]
                           lookup:^CLMusicLibraryItem *(unsigned long long persistentID) {
                               return [CLMusicLibrary itemWithPersistentID:persistentID];
                           }
                       fileReader:^NSData *(NSString *path) {
                           NSError *error = nil;
                           NSData *data = [NSData dataWithContentsOfFile:path
                                                                 options:NSDataReadingMappedIfSafe
                                                                   error:&error];
                           // A missing sidecar is normal; anything else (the sandbox) is worth a line.
                           BOOL missing = [error.domain isEqualToString:NSCocoaErrorDomain] &&
                                          error.code == NSFileReadNoSuchFileError;
                           if (!data && !missing) {
                               CLLogDebug(@"[embedded] cannot read %@: %@", path.lastPathComponent,
                                          error.localizedDescription);
                           }
                           return data;
                       }
                     itemWaitTime:kCLEmbeddedItemWait];
}

- (instancetype)initWithRegistry:(CLMusicItemRegistry *)registry
                          lookup:(CLMusicLibraryLookup)lookup
                      fileReader:(CLEmbeddedFileReader)fileReader
                    itemWaitTime:(NSTimeInterval)itemWaitTime {
    self = [super init];
    if (!self) return nil;
    _registry = registry;
    _lookup = [lookup copy];
    _fileReader = [fileReader copy];
    _itemWaitTime = itemWaitTime;
    _queue = dispatch_queue_create("com.andi.carly.embedded", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (NSString *)identifier {
    return CLEmbeddedLyricsProviderIdentifier;
}

- (void)fetchLyricsForTrack:(CLTrack *)track completion:(CLLyricsCompletion)completion {
    if (!completion) return;
    if (![track.bundleIdentifier isEqualToString:kCLAppleMusicBundleIdentifier]) {
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
            completion(nil, [NSError errorWithDomain:@"CLEmbeddedLyricsProvider" code:1
                                            userInfo:@{ NSLocalizedDescriptionKey:
                                                            @"Apple Music has not reported this song yet" }]);
            return;
        }
        completion([self lyricsForTrack:track info:info], nil);
    }];
}

/// Runs on _queue.
- (CLLyrics *)lyricsForTrack:(CLTrack *)track info:(CLMusicItemInfo *)info {
    unsigned long long persistentID = info.libraryPersistentID;
    if (persistentID == 0 || !_lookup) return nil;

    CLMusicLibraryItem *item = _lookup(persistentID);
    if (!item) return nil;
    if (!CLTitlesMatch(item.title, track.title)) {
        CLLogDebug(@"[embedded] library item %llu is \"%@\", not \"%@\"; ignoring it",
                   persistentID, item.title ?: @"?", track.title);
        return nil;
    }

    NSString *source = CLEmbeddedLyricsProviderIdentifier;
    CLLyrics *plain = nil;

    CLLyrics *fromDatabase = [CLEmbeddedLyricsReader lyricsFromText:item.lyrics source:source];
    if (fromDatabase.kind == CLLyricsKindSynced) {
        CLLogDebug(@"[embedded] \"%@\": synced lyrics in the library's lyrics text", track.title);
        return fromDatabase;
    }
    if (fromDatabase.kind == CLLyricsKindPlain) plain = fromDatabase;

    NSString *path = item.filePath;
    if (path.length && _fileReader) {
        CLLyrics *fromFile = [CLEmbeddedLyricsReader lyricsFromAudioData:_fileReader(path) source:source];
        if (fromFile.kind == CLLyricsKindSynced) {
            CLLogDebug(@"[embedded] \"%@\": synced lyrics in the file's tags", track.title);
            return fromFile;
        }
        if (!plain && fromFile.kind == CLLyricsKindPlain) plain = fromFile;

        NSString *sidecar = [[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"lrc"];
        NSString *text = [CLEmbeddedLyricsReader stringFromTextData:_fileReader(sidecar)];
        CLLyrics *fromSidecar = [CLEmbeddedLyricsReader lyricsFromText:text source:source];
        if (fromSidecar.kind == CLLyricsKindSynced) {
            CLLogDebug(@"[embedded] \"%@\": synced lyrics in %@", track.title, sidecar.lastPathComponent);
            return fromSidecar;
        }
        if (!plain && fromSidecar.kind == CLLyricsKindPlain) plain = fromSidecar;
    }

    CLLogDebug(@"[embedded] \"%@\": %@", track.title, plain ? @"plain lyrics only" : @"no embedded lyrics");
    return plain;
}

@end
