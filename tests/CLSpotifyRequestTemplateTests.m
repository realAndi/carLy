// Tests for CLSpotifyRequestTemplate (Tweak/Lyrics/CLSpotifyRequestTemplate.m): what carLy in
// Spotify learns from Spotify's own API requests, and the lyrics request it builds from them. Every
// token here is a made-up string; the class never sees a real one outside Spotify.
#import "CLSpotifyRequestTemplateTests.h"
#import "CLTestCase.h"
#import "Lyrics/CLSpotifyRequestTemplate.h"

static NSURLRequest *CLSpotifyRequest(NSString *url, NSDictionary<NSString *, NSString *> *headers) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        [request setValue:value forHTTPHeaderField:name];
    }];
    return request;
}

static NSDictionary *CLSpotifyHeaders(NSString *token) {
    return @{ @"Authorization": [@"Bearer " stringByAppendingString:token],
              @"client-token": @"client-token-1",
              @"User-Agent": @"Spotify/9.1.82 iOS/17.3 (iPhone16,1)",
              @"App-Platform": @"iOS",
              @"Accept-Language": @"en",
              @"Content-Type": @"application/x-protobuf",
              @"Content-Length": @"42",
              @"If-None-Match": @"\"etag\"",
              @"Cookie": @"sp_t=abc",
              @"Accept-Encoding": @"gzip" };
}

static void TestHosts(void) {
    CL_ASSERT_TRUE([CLSpotifyRequestTemplate isSpotifyAPIHost:@"gew1-spclient.spotify.com"]);
    CL_ASSERT_TRUE([CLSpotifyRequestTemplate isSpotifyAPIHost:@"spclient.wg.spotify.com"]);
    CL_ASSERT_TRUE([CLSpotifyRequestTemplate isSpotifyAPIHost:@"GUC3-SPCLIENT.SPOTIFY.COM"]);
    CL_ASSERT_FALSE([CLSpotifyRequestTemplate isSpotifyAPIHost:@"api.spotify.com"]);
    CL_ASSERT_FALSE([CLSpotifyRequestTemplate isSpotifyAPIHost:@"i.scdn.co"]);
    CL_ASSERT_FALSE([CLSpotifyRequestTemplate isSpotifyAPIHost:@"spclient.spotify.com.evil.example"]);
    CL_ASSERT_FALSE([CLSpotifyRequestTemplate isSpotifyAPIHost:nil]);
}

static void TestIgnoresWhatItShouldNotLearnFrom(void) {
    CLSpotifyRequestTemplate *template = [[CLSpotifyRequestTemplate alloc] init];
    CL_ASSERT_FALSE([template observeRequest:nil]);
    // Not an API host, no Bearer, not https.
    CL_ASSERT_FALSE([template observeRequest:CLSpotifyRequest(@"https://i.scdn.co/image/ab67", CLSpotifyHeaders(@"t1"))]);
    CL_ASSERT_FALSE([template observeRequest:CLSpotifyRequest(@"https://gew1-spclient.spotify.com/metadata/4/track/x",
                                                              @{ @"Authorization": @"Basic Zm9vOmJhcg==" })]);
    CL_ASSERT_FALSE([template observeRequest:CLSpotifyRequest(@"https://gew1-spclient.spotify.com/metadata/4/track/x", @{})]);
    CL_ASSERT_FALSE([template observeRequest:CLSpotifyRequest(@"http://gew1-spclient.spotify.com/metadata/4/track/x",
                                                              CLSpotifyHeaders(@"t1"))]);
    // Our own lyrics request.
    NSMutableURLRequest *own = [CLSpotifyRequest(@"https://gew1-spclient.spotify.com/color-lyrics/v2/track/x",
                                                 CLSpotifyHeaders(@"t1")) mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:CLSpotifyOwnRequestProperty inRequest:own];
    CL_ASSERT_FALSE([template observeRequest:own]);

    CL_ASSERT_FALSE(template.hasAuthorization);
    CL_ASSERT_NIL([template lyricsRequestForTrackID:@"2K6Nk2bR9xPE39EY9mARVa"]);
}

static void TestBuildsFromAnyAuthorisedRequest(void) {
    CLSpotifyRequestTemplate *template = [[CLSpotifyRequestTemplate alloc] init];
    CL_ASSERT_TRUE([template observeRequest:CLSpotifyRequest(@"https://gew1-spclient.spotify.com/metadata/4/track/abc?market=from_token",
                                                             CLSpotifyHeaders(@"token-1"))]);
    CL_ASSERT_TRUE(template.hasAuthorization);
    CL_ASSERT_EQ(template.host, @"gew1-spclient.spotify.com");
    CL_ASSERT_FALSE(template.hasLyricsRequestShape);
    CL_ASSERT_TRUE(template.authorizationSeenAt > 0);
    // The same token again changes nothing worth telling the service about.
    CL_ASSERT_FALSE([template observeRequest:CLSpotifyRequest(@"https://gew1-spclient.spotify.com/other",
                                                              CLSpotifyHeaders(@"token-1"))]);

    NSURLRequest *request = [template lyricsRequestForTrackID:@"2K6Nk2bR9xPE39EY9mARVa"];
    CL_ASSERT_NOT_NIL(request);
    CL_ASSERT_EQ(request.HTTPMethod, @"GET");
    CL_ASSERT_EQ(request.URL.absoluteString,
                 @"https://gew1-spclient.spotify.com/color-lyrics/v2/track/2K6Nk2bR9xPE39EY9mARVa?format=json&vocalRemoval=false&market=from_token");
    CL_ASSERT_EQ([request valueForHTTPHeaderField:@"Authorization"], @"Bearer token-1");
    CL_ASSERT_EQ([request valueForHTTPHeaderField:@"client-token"], @"client-token-1");
    CL_ASSERT_EQ([request valueForHTTPHeaderField:@"App-Platform"], @"iOS");
    CL_ASSERT_EQ([request valueForHTTPHeaderField:@"User-Agent"], @"Spotify/9.1.82 iOS/17.3 (iPhone16,1)");
    CL_ASSERT_EQ([request valueForHTTPHeaderField:@"Accept"], @"application/json");
    // The request-specific headers are not replayed.
    CL_ASSERT_NIL([request valueForHTTPHeaderField:@"Content-Type"]);
    CL_ASSERT_NIL([request valueForHTTPHeaderField:@"Content-Length"]);
    CL_ASSERT_NIL([request valueForHTTPHeaderField:@"If-None-Match"]);
    CL_ASSERT_NIL([request valueForHTTPHeaderField:@"Cookie"]);
    CL_ASSERT_NIL([request valueForHTTPHeaderField:@"Accept-Encoding"]);
    CL_ASSERT_FALSE(request.HTTPShouldHandleCookies);
    CL_ASSERT_NOT_NIL([NSURLProtocol propertyForKey:CLSpotifyOwnRequestProperty inRequest:request]);
    // And it is never learnt from.
    CL_ASSERT_FALSE([template observeRequest:request]);

    // Invalid ids build nothing.
    CL_ASSERT_NIL([template lyricsRequestForTrackID:@"../../x"]);
    CL_ASSERT_NIL([template lyricsRequestForTrackID:@""]);
}

static void TestCopiesSpotifysOwnLyricsRequest(void) {
    CLSpotifyRequestTemplate *template = [[CLSpotifyRequestTemplate alloc] init];
    [template observeRequest:CLSpotifyRequest(@"https://gew1-spclient.spotify.com/metadata/4/track/abc", CLSpotifyHeaders(@"token-1"))];
    NSMutableDictionary *lyricsHeaders = [CLSpotifyHeaders(@"token-1") mutableCopy];
    lyricsHeaders[@"Accept"] = @"application/protobuf";
    CL_ASSERT_TRUE([template observeRequest:CLSpotifyRequest(@"https://guc3-spclient.spotify.com/color-lyrics/v2/track/OtherTrack0000000000000?clientLanguage=en",
                                                             lyricsHeaders)]);
    CL_ASSERT_TRUE(template.hasLyricsRequestShape);

    // A newer token on any later request replaces the one the lyrics request carried; its host,
    // query and Accept stay.
    CL_ASSERT_TRUE([template observeRequest:CLSpotifyRequest(@"https://gew1-spclient.spotify.com/metadata/4/track/def",
                                                             CLSpotifyHeaders(@"token-2"))]);
    NSURLRequest *request = [template lyricsRequestForTrackID:@"2K6Nk2bR9xPE39EY9mARVa"];
    CL_ASSERT_EQ(request.URL.absoluteString,
                 @"https://guc3-spclient.spotify.com/color-lyrics/v2/track/2K6Nk2bR9xPE39EY9mARVa?clientLanguage=en");
    CL_ASSERT_EQ([request valueForHTTPHeaderField:@"Accept"], @"application/protobuf");
    CL_ASSERT_EQ([request valueForHTTPHeaderField:@"Authorization"], @"Bearer token-2");
    CL_ASSERT_EQ(template.host, @"guc3-spclient.spotify.com");
}

static void TestRejectedToken(void) {
    CLSpotifyRequestTemplate *template = [[CLSpotifyRequestTemplate alloc] init];
    [template observeRequest:CLSpotifyRequest(@"https://gew1-spclient.spotify.com/a", CLSpotifyHeaders(@"stale"))];
    NSURLRequest *refused = [template lyricsRequestForTrackID:@"2K6Nk2bR9xPE39EY9mARVa"];
    [template rejectAuthorizationOfRequest:refused];
    CL_ASSERT_FALSE(template.hasAuthorization);
    CL_ASSERT_NIL([template lyricsRequestForTrackID:@"2K6Nk2bR9xPE39EY9mARVa"]);
    // Spotify still sending the refused token does not bring it back...
    CL_ASSERT_FALSE([template observeRequest:CLSpotifyRequest(@"https://gew1-spclient.spotify.com/b", CLSpotifyHeaders(@"stale"))]);
    CL_ASSERT_FALSE(template.hasAuthorization);
    // ...a fresh one does.
    CL_ASSERT_TRUE([template observeRequest:CLSpotifyRequest(@"https://gew1-spclient.spotify.com/c", CLSpotifyHeaders(@"fresh"))]);
    CL_ASSERT_EQ([[template lyricsRequestForTrackID:@"2K6Nk2bR9xPE39EY9mARVa"] valueForHTTPHeaderField:@"Authorization"],
                 @"Bearer fresh");
    // The description never shows a token.
    CL_ASSERT_TRUE([template.description rangeOfString:@"fresh"].location == NSNotFound);
}

void CLRunSpotifyRequestTemplateTests(void) {
    CLTestBeginSuite("CLSpotifyRequestTemplate");
    TestHosts();
    TestIgnoresWhatItShouldNotLearnFrom();
    TestBuildsFromAnyAuthorisedRequest();
    TestCopiesSpotifysOwnLyricsRequest();
    TestRejectedToken();
}
