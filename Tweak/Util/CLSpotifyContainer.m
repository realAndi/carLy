#import "CLSpotifyContainer.h"
#import "CLLog.h"

#import <dirent.h>
#import <errno.h>
#import <string.h>
#import <unistd.h>

static NSString *const kCLSpotifyBundleIdentifier = @"com.spotify.client";
static NSString *const kCLContainersRoot = @"/var/mobile/Containers/Data/Application";
static NSString *const kCLContainerMetadataName = @".com.apple.mobile_container_manager.metadata.plist";
static NSString *const kCLContainerMetadataKey = @"MCMMetadataIdentifier";

static NSString *const kCLCacheDatabaseRelativePath = @"Library/Caches/com.spotify.client/nsurlcache/Cache.db";
static NSString *const kCLFSCachedDataRelativePath = @"Library/Caches/com.spotify.client/nsurlcache/fsCachedData";
static NSString *const kCLOfflineLyricsRelativePath = @"Library/Application Support/lyrics_offline.sqlite3";

/// Reads one container's metadata plist (binary or XML) and returns its bundle identifier.
static NSString *CLContainerIdentifierAtPath(NSString *containerPath) {
    if (containerPath.length == 0) return nil;
    NSString *plistPath = [containerPath stringByAppendingPathComponent:kCLContainerMetadataName];
    NSURL *url = [NSURL fileURLWithPath:plistPath isDirectory:NO];
    if (!url) return nil;
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfURL:url error:NULL];
    id identifier = metadata[kCLContainerMetadataKey];
    if (![identifier isKindOfClass:[NSString class]]) return nil;
    return (NSString *)identifier;
}

/// Walks the data-container root once. Returns nil (and explains why, once) on failure.
static NSString *CLScanForSpotifyContainer(void) {
    DIR *directory = opendir(kCLContainersRoot.fileSystemRepresentation);
    if (!directory) {
        int failure = errno;
        CLLogInfo(@"[spotify-cache] cannot list %@: %s (errno %d) — Spotify's lyrics cache is unavailable",
                  kCLContainersRoot, strerror(failure), failure);
        return nil;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *match = nil;
    NSUInteger inspected = 0;
    NSUInteger identified = 0;
    struct dirent *entry = NULL;

    while (!match && (entry = readdir(directory)) != NULL) {
        if (entry->d_name[0] == '\0' || entry->d_name[0] == '.') continue;
        if (entry->d_type != DT_DIR && entry->d_type != DT_UNKNOWN && entry->d_type != DT_LNK) continue;

        @autoreleasepool {
            NSString *name = [fileManager stringWithFileSystemRepresentation:entry->d_name
                                                                      length:strnlen(entry->d_name, sizeof(entry->d_name))];
            if (name.length > 0) {
                inspected += 1;
                NSString *containerPath = [kCLContainersRoot stringByAppendingPathComponent:name];
                NSString *identifier = CLContainerIdentifierAtPath(containerPath);
                if (identifier.length > 0) {
                    identified += 1;
                    if ([identifier isEqualToString:kCLSpotifyBundleIdentifier]) match = containerPath;
                }
            }
        }
    }
    closedir(directory);

    if (match) {
        CLLogDebug(@"[spotify-cache] Spotify container: %@", match);
        return match;
    }
    if (inspected > 0 && identified == 0) {
        // The directory listed but not one metadata plist could be read: a sandbox denial rather
        // than a missing app. Worth an info line — it is the signal Phase 0 is looking for.
        CLLogInfo(@"[spotify-cache] listed %lu containers but could read no metadata plist (sandboxed?) — Spotify's lyrics cache is unavailable",
                  (unsigned long)inspected);
    } else {
        CLLogInfo(@"[spotify-cache] no container for %@ among %lu candidates", kCLSpotifyBundleIdentifier, (unsigned long)inspected);
    }
    return nil;
}

@implementation CLSpotifyContainer

+ (NSString *)dataContainerPath {
    static NSString *sContainerPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sContainerPath = CLScanForSpotifyContainer();
    });
    return sContainerPath;
}

+ (NSString *)cacheDatabasePath {
    NSString *container = [self dataContainerPath];
    return container.length > 0 ? [container stringByAppendingPathComponent:kCLCacheDatabaseRelativePath] : nil;
}

+ (NSString *)fsCachedDataDirectory {
    NSString *container = [self dataContainerPath];
    return container.length > 0 ? [container stringByAppendingPathComponent:kCLFSCachedDataRelativePath] : nil;
}

+ (NSString *)offlineLyricsDatabasePath {
    NSString *container = [self dataContainerPath];
    return container.length > 0 ? [container stringByAppendingPathComponent:kCLOfflineLyricsRelativePath] : nil;
}

+ (BOOL)isPathReadable:(NSString *)path {
    if (path.length == 0) return NO;
    return access(path.fileSystemRepresentation, R_OK) == 0;
}

@end
