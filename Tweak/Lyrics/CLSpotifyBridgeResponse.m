#import "CLSpotifyBridgeResponse.h"

static const NSInteger kCLResponseVersion = 1;
static NSString *const kCLStatusLyrics = @"lyrics";
static NSString *const kCLStatusNone = @"none";
static NSString *const kCLStatusError = @"error";

@interface CLSpotifyBridgeResponse ()
@property (nonatomic, readwrite) CLSpotifyBridgeResponseStatus status;
@property (nonatomic, readwrite, nullable) CLLyrics *lyrics;
@property (nonatomic, readwrite, copy, nullable) NSString *message;
@property (nonatomic, readwrite) NSInteger httpStatus;
@property (nonatomic, readwrite) NSTimeInterval respondedAt;
@end

@implementation CLSpotifyBridgeResponse

+ (instancetype)responseWithStatus:(CLSpotifyBridgeResponseStatus)status
                            lyrics:(CLLyrics *)lyrics
                           message:(NSString *)message
                        httpStatus:(NSInteger)httpStatus {
    CLSpotifyBridgeResponse *response = [[self alloc] init];
    response.status = status;
    response.lyrics = lyrics;
    response.message = message;
    response.httpStatus = httpStatus;
    response.respondedAt = [[NSDate date] timeIntervalSince1970];
    return response;
}

+ (instancetype)responseWithLyrics:(CLLyrics *)lyrics httpStatus:(NSInteger)httpStatus {
    if (!lyrics || lyrics.kind == CLLyricsKindNone) return nil;
    return [self responseWithStatus:CLSpotifyBridgeResponseStatusLyrics lyrics:lyrics message:nil httpStatus:httpStatus];
}

+ (instancetype)noLyricsWithHTTPStatus:(NSInteger)httpStatus {
    return [self responseWithStatus:CLSpotifyBridgeResponseStatusNoLyrics lyrics:nil message:nil httpStatus:httpStatus];
}

+ (instancetype)errorWithMessage:(NSString *)message httpStatus:(NSInteger)httpStatus {
    return [self responseWithStatus:CLSpotifyBridgeResponseStatusError
                             lyrics:nil
                            message:message.length > 0 ? message : @"unknown error"
                         httpStatus:httpStatus];
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithCapacity:6];
    dictionary[@"v"] = @(kCLResponseVersion);
    switch (self.status) {
        case CLSpotifyBridgeResponseStatusLyrics: dictionary[@"status"] = kCLStatusLyrics; break;
        case CLSpotifyBridgeResponseStatusNoLyrics: dictionary[@"status"] = kCLStatusNone; break;
        case CLSpotifyBridgeResponseStatusError: dictionary[@"status"] = kCLStatusError; break;
    }
    if (self.lyrics) dictionary[@"lyrics"] = [self.lyrics dictionaryRepresentation];
    if (self.message.length > 0) dictionary[@"message"] = self.message;
    dictionary[@"http"] = @(self.httpStatus);
    dictionary[@"at"] = @(self.respondedAt);
    return [dictionary copy];
}

+ (instancetype)responseWithDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;
    id version = dictionary[@"v"];
    if (![version isKindOfClass:[NSNumber class]] || [(NSNumber *)version integerValue] != kCLResponseVersion) return nil;

    id rawStatus = dictionary[@"status"];
    if (![rawStatus isKindOfClass:[NSString class]]) return nil;
    CLSpotifyBridgeResponseStatus status;
    CLLyrics *lyrics = nil;
    if ([rawStatus isEqualToString:kCLStatusLyrics]) {
        status = CLSpotifyBridgeResponseStatusLyrics;
        id rawLyrics = dictionary[@"lyrics"];
        lyrics = [rawLyrics isKindOfClass:[NSDictionary class]] ? [CLLyrics lyricsWithDictionary:rawLyrics] : nil;
        if (!lyrics || lyrics.kind == CLLyricsKindNone) return nil;
    } else if ([rawStatus isEqualToString:kCLStatusNone]) {
        status = CLSpotifyBridgeResponseStatusNoLyrics;
    } else if ([rawStatus isEqualToString:kCLStatusError]) {
        status = CLSpotifyBridgeResponseStatusError;
    } else {
        return nil;
    }

    id message = dictionary[@"message"];
    id http = dictionary[@"http"];
    id at = dictionary[@"at"];
    CLSpotifyBridgeResponse *response = [[self alloc] init];
    response.status = status;
    response.lyrics = lyrics;
    response.message = [message isKindOfClass:[NSString class]] ? message : nil;
    response.httpStatus = [http isKindOfClass:[NSNumber class]] ? [(NSNumber *)http integerValue] : 0;
    response.respondedAt = [at isKindOfClass:[NSNumber class]] ? [(NSNumber *)at doubleValue] : 0;
    return response;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<CLSpotifyBridgeResponse status=%ld http=%ld lines=%lu%@>",
            (long)self.status, (long)self.httpStatus, (unsigned long)self.lyrics.lines.count,
            self.message.length > 0 ? [@" " stringByAppendingString:self.message] : @""];
}

@end
