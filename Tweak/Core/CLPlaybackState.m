#import "Core/CLPlaybackState.h"

/// Two songs count as the same when their durations agree within this many seconds.
static const NSTimeInterval kCLDurationTolerance = 2.0;
/// Never extrapolate more than this (a stale timestamp after a long sleep must not run away).
static const NSTimeInterval kCLMaxExtrapolation = 86400.0;

static NSString *CLTrimmed(NSString *string) {
    if (![string isKindOfClass:NSString.class]) return @"";
    return [string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

/// Case/diacritic/width-insensitive form used when comparing titles and artists.
static NSString *CLFolded(NSString *string) {
    NSString *trimmed = CLTrimmed(string);
    if (trimmed.length == 0) return @"";
    return [trimmed stringByFoldingWithOptions:(NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch |
                                                NSWidthInsensitiveSearch)
                                        locale:nil];
}

/// "spotify:track:ID#UUID" -> "spotify:track:ID". The suffix changes on every play of the track.
static NSString *CLContentIdentity(NSString *identifier) {
    NSString *trimmed = CLTrimmed(identifier);
    if (trimmed.length == 0) return nil;
    NSRange hash = [trimmed rangeOfString:@"#"];
    if (hash.location == NSNotFound) return trimmed;
    if (hash.location == 0) return nil;
    return [trimmed substringToIndex:hash.location];
}

static BOOL CLStringsEqual(NSString *a, NSString *b) {
    if (a == b) return YES;
    if (a.length == 0 && b.length == 0) return YES;
    if (a.length == 0 || b.length == 0) return NO;
    return [a isEqualToString:b];
}

@implementation CLPlaybackState

- (instancetype)initWithTitle:(NSString *)title
                       artist:(NSString *)artist
                        album:(NSString *)album
                     duration:(NSTimeInterval)duration
                  elapsedTime:(NSTimeInterval)elapsedTime
                    timestamp:(NSDate *)timestamp
                 playbackRate:(double)playbackRate
             bundleIdentifier:(NSString *)bundleIdentifier
            contentIdentifier:(NSString *)contentIdentifier
                    isPlaying:(BOOL)isPlaying
              isAdvertisement:(BOOL)isAdvertisement
                       origin:(CLPlaybackStateOrigin)origin {
    self = [super init];
    if (!self) return nil;
    NSString *cleanTitle = CLTrimmed(title);
    NSString *cleanArtist = CLTrimmed(artist);
    NSString *cleanAlbum = CLTrimmed(album);
    NSString *cleanBundle = CLTrimmed(bundleIdentifier);
    NSString *cleanContent = CLTrimmed(contentIdentifier);
    _title = cleanTitle.length ? [cleanTitle copy] : nil;
    _artist = cleanArtist.length ? [cleanArtist copy] : nil;
    _album = cleanAlbum.length ? [cleanAlbum copy] : nil;
    _bundleIdentifier = cleanBundle.length ? [cleanBundle copy] : nil;
    _contentIdentifier = cleanContent.length ? [cleanContent copy] : nil;
    _duration = (isfinite(duration) && duration > 0) ? duration : 0;
    _elapsedTime = (isfinite(elapsedTime) && elapsedTime > 0) ? elapsedTime : 0;
    _timestamp = [timestamp isKindOfClass:NSDate.class] ? [timestamp copy] : nil;
    _playbackRate = isfinite(playbackRate) ? playbackRate : 0;
    _isPlaying = isPlaying;
    _isAdvertisement = isAdvertisement;
    _origin = origin;
    return self;
}

+ (instancetype)stateWithTitle:(NSString *)title
                        artist:(NSString *)artist
                         album:(NSString *)album
                      duration:(NSTimeInterval)duration
              bundleIdentifier:(NSString *)bundleIdentifier
             contentIdentifier:(NSString *)contentIdentifier
                        origin:(CLPlaybackStateOrigin)origin {
    return [[self alloc] initWithTitle:title
                                artist:artist
                                 album:album
                              duration:duration
                           elapsedTime:0
                             timestamp:nil
                          playbackRate:0
                      bundleIdentifier:bundleIdentifier
                     contentIdentifier:contentIdentifier
                             isPlaying:NO
                       isAdvertisement:NO
                                origin:origin];
}

+ (instancetype)emptyState {
    return [[self alloc] initWithTitle:nil
                                artist:nil
                                 album:nil
                              duration:0
                           elapsedTime:0
                             timestamp:nil
                          playbackRate:0
                      bundleIdentifier:nil
                     contentIdentifier:nil
                             isPlaying:NO
                       isAdvertisement:NO
                                origin:CLPlaybackStateOriginUnknown];
}

#pragma mark - Derived

- (double)effectiveRate {
    if (_playbackRate != 0.0) return _playbackRate;
    return _isPlaying ? 1.0 : 0.0;
}

- (BOOL)hasTrackInfo {
    return _title.length > 0;
}

- (NSString *)contentIdentity {
    return CLContentIdentity(_contentIdentifier);
}

- (NSInteger)informationScore {
    NSInteger score = 0;
    if (_title.length) score += 3;
    if (_artist.length) score += 3;
    if (_album.length) score += 1;
    if (_duration > 0) score += 2;
    if (_contentIdentifier.length) score += 3;
    if (_bundleIdentifier.length) score += 1;
    if (_timestamp) score += 2;
    return score;
}

- (NSTimeInterval)elapsedNow {
    NSTimeInterval elapsed = _elapsedTime;
    double rate = self.effectiveRate;
    if (_timestamp && rate != 0.0) {
        NSTimeInterval age = -[_timestamp timeIntervalSinceNow];
        if (!isfinite(age) || age < 0) age = 0;                       // future stamp / clock skew
        if (age > kCLMaxExtrapolation) age = kCLMaxExtrapolation;     // stale stamp after sleep
        elapsed += age * rate;
    }
    if (!isfinite(elapsed) || elapsed < 0) elapsed = 0;
    if (_duration > 0 && elapsed > _duration) elapsed = _duration;
    return elapsed;
}

- (CLTrack *)track {
    if (!self.hasTrackInfo) return nil;
    CLTrack *track = [[CLTrack alloc] init];
    track.title = _title ?: @"";
    track.artist = _artist ?: @"";
    track.album = _album;
    track.duration = _duration;
    track.bundleIdentifier = _bundleIdentifier;
    track.contentIdentifier = _contentIdentifier;
    return track;
}

#pragma mark - Comparison

- (BOOL)isSameSongAs:(CLPlaybackState *)other {
    if (other == self) return YES;
    if (![other isKindOfClass:CLPlaybackState.class]) return NO;

    NSString *mine = self.contentIdentity;
    NSString *theirs = other.contentIdentity;
    if (mine.length && theirs.length) return [mine isEqualToString:theirs];

    if (!self.hasTrackInfo || !other.hasTrackInfo) return NO;   // unknown is never "the same song"
    if (!CLStringsEqual(CLFolded(_title), CLFolded(other.title))) return NO;

    NSString *myArtist = CLFolded(_artist);
    NSString *theirArtist = CLFolded(other.artist);
    if (myArtist.length && theirArtist.length && ![myArtist isEqualToString:theirArtist]) return NO;

    if (_duration > 0 && other.duration > 0 &&
        fabs(_duration - other.duration) > kCLDurationTolerance) return NO;
    return YES;
}

- (BOOL)isEqualToPlaybackState:(CLPlaybackState *)other {
    if (other == self) return YES;
    if (![other isKindOfClass:CLPlaybackState.class]) return NO;
    if (!CLStringsEqual(_title, other.title)) return NO;
    if (!CLStringsEqual(_artist, other.artist)) return NO;
    if (!CLStringsEqual(_album, other.album)) return NO;
    if (!CLStringsEqual(_bundleIdentifier, other.bundleIdentifier)) return NO;
    if (!CLStringsEqual(_contentIdentifier, other.contentIdentifier)) return NO;
    if (fabs(_duration - other.duration) > 0.001) return NO;
    if (fabs(_elapsedTime - other.elapsedTime) > 0.001) return NO;
    if (fabs(_playbackRate - other.playbackRate) > 0.001) return NO;
    if (_isPlaying != other.isPlaying) return NO;
    if (_isAdvertisement != other.isAdvertisement) return NO;
    NSDate *otherStamp = other.timestamp;
    if ((_timestamp == nil) != (otherStamp == nil)) return NO;
    if (_timestamp && fabs([_timestamp timeIntervalSinceDate:otherStamp]) > 0.001) return NO;
    return YES;
}

- (BOOL)isEqual:(id)object {
    if (object == self) return YES;
    return [self isEqualToPlaybackState:object];
}

- (NSUInteger)hash {
    NSUInteger hash = CLFolded(_title).hash;
    hash = hash * 31 + CLFolded(_artist).hash;
    hash = hash * 31 + (NSUInteger)llround(_duration);
    hash = hash * 31 + (NSUInteger)(_isPlaying ? 1 : 0);
    return hash;
}

#pragma mark - Derivation

- (instancetype)stateByFillingGapsFrom:(CLPlaybackState *)other {
    if (![other isKindOfClass:CLPlaybackState.class] || other == self) return self;

    NSString *title = _title.length ? _title : other.title;
    NSString *artist = _artist.length ? _artist : other.artist;
    NSString *album = _album.length ? _album : other.album;
    NSString *bundle = _bundleIdentifier.length ? _bundleIdentifier : other.bundleIdentifier;
    NSString *content = _contentIdentifier.length ? _contentIdentifier : other.contentIdentifier;
    NSTimeInterval duration = _duration > 0 ? _duration : other.duration;

    // Only adopt the other sample's clock when we have none at all.
    NSTimeInterval elapsed = _elapsedTime;
    NSDate *stamp = _timestamp;
    double rate = _playbackRate;
    BOOL playing = _isPlaying;
    if (!_timestamp && other.timestamp) {
        elapsed = other.elapsedTime;
        stamp = other.timestamp;
        rate = other.playbackRate;
        playing = other.isPlaying;
    }

    CLPlaybackState *merged = [[CLPlaybackState alloc] initWithTitle:title
                                                             artist:artist
                                                              album:album
                                                           duration:duration
                                                        elapsedTime:elapsed
                                                          timestamp:stamp
                                                       playbackRate:rate
                                                   bundleIdentifier:bundle
                                                  contentIdentifier:content
                                                          isPlaying:playing
                                                    isAdvertisement:(_isAdvertisement || other.isAdvertisement)
                                                             origin:CLPlaybackStateOriginMerged];
    return [merged isEqualToPlaybackState:self] ? self : merged;
}

- (instancetype)stateByUpdatingElapsedTime:(NSTimeInterval)elapsedTime
                                 timestamp:(NSDate *)timestamp
                              playbackRate:(double)playbackRate
                                 isPlaying:(BOOL)isPlaying {
    return [[CLPlaybackState alloc] initWithTitle:_title
                                           artist:_artist
                                            album:_album
                                         duration:_duration
                                      elapsedTime:elapsedTime
                                        timestamp:timestamp
                                     playbackRate:playbackRate
                                 bundleIdentifier:_bundleIdentifier
                                contentIdentifier:_contentIdentifier
                                        isPlaying:isPlaying
                                  isAdvertisement:_isAdvertisement
                                           origin:_origin];
}

- (instancetype)stateBySettingBundleIdentifier:(NSString *)bundleIdentifier {
    NSString *clean = CLTrimmed(bundleIdentifier);
    if (CLStringsEqual(clean.length ? clean : nil, _bundleIdentifier)) return self;
    return [[CLPlaybackState alloc] initWithTitle:_title
                                           artist:_artist
                                            album:_album
                                         duration:_duration
                                      elapsedTime:_elapsedTime
                                        timestamp:_timestamp
                                     playbackRate:_playbackRate
                                 bundleIdentifier:clean
                                contentIdentifier:_contentIdentifier
                                        isPlaying:_isPlaying
                                  isAdvertisement:_isAdvertisement
                                           origin:_origin];
}

#pragma mark - NSCopying / description

- (id)copyWithZone:(NSZone *)zone {
    return self;   // immutable
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<CLPlaybackState %@ — %@ | %.1f/%.1fs rate=%.2f %@%@ app=%@ id=%@ origin=%ld>",
            _title ?: @"(no title)", _artist ?: @"(no artist)", self.elapsedNow, _duration,
            _playbackRate, _isPlaying ? @"playing" : @"paused", _isAdvertisement ? @" AD" : @"",
            _bundleIdentifier ?: @"?", self.contentIdentity ?: @"?", (long)_origin];
}

@end
