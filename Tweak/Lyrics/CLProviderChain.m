// CLProviderChain.m — sequential provider fan-out (contract in CLProviderChain.h).
//
// One request at a time, in provider order: the first synced (or instrumental) result wins; a
// plain-text result is held while the remaining providers are asked (an "instrumental" after it is
// ignored: something already had words), and is delivered only when none of them has synced lyrics (a car display wants timed lines, and an embedded or transcript-
// only plain text must not hide LRCLIB's synced copy). Misses and errors fall through to the next
// provider, and an all-miss resolves to CLLyrics kind None with source "chain" so callers can cache
// the negative.
//
// Cancellation: resolveLyricsForTrack: returns an opaque token that is kept in a live set.
// cancel: removes it; every callback checks the set before doing anything, so a track change
// mid-flight silently drops the old answer instead of flashing the wrong lyrics. Delivering the
// completion also removes the token, which is what makes "exactly once" true even if a provider
// misbehaves and calls back twice.
//
// Transient failures: when every provider misses, the completion still gets a CLLyrics of kind
// None with source "chain" (the contract), but the error argument carries the first provider
// error seen along the way (LRCLIB 503, no connectivity, ...). A caller must therefore only
// negative-cache an all-miss when error == nil — otherwise a minute without data would hide the
// lyrics for that song for the whole 24 h negative TTL.
//
// Everything after the initial call runs off the main thread (providers call back on their own
// queues, the step advance hops onto a private serial queue so a synchronous provider cannot
// recurse). The completion is always delivered with dispatch_async on the main queue.
#import "CLProviderChain.h"
#import "Util/CLLog.h"
#import <os/lock.h>

static NSString *const kCLChainSource = @"chain";

@implementation CLProviderChain {
    NSMutableSet *_liveTokens;
    os_unfair_lock _lock;
    dispatch_queue_t _stepQueue;
}

- (instancetype)init {
    return [self initWithProviders:@[]];
}

- (instancetype)initWithProviders:(NSArray<id<CLLyricsProvider>> *)providers {
    self = [super init];
    if (self) {
        _liveTokens = [NSMutableSet set];
        _lock = OS_UNFAIR_LOCK_INIT;
        _stepQueue = dispatch_queue_create("com.andi.carly.chain",
                                           DISPATCH_QUEUE_SERIAL);
        _providers = [[self class] sanitizedProviders:providers];
    }
    return self;
}

- (void)setProviders:(NSArray<id<CLLyricsProvider>> *)providers {
    _providers = [[self class] sanitizedProviders:providers];
}

/// Drops nils, NSNulls and anything that cannot actually answer a fetch, so the step loop never
/// has to re-check and a bad prefs value cannot take the host down.
+ (NSArray<id<CLLyricsProvider>> *)sanitizedProviders:(NSArray *)providers {
    if (![providers isKindOfClass:[NSArray class]] || providers.count == 0) return @[];
    NSMutableArray *clean = [NSMutableArray arrayWithCapacity:providers.count];
    for (id provider in providers) {
        if (!provider || provider == [NSNull null]) continue;
        if (![provider respondsToSelector:@selector(fetchLyricsForTrack:completion:)]) continue;
        [clean addObject:provider];
    }
    return clean;
}

#pragma mark - Tokens

- (BOOL)isTokenLive:(id)token {
    if (!token) return NO;
    os_unfair_lock_lock(&_lock);
    BOOL live = [_liveTokens containsObject:token];
    os_unfair_lock_unlock(&_lock);
    return live;
}

/// Removes the token and reports whether this caller is the one that got to finish it.
- (BOOL)claimToken:(id)token {
    if (!token) return NO;
    os_unfair_lock_lock(&_lock);
    BOOL claimed = [_liveTokens containsObject:token];
    if (claimed) [_liveTokens removeObject:token];
    os_unfair_lock_unlock(&_lock);
    return claimed;
}

- (void)cancel:(id)token {
    if (!token) return;
    os_unfair_lock_lock(&_lock);
    BOOL removed = [_liveTokens containsObject:token];
    if (removed) [_liveTokens removeObject:token];
    os_unfair_lock_unlock(&_lock);
    if (removed) CLLogDebug(@"[chain] cancelled a pending resolve");
}

#pragma mark - Resolve

- (id)resolveLyricsForTrack:(CLTrack *)track completion:(CLLyricsCompletion)completion {
    id token = [[NSObject alloc] init];
    if (!completion) return token;

    os_unfair_lock_lock(&_lock);
    [_liveTokens addObject:token];
    os_unfair_lock_unlock(&_lock);

    NSArray<id<CLLyricsProvider>> *providers = self.providers;
    CLTrack *snapshot = [track isKindOfClass:[CLTrack class]] ? [track copy] : nil;
    CLLyricsCompletion copied = [completion copy];

    if (!snapshot || snapshot.title.length == 0 || snapshot.artist.length == 0 || providers.count == 0) {
        CLLogDebug(@"[chain] nothing to resolve (providers=%lu)", (unsigned long)providers.count);
        [self finishToken:token lyrics:[CLLyrics noneFromSource:kCLChainSource] error:nil
               completion:copied];
        return token;
    }

    dispatch_async(_stepQueue, ^{
        [self runProviderAtIndex:0 providers:providers track:snapshot token:token
                    firstError:nil heldPlain:nil completion:copied];
    });
    return token;
}

- (void)runProviderAtIndex:(NSUInteger)index
                 providers:(NSArray<id<CLLyricsProvider>> *)providers
                     track:(CLTrack *)track
                     token:(id)token
                firstError:(NSError *)firstError
                 heldPlain:(CLLyrics *)heldPlain
                completion:(CLLyricsCompletion)completion {
    if (![self isTokenLive:token]) return;

    if (index >= providers.count) {
        if (heldPlain) {
            // A later provider's failure travels with it: that provider might have had synced
            // lines, so the caller shows the plain text but does not cache it.
            CLLogInfo(@"[chain] no synced lyrics anywhere; using %@'s plain text", heldPlain.source);
            [self finishToken:token lyrics:heldPlain error:firstError completion:completion];
            return;
        }
        CLLogDebug(@"[chain] all providers missed%@", firstError ? @" (with errors)" : @"");
        [self finishToken:token lyrics:[CLLyrics noneFromSource:kCLChainSource] error:firstError
               completion:completion];
        return;
    }

    id<CLLyricsProvider> provider = providers[index];
    NSString *identifier = [provider respondsToSelector:@selector(identifier)]
        ? (provider.identifier ?: @"?") : @"?";

    // Guards against a provider that calls its completion more than once: only the first call
    // advances the chain.
    NSObject *guard = [[NSObject alloc] init];
    __block BOOL consumed = NO;

    [provider fetchLyricsForTrack:track completion:^(CLLyrics *lyrics, NSError *error) {
        BOOL first = NO;
        @synchronized (guard) {
            if (!consumed) {
                consumed = YES;
                first = YES;
            }
        }
        if (!first) {
            CLLogError(@"[chain] provider %@ called its completion twice", identifier);
            return;
        }
        if (![self isTokenLive:token]) return;

        NSError *carriedError = firstError;
        if (error) {
            CLLogInfo(@"[chain] %@ failed: %@", identifier, error.localizedDescription);
            if (!carriedError) carriedError = error;   // reported if every provider misses
        }
        CLLyrics *held = heldPlain;
        if (held && lyrics.kind == CLLyricsKindInstrumental) {
            // An earlier source has words for this song (often the user's own file); a later
            // "instrumental" is more likely a wrong match than the truth. Keep looking.
            CLLogInfo(@"[chain] %@ says instrumental, but %@ has words; ignoring it", identifier, held.source);
        } else if ([lyrics isKindOfClass:[CLLyrics class]] && lyrics.kind != CLLyricsKindNone) {
            if (lyrics.source.length == 0) lyrics.source = identifier;
            if (!(lyrics.fetchedAt > 0)) lyrics.fetchedAt = [NSDate date].timeIntervalSince1970;
            CLLogInfo(@"[chain] %@ answered: kind=%ld lines=%lu",
                      identifier, (long)lyrics.kind, (unsigned long)lyrics.lines.count);
            if (lyrics.kind != CLLyricsKindPlain) {
                [self finishToken:token lyrics:lyrics error:nil completion:completion];
                return;
            }
            if (!held) held = lyrics;   // keep the first plain text, look on for synced lines
        }

        dispatch_async(self->_stepQueue, ^{
            [self runProviderAtIndex:index + 1 providers:providers track:track token:token
                          firstError:carriedError heldPlain:held completion:completion];
        });
    }];
}

- (void)finishToken:(id)token
             lyrics:(CLLyrics *)lyrics
              error:(NSError *)error
         completion:(CLLyricsCompletion)completion {
    if (![self claimToken:token]) return;   // cancelled, or already delivered
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(lyrics, error);
    });
}

@end
