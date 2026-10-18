#import "Lyrics/CLProviderFactory.h"
#import "Lyrics/CLAppleMusicProvider.h"
#import "Lyrics/CLCustomEndpointProvider.h"
#import "Lyrics/CLEmbeddedLyricsProvider.h"
#import "Lyrics/CLLRCLibProvider.h"
#import "Lyrics/CLSpotifyAppProvider.h"
#import "Lyrics/CLSpotifyCacheProvider.h"
#import "Util/CLLog.h"

NSString *const CLProviderIdentifierEmbedded = @"embedded";
NSString *const CLProviderIdentifierAppleMusic = @"apple-music";
NSString *const CLProviderIdentifierSpotify = @"spotify";
NSString *const CLProviderIdentifierSpotifyCache = @"spotify-cache";
NSString *const CLProviderIdentifierLRCLib = @"lrclib";
NSString *const CLProviderIdentifierCustom = @"custom";

@implementation CLProviderFactory

+ (NSArray<NSString *> *)defaultOrder {
    return @[ CLProviderIdentifierEmbedded, CLProviderIdentifierAppleMusic, CLProviderIdentifierSpotify,
              CLProviderIdentifierSpotifyCache, CLProviderIdentifierLRCLib, CLProviderIdentifierCustom ];
}

/// Sources added after the Source Order page first shipped. That page always saves every source it
/// knows, so a saved order without these was written by an older version, not by a user who left
/// them out.
+ (NSArray<NSString *> *)identifiersAddedLater {
    return @[ CLProviderIdentifierEmbedded, CLProviderIdentifierAppleMusic, CLProviderIdentifierSpotify ];
}

/// `order` with every source from +identifiersAddedLater that it does not list put where
/// +defaultOrder would run it relative to the listed ones: right before the first listed source
/// that comes after it there, or at the end.
+ (NSArray *)orderAddingLaterIdentifiers:(NSArray *)order {
    NSArray<NSString *> *defaults = [self defaultOrder];
    NSMutableArray *upgraded = [order mutableCopy];
    for (NSString *added in [self identifiersAddedLater]) {
        BOOL listed = NO;
        for (id entry in upgraded) {
            if ([entry isKindOfClass:[NSString class]] &&
                [(NSString *)entry caseInsensitiveCompare:added] == NSOrderedSame) {
                listed = YES;
                break;
            }
        }
        if (listed) continue;
        NSUInteger rank = [defaults indexOfObject:added];
        NSUInteger position = upgraded.count;
        for (NSUInteger index = 0; index < upgraded.count; index++) {
            id entry = upgraded[index];
            if (![entry isKindOfClass:[NSString class]]) continue;
            NSUInteger entryRank = [defaults indexOfObject:[(NSString *)entry lowercaseString]];
            if (entryRank != NSNotFound && entryRank > rank) {
                position = index;
                break;
            }
        }
        [upgraded insertObject:added atIndex:position];
    }
    return [upgraded copy];
}

+ (NSArray<NSString *> *)identifiersForOrder:(NSArray *)order
                             embeddedEnabled:(BOOL)embeddedEnabled
                           appleMusicEnabled:(BOOL)appleMusicEnabled
                        spotifyLyricsEnabled:(BOOL)spotifyLyricsEnabled
                         spotifyCacheEnabled:(BOOL)spotifyCacheEnabled
                               lrclibEnabled:(BOOL)lrclibEnabled
                       customEndpointEnabled:(BOOL)customEndpointEnabled
                                 offlineOnly:(BOOL)offlineOnly {
    BOOL configured = [order isKindOfClass:[NSArray class]] && order.count > 0;
    NSArray *source = configured ? [self orderAddingLaterIdentifiers:order] : [self defaultOrder];

    NSMutableArray<NSString *> *resolved = [NSMutableArray arrayWithCapacity:source.count];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithCapacity:source.count];

    for (id entry in source) {
        if (![entry isKindOfClass:[NSString class]]) continue;
        NSString *identifier = [(NSString *)entry lowercaseString];
        if (identifier.length == 0 || [seen containsObject:identifier]) continue;
        [seen addObject:identifier];

        if ([identifier isEqualToString:CLProviderIdentifierEmbedded]) {
            // On-disk (the song file and the library database): exempt from offlineOnly.
            if (!embeddedEnabled) continue;
        } else if ([identifier isEqualToString:CLProviderIdentifierAppleMusic]) {
            if (offlineOnly || !appleMusicEnabled) continue;
        } else if ([identifier isEqualToString:CLProviderIdentifierSpotify]) {
            // Spotify's API, reached through Spotify's own process: a network source.
            if (offlineOnly || !spotifyLyricsEnabled) continue;
        } else if ([identifier isEqualToString:CLProviderIdentifierSpotifyCache]) {
            // Deliberately exempt from offlineOnly: it is the on-disk source.
            if (!spotifyCacheEnabled) continue;
        } else if ([identifier isEqualToString:CLProviderIdentifierLRCLib]) {
            if (offlineOnly || !lrclibEnabled) continue;
        } else if ([identifier isEqualToString:CLProviderIdentifierCustom]) {
            if (offlineOnly || !customEndpointEnabled) continue;
        } else {
            CLLogInfo(@"ignoring unknown provider identifier '%@' in providerOrder", identifier);
            continue;
        }
        [resolved addObject:identifier];
    }
    return [resolved copy];
}

+ (NSArray<id<CLLyricsProvider>> *)providersForIdentifiers:(NSArray<NSString *> *)identifiers
                                         customEndpointURL:(NSString *)customEndpointURL
                                    customEndpointHeader:(NSString *)headerName
                              customEndpointHeaderValue:(NSString *)headerValue {
    NSMutableArray<id<CLLyricsProvider>> *providers = [NSMutableArray arrayWithCapacity:identifiers.count];
    for (id entry in identifiers) {
        if (![entry isKindOfClass:[NSString class]]) continue;
        NSString *identifier = (NSString *)entry;

        if ([identifier isEqualToString:CLProviderIdentifierEmbedded]) {
            [providers addObject:[[CLEmbeddedLyricsProvider alloc] init]];
        } else if ([identifier isEqualToString:CLProviderIdentifierAppleMusic]) {
            [providers addObject:[[CLAppleMusicProvider alloc] init]];
        } else if ([identifier isEqualToString:CLProviderIdentifierSpotify]) {
            [providers addObject:[[CLSpotifyAppProvider alloc] init]];
        } else if ([identifier isEqualToString:CLProviderIdentifierSpotifyCache]) {
            [providers addObject:[[CLSpotifyCacheProvider alloc] init]];
        } else if ([identifier isEqualToString:CLProviderIdentifierLRCLib]) {
            [providers addObject:[[CLLRCLibProvider alloc] init]];
        } else if ([identifier isEqualToString:CLProviderIdentifierCustom]) {
            CLCustomEndpointProvider *provider =
                [[CLCustomEndpointProvider alloc] initWithURLTemplate:customEndpointURL ?: @""
                                                           headerName:headerName ?: @""
                                                          headerValue:headerValue ?: @""];
            if (!provider.isEnabled) continue;
            [providers addObject:provider];
        }
    }
    return [providers copy];
}

@end
