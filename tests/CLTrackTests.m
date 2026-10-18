// Tests for CLTrack: -spotifyTrackID, -cacheKey and -isSameSongAs: (Tweak/Lyrics/CLLyricsTypes.m).
#import "CLTrackTests.h"
#import "CLTestCase.h"
#import "Lyrics/CLLyricsTypes.h"
#import <math.h>

static CLTrack *CLMakeTrack(NSString *title, NSString *artist, NSString *album,
                             NSTimeInterval duration, NSString *contentIdentifier) {
    CLTrack *track = [[CLTrack alloc] init];
    track.title = title;
    track.artist = artist;
    track.album = album;
    track.duration = duration;
    track.contentIdentifier = contentIdentifier;
    return track;
}

static void CLTestTrackSpotifyTrackID(void) {
    CLTrack *withUUID = CLMakeTrack(@"T", @"A", nil, 0,
        @"spotify:track:2K6Nk2bR9xPE39EY9mARVa#ECB12E3A-1234-5678-9ABC-DEF012345678");
    CL_ASSERT_EQ(withUUID.spotifyTrackID, @"2K6Nk2bR9xPE39EY9mARVa");

    CLTrack *noUUID = CLMakeTrack(@"T", @"A", nil, 0, @"spotify:track:abc123");
    CL_ASSERT_EQ(noUUID.spotifyTrackID, @"abc123");

    CLTrack *caseInsensitivePrefix = CLMakeTrack(@"T", @"A", nil, 0, @"SPOTIFY:TRACK:abcDEF123");
    CL_ASSERT_EQ(caseInsensitivePrefix.spotifyTrackID, @"abcDEF123");

    CLTrack *nonSpotify = CLMakeTrack(@"T", @"A", nil, 0, @"com.apple.music:1234-5678");
    CL_ASSERT_NIL(nonSpotify.spotifyTrackID);

    CLTrack *noContentIdentifier = CLMakeTrack(@"T", @"A", nil, 0, nil);
    CL_ASSERT_NIL(noContentIdentifier.spotifyTrackID);

    CLTrack *nonBase62 = CLMakeTrack(@"T", @"A", nil, 0, @"spotify:track:abc-123");
    CL_ASSERT_NIL(nonBase62.spotifyTrackID);

    CLTrack *emptyAfterPrefix = CLMakeTrack(@"T", @"A", nil, 0, @"spotify:track:");
    CL_ASSERT_NIL(emptyAfterPrefix.spotifyTrackID);

    CLTrack *emptyBeforeHash = CLMakeTrack(@"T", @"A", nil, 0, @"spotify:track:#justauuid");
    CL_ASSERT_NIL(emptyBeforeHash.spotifyTrackID);

    CLTrack *withStrayWhitespace = CLMakeTrack(@"T", @"A", nil, 0, @"spotify:track: abc123 ");
    CL_ASSERT_EQ(withStrayWhitespace.spotifyTrackID, @"abc123");

    CLTrack *tooShortPrefix = CLMakeTrack(@"T", @"A", nil, 0, @"spotify:track");
    CL_ASSERT_NIL(tooShortPrefix.spotifyTrackID);
}

static void CLTestTrackCacheKeyStability(void) {
    CLTrack *a = CLMakeTrack(@"Sweet Lies", @"Qendresa", @"Londra", 100.1, nil);
    CLTrack *b = CLMakeTrack(@"SWEET LIES", @"QENDRESA", @"Different Album", 100.4, nil);
    // Case-insensitive, album/bundle-independent, and 100.1/100.4 both round to 100.
    CL_ASSERT_EQ(a.cacheKey, b.cacheKey);
    CL_ASSERT_EQ(a.cacheKey.length, (NSUInteger)40);

    // 40 lowercase hex characters.
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    CL_ASSERT_TRUE([a.cacheKey rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound);

    CLTrack *roundsDifferently = CLMakeTrack(@"Sweet Lies", @"Qendresa", nil, 100.6, nil);
    CL_ASSERT_FALSE([a.cacheKey isEqualToString:roundsDifferently.cacheKey]);

    CLTrack *differentTitle = CLMakeTrack(@"Different Title", @"Qendresa", nil, 100.1, nil);
    CL_ASSERT_FALSE([a.cacheKey isEqualToString:differentTitle.cacheKey]);

    // Non-finite / negative durations both collapse to "unknown" (0).
    CLTrack *nanDuration = CLMakeTrack(@"X", @"Y", nil, NAN, nil);
    CLTrack *zeroDuration = CLMakeTrack(@"X", @"Y", nil, 0, nil);
    CLTrack *negativeDuration = CLMakeTrack(@"X", @"Y", nil, -5, nil);
    CL_ASSERT_EQ(nanDuration.cacheKey, zeroDuration.cacheKey);
    CL_ASSERT_EQ(negativeDuration.cacheKey, zeroDuration.cacheKey);
}

static void CLTestTrackIsSameSongAsTolerance(void) {
    CLTrack *a = CLMakeTrack(@"Song", @"Artist", nil, 200.0, nil);
    CLTrack *sameWithinTolerance = CLMakeTrack(@"SONG", @"ARTIST", nil, 201.5, nil);
    CLTrack *outsideTolerance = CLMakeTrack(@"Song", @"Artist", nil, 203.1, nil);
    CLTrack *differentTitle = CLMakeTrack(@"Other Song", @"Artist", nil, 200.0, nil);
    CLTrack *differentArtist = CLMakeTrack(@"Song", @"Other Artist", nil, 200.0, nil);
    CLTrack *unknownDuration = CLMakeTrack(@"Song", @"Artist", nil, 0, nil);

    CL_ASSERT_TRUE([a isSameSongAs:a]);                        // identical instance
    CL_ASSERT_TRUE([a isSameSongAs:sameWithinTolerance]);      // case-insensitive, <=2s apart
    CL_ASSERT_FALSE([a isSameSongAs:outsideTolerance]);        // >2s apart
    CL_ASSERT_FALSE([a isSameSongAs:differentTitle]);
    CL_ASSERT_FALSE([a isSameSongAs:differentArtist]);
    CL_ASSERT_TRUE([a isSameSongAs:unknownDuration]);          // one side doesn't know duration yet
    CL_ASSERT_TRUE([unknownDuration isSameSongAs:a]);          // symmetric for the "unknown" side
    CL_ASSERT_FALSE([a isSameSongAs:nil]);
}

static void CLTestTrackCopyIsIndependent(void) {
    CLTrack *original = CLMakeTrack(@"Song", @"Artist", @"Album", 123.0, @"spotify:track:abc#uuid");
    original.bundleIdentifier = @"com.spotify.client";
    CLTrack *copy = [original copy];

    CL_ASSERT_TRUE(copy != original);
    CL_ASSERT_EQ(copy.title, original.title);
    CL_ASSERT_EQ(copy.artist, original.artist);
    CL_ASSERT_EQ(copy.album, original.album);
    CL_ASSERT_NEAR(copy.duration, original.duration, 0.0001);
    CL_ASSERT_EQ(copy.bundleIdentifier, original.bundleIdentifier);
    CL_ASSERT_EQ(copy.contentIdentifier, original.contentIdentifier);
    CL_ASSERT_EQ(copy.cacheKey, original.cacheKey);

    copy.title = @"A different title entirely";
    CL_ASSERT_FALSE([original.title isEqualToString:copy.title]);
}

void CLRunTrackTests(void) {
    CLTestBeginSuite("CLTrack");
    CLTestTrackSpotifyTrackID();
    CLTestTrackCacheKeyStability();
    CLTestTrackIsSameSongAsTolerance();
    CLTestTrackCopyIsIndependent();
}
