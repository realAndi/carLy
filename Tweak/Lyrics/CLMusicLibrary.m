#import "Lyrics/CLMusicLibrary.h"
#import "Util/CLLog.h"
#import <dlfcn.h>
#import <objc/message.h>

/// MPMediaLibraryAuthorizationStatusAuthorized.
static const NSInteger kCLMediaLibraryAuthorized = 3;

/// A MediaPlayer property-name constant, falling back to its known value when the symbol is not
/// loaded (the values are part of MediaPlayer's stable API; "filePath" is exported but private).
static NSString *CLMediaPlayerConstant(const char *symbol, NSString *fallback) {
    NSString *__unsafe_unretained *pointer = (NSString *__unsafe_unretained *)dlsym(RTLD_DEFAULT, symbol);
    NSString *value = pointer ? *pointer : nil;
    return [value isKindOfClass:[NSString class]] && value.length ? value : fallback;
}

static id CLItemValue(id item, NSString *property) {
    if (!item || !property || ![item respondsToSelector:@selector(valueForProperty:)]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(item, @selector(valueForProperty:), property);
}

@implementation CLMusicLibrary

+ (CLMusicLibraryItem *)itemWithPersistentID:(unsigned long long)persistentID {
    if (persistentID == 0) return nil;

    Class libraryClass = NSClassFromString(@"MPMediaLibrary");
    Class queryClass = NSClassFromString(@"MPMediaQuery");
    Class predicateClass = NSClassFromString(@"MPMediaPropertyPredicate");
    SEL statusSelector = NSSelectorFromString(@"authorizationStatus");
    SEL predicateSelector = NSSelectorFromString(@"predicateWithValue:forProperty:");
    SEL querySelector = NSSelectorFromString(@"initWithFilterPredicates:");
    SEL itemsSelector = NSSelectorFromString(@"items");
    if (!libraryClass || !queryClass || !predicateClass ||
        ![libraryClass respondsToSelector:statusSelector] ||
        ![predicateClass respondsToSelector:predicateSelector] ||
        ![queryClass instancesRespondToSelector:querySelector] ||
        ![queryClass instancesRespondToSelector:itemsSelector]) {
        CLLogDebug(@"[embedded] MediaPlayer is not loaded here; no library lookup");
        return nil;
    }
    NSInteger status = ((NSInteger (*)(id, SEL))objc_msgSend)(libraryClass, statusSelector);
    if (status != kCLMediaLibraryAuthorized) {
        CLLogDebug(@"[embedded] media library not authorised here (status %ld)", (long)status);
        return nil;
    }

    NSString *persistentIDKey = CLMediaPlayerConstant("MPMediaItemPropertyPersistentID", @"persistentID");
    id predicate = ((id (*)(id, SEL, id, id))objc_msgSend)(predicateClass, predicateSelector,
                                                          @(persistentID), persistentIDKey);
    if (!predicate) return nil;
    id query = ((id (*)(id, SEL, id))objc_msgSend)([queryClass alloc], querySelector,
                                                  [NSSet setWithObject:predicate]);
    id items = query ? ((id (*)(id, SEL))objc_msgSend)(query, itemsSelector) : nil;
    id item = [items isKindOfClass:[NSArray class]] ? [(NSArray *)items firstObject] : nil;
    if (!item) {
        CLLogDebug(@"[embedded] no library item with persistent id %llu", persistentID);
        return nil;
    }

    id title = CLItemValue(item, CLMediaPlayerConstant("MPMediaItemPropertyTitle", @"title"));
    id duration = CLItemValue(item, CLMediaPlayerConstant("MPMediaItemPropertyPlaybackDuration", @"playbackDuration"));
    id lyrics = CLItemValue(item, CLMediaPlayerConstant("MPMediaItemPropertyLyrics", @"lyrics"));
    // assetURL is nil for protected or non-local items; only then is there a file worth reading.
    id assetURL = CLItemValue(item, CLMediaPlayerConstant("MPMediaItemPropertyAssetURL", @"assetURL"));
    id filePath = assetURL ? CLItemValue(item, CLMediaPlayerConstant("MPMediaItemPropertyFilePath", @"filePath")) : nil;

    return [[CLMusicLibraryItem alloc]
        initWithTitle:[title isKindOfClass:[NSString class]] ? title : nil
             duration:[duration respondsToSelector:@selector(doubleValue)] ? [duration doubleValue] : 0
               lyrics:[lyrics isKindOfClass:[NSString class]] ? lyrics : nil
             filePath:[filePath isKindOfClass:[NSString class]] && [(NSString *)filePath isAbsolutePath] ? filePath : nil];
}

@end
