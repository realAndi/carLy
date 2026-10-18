// What the embedded-lyrics provider needs to know about one item of the local Music library.
// Plain value object; CLMusicLibrary fills it from MPMediaItem, tests build it by hand.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLMusicLibraryItem : NSObject

- (instancetype)initWithTitle:(nullable NSString *)title
                     duration:(NSTimeInterval)duration
                       lyrics:(nullable NSString *)lyrics
                     filePath:(nullable NSString *)filePath NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy, nullable) NSString *title;
@property (nonatomic, readonly) NSTimeInterval duration;
/// MPMediaItemPropertyLyrics: the text MusicLibrary keeps in `lyrics.lyrics` (the file's USLT or
/// ©lyr as AVFoundation read it). Plain text, although it may hold LRC. nil when empty.
@property (nonatomic, readonly, copy, nullable) NSString *lyrics;
/// Absolute path of a DRM-free local audio file (/var/mobile/Media/iTunes_Control/Music/Fxx/…),
/// nil when the item has none (streamed, cloud-only or protected).
@property (nonatomic, readonly, copy, nullable) NSString *filePath;

@end

NS_ASSUME_NONNULL_END
