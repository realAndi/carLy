#import "Lyrics/CLMusicLibraryItem.h"
#import <math.h>

static NSString *CLNonEmptyOrNil(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length ? value : nil;
}

@implementation CLMusicLibraryItem

- (instancetype)initWithTitle:(NSString *)title
                     duration:(NSTimeInterval)duration
                       lyrics:(NSString *)lyrics
                     filePath:(NSString *)filePath {
    self = [super init];
    if (!self) return nil;
    _title = [CLNonEmptyOrNil(title) copy];
    _duration = (isfinite(duration) && duration > 0) ? duration : 0;
    _lyrics = [CLNonEmptyOrNil(lyrics) copy];
    _filePath = [CLNonEmptyOrNil(filePath) copy];
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<CLMusicLibraryItem %@ (%.0fs) lyrics=%lu chars file=%@>",
            _title ?: @"?", _duration, (unsigned long)_lyrics.length, _filePath.lastPathComponent ?: @"none"];
}

@end
