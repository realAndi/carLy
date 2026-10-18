// CLLRCLibProvider.m — see CLLRCLibProvider.h for the lookup strategy.
//
// Safety notes: the session is ephemeral (nothing of the user's is written to disk, no cookies),
// every request carries an explicit timeout, the completion is wrapped so it can only fire once
// no matter how the steps interleave, and no lyric text is ever logged above debug level.
#import "CLLRCLibProvider.h"
#import "CLLRCParser.h"
#import "Util/CLLog.h"
#import <math.h>

#ifndef CL_VERSION
#define CL_VERSION "dev"
#endif

NSString *const CLLRCLibErrorDomain = @"com.andi.carly.lrclib";

static NSString *const kCLLRCLibBaseURL = @"https://lrclib.net";
static NSString *const kCLLRCLibRepository = @"https://github.com/realAndi/carLy";
static NSString *const kCLLRCLibIdentifier = @"lrclib";

#pragma mark - Small helpers

static NSString *CLTrimmedOrNil(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [value stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length ? trimmed : nil;
}

static NSString *CLJSONString(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *string = (NSString *)value;
    return string.length ? string : nil;
}

static double CLJSONNumber(id value) {
    if ([value isKindOfClass:[NSNumber class]]) {
        double number = [(NSNumber *)value doubleValue];
        return isfinite(number) ? number : 0;
    }
    if ([value isKindOfClass:[NSString class]]) {
        double number = [(NSString *)value doubleValue];
        return isfinite(number) ? number : 0;
    }
    return 0;
}

static BOOL CLJSONBool(id value) {
    return [value isKindOfClass:[NSNumber class]] && [(NSNumber *)value boolValue];
}

static NSTimeInterval CLSaneSeconds(NSTimeInterval value) {
    return (isfinite(value) && value > 0) ? value : 0;
}

/// Wraps a completion so that only the first call gets through (belt and braces around the
/// multi-step request flow; a double delivery would confuse the provider chain).
static CLLyricsCompletion CLOnceCompletion(CLLyricsCompletion completion) {
    NSObject *lock = [[NSObject alloc] init];
    __block CLLyricsCompletion pending = [completion copy];
    CLLyricsCompletion once = ^(CLLyrics *lyrics, NSError *error) {
        CLLyricsCompletion deliver = nil;
        @synchronized (lock) {
            deliver = pending;
            pending = nil;
        }
        if (deliver) deliver(lyrics, error);
    };
    return [once copy];
}

static NSURL *CLLRCLibURL(NSString *path, NSArray<NSURLQueryItem *> *items) {
    NSURLComponents *components = [NSURLComponents componentsWithString:kCLLRCLibBaseURL];
    if (!components) return nil;
    components.path = path;
    components.queryItems = items;
    NSString *query = components.percentEncodedQuery;
    if (query.length) {
        // NSURLComponents leaves '+' alone; on the wire that would decode as a space.
        components.percentEncodedQuery = [query stringByReplacingOccurrencesOfString:@"+"
                                                                         withString:@"%2B"];
    }
    return components.URL;
}

static NSError *CLLRCLibHTTPError(NSInteger status, NSURL *url) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = [NSString stringWithFormat:@"lrclib.net returned HTTP %ld",
                                       (long)status];
    if (url.absoluteString.length) info[NSURLErrorFailingURLStringErrorKey] = url.absoluteString;
    return [NSError errorWithDomain:CLLRCLibErrorDomain code:status userInfo:info];
}

#pragma mark -

@interface CLLRCLibProvider ()
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation CLLRCLibProvider

- (instancetype)init {
    self = [super init];
    if (self) {
        _timeout = 8.0;
        _durationTolerance = 3.0;

        NSString *client = [NSString stringWithFormat:@"carLy %s (%@)",
                            CL_VERSION, kCLLRCLibRepository];
        NSURLSessionConfiguration *configuration =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = _timeout;
        configuration.timeoutIntervalForResource = 20.0;
        configuration.HTTPShouldSetCookies = NO;
        configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.HTTPAdditionalHeaders = @{
            @"Lrclib-Client": client,
            @"User-Agent": client,
            @"Accept": @"application/json",
        };
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

- (void)dealloc {
    [_session finishTasksAndInvalidate];
}

- (NSString *)identifier {
    return kCLLRCLibIdentifier;
}

#pragma mark - CLLyricsProvider

- (void)fetchLyricsForTrack:(CLTrack *)track completion:(CLLyricsCompletion)completion {
    if (!completion) return;
    CLLyricsCompletion finish = CLOnceCompletion(completion);

    NSString *title = [track isKindOfClass:[CLTrack class]] ? CLTrimmedOrNil(track.title) : nil;
    NSString *artist = [track isKindOfClass:[CLTrack class]] ? CLTrimmedOrNil(track.artist) : nil;
    if (!title || !artist) {
        // Nothing to ask for. Stay asynchronous: providers must never call back inline.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ finish(nil, nil); });
        return;
    }

    NSString *album = CLTrimmedOrNil(track.album);
    NSTimeInterval duration = CLSaneSeconds(track.duration);

    dispatch_block_t runSearch = ^{
        [self searchWithTitle:title artist:artist duration:duration finish:finish];
    };
    dispatch_block_t runGetWithoutAlbum = ^{
        [self getWithTitle:title artist:artist album:nil duration:duration
                    onMiss:runSearch finish:finish];
    };

    if (duration <= 0) {
        // /api/get requires a duration to match against; go straight to the search endpoint.
        runSearch();
    } else if (album) {
        [self getWithTitle:title artist:artist album:album duration:duration
                    onMiss:runGetWithoutAlbum finish:finish];
    } else {
        runGetWithoutAlbum();
    }
}

#pragma mark - Steps

- (void)getWithTitle:(NSString *)title
              artist:(NSString *)artist
               album:(NSString *)album
            duration:(NSTimeInterval)duration
              onMiss:(dispatch_block_t)onMiss
              finish:(CLLyricsCompletion)finish {
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    [items addObject:[NSURLQueryItem queryItemWithName:@"track_name" value:title]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"artist_name" value:artist]];
    if (album.length) [items addObject:[NSURLQueryItem queryItemWithName:@"album_name" value:album]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"duration"
                                                 value:[NSString stringWithFormat:@"%ld",
                                                        lround(duration)]]];

    NSURL *url = CLLRCLibURL(@"/api/get", items);
    if (!url) {
        onMiss();
        return;
    }

    [self requestURL:url handler:^(id json, NSInteger status, NSError *error) {
        if (error) {
            CLLogInfo(@"[lrclib] /get transport error: %@", error.localizedDescription);
            finish(nil, error);
            return;
        }
        if (status == 404) {
            CLLogDebug(@"[lrclib] /get 404 (album=%@)", album.length ? album : @"-");
            onMiss();
            return;
        }
        if (status < 200 || status > 299) {
            CLLogInfo(@"[lrclib] /get HTTP %ld", (long)status);
            finish(nil, CLLRCLibHTTPError(status, url));
            return;
        }
        CLLyrics *lyrics = [self lyricsFromEntry:json];
        if (lyrics) {
            CLLogInfo(@"[lrclib] /get hit: kind=%ld lines=%lu",
                      (long)lyrics.kind, (unsigned long)lyrics.lines.count);
            finish(lyrics, nil);
        } else {
            CLLogDebug(@"[lrclib] /get 200 but no usable lyrics");
            onMiss();
        }
    }];
}

- (void)searchWithTitle:(NSString *)title
                 artist:(NSString *)artist
               duration:(NSTimeInterval)duration
                 finish:(CLLyricsCompletion)finish {
    NSArray<NSURLQueryItem *> *items = @[
        [NSURLQueryItem queryItemWithName:@"track_name" value:title],
        [NSURLQueryItem queryItemWithName:@"artist_name" value:artist],
    ];
    NSURL *url = CLLRCLibURL(@"/api/search", items);
    if (!url) {
        finish(nil, nil);
        return;
    }

    [self requestURL:url handler:^(id json, NSInteger status, NSError *error) {
        if (error) {
            CLLogInfo(@"[lrclib] /search transport error: %@", error.localizedDescription);
            finish(nil, error);
            return;
        }
        if (status == 404) {
            finish(nil, nil);
            return;
        }
        if (status < 200 || status > 299) {
            CLLogInfo(@"[lrclib] /search HTTP %ld", (long)status);
            finish(nil, CLLRCLibHTTPError(status, url));
            return;
        }
        if (![json isKindOfClass:[NSArray class]]) {
            finish(nil, nil);
            return;
        }
        CLLyrics *lyrics = [self lyricsFromSearchResults:(NSArray *)json duration:duration];
        if (lyrics) {
            CLLogInfo(@"[lrclib] /search hit: kind=%ld lines=%lu (of %lu candidates)",
                      (long)lyrics.kind, (unsigned long)lyrics.lines.count,
                      (unsigned long)[(NSArray *)json count]);
        } else {
            CLLogDebug(@"[lrclib] /search: no candidate matched");
        }
        finish(lyrics, nil);
    }];
}

- (void)requestURL:(NSURL *)url handler:(void (^)(id json, NSInteger status, NSError *error))handler {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = self.timeout > 0 ? self.timeout : 8.0;
    CLLogDebug(@"[lrclib] GET %@", url.absoluteString);

    NSURLSessionDataTask *task =
        [self.session dataTaskWithRequest:request
                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            handler(nil, 0, error);
            return;
        }
        NSInteger status = 0;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            status = ((NSHTTPURLResponse *)response).statusCode;
        }
        id json = nil;
        if (data.length) {
            json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        }
        handler(json, status, nil);
    }];
    [task resume];
}

#pragma mark - Decoding

/// One LRCLIB track object -> CLLyrics, or nil when the entry carries nothing usable.
- (CLLyrics *)lyricsFromEntry:(id)entry {
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dictionary = (NSDictionary *)entry;

    NSString *synced = CLJSONString(dictionary[@"syncedLyrics"]);
    NSString *plain = CLJSONString(dictionary[@"plainLyrics"]);

    if (synced.length) {
        NSArray<CLLyricLine *> *lines = [CLLRCParser parse:synced];
        if (lines.count) {
            CLLyrics *lyrics = [CLLyrics syncedWithLines:lines source:self.identifier];
            lyrics.plainText = plain.length ? plain : [CLLRCParser plainTextFromLines:lines];
            return lyrics;
        }
        CLLogDebug(@"[lrclib] syncedLyrics present but unparseable");
    }
    if (CLJSONBool(dictionary[@"instrumental"])) {
        return [CLLyrics instrumentalFromSource:self.identifier];
    }
    if (plain.length) {
        CLLyrics *lyrics = [CLLyrics plainWithText:plain source:self.identifier];
        return lyrics.kind == CLLyricsKindNone ? nil : lyrics;
    }
    return nil;
}

/// Picks the best /api/search candidate: synced beats plain beats instrumental, and within each
/// group the duration closest to ours wins. When our duration is unknown the first entry of the
/// best available group is used, which is LRCLIB's own relevance order.
- (CLLyrics *)lyricsFromSearchResults:(NSArray *)results duration:(NSTimeInterval)duration {
    if (results.count == 0) return nil;
    NSTimeInterval tolerance = self.durationTolerance > 0 ? self.durationTolerance : 3.0;

    NSDictionary *bestSynced = nil;
    NSDictionary *bestPlain = nil;
    NSDictionary *bestInstrumental = nil;
    double bestSyncedDelta = INFINITY;
    double bestPlainDelta = INFINITY;
    double bestInstrumentalDelta = INFINITY;

    for (id entry in results) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *candidate = (NSDictionary *)entry;

        double delta = 0;
        if (duration > 0) {
            double candidateDuration = CLJSONNumber(candidate[@"duration"]);
            if (candidateDuration <= 0) continue;          // cannot be verified -> skip
            delta = fabs(candidateDuration - duration);
            if (delta > tolerance) continue;
        }

        if (CLJSONString(candidate[@"syncedLyrics"]).length) {
            if (delta < bestSyncedDelta) {
                bestSyncedDelta = delta;
                bestSynced = candidate;
            }
        } else if (CLJSONString(candidate[@"plainLyrics"]).length) {
            if (delta < bestPlainDelta) {
                bestPlainDelta = delta;
                bestPlain = candidate;
            }
        } else if (CLJSONBool(candidate[@"instrumental"])) {
            if (delta < bestInstrumentalDelta) {
                bestInstrumentalDelta = delta;
                bestInstrumental = candidate;
            }
        }
    }

    NSDictionary *chosen = bestSynced ?: (bestPlain ?: bestInstrumental);
    return chosen ? [self lyricsFromEntry:chosen] : nil;
}

@end
