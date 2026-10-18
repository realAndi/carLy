#import "CLSpotifyRequestTemplate.h"
#import "CLSpotifyBridge.h"

#import <os/lock.h>

NSString *const CLSpotifyOwnRequestProperty = @"CLSpotifyOwnRequest";

/// The web player's lyrics query (format=json is what makes the API answer in JSON).
static NSString *const kCLFallbackLyricsQuery = @"format=json&vocalRemoval=false&market=from_token";
static const NSTimeInterval kCLLyricsRequestTimeout = 8.0;

/// Header lookup that ignores case, as HTTP does. nil unless the value is a non-empty string.
static NSString *CLHeaderValue(NSDictionary *headers, NSString *name) {
    if (![headers isKindOfClass:[NSDictionary class]]) return nil;
    for (id key in headers) {
        if (![key isKindOfClass:[NSString class]] || [(NSString *)key caseInsensitiveCompare:name] != NSOrderedSame) continue;
        id value = headers[key];
        return ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) ? value : nil;
    }
    return nil;
}

static BOOL CLIsBearer(NSString *authorization) {
    return authorization.length > 7 &&
           [authorization rangeOfString:@"Bearer " options:NSCaseInsensitiveSearch | NSAnchoredSearch].location == 0;
}

/// Spotify's headers minus the ones that describe *that* request rather than the client: its body,
/// its connection, its cache validators (a replayed If-None-Match would get a bodiless 304), cookies,
/// and the login, which -lyricsRequestForTrackID: sets from the newest values on its own.
static NSDictionary<NSString *, NSString *> *CLReplayableHeaders(NSDictionary *headers) {
    static NSSet<NSString *> *dropped;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dropped = [NSSet setWithArray:@[ @"authorization", @"client-token", @"host", @"connection", @"keep-alive",
                                         @"transfer-encoding", @"te", @"upgrade", @"expect", @"cookie",
                                         @"accept-encoding", @"range", @"if-none-match", @"if-modified-since",
                                         @"if-match", @"if-unmodified-since", @"if-range" ]];
    });
    NSMutableDictionary<NSString *, NSString *> *kept = [NSMutableDictionary dictionaryWithCapacity:headers.count];
    for (id key in headers) {
        id value = headers[key];
        if (![key isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSString class]]) continue;
        NSString *name = [(NSString *)key lowercaseString];
        if ([dropped containsObject:name] || [name hasPrefix:@"content-"] || [name hasPrefix:@"proxy-"]) continue;
        kept[key] = value;
    }
    return [kept copy];
}

@implementation CLSpotifyRequestTemplate {
    os_unfair_lock _lock;
    NSString *_authorization;
    NSString *_clientToken;
    /// The token the API last answered 401 to; requests still carrying it are not learnt from.
    NSString *_rejectedAuthorization;
    NSString *_host;
    NSDictionary<NSString *, NSString *> *_headers;
    NSTimeInterval _authorizationSeenAt;
    // Spotify's own color-lyrics request, once seen.
    NSString *_lyricsHost;
    NSString *_lyricsQuery;
    NSDictionary<NSString *, NSString *> *_lyricsHeaders;
}

+ (instancetype)sharedTemplate {
    static CLSpotifyRequestTemplate *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) _lock = OS_UNFAIR_LOCK_INIT;
    return self;
}

+ (BOOL)isSpotifyAPIHost:(NSString *)host {
    if (host.length == 0) return NO;
    NSString *lower = host.lowercaseString;
    return [lower hasSuffix:@".spotify.com"] && [lower rangeOfString:@"spclient"].location != NSNotFound;
}

- (BOOL)observeRequest:(NSURLRequest *)request {
    NSURL *url = request.URL;
    if (!url || ![CLSpotifyRequestTemplate isSpotifyAPIHost:url.host]) return NO;
    if ([url.scheme caseInsensitiveCompare:@"https"] != NSOrderedSame) return NO;
    if ([NSURLProtocol propertyForKey:CLSpotifyOwnRequestProperty inRequest:request]) return NO;

    NSDictionary *headers = request.allHTTPHeaderFields;
    NSString *authorization = CLHeaderValue(headers, @"Authorization");
    if (!CLIsBearer(authorization)) return NO;
    NSString *clientToken = CLHeaderValue(headers, @"client-token");
    NSDictionary<NSString *, NSString *> *replayable = CLReplayableHeaders(headers);
    NSString *host = url.host.lowercaseString;
    BOOL isLyrics = [url.path rangeOfString:@"/color-lyrics/"].location != NSNotFound;
    NSString *query = url.query;

    os_unfair_lock_lock(&_lock);
    if ([authorization isEqualToString:_rejectedAuthorization]) {
        os_unfair_lock_unlock(&_lock);
        return NO;
    }
    BOOL changed = ![authorization isEqualToString:_authorization] || ![host isEqualToString:_host] ||
                   (isLyrics && !_lyricsHeaders);
    _authorization = authorization;
    if (clientToken) _clientToken = clientToken;
    _host = host;
    _headers = replayable;
    _authorizationSeenAt = [[NSDate date] timeIntervalSince1970];
    if (isLyrics) {
        _lyricsHost = host;
        _lyricsQuery = query;
        _lyricsHeaders = replayable;
    }
    os_unfair_lock_unlock(&_lock);
    return changed;
}

- (BOOL)hasAuthorization {
    os_unfair_lock_lock(&_lock);
    BOOL has = _authorization != nil && _host != nil;
    os_unfair_lock_unlock(&_lock);
    return has;
}

- (NSString *)host {
    os_unfair_lock_lock(&_lock);
    NSString *host = _lyricsHeaders ? _lyricsHost : _host;
    os_unfair_lock_unlock(&_lock);
    return host;
}

- (NSTimeInterval)authorizationSeenAt {
    os_unfair_lock_lock(&_lock);
    NSTimeInterval seenAt = _authorization ? _authorizationSeenAt : 0;
    os_unfair_lock_unlock(&_lock);
    return seenAt;
}

- (BOOL)hasLyricsRequestShape {
    os_unfair_lock_lock(&_lock);
    BOOL has = _lyricsHeaders != nil;
    os_unfair_lock_unlock(&_lock);
    return has;
}

- (NSURLRequest *)lyricsRequestForTrackID:(NSString *)trackID {
    if (![CLSpotifyBridge isValidTrackID:trackID]) return nil;

    os_unfair_lock_lock(&_lock);
    NSString *authorization = _authorization;
    NSString *clientToken = _clientToken;
    BOOL exact = _lyricsHeaders != nil;
    NSString *host = exact ? _lyricsHost : _host;
    NSString *query = exact ? _lyricsQuery : kCLFallbackLyricsQuery;
    NSDictionary<NSString *, NSString *> *headers = exact ? _lyricsHeaders : _headers;
    os_unfair_lock_unlock(&_lock);
    if (!authorization || host.length == 0) return nil;

    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"https";
    components.host = host;
    components.path = [@"/color-lyrics/v2/track/" stringByAppendingString:trackID];
    @try {
        // NSURL handed us this query already percent-encoded; the setter raises on anything that is not.
        if (query.length > 0) components.percentEncodedQuery = query;
    } @catch (NSException *exception) {
        components.percentEncodedQuery = kCLFallbackLyricsQuery;
    }
    NSURL *url = components.URL;
    if (!url) return nil;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:kCLLyricsRequestTimeout];
    request.HTTPMethod = @"GET";
    request.HTTPShouldHandleCookies = NO;
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        [request setValue:value forHTTPHeaderField:name];
    }];
    if (!exact) [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:authorization forHTTPHeaderField:@"Authorization"];
    if (clientToken) [request setValue:clientToken forHTTPHeaderField:@"client-token"];
    [NSURLProtocol setProperty:@YES forKey:CLSpotifyOwnRequestProperty inRequest:request];
    return [request copy];
}

- (void)rejectAuthorizationOfRequest:(NSURLRequest *)request {
    NSString *authorization = CLHeaderValue(request.allHTTPHeaderFields, @"Authorization");
    if (!authorization) return;
    os_unfair_lock_lock(&_lock);
    _rejectedAuthorization = authorization;
    if ([authorization isEqualToString:_authorization]) {
        _authorization = nil;
        _authorizationSeenAt = 0;
    }
    os_unfair_lock_unlock(&_lock);
}

- (NSString *)description {
    // Deliberately says nothing about the token itself.
    return [NSString stringWithFormat:@"<CLSpotifyRequestTemplate authorized=%d host=%@ lyricsShape=%d>",
            self.hasAuthorization, self.host ?: @"-", self.hasLyricsRequestShape];
}

@end
