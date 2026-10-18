// Locates Spotify's data container so we can read the lyrics it already cached on disk.
// Nothing here writes to, or locks, anything Spotify owns: these are path lookups only.
//
// The lookup walks /var/mobile/Containers/Data/Application/*/ and matches
// MCMMetadataIdentifier == com.spotify.client in each container's metadata plist. Whether the
// CarPlayTemplateUIHost sandbox permits that walk is a Phase 0 question (PLAN.md §5); when it is
// denied every accessor returns nil and the provider degrades to "no lyrics".
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLSpotifyContainer : NSObject

/// Spotify's data container, e.g. /var/mobile/Containers/Data/Application/<UUID>.
/// Resolved at most once per process (success *and* failure are remembered) and safe to call from
/// any thread. Returns nil when the container cannot be found or the directory cannot be read;
/// the failure is logged once at info level together with its errno.
+ (nullable NSString *)dataContainerPath;

/// <container>/Library/Caches/com.spotify.client/nsurlcache/Cache.db — the NSURLCache SQLite file
/// that holds `color-lyrics` responses. nil when the container is unknown.
+ (nullable NSString *)cacheDatabasePath;

/// <container>/Library/Caches/com.spotify.client/nsurlcache/fsCachedData — bodies too large to be
/// stored inline live here, named by the UUID kept in cfurl_cache_receiver_data.receiver_data.
+ (nullable NSString *)fsCachedDataDirectory;

/// <container>/Library/Application Support/lyrics_offline.sqlite3 — lyrics for downloaded tracks.
+ (nullable NSString *)offlineLyricsDatabasePath;

/// YES when the path exists and is readable by this process (a cheap access(2) check).
+ (BOOL)isPathReadable:(nullable NSString *)path;

@end

NS_ASSUME_NONNULL_END
