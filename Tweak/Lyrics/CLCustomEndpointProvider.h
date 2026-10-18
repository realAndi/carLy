// CLCustomEndpointProvider — optional user-supplied lyrics endpoint (PLAN.md §3.3).
//
// The user types a URL template in the settings page, e.g.
//   https://example.org/lyrics?a={artist}&t={title}&b={album}&d={duration}
// {artist} {title} {album} {duration} are replaced with the track's values, percent-escaped for
// use inside a query component ({duration} is whole seconds). Unknown placeholders are left
// alone; an album/duration we do not know substitutes as an empty string.
// An optional single header (name + value) is sent, for endpoints that want an API key the user
// owns. Nothing is ever sent anywhere else, and the provider is completely inert while the
// template is empty — the default state.
//
// Response handling, in order:
//   * JSON object (or array of objects, first one used) with "syncedLyrics" -> parsed as LRC,
//     else "plainLyrics" -> plain, else "instrumental": true -> instrumental.
//   * otherwise the raw body: if it parses as LRC -> synced, else non-empty text -> plain.
// HTTP 404/204 or an empty body -> (nil, nil) = miss. Transport failures and other non-2xx
// statuses -> (nil, error). Completion fires exactly once, off the main thread.
#import "CLLyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const CLCustomEndpointErrorDomain;   // code == HTTP status

@interface CLCustomEndpointProvider : NSObject <CLLyricsProvider>
- (instancetype)initWithURLTemplate:(nullable NSString *)urlTemplate
                         headerName:(nullable NSString *)headerName
                        headerValue:(nullable NSString *)headerValue NS_DESIGNATED_INITIALIZER;
/// Creates a disabled provider; set urlTemplate later (e.g. from the prefs reload path).
- (instancetype)init;

/// Live-editable from the prefs reload path; empty template = provider disabled.
@property (nonatomic, copy, nullable) NSString *urlTemplate;
@property (nonatomic, copy, nullable) NSString *headerName;
@property (nonatomic, copy, nullable) NSString *headerValue;
/// Per-request timeout in seconds. Default 8.
@property (nonatomic) NSTimeInterval timeout;
/// YES when a request would actually be made for this configuration.
@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;

/// Pure decoder: a response body in, CLLyrics out. No network, no disk, no state beyond
/// `identifier`, safe on any thread and independent of `isEnabled`. This is the whole of the
/// response handling described above, exposed so the JSON-vs-raw-body branching can be pinned
/// down with fixtures instead of a live endpoint (tests/CLCustomEndpointProviderTests.m).
/// `response` only supplies the text encoding and may be nil (UTF-8 is then assumed).
/// nil means "this body carries no usable lyrics".
- (nullable CLLyrics *)lyricsFromData:(nullable NSData *)data
                             response:(nullable NSURLResponse *)response;
@end

NS_ASSUME_NONNULL_END
