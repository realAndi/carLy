// Contract: implemented by the lyrics-core slice in CLProviderChain.m.
#import "CLLyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface CLProviderChain : NSObject
- (instancetype)initWithProviders:(NSArray<id<CLLyricsProvider>> *)providers;
@property (nonatomic, copy) NSArray<id<CLLyricsProvider>> *providers;
/// Tries providers in order; the first synced or instrumental result wins. A plain result is held
/// while the rest are tried (a later instrumental is then ignored) and delivered only if none of
/// them has synced lines — together with
/// the first provider error seen, if any, so the caller can skip caching it. If all miss,
/// completion gets a CLLyrics of kind none (source = "chain") and the first provider error.
/// Completion is delivered on the main queue, exactly once, unless the returned token was
/// cancelled first.
- (id)resolveLyricsForTrack:(CLTrack *)track completion:(CLLyricsCompletion)completion;
- (void)cancel:(id)token;
@end

NS_ASSUME_NONNULL_END
