// What the Apple Music app knows about the song it is playing, beyond what MediaRemote's
// now-playing dictionary exports: the ids Apple's own lyrics request uses and whether the catalog
// has lyrics at all. Filled in the Music process by the MRNowPlayingPlayerClient hook
// (Tweak/Hooks/MusicAppHooks.x) from MRContentItemMetadata; read by the Apple Music and embedded
// lyrics providers. Plain value object, Foundation only. Evidence for every field:
// docs/research/apple-music-lyrics.md and docs/research/embedded-lyrics.md.
#import <Foundation/Foundation.h>
#import "Lyrics/CLLyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CLMusicLyricsAvailability) {
    CLMusicLyricsAvailabilityUnknown = 0,   ///< the content item did not say (hasLyricsAvailable NO)
    CLMusicLyricsAvailabilityAvailable,     ///< Apple Music has lyrics for it
    CLMusicLyricsAvailabilityNone,          ///< Apple Music says it has none
};

@interface CLMusicItemInfo : NSObject

- (instancetype)initWithTitle:(nullable NSString *)title
                       artist:(nullable NSString *)artist
                     duration:(NSTimeInterval)duration
              storeIdentifier:(long long)storeIdentifier
       subscriptionIdentifier:(long long)subscriptionIdentifier
             lyricsIdentifier:(long long)lyricsIdentifier
           lyricsAvailability:(CLMusicLyricsAvailability)lyricsAvailability
          libraryPersistentID:(unsigned long long)libraryPersistentID NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy, nullable) NSString *title;
@property (nonatomic, readonly, copy, nullable) NSString *artist;
@property (nonatomic, readonly) NSTimeInterval duration;              ///< 0 when unknown
@property (nonatomic, readonly) long long storeIdentifier;            ///< iTunesStoreIdentifier, 0 when none
@property (nonatomic, readonly) long long subscriptionIdentifier;     ///< iTunesStoreSubscriptionIdentifier
@property (nonatomic, readonly) long long lyricsIdentifier;           ///< lyricsAdamID (only when hasLyricsAdamID)
@property (nonatomic, readonly) CLMusicLyricsAvailability lyricsAvailability;
/// The local library persistent id, 0 when the item is not (known to be) in the library.
/// MRContentItemMetadata.legacyUniqueIdentifier carries it, but falls back to a store id for
/// catalog items; the initializer drops a value equal to either store id, and the embedded
/// provider still checks the library item's title before trusting it.
@property (nonatomic, readonly) unsigned long long libraryPersistentID;
/// When the hook recorded it (CFAbsoluteTime).
@property (nonatomic, readonly) CFAbsoluteTime recordedAt;

/// The id Apple's own MPStoreLyricsRequest would ask for: lyricsAdamID, else the subscription
/// adam id, else the store id. 0 when the item has none of them (a local file).
@property (nonatomic, readonly) long long preferredLyricsIdentifier;

/// Same song as `track`: title and artist equal ignoring case and surrounding whitespace, and the
/// durations within 2 s when both are known. An item with no title never matches.
- (BOOL)describesTrack:(nullable CLTrack *)track;

/// Same ids and flags as `other` (ignores recordedAt).
- (BOOL)isEquivalentToInfo:(nullable CLMusicItemInfo *)other;

@end

NS_ASSUME_NONNULL_END
