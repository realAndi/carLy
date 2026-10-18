// Apple Music's lyrics TTML for a catalog song, fetched the way the Music app fetches it: through
// MediaPlayer's own MPStoreLyricsMusicKitRequestOperation (or the older
// MPStoreLyricsRequestOperation), which reads the storefront and language from the URL bag and
// signs the amp-api `syllable-lyrics` request with the signed-in account. No keys, no URL built
// here, no session hook. Only works inside a process that is signed in to Apple Music — the
// Music app. Disassembly notes: docs/research/apple-music-lyrics.md.
//
// Private API, resolved at runtime (class and selector checks before every use), Foundation only.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Called exactly once, on a private queue. `ttml` is non-nil only on success.
typedef void (^CLStoreLyricsCompletion)(NSString *_Nullable ttml, NSError *_Nullable error);

extern NSString *const CLStoreLyricsErrorDomain;
typedef NS_ENUM(NSInteger, CLStoreLyricsErrorCode) {
    CLStoreLyricsErrorUnavailable = 1,   ///< the operation class or its selectors are missing
    CLStoreLyricsErrorTimedOut = 2,      ///< no answer within the timeout (the operation is cancelled)
    CLStoreLyricsErrorNoContent = 3,     ///< answered, but without a TTML string
    CLStoreLyricsErrorInvalidIdentifier = 4,
};

@interface CLStoreLyricsFetcher : NSObject

/// YES when one of the two operation classes exists with `setSongAdamID:` and
/// `setResponseHandler:`.
+ (BOOL)isAvailable;

/// Starts one request for `adamID` (a lyrics, subscription or store adam id). Never blocks.
/// A request MediaPlayer fails is reported with its own error.
+ (void)fetchTTMLForAdamID:(long long)adamID
                   timeout:(NSTimeInterval)timeout
                completion:(CLStoreLyricsCompletion)completion;

@end

NS_ASSUME_NONNULL_END
