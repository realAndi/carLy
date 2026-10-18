// Looks an item of the local Music library up by persistent id, through MediaPlayer's public
// MPMediaQuery (resolved at runtime, so nothing links MediaPlayer and a process without it simply
// finds nothing). The file path comes from MediaPlayer's exported-but-private
// MPMediaItemPropertyFilePath ("filePath"), and only when the public assetURL says a DRM-free local
// file exists. Evidence: docs/research/embedded-lyrics.md.
//
// Only answers when the process is already authorised for the media library (the Music app is);
// it never asks for authorisation, so it can never raise a permission prompt. May be called from
// any thread; call it off the main thread (a query can touch the library database).
#import "Lyrics/CLMusicLibraryItem.h"

NS_ASSUME_NONNULL_BEGIN

@interface CLMusicLibrary : NSObject

+ (nullable CLMusicLibraryItem *)itemWithPersistentID:(unsigned long long)persistentID;

@end

NS_ASSUME_NONNULL_END
