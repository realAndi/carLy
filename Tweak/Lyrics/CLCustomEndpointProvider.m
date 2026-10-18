// CLCustomEndpointProvider.m — see CLCustomEndpointProvider.h.
//
// Safety notes: only http/https templates are accepted (never file:, never a custom scheme), the
// response is capped so a hostile endpoint cannot balloon memory inside the CarPlay host, the
// session is ephemeral and cookie-less, and the user's header value is never logged.
#import "CLCustomEndpointProvider.h"
#import "CLLRCParser.h"
#import "Util/CLLog.h"
#import <math.h>

NSString *const CLCustomEndpointErrorDomain = @"com.andi.carly.custom";

static NSString *const kCLCustomIdentifier = @"custom";
static const NSUInteger kCLCustomMaxResponseBytes = 2 * 1024 * 1024;

#pragma mark - Helpers

static NSString *CLTrimmed(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [value stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length ? trimmed : nil;
}

static NSString *CLJSONText(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *string = (NSString *)value;
    return string.length ? string : nil;
}

/// Percent-escapes a value so it is safe inside a query component (and inside a path segment).
static NSString *CLEscapeForQuery(NSString *value) {
    static NSCharacterSet *allowed = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *set = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
        [set removeCharactersInString:@":/?#[]@!$&'()*+,;="];
        allowed = [set copy];
    });
    return [(value ?: @"") stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static NSString *CLReplacePlaceholder(NSString *template, NSString *placeholder, NSString *value) {
    return [template stringByReplacingOccurrencesOfString:placeholder
                                               withString:value
                                                  options:NSCaseInsensitiveSearch
                                                    range:NSMakeRange(0, template.length)];
}

static CLLyricsCompletion CLCustomOnceCompletion(CLLyricsCompletion completion) {
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

static NSString *CLDecodeBody(NSData *data, NSURLResponse *response) {
    if (data.length == 0) return nil;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        NSString *encodingName = response.textEncodingName;
        if (encodingName.length) {
            CFStringEncoding cfEncoding =
                CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)encodingName);
            if (cfEncoding != kCFStringEncodingInvalidId) {
                text = [[NSString alloc] initWithData:data
                                             encoding:CFStringConvertEncodingToNSStringEncoding(cfEncoding)];
            }
        }
    }
    if (!text) text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if ([text hasPrefix:@"﻿"]) text = [text substringFromIndex:1];
    return text.length ? text : nil;
}

static NSError *CLCustomHTTPError(NSInteger status, NSURL *url) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = [NSString stringWithFormat:@"custom endpoint returned HTTP %ld",
                                       (long)status];
    if (url.absoluteString.length) info[NSURLErrorFailingURLStringErrorKey] = url.absoluteString;
    return [NSError errorWithDomain:CLCustomEndpointErrorDomain code:status userInfo:info];
}

#pragma mark -

@interface CLCustomEndpointProvider ()
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation CLCustomEndpointProvider

- (instancetype)initWithURLTemplate:(NSString *)urlTemplate
                         headerName:(NSString *)headerName
                        headerValue:(NSString *)headerValue {
    self = [super init];
    if (self) {
        _urlTemplate = [urlTemplate copy];
        _headerName = [headerName copy];
        _headerValue = [headerValue copy];
        _timeout = 8.0;

        NSURLSessionConfiguration *configuration =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = _timeout;
        configuration.timeoutIntervalForResource = 20.0;
        configuration.HTTPShouldSetCookies = NO;
        configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

- (instancetype)init {
    return [self initWithURLTemplate:nil headerName:nil headerValue:nil];
}

- (void)dealloc {
    [_session finishTasksAndInvalidate];
}

- (NSString *)identifier {
    return kCLCustomIdentifier;
}

- (BOOL)isEnabled {
    NSString *template = CLTrimmed(self.urlTemplate);
    if (!template) return NO;
    NSString *lower = template.lowercaseString;
    return [lower hasPrefix:@"http://"] || [lower hasPrefix:@"https://"];
}

#pragma mark - CLLyricsProvider

- (void)fetchLyricsForTrack:(CLTrack *)track completion:(CLLyricsCompletion)completion {
    if (!completion) return;
    CLLyricsCompletion finish = CLCustomOnceCompletion(completion);

    NSURL *url = [self urlForTrack:track];
    if (!url) {
        // Disabled, or the template did not produce a usable http(s) URL. Stay asynchronous.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ finish(nil, nil); });
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = self.timeout > 0 ? self.timeout : 8.0;
    NSString *headerName = CLTrimmed(self.headerName);
    NSString *headerValue = self.headerValue;
    if (headerName && [headerValue isKindOfClass:[NSString class]] && headerValue.length) {
        [request setValue:headerValue forHTTPHeaderField:headerName];
    }
    CLLogDebug(@"[custom] GET %@", url.host ?: @"?");   // never log the full URL: it holds the query

    NSURLSessionDataTask *task =
        [self.session dataTaskWithRequest:request
                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            CLLogInfo(@"[custom] transport error: %@", error.localizedDescription);
            finish(nil, error);
            return;
        }
        NSInteger status = 0;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            status = ((NSHTTPURLResponse *)response).statusCode;
        }
        if (status == 404 || status == 204) {
            finish(nil, nil);
            return;
        }
        if (status != 0 && (status < 200 || status > 299)) {
            CLLogInfo(@"[custom] HTTP %ld", (long)status);
            finish(nil, CLCustomHTTPError(status, url));
            return;
        }
        if (data.length > kCLCustomMaxResponseBytes) {
            CLLogInfo(@"[custom] response too large (%lu bytes), ignored",
                      (unsigned long)data.length);
            finish(nil, nil);
            return;
        }
        CLLyrics *lyrics = [self lyricsFromData:data response:response];
        if (lyrics) {
            CLLogInfo(@"[custom] hit: kind=%ld lines=%lu",
                      (long)lyrics.kind, (unsigned long)lyrics.lines.count);
        }
        finish(lyrics, nil);
    }];
    [task resume];
}

#pragma mark - Request building

- (NSURL *)urlForTrack:(CLTrack *)track {
    if (!self.isEnabled) return nil;
    if (![track isKindOfClass:[CLTrack class]]) return nil;

    NSString *title = CLTrimmed(track.title);
    NSString *artist = CLTrimmed(track.artist);
    if (!title || !artist) return nil;

    NSTimeInterval duration = (isfinite(track.duration) && track.duration > 0) ? track.duration : 0;
    NSString *filled = CLTrimmed(self.urlTemplate);
    filled = CLReplacePlaceholder(filled, @"{artist}", CLEscapeForQuery(artist));
    filled = CLReplacePlaceholder(filled, @"{title}", CLEscapeForQuery(title));
    filled = CLReplacePlaceholder(filled, @"{album}", CLEscapeForQuery(CLTrimmed(track.album) ?: @""));
    filled = CLReplacePlaceholder(filled, @"{duration}",
                                  [NSString stringWithFormat:@"%ld", lround(duration)]);

    NSURL *url = [NSURL URLWithString:filled];
    NSString *scheme = url.scheme.lowercaseString;
    if (!url || !url.host.length || !([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"])) {
        CLLogInfo(@"[custom] template did not produce a usable http(s) URL");
        return nil;
    }
    return url;
}

#pragma mark - Decoding

- (CLLyrics *)lyricsFromData:(NSData *)data response:(NSURLResponse *)response {
    NSString *body = CLDecodeBody(data, response);
    NSString *trimmed = CLTrimmed(body);
    if (!trimmed) return nil;

    if ([trimmed hasPrefix:@"{"] || [trimmed hasPrefix:@"["]) {
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        NSDictionary *object = nil;
        if ([json isKindOfClass:[NSDictionary class]]) {
            object = (NSDictionary *)json;
        } else if ([json isKindOfClass:[NSArray class]]) {
            for (id entry in (NSArray *)json) {
                if ([entry isKindOfClass:[NSDictionary class]]) {
                    object = (NSDictionary *)entry;
                    break;
                }
            }
        }
        if (object) return [self lyricsFromJSONObject:object];
        if (json) return nil;   // valid JSON we cannot interpret -> miss, do not guess
    }

    return [self lyricsFromText:trimmed];
}

- (CLLyrics *)lyricsFromJSONObject:(NSDictionary *)object {
    NSString *synced = CLJSONText(object[@"syncedLyrics"]);
    NSString *plain = CLJSONText(object[@"plainLyrics"]);

    if (synced.length) {
        NSArray<CLLyricLine *> *lines = [CLLRCParser parse:synced];
        if (lines.count) {
            CLLyrics *lyrics = [CLLyrics syncedWithLines:lines source:self.identifier];
            lyrics.plainText = plain.length ? plain : [CLLRCParser plainTextFromLines:lines];
            return lyrics;
        }
    }
    id instrumental = object[@"instrumental"];
    if ([instrumental isKindOfClass:[NSNumber class]] && [(NSNumber *)instrumental boolValue]) {
        return [CLLyrics instrumentalFromSource:self.identifier];
    }
    if (plain.length) {
        CLLyrics *lyrics = [CLLyrics plainWithText:plain source:self.identifier];
        return lyrics.kind == CLLyricsKindNone ? nil : lyrics;
    }
    return nil;
}

- (CLLyrics *)lyricsFromText:(NSString *)text {
    NSArray<CLLyricLine *> *lines = [CLLRCParser parse:text];
    if (lines.count) {
        CLLyrics *lyrics = [CLLyrics syncedWithLines:lines source:self.identifier];
        lyrics.plainText = [CLLRCParser plainTextFromLines:lines];
        return lyrics;
    }
    CLLyrics *lyrics = [CLLyrics plainWithText:text source:self.identifier];
    return lyrics.kind == CLLyricsKindNone ? nil : lyrics;
}

@end
