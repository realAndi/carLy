// Shared contract between the now-playing source, providers, cache, sync engine and UI.
// Implemented in CLLyricsTypes.m. Keep this header stable; other modules compile against it.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CLLyricsKind) {
    CLLyricsKindNone = 0,        // nothing found
    CLLyricsKindSynced,          // lines with timestamps
    CLLyricsKindPlain,           // plainText only
    CLLyricsKindInstrumental,    // provider says instrumental
};

/// Immutable description of the track we want lyrics for.
@interface CLTrack : NSObject <NSCopying>
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy, nullable) NSString *album;
@property (nonatomic) NSTimeInterval duration;                    // seconds, 0 if unknown
@property (nonatomic, copy, nullable) NSString *bundleIdentifier;  // now-playing app, e.g. com.spotify.client
@property (nonatomic, copy, nullable) NSString *contentIdentifier; // raw, e.g. "spotify:track:ID#UUID"
/// Base-62 Spotify track id parsed from contentIdentifier ("spotify:track:<id>" prefix), nil otherwise.
@property (nonatomic, readonly, nullable) NSString *spotifyTrackID;
/// Stable cache key: sha1 of lowercase "artist|title|round(duration)".
@property (nonatomic, readonly) NSString *cacheKey;
- (BOOL)isSameSongAs:(nullable CLTrack *)other;   // title+artist+duration within 2 s
@end

@interface CLLyricLine : NSObject
@property (nonatomic) NSTimeInterval time;   // seconds from track start
@property (nonatomic, copy) NSString *text;
+ (instancetype)lineWithTime:(NSTimeInterval)time text:(NSString *)text;
@end

@interface CLLyrics : NSObject
@property (nonatomic) CLLyricsKind kind;
@property (nonatomic, copy) NSArray<CLLyricLine *> *lines;   // sorted ascending by time; empty unless synced
@property (nonatomic, copy, nullable) NSString *plainText;   // set for plain, may also be set for synced
@property (nonatomic, copy) NSString *source;                // provider identifier that produced it
@property (nonatomic) NSTimeInterval fetchedAt;              // unix time, for cache TTL
+ (instancetype)noneFromSource:(NSString *)source;
/// "This track has no lyrics because it has no words." Distinct from `noneFromSource:` so the UI
/// can say "instrumental" instead of "no lyrics"; cached like any other positive result.
+ (instancetype)instrumentalFromSource:(NSString *)source;
+ (instancetype)syncedWithLines:(NSArray<CLLyricLine *> *)lines source:(NSString *)source;
+ (instancetype)plainWithText:(NSString *)text source:(NSString *)source;
- (NSDictionary *)dictionaryRepresentation;                  // JSON-safe
+ (nullable instancetype)lyricsWithDictionary:(NSDictionary *)dictionary;
@end

typedef void (^CLLyricsCompletion)(CLLyrics *_Nullable lyrics, NSError *_Nullable error);

/// A lyrics source. fetch must be asynchronous, must never block the caller, may call back on any
/// queue, and must call completion exactly once. nil lyrics + nil error means "no match".
@protocol CLLyricsProvider <NSObject>
@property (nonatomic, readonly) NSString *identifier;   // "spotify-cache", "lrclib", "custom"
- (void)fetchLyricsForTrack:(CLTrack *)track completion:(CLLyricsCompletion)completion;
@end

NS_ASSUME_NONNULL_END
