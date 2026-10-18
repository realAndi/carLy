#import "CLSpotifyCacheProvider.h"

#import "CLSpotifyColorLyricsDecoder.h"
#import "Util/CLLog.h"
#import "Util/CLSpotifyContainer.h"

#import <sqlite3.h>
#import <sys/stat.h>

static NSString *const kCLSpotifyProviderIdentifier = @"spotify-cache";
static NSString *const kCLCacheDatabaseLocalName = @"Cache.db";
static NSString *const kCLOfflineDatabaseLocalName = @"lyrics_offline.sqlite3";

/// Runs against an open database. Reports the last SQLite result code through `status` so the
/// caller can decide whether a retry is worth it.
typedef NSData *_Nullable (^CLSpotifyDatabaseQuery)(sqlite3 *database, int *status);

#pragma mark - Track id

/// Spotify track ids are 22 base-62 characters. Rejecting everything else keeps LIKE wildcards
/// ('%' and '_') and path separators out of the pattern we bind below.
static NSString *CLSanitizedSpotifyTrackID(CLTrack *track) {
    if (!track || ![track respondsToSelector:@selector(spotifyTrackID)]) return nil;
    NSString *trackID = track.spotifyTrackID;
    if (![trackID isKindOfClass:[NSString class]]) return nil;
    if (trackID.length == 0 || trackID.length > 64) return nil;

    static NSCharacterSet *disallowed = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"];
        disallowed = [allowed invertedSet];
    });
    if ([trackID rangeOfCharacterFromSet:disallowed].location != NSNotFound) return nil;
    return trackID;
}

#pragma mark - File stamps

static NSString *CLFileStamp(NSString *path) {
    struct stat info;
    if (path.length == 0) return @"-";
    if (lstat(path.fileSystemRepresentation, &info) != 0) return @"-";
    return [NSString stringWithFormat:@"%lld.%09ld:%lld",
            (long long)info.st_mtimespec.tv_sec, (long)info.st_mtimespec.tv_nsec, (long long)info.st_size];
}

/// Size + mtime of the database and of its WAL sidecars. Unchanged signature → the copy we
/// already made is still current.
static NSString *CLDatabaseSignature(NSString *path) {
    return [NSString stringWithFormat:@"%@|%@|%@",
            CLFileStamp(path),
            CLFileStamp([path stringByAppendingString:@"-wal"]),
            CLFileStamp([path stringByAppendingString:@"-shm"])];
}

/// SQLite can refuse a read-only open of a WAL database when it would have to rebuild the shared
/// -shm index. Our copy is private, so one retry with write access is safe and fixes exactly that.
static BOOL CLDeservesWritableRetry(int status) {
    switch (status) {
        case SQLITE_CANTOPEN:
        case SQLITE_READONLY:
        case SQLITE_BUSY:
        case SQLITE_LOCKED:
        case SQLITE_IOERR:
        case SQLITE_PROTOCOL:
            return YES;
        default:
            return NO;
    }
}

#pragma mark -

/// One queue for the whole class, not one per instance: every provider shares the same working
/// copies under <NSCachesDirectory>/carLy/spotify, so two instances (the chain's and, say, the
/// test tool's) must never copy and read them at the same time. Everything below marked "on the
/// work queue" runs here, which is also what makes CLSpotifyCacheSignatures() safe to mutate
/// without a lock.
static dispatch_queue_t CLSpotifyCacheQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_attr_t attributes =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        queue = dispatch_queue_create("com.andi.carly.spotify-cache", attributes);
    });
    return queue;
}

/// source database path → size/mtime signature of the copy we hold. Work queue only.
static NSMutableDictionary<NSString *, NSString *> *CLSpotifyCacheSignatures(void) {
    static NSMutableDictionary *signatures;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ signatures = [NSMutableDictionary dictionary]; });
    return signatures;
}

@implementation CLSpotifyCacheProvider

- (NSString *)identifier {
    return kCLSpotifyProviderIdentifier;
}

#pragma mark - CLLyricsProvider

- (void)fetchLyricsForTrack:(CLTrack *)track completion:(CLLyricsCompletion)completion {
    if (!completion) return;
    NSString *trackID = CLSanitizedSpotifyTrackID(track);
    if (trackID.length == 0) {
        completion(nil, nil);   // not a Spotify track: no work, no disk, no queue hop
        return;
    }
    dispatch_async(CLSpotifyCacheQueue(), ^{
        CLLyrics *lyrics = nil;
        @autoreleasepool {
            lyrics = [self lyricsForTrackID:trackID];
        }
        completion(lyrics, nil);
    });
}

#pragma mark - Lookup (work queue only)

- (CLLyrics *)lyricsForTrackID:(NSString *)trackID {
    NSData *body = [self cachedResponseBodyForTrackID:trackID];
    CLLyrics *lyrics = [[self class] lyricsFromResponseData:body source:kCLSpotifyProviderIdentifier];
    if (!lyrics) {
        NSData *offline = [self offlineEntityDataForTrackID:trackID];
        lyrics = [[self class] lyricsFromResponseData:offline source:kCLSpotifyProviderIdentifier];
    }
    if (lyrics) {
        CLLogDebug(@"[spotify-cache] hit for %@: kind %ld, %lu line(s)",
                   trackID, (long)lyrics.kind, (unsigned long)lyrics.lines.count);
    } else {
        CLLogDebug(@"[spotify-cache] miss for %@", trackID);
    }
    return lyrics;
}

- (NSData *)cachedResponseBodyForTrackID:(NSString *)trackID {
    NSString *source = [CLSpotifyContainer cacheDatabasePath];
    if (source.length == 0) return nil;
    NSString *fragment = [@"/color-lyrics/v2/track/" stringByAppendingString:trackID];
    NSString *pattern = [NSString stringWithFormat:@"%%%@%%", fragment];
    return [self runQuery:^NSData *(sqlite3 *database, int *status) {
        return [self responseBodyMatchingPattern:pattern fragment:fragment inDatabase:database status:status];
    } onCopyOfDatabaseAtPath:source localName:kCLCacheDatabaseLocalName];
}

/// `fragment` is the case-sensitive "/color-lyrics/v2/track/<id>" the row has to contain. SQLite's
/// LIKE folds ASCII case, and Spotify ids are base62, so two ids can differ by case alone; the
/// row is re-checked here rather than risk putting another song's words on the screen.
- (NSData *)responseBodyMatchingPattern:(NSString *)pattern
                               fragment:(NSString *)fragment
                             inDatabase:(sqlite3 *)database
                                 status:(int *)status {
    static const char *const kSQL =
        "SELECT d.receiver_data, d.isDataOnFS, r.request_key "
        "FROM cfurl_cache_response r "
        "JOIN cfurl_cache_receiver_data d ON r.entry_ID = d.entry_ID "
        "WHERE r.request_key LIKE ? "
        "ORDER BY r.time_stamp DESC LIMIT 1";

    sqlite3_stmt *statement = NULL;
    int result = sqlite3_prepare_v2(database, kSQL, -1, &statement, NULL);
    if (result != SQLITE_OK) {
        CLLogDebug(@"[spotify-cache] prepare(cache) failed: %d %s", result, sqlite3_errmsg(database));
        if (status) *status = result;
        sqlite3_finalize(statement);
        return nil;
    }

    NSData *body = nil;
    result = sqlite3_bind_text(statement, 1, pattern.UTF8String, -1, SQLITE_TRANSIENT);
    if (result == SQLITE_OK) {
        result = sqlite3_step(statement);
        if (result == SQLITE_ROW) {
            const unsigned char *key = sqlite3_column_text(statement, 2);
            NSString *requestKey = key ? @((const char *)key) : nil;
            if ([requestKey rangeOfString:fragment options:NSLiteralSearch].location == NSNotFound) {
                CLLogDebug(@"[spotify-cache] ignoring a row that only matches case-insensitively");
            } else {
                int storedOnFileSystem = sqlite3_column_int(statement, 1);
                const void *bytes = sqlite3_column_blob(statement, 0);
                int length = sqlite3_column_bytes(statement, 0);
                if (bytes != NULL && length > 0) {
                    NSData *stored = [NSData dataWithBytes:bytes length:(NSUInteger)length];
                    body = storedOnFileSystem != 0 ? [self fileBackedBodyForReceiverData:stored] : stored;
                }
            }
        } else if (result != SQLITE_DONE) {
            CLLogDebug(@"[spotify-cache] step(cache) failed: %d %s", result, sqlite3_errmsg(database));
        }
    } else {
        CLLogDebug(@"[spotify-cache] bind(cache) failed: %d %s", result, sqlite3_errmsg(database));
    }

    if (status) *status = result;
    sqlite3_finalize(statement);
    return body;
}

/// With isDataOnFS = 1 the blob is the file name of the body inside nsurlcache/fsCachedData.
- (NSData *)fileBackedBodyForReceiverData:(NSData *)stored {
    NSString *directory = [CLSpotifyContainer fsCachedDataDirectory];
    if (directory.length == 0 || stored.length == 0) return nil;

    const char *raw = (const char *)stored.bytes;
    if (!raw) return nil;
    NSUInteger length = 0;
    while (length < stored.length && raw[length] != '\0') length += 1;

    NSString *name = [[NSString alloc] initWithBytes:raw length:length encoding:NSUTF8StringEncoding];
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length == 0 || name.length > 255) return nil;
    // Never let a cache row send us outside the directory it names.
    if ([name rangeOfString:@"/"].location != NSNotFound || [name hasPrefix:@"."]) return nil;

    NSError *error = nil;
    NSString *path = [directory stringByAppendingPathComponent:name];
    NSData *body = [NSData dataWithContentsOfFile:path options:0 error:&error];
    if (!body) CLLogDebug(@"[spotify-cache] fsCachedData body unreadable: %@", error.localizedDescription);
    return body;
}

- (NSData *)offlineEntityDataForTrackID:(NSString *)trackID {
    NSString *source = [CLSpotifyContainer offlineLyricsDatabasePath];
    if (source.length == 0) return nil;
    NSString *uri = [@"spotify:track:" stringByAppendingString:trackID];
    return [self runQuery:^NSData *(sqlite3 *database, int *status) {
        return [self entityDataForTrackURI:uri inDatabase:database status:status];
    } onCopyOfDatabaseAtPath:source localName:kCLOfflineDatabaseLocalName];
}

- (NSData *)entityDataForTrackURI:(NSString *)uri inDatabase:(sqlite3 *)database status:(int *)status {
    static const char *const kSQL = "SELECT entity_data FROM lyrics_entities WHERE track_uri = ? LIMIT 1";

    sqlite3_stmt *statement = NULL;
    int result = sqlite3_prepare_v2(database, kSQL, -1, &statement, NULL);
    if (result != SQLITE_OK) {
        // Expected when the table does not exist yet (nothing downloaded for offline playback).
        CLLogDebug(@"[spotify-cache] prepare(offline) failed: %d %s", result, sqlite3_errmsg(database));
        if (status) *status = result;
        sqlite3_finalize(statement);
        return nil;
    }

    NSData *entity = nil;
    result = sqlite3_bind_text(statement, 1, uri.UTF8String, -1, SQLITE_TRANSIENT);
    if (result == SQLITE_OK) {
        result = sqlite3_step(statement);
        if (result == SQLITE_ROW) {
            const void *bytes = sqlite3_column_blob(statement, 0);
            int length = sqlite3_column_bytes(statement, 0);
            if (bytes != NULL && length > 0) entity = [NSData dataWithBytes:bytes length:(NSUInteger)length];
        } else if (result != SQLITE_DONE) {
            CLLogDebug(@"[spotify-cache] step(offline) failed: %d %s", result, sqlite3_errmsg(database));
        }
    } else {
        CLLogDebug(@"[spotify-cache] bind(offline) failed: %d %s", result, sqlite3_errmsg(database));
    }

    if (status) *status = result;
    sqlite3_finalize(statement);
    return entity;
}

#pragma mark - SQLite plumbing (work queue only)

- (NSData *)runQuery:(CLSpotifyDatabaseQuery)query
    onCopyOfDatabaseAtPath:(NSString *)source
                 localName:(NSString *)localName {
    if (!query) return nil;
    NSString *copyPath = [self workingCopyOfDatabaseAtPath:source localName:localName];
    if (copyPath.length == 0) return nil;

    int status = SQLITE_OK;
    NSData *result = [self runQuery:query onDatabaseAtPath:copyPath readOnly:YES status:&status];
    if (!result && CLDeservesWritableRetry(status)) {
        status = SQLITE_OK;
        result = [self runQuery:query onDatabaseAtPath:copyPath readOnly:NO status:&status];
    }
    return result;
}

- (NSData *)runQuery:(CLSpotifyDatabaseQuery)query
    onDatabaseAtPath:(NSString *)path
            readOnly:(BOOL)readOnly
              status:(int *)outStatus {
    sqlite3 *database = NULL;
    int flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE;
    int result = sqlite3_open_v2(path.fileSystemRepresentation, &database, flags, NULL);
    if (result != SQLITE_OK) {
        CLLogDebug(@"[spotify-cache] open(%@, %@) failed: %d %s", path.lastPathComponent,
                   readOnly ? @"ro" : @"rw", result, database ? sqlite3_errmsg(database) : "");
        if (outStatus) *outStatus = result;
        if (database) sqlite3_close_v2(database);   // open_v2 may hand back a handle even on error
        return nil;
    }

    sqlite3_busy_timeout(database, 250);
    int status = SQLITE_OK;
    NSData *data = query(database, &status);
    if (outStatus) *outStatus = status;
    sqlite3_close_v2(database);
    return data;
}

#pragma mark - Working copies (work queue only)

+ (NSString *)workingDirectory {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (caches.length == 0) return nil;
    return [[caches stringByAppendingPathComponent:@"carLy"] stringByAppendingPathComponent:@"spotify"];
}

- (NSString *)workingCopyOfDatabaseAtPath:(NSString *)source localName:(NSString *)localName {
    if (source.length == 0 || localName.length == 0) return nil;
    if (![CLSpotifyContainer isPathReadable:source]) {
        CLLogDebug(@"[spotify-cache] not readable: %@", source.lastPathComponent);
        return nil;
    }

    NSString *directory = [[self class] workingDirectory];
    if (directory.length == 0) return nil;
    NSError *error = nil;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
        CLLogDebug(@"[spotify-cache] cannot create %@: %@", directory, error.localizedDescription);
        return nil;
    }

    NSString *destination = [directory stringByAppendingPathComponent:localName];
    NSString *signature = CLDatabaseSignature(source);
    NSMutableDictionary<NSString *, NSString *> *signatures = CLSpotifyCacheSignatures();
    NSString *previous = signatures[source];
    if (previous.length > 0 && [previous isEqualToString:signature] &&
        [CLSpotifyContainer isPathReadable:destination]) {
        return destination;   // Spotify has not written since our last copy
    }

    [signatures removeObjectForKey:source];
    if (![self copyDatabaseFromPath:source toPath:destination]) return nil;
    signatures[source] = signature;
    return destination;
}

/// Copies the database and its WAL sidecars. Reading Spotify's files takes no SQLite lock; only
/// the copy is ever opened. A stale -wal next to a fresh database would corrupt the read, so a
/// sidecar that is missing at the source is deleted at the destination.
- (BOOL)copyDatabaseFromPath:(NSString *)source toPath:(NSString *)destination {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *suffix in @[@"", @"-wal", @"-shm"]) {
        NSString *from = [source stringByAppendingString:suffix];
        NSString *to = [destination stringByAppendingString:suffix];
        NSError *error = nil;

        if ([fileManager fileExistsAtPath:to] && ![fileManager removeItemAtPath:to error:&error]) {
            CLLogDebug(@"[spotify-cache] cannot replace %@: %@", to.lastPathComponent, error.localizedDescription);
            return NO;
        }
        if (![fileManager fileExistsAtPath:from]) continue;   // no sidecar is normal
        if (![fileManager copyItemAtPath:from toPath:to error:&error]) {
            CLLogDebug(@"[spotify-cache] copy of %@ failed: %@", from.lastPathComponent, error.localizedDescription);
            return NO;
        }
    }
    return YES;
}

#pragma mark - Public helpers

+ (CLLyrics *)lyricsFromResponseData:(NSData *)data source:(NSString *)source {
    // The decoding itself lives in CLSpotifyColorLyricsDecoder since 0.9.0, shared with the bodies
    // carLy fetches inside Spotify; the cache only ever holds protobuf.
    return [CLSpotifyColorLyricsDecoder lyricsFromProtobufData:data
                                                        source:source.length > 0 ? source : kCLSpotifyProviderIdentifier];
}

+ (void)clearDatabaseCopies {
    NSString *directory = [self workingDirectory];
    if (directory.length == 0) return;
    // On the work queue so it can never delete a database out from under a running query, and
    // asynchronously so a "clear cache" tap never blocks the main thread.
    dispatch_async(CLSpotifyCacheQueue(), ^{
        [CLSpotifyCacheSignatures() removeAllObjects];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (![fileManager fileExistsAtPath:directory]) return;
        NSError *error = nil;
        if (![fileManager removeItemAtPath:directory error:&error]) {
            CLLogDebug(@"[spotify-cache] cannot clear %@: %@", directory, error.localizedDescription);
        }
    });
}

@end
