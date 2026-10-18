#import "Lyrics/CLStoreLyricsFetcher.h"
#import "Util/CLLog.h"
#import <objc/message.h>
#import <os/lock.h>

NSString *const CLStoreLyricsErrorDomain = @"CLStoreLyricsErrorDomain";

/// Answers the completion at most once, whichever of the response handler and the timeout wins.
@interface CLStoreLyricsAttempt : NSObject
- (instancetype)initWithCompletion:(CLStoreLyricsCompletion)completion queue:(dispatch_queue_t)queue;
/// YES when this call delivered the answer, NO when an earlier call already had.
- (BOOL)finishWithTTML:(nullable NSString *)ttml error:(nullable NSError *)error;
@end

@implementation CLStoreLyricsAttempt {
    os_unfair_lock _lock;
    BOOL _finished;
    CLStoreLyricsCompletion _completion;
    dispatch_queue_t _queue;
}

- (instancetype)initWithCompletion:(CLStoreLyricsCompletion)completion queue:(dispatch_queue_t)queue {
    self = [super init];
    if (!self) return nil;
    _lock = OS_UNFAIR_LOCK_INIT;
    _completion = [completion copy];
    _queue = queue;
    return self;
}

- (BOOL)finishWithTTML:(NSString *)ttml error:(NSError *)error {
    os_unfair_lock_lock(&_lock);
    BOOL first = !_finished;
    _finished = YES;
    CLStoreLyricsCompletion completion = _completion;
    _completion = nil;
    os_unfair_lock_unlock(&_lock);
    if (first && completion) {
        dispatch_async(_queue, ^{ completion(ttml, error); });
    }
    return first;
}

@end

static NSError *CLStoreLyricsError(CLStoreLyricsErrorCode code, NSString *message) {
    return [NSError errorWithDomain:CLStoreLyricsErrorDomain code:code
                           userInfo:@{ NSLocalizedDescriptionKey: message }];
}

/// MPStoreLyricsMusicKitRequestOperation is what MPStoreLyricsRequest uses while the MediaPlayer
/// "Suntory" feature flag is on (21D50 ships it on); the older operation has the same interface.
static Class CLStoreLyricsOperationClass(void) {
    static Class operationClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSString *name in @[ @"MPStoreLyricsMusicKitRequestOperation", @"MPStoreLyricsRequestOperation" ]) {
            Class candidate = NSClassFromString(name);
            if (candidate && [candidate isSubclassOfClass:[NSOperation class]] &&
                [candidate instancesRespondToSelector:@selector(setSongAdamID:)] &&
                [candidate instancesRespondToSelector:@selector(setResponseHandler:)]) {
                operationClass = candidate;
                break;
            }
        }
        CLLogInfo(@"[apple-music] lyrics operation: %@",
                  operationClass ? NSStringFromClass(operationClass) : @"(none, Apple Music lyrics off)");
    });
    return operationClass;
}

@implementation CLStoreLyricsFetcher

+ (BOOL)isAvailable {
    return CLStoreLyricsOperationClass() != Nil;
}

+ (NSOperationQueue *)operationQueue {
    static NSOperationQueue *queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = [[NSOperationQueue alloc] init];
        queue.name = @"com.andi.carly.store-lyrics";
        queue.maxConcurrentOperationCount = 2;
        queue.qualityOfService = NSQualityOfServiceUserInitiated;
    });
    return queue;
}

+ (dispatch_queue_t)callbackQueue {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.andi.carly.store-lyrics.callback", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

+ (void)fetchTTMLForAdamID:(long long)adamID
                   timeout:(NSTimeInterval)timeout
                completion:(CLStoreLyricsCompletion)completion {
    if (!completion) return;
    CLStoreLyricsAttempt *attempt = [[CLStoreLyricsAttempt alloc] initWithCompletion:completion
                                                                              queue:[self callbackQueue]];
    if (adamID <= 0) {
        [attempt finishWithTTML:nil error:CLStoreLyricsError(CLStoreLyricsErrorInvalidIdentifier, @"no adam id")];
        return;
    }
    Class operationClass = CLStoreLyricsOperationClass();
    if (!operationClass) {
        [attempt finishWithTTML:nil error:CLStoreLyricsError(CLStoreLyricsErrorUnavailable,
                                                             @"MediaPlayer lyrics operation not found")];
        return;
    }

    NSOperation *operation = [[operationClass alloc] init];
    if (!operation) {
        [attempt finishWithTTML:nil error:CLStoreLyricsError(CLStoreLyricsErrorUnavailable,
                                                             @"lyrics operation did not initialise")];
        return;
    }
    ((void (*)(id, SEL, long long))objc_msgSend)(operation, @selector(setSongAdamID:), adamID);

    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    // (MPStoreLyricsResponse *response, NSError *error): -finishWithError: calls it with (nil, error),
    // the success path with the response whose lyricsContent is the TTML.
    id handler = ^(id response, NSError *error) {
        NSString *ttml = nil;
        if (response && [response respondsToSelector:@selector(lyricsContent)]) {
            id content = ((id (*)(id, SEL))objc_msgSend)(response, @selector(lyricsContent));
            if ([content isKindOfClass:[NSString class]] && [(NSString *)content length] > 0) ttml = content;
        }
        NSError *reported = [error isKindOfClass:[NSError class]] ? error : nil;
        if (!ttml && !reported) {
            reported = CLStoreLyricsError(CLStoreLyricsErrorNoContent, @"response carried no TTML");
        }
        if ([attempt finishWithTTML:ttml error:(ttml ? nil : reported)]) {
            CLLogDebug(@"[apple-music] adam id %lld answered in %.2f s: %@", adamID,
                       CFAbsoluteTimeGetCurrent() - started,
                       ttml ? [NSString stringWithFormat:@"%lu chars of TTML", (unsigned long)ttml.length]
                            : reported.localizedDescription);
        }
    };
    ((void (*)(id, SEL, id))objc_msgSend)(operation, @selector(setResponseHandler:), handler);

    NSTimeInterval limit = timeout > 0 ? timeout : 15.0;
    __weak NSOperation *weakOperation = operation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(limit * NSEC_PER_SEC)), [self callbackQueue], ^{
        if ([attempt finishWithTTML:nil error:CLStoreLyricsError(CLStoreLyricsErrorTimedOut,
                                                                 @"lyrics request timed out")]) {
            CLLogInfo(@"[apple-music] adam id %lld: no answer after %.0f s, cancelling", adamID, limit);
            [weakOperation cancel];
        }
    });

    [[self operationQueue] addOperation:operation];
}

@end
