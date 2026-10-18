#import "CLSpotifyBridge.h"
#import "CLSpotifyBridgeResponse.h"
#import "Util/CLLog.h"

#import <notify.h>
#import <stdlib.h>
#import <sys/stat.h>

NSString *const CLSpotifyBridgeRequestNotification = @"com.andi.carly/spotify.request";
NSString *const CLSpotifyBridgeResponseNotification = @"com.andi.carly/spotify.response";

NSString *const CLSpotifyBridgeStatusPID = @"pid";
NSString *const CLSpotifyBridgeStatusVersion = @"version";
NSString *const CLSpotifyBridgeStatusAuthorized = @"authorized";
NSString *const CLSpotifyBridgeStatusHost = @"host";
NSString *const CLSpotifyBridgeStatusAuthorizedAt = @"authorizedAt";
NSString *const CLSpotifyBridgeStatusLyricsShape = @"lyricsShape";
NSString *const CLSpotifyBridgeStatusLastResult = @"lastResult";
NSString *const CLSpotifyBridgeStatusUpdatedAt = @"updatedAt";

NSString *const CLSpotifyBridgeRequestTitle = @"title";
NSString *const CLSpotifyBridgeRequestArtist = @"artist";
NSString *const CLSpotifyBridgeRequestDuration = @"duration";
NSString *const CLSpotifyBridgeRequestTime = @"at";

static const NSInteger kCLBridgeVersion = 1;
/// Hard-coded jbroot like CLPrefs' plist fallback: rootless.h on this Theos goes through libroot,
/// which the phone's libroot-dopamine cannot serve (CLAUDE.md).
static NSString *const kCLBridgeDefaultDirectory = @"/var/jb/var/mobile/Library/Caches/carLy/SpotifyBridge";
/// Bigger than any lyrics document; anything larger is not ours and is not read.
static const unsigned long long kCLBridgeMaximumFileSize = 1024 * 1024;

@implementation CLSpotifyBridge

+ (NSString *)directory {
    static NSString *directory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *override = getenv("CARLY_SPOTIFY_BRIDGE_DIR");
        NSString *candidate = override != NULL ? @(override) : nil;
        candidate = [candidate stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        directory = (candidate.length > 1 && [candidate hasPrefix:@"/"]) ? [candidate copy] : kCLBridgeDefaultDirectory;
    });
    return directory;
}

+ (BOOL)isValidTrackID:(NSString *)trackID {
    if (![trackID isKindOfClass:[NSString class]] || trackID.length == 0 || trackID.length > 64) return NO;
    for (NSUInteger i = 0; i < trackID.length; i++) {
        unichar c = [trackID characterAtIndex:i];
        BOOL base62 = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        if (!base62) return NO;
    }
    return YES;
}

#pragma mark - Paths

+ (NSString *)requestsDirectory {
    return [[self directory] stringByAppendingPathComponent:@"requests"];
}

+ (NSString *)responsesDirectory {
    return [[self directory] stringByAppendingPathComponent:@"responses"];
}

+ (NSString *)requestPathForTrackID:(NSString *)trackID {
    if (![self isValidTrackID:trackID]) return nil;
    return [[self requestsDirectory] stringByAppendingPathComponent:[trackID stringByAppendingPathExtension:@"json"]];
}

+ (NSString *)responsePathForTrackID:(NSString *)trackID {
    if (![self isValidTrackID:trackID]) return nil;
    return [[self responsesDirectory] stringByAppendingPathComponent:[trackID stringByAppendingPathExtension:@"json"]];
}

+ (NSString *)statusPath {
    return [[self directory] stringByAppendingPathComponent:@"status.json"];
}

#pragma mark - File plumbing

/// Creates `directory` and its parents. YES when it exists afterwards.
+ (BOOL)ensureDirectory:(NSString *)directory {
    BOOL isDirectory = NO;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:directory isDirectory:&isDirectory] && isDirectory) return YES;
    NSError *error = nil;
    NSDictionary *attributes = @{ NSFilePosixPermissions: @(0755) };
    if (![fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:attributes error:&error]) {
        // The usual cause: this process did not get Dopamine's extension for <jbroot>/var/mobile.
        static BOOL reported = NO;
        if (!reported) {
            CLLogInfo(@"[spotify-bridge] cannot create %@: %@", directory, error.localizedDescription ?: @"?");
        }
        reported = YES;
        return NO;
    }
    return YES;
}

+ (BOOL)writeJSONObject:(id)object toPath:(NSString *)path {
    if (path.length == 0 || ![NSJSONSerialization isValidJSONObject:object]) return NO;
    if (![self ensureDirectory:[path stringByDeletingLastPathComponent]]) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    if (data.length == 0) return NO;
    // Atomic: Foundation writes a temporary next to `path` and renames it over, so a reader in the
    // other process never sees half a document.
    NSError *error = nil;
    if ([data writeToFile:path options:NSDataWritingAtomic | NSDataWritingFileProtectionNone error:&error]) return YES;
    // A volume without per-file protection classes may refuse the class; the jbroot lives on
    // Preboot, where nothing is locked away anyway.
    error = nil;
    if ([data writeToFile:path options:NSDataWritingAtomic error:&error]) return YES;
    CLLogInfo(@"[spotify-bridge] cannot write %@: %@", path.lastPathComponent, error.localizedDescription ?: @"?");
    return NO;
}

+ (NSDictionary *)JSONDictionaryAtPath:(NSString *)path {
    if (path.length == 0) return nil;
    struct stat info;
    if (stat(path.fileSystemRepresentation, &info) != 0) return nil;
    if (!S_ISREG(info.st_mode) || info.st_size <= 0 || (unsigned long long)info.st_size > kCLBridgeMaximumFileSize) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:NULL];
    if (data.length == 0) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

+ (void)removePath:(NSString *)path {
    if (path.length == 0) return;
    unlink(path.fileSystemRepresentation);
}

/// Unix modification time, 0 when the file is missing.
+ (NSTimeInterval)modificationTimeOfPath:(NSString *)path {
    struct stat info;
    if (path.length == 0 || stat(path.fileSystemRepresentation, &info) != 0) return 0;
    return (NSTimeInterval)info.st_mtimespec.tv_sec + (NSTimeInterval)info.st_mtimespec.tv_nsec / 1e9;
}

/// Track ids that have a "<id>.json" in `directory`.
+ (NSArray<NSString *> *)trackIDsInDirectory:(NSString *)directory {
    NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:NULL];
    NSMutableArray<NSString *> *trackIDs = [NSMutableArray arrayWithCapacity:names.count];
    for (NSString *name in names) {
        if (![name.pathExtension isEqualToString:@"json"]) continue;   // also skips atomic-write temporaries
        NSString *trackID = name.stringByDeletingPathExtension;
        if ([self isValidTrackID:trackID]) [trackIDs addObject:trackID];
    }
    return trackIDs;
}

#pragma mark - Requests

+ (BOOL)writeRequestForTrackID:(NSString *)trackID info:(NSDictionary *)info {
    NSString *path = [self requestPathForTrackID:trackID];
    if (!path) return NO;
    NSMutableDictionary *request = [NSMutableDictionary dictionaryWithCapacity:info.count + 2];
    if ([info isKindOfClass:[NSDictionary class]]) [request addEntriesFromDictionary:info];
    request[@"v"] = @(kCLBridgeVersion);
    request[CLSpotifyBridgeRequestTime] = @([[NSDate date] timeIntervalSince1970]);
    return [self writeJSONObject:request toPath:path];
}

+ (NSArray<NSString *> *)pendingRequestTrackIDs {
    NSArray<NSString *> *trackIDs = [self trackIDsInDirectory:[self requestsDirectory]];
    if (trackIDs.count < 2) return trackIDs;
    NSMutableDictionary<NSString *, NSNumber *> *times = [NSMutableDictionary dictionaryWithCapacity:trackIDs.count];
    for (NSString *trackID in trackIDs) {
        times[trackID] = @([self modificationTimeOfPath:[self requestPathForTrackID:trackID]]);
    }
    return [trackIDs sortedArrayUsingComparator:^NSComparisonResult(NSString *lhs, NSString *rhs) {
        return [times[lhs] compare:times[rhs]];
    }];
}

+ (NSDictionary *)requestForTrackID:(NSString *)trackID {
    NSDictionary *request = [self JSONDictionaryAtPath:[self requestPathForTrackID:trackID]];
    id version = request[@"v"];
    if (![version isKindOfClass:[NSNumber class]] || [(NSNumber *)version integerValue] != kCLBridgeVersion) return nil;
    return request;
}

+ (void)removeRequestForTrackID:(NSString *)trackID {
    [self removePath:[self requestPathForTrackID:trackID]];
}

#pragma mark - Responses

+ (BOOL)writeResponse:(CLSpotifyBridgeResponse *)response forTrackID:(NSString *)trackID {
    if (!response) return NO;
    return [self writeJSONObject:[response dictionaryRepresentation] toPath:[self responsePathForTrackID:trackID]];
}

+ (CLSpotifyBridgeResponse *)responseForTrackID:(NSString *)trackID {
    return [CLSpotifyBridgeResponse responseWithDictionary:[self JSONDictionaryAtPath:[self responsePathForTrackID:trackID]]];
}

+ (void)removeResponseForTrackID:(NSString *)trackID {
    [self removePath:[self responsePathForTrackID:trackID]];
}

#pragma mark - Status

+ (BOOL)writeStatus:(NSDictionary *)status {
    NSMutableDictionary *document = [NSMutableDictionary dictionaryWithCapacity:status.count + 2];
    if ([status isKindOfClass:[NSDictionary class]]) [document addEntriesFromDictionary:status];
    document[@"v"] = @(kCLBridgeVersion);
    document[CLSpotifyBridgeStatusUpdatedAt] = @([[NSDate date] timeIntervalSince1970]);
    return [self writeJSONObject:document toPath:[self statusPath]];
}

+ (NSDictionary *)status {
    NSDictionary *status = [self JSONDictionaryAtPath:[self statusPath]];
    id version = status[@"v"];
    if (![version isKindOfClass:[NSNumber class]] || [(NSNumber *)version integerValue] != kCLBridgeVersion) return nil;
    return status;
}

+ (void)removeStatus {
    [self removePath:[self statusPath]];
}

#pragma mark - Housekeeping

+ (void)pruneEntriesOlderThan:(NSTimeInterval)age {
    NSTimeInterval cutoff = [[NSDate date] timeIntervalSince1970] - MAX(age, 0.0);
    for (NSString *trackID in [self trackIDsInDirectory:[self requestsDirectory]]) {
        NSString *path = [self requestPathForTrackID:trackID];
        if ([self modificationTimeOfPath:path] < cutoff) [self removePath:path];
    }
    for (NSString *trackID in [self trackIDsInDirectory:[self responsesDirectory]]) {
        NSString *path = [self responsePathForTrackID:trackID];
        if ([self modificationTimeOfPath:path] < cutoff) [self removePath:path];
    }
}

+ (void)postNotification:(NSString *)name {
    if (name.length == 0) return;
    uint32_t status = notify_post(name.UTF8String);
    if (status != NOTIFY_STATUS_OK) CLLogDebug(@"[spotify-bridge] notify_post(%@) failed: %u", name, status);
}

@end
