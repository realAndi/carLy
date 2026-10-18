// The mailbox between carLy in CarPlayTemplateUIHost and carLy in Spotify (0.9.0).
//
// Spotify's own lyrics (`color-lyrics/v2/track/<id>`) need Spotify's login, which exists only inside
// Spotify's process, while the CarPlay screen is drawn by CarPlayTemplateUIHost — another sandbox
// that cannot read Spotify's container (PLAN.md §3.2, every drive log since 2026-09-21). Neither
// process can reach the other's files, but Dopamine hands every process it checks in a read-write
// sandbox extension for <jbroot>/var/mobile (launchdhook, systemwide_process_checkin), so a
// directory there is the one place both can read and write. Layout, under
// /var/jb/var/mobile/Library/Caches/carLy/SpotifyBridge:
//
//   requests/<trackID>.json    host → Spotify: "fetch Spotify's lyrics for this track"
//                              { "v": 1, "at": <unix>, "title", "artist", "duration" } — the song
//                              fields only feed Spotify's log line
//   responses/<trackID>.json   Spotify → host: a CLSpotifyBridgeResponse
//   status.json                Spotify → host: who answers (see the CLSpotifyBridgeStatus* keys)
//
// plus one Darwin notification each way that says "look now" (the host also polls, so a lost
// notification costs a quarter of a second, not the lyrics). Every file is written atomically (a
// reader never sees half of one) and with no data protection: Spotify's default class would make
// its files unreadable while the phone is locked, which in a car is most of the time.
//
// What crosses: Spotify track ids, the song's title/artist/duration, finished lyrics and a status
// summary. Never a token, a cookie or a header — the login stays in Spotify's memory.
//
// Track ids are the only thing paths are built from, and only after +isValidTrackID: (1–64 base-62
// characters, so no separators, dots or wildcards). Every method is safe on any thread, never
// throws and never blocks on anything but the file system.
#import <Foundation/Foundation.h>

@class CLSpotifyBridgeResponse;

NS_ASSUME_NONNULL_BEGIN

/// Darwin notification the host posts after writing a request.
extern NSString *const CLSpotifyBridgeRequestNotification;    // com.andi.carly/spotify.request
/// Darwin notification Spotify posts after writing a response.
extern NSString *const CLSpotifyBridgeResponseNotification;   // com.andi.carly/spotify.response

/// status.json keys.
extern NSString *const CLSpotifyBridgeStatusPID;            ///< NSNumber, Spotify's pid
extern NSString *const CLSpotifyBridgeStatusVersion;        ///< NSString, carLy version in Spotify
extern NSString *const CLSpotifyBridgeStatusAuthorized;     ///< NSNumber (bool): a login has been seen
extern NSString *const CLSpotifyBridgeStatusHost;           ///< NSString, the API host Spotify uses
extern NSString *const CLSpotifyBridgeStatusAuthorizedAt;   ///< NSNumber, unix time the login was last seen
extern NSString *const CLSpotifyBridgeStatusLyricsShape;    ///< NSNumber (bool): Spotify's own lyrics request was seen
extern NSString *const CLSpotifyBridgeStatusLastResult;     ///< NSString, one line about the last fetch
extern NSString *const CLSpotifyBridgeStatusUpdatedAt;      ///< NSNumber, unix time of this write

/// Request keys (besides "v").
extern NSString *const CLSpotifyBridgeRequestTitle;
extern NSString *const CLSpotifyBridgeRequestArtist;
extern NSString *const CLSpotifyBridgeRequestDuration;
extern NSString *const CLSpotifyBridgeRequestTime;          ///< NSNumber, unix time it was written

@interface CLSpotifyBridge : NSObject

/// The root. /var/jb/var/mobile/Library/Caches/carLy/SpotifyBridge, or the absolute directory
/// named by the environment variable CARLY_SPOTIFY_BRIDGE_DIR (tests; nothing sets it on the
/// phone). Resolved once per process.
+ (NSString *)directory;

/// YES for 1–64 base-62 characters.
+ (BOOL)isValidTrackID:(nullable NSString *)trackID;

#pragma mark Requests (host writes, Spotify reads)

/// `info` holds CLSpotifyBridgeRequest* keys (JSON types only); "v" and the time are added here.
+ (BOOL)writeRequestForTrackID:(NSString *)trackID info:(nullable NSDictionary *)info;
/// Track ids with a request file, oldest request first.
+ (NSArray<NSString *> *)pendingRequestTrackIDs;
+ (nullable NSDictionary *)requestForTrackID:(NSString *)trackID;
+ (void)removeRequestForTrackID:(NSString *)trackID;

#pragma mark Responses (Spotify writes, host reads)

+ (BOOL)writeResponse:(CLSpotifyBridgeResponse *)response forTrackID:(NSString *)trackID;
+ (nullable CLSpotifyBridgeResponse *)responseForTrackID:(NSString *)trackID;
+ (void)removeResponseForTrackID:(NSString *)trackID;

#pragma mark Status (Spotify writes, host reads)

/// "v" and CLSpotifyBridgeStatusUpdatedAt are added here.
+ (BOOL)writeStatus:(NSDictionary *)status;
+ (nullable NSDictionary *)status;
+ (void)removeStatus;

#pragma mark Housekeeping

/// Deletes requests and responses whose files are older than `age` seconds.
+ (void)pruneEntriesOlderThan:(NSTimeInterval)age;

/// notify_post. A sandbox that refuses it only costs the poll interval on the host side.
+ (void)postNotification:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
