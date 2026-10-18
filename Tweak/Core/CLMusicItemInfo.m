#import "Core/CLMusicItemInfo.h"
#import <math.h>

static NSString *CLTrimmedOrNil(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length ? trimmed : nil;
}

static BOOL CLSameText(NSString *lhs, NSString *rhs) {
    NSString *left = CLTrimmedOrNil(lhs) ?: @"";
    NSString *right = CLTrimmedOrNil(rhs) ?: @"";
    return [left caseInsensitiveCompare:right] == NSOrderedSame;
}

static NSTimeInterval CLSaneSeconds(NSTimeInterval value) {
    return (isfinite(value) && value > 0) ? value : 0;
}

@implementation CLMusicItemInfo

- (instancetype)initWithTitle:(NSString *)title
                       artist:(NSString *)artist
                     duration:(NSTimeInterval)duration
              storeIdentifier:(long long)storeIdentifier
       subscriptionIdentifier:(long long)subscriptionIdentifier
             lyricsIdentifier:(long long)lyricsIdentifier
           lyricsAvailability:(CLMusicLyricsAvailability)lyricsAvailability
          libraryPersistentID:(unsigned long long)libraryPersistentID {
    self = [super init];
    if (!self) return nil;
    _title = [CLTrimmedOrNil(title) copy];
    _artist = [CLTrimmedOrNil(artist) copy];
    _duration = CLSaneSeconds(duration);
    _storeIdentifier = MAX(storeIdentifier, 0LL);
    _subscriptionIdentifier = MAX(subscriptionIdentifier, 0LL);
    _lyricsIdentifier = MAX(lyricsIdentifier, 0LL);
    _lyricsAvailability = lyricsAvailability;
    // legacyUniqueIdentifier falls back to a store id for catalog items (MPAVItem
    // _updateContentItemIncludingPlaybackState:), which is not a library item.
    BOOL isStoreID = libraryPersistentID != 0 &&
        (libraryPersistentID == (unsigned long long)_storeIdentifier ||
         libraryPersistentID == (unsigned long long)_subscriptionIdentifier);
    _libraryPersistentID = isStoreID ? 0 : libraryPersistentID;
    _recordedAt = CFAbsoluteTimeGetCurrent();
    return self;
}

- (long long)preferredLyricsIdentifier {
    if (_lyricsIdentifier > 0) return _lyricsIdentifier;
    if (_subscriptionIdentifier > 0) return _subscriptionIdentifier;
    return _storeIdentifier;
}

- (BOOL)describesTrack:(CLTrack *)track {
    if (![track isKindOfClass:[CLTrack class]] || !_title) return NO;
    if (!CLSameText(_title, track.title) || !CLSameText(_artist, track.artist)) return NO;
    NSTimeInterval theirs = CLSaneSeconds(track.duration);
    if (_duration <= 0 || theirs <= 0) return YES;
    return fabs(_duration - theirs) <= 2.0;
}

- (BOOL)isEquivalentToInfo:(CLMusicItemInfo *)other {
    if (![other isKindOfClass:[CLMusicItemInfo class]]) return NO;
    return CLSameText(_title, other.title) && CLSameText(_artist, other.artist) &&
           fabs(_duration - other.duration) < 0.5 &&
           _storeIdentifier == other.storeIdentifier &&
           _subscriptionIdentifier == other.subscriptionIdentifier &&
           _lyricsIdentifier == other.lyricsIdentifier &&
           _lyricsAvailability == other.lyricsAvailability &&
           _libraryPersistentID == other.libraryPersistentID;
}

- (NSString *)description {
    static NSString *const availability[] = { @"?", @"yes", @"no" };
    NSInteger index = (_lyricsAvailability >= 0 && _lyricsAvailability <= 2) ? _lyricsAvailability : 0;
    return [NSString stringWithFormat:@"<CLMusicItemInfo %@ — %@ (%.0fs) store=%lld sub=%lld lyricsID=%lld lyrics=%@ pid=%llu>",
            _artist ?: @"?", _title ?: @"?", _duration, _storeIdentifier, _subscriptionIdentifier,
            _lyricsIdentifier, availability[index], _libraryPersistentID];
}

@end
