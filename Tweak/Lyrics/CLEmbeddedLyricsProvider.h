// Lyrics the user embedded in their own song files, for tracks of the local Music library that the
// Apple Music app is playing. No network. Pipeline and evidence: docs/research/embedded-lyrics.md.
//
//   1. The Music hook has recorded the now-playing item (CLMusicItemRegistry): its library
//      persistent id. None -> no match (not a library file).
//   2. The library item (CLMusicLibrary), checked against the track's title.
//   3. Its database lyrics text (USLT / ©lyr as iOS read them) -> CLEmbeddedLyricsReader, which
//      turns LRC text into synced lines. Synced -> done.
//   4. The audio file itself (memory-mapped, tags only): SYLT, FLAC/Vorbis LYRICS, a fresher tag.
//      Then a sidecar "<file>.lrc". The first synced result wins; otherwise the first plain one.
// Anything other than a com.apple.Music track is answered "no match" at once.
#import "CLLyricsTypes.h"
#import "Lyrics/CLMusicLibraryItem.h"

@class CLMusicItemRegistry;

NS_ASSUME_NONNULL_BEGIN

/// Library lookup by persistent id; nil when there is no such item.
typedef CLMusicLibraryItem *_Nullable (^CLMusicLibraryLookup)(unsigned long long persistentID);
/// Reads a file for the tag reader; nil when it cannot be read.
typedef NSData *_Nullable (^CLEmbeddedFileReader)(NSString *path);

extern NSString *const CLEmbeddedLyricsProviderIdentifier;   // "embedded"

@interface CLEmbeddedLyricsProvider : NSObject <CLLyricsProvider>

/// The real thing: the shared registry, CLMusicLibrary and memory-mapped reads.
- (instancetype)init;
/// Test seam.
- (instancetype)initWithRegistry:(CLMusicItemRegistry *)registry
                          lookup:(CLMusicLibraryLookup)lookup
                      fileReader:(CLEmbeddedFileReader)fileReader
                    itemWaitTime:(NSTimeInterval)itemWaitTime NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly) NSString *identifier;

/// Completion on a private serial queue (synchronously for a track that is not Apple Music's).
/// nil + nil = no match. An error only when the registry is live but never learnt the track, so
/// the controller does not negative-cache a timing miss.
- (void)fetchLyricsForTrack:(CLTrack *)track completion:(CLLyricsCompletion)completion;

@end

NS_ASSUME_NONNULL_END
