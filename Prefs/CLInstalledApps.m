#import "CLInstalledApps.h"
#import <objc/message.h>

NSString *const CLInstalledAppBundleIDKey = @"bundleID";
NSString *const CLInstalledAppNameKey = @"name";

static id CLSendObject(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static NSString *CLSendString(id target, NSString *selectorName) {
    id value = CLSendObject(target, selectorName);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static BOOL CLSendBool(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
}

static id CLInfoValue(id proxy, NSString *key, Class valueClass) {
    SEL selector = NSSelectorFromString(@"objectForInfoDictionaryKey:ofClass:");
    if (!proxy || ![proxy respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id, Class))objc_msgSend)(proxy, selector, key, valueClass);
}

/// Apple's own audio apps whose Info.plist may not declare the background mode.
static NSSet<NSString *> *CLAppleAudioApps(void) {
    static NSSet<NSString *> *apps;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ apps = [NSSet setWithArray:@[ @"com.apple.Music", @"com.apple.podcasts", @"com.apple.iBooks" ]]; });
    return apps;
}

@implementation CLInstalledApps

+ (void)loadWithCompletion:(void (^)(NSArray<NSDictionary *> *, NSArray<NSDictionary *> *))completion {
    if (!completion) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSDictionary *> *audio = [NSMutableArray array];
        NSMutableArray<NSDictionary *> *other = [NSMutableArray array];
        @try {
            Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
            id workspace = CLSendObject(workspaceClass, @"defaultWorkspace");
            id proxies = CLSendObject(workspace, @"allInstalledApplications");
            NSMutableSet<NSString *> *seen = [NSMutableSet set];
            for (id proxy in ([proxies isKindOfClass:[NSArray class]] ? proxies : @[])) {
                NSString *bundleID = CLSendString(proxy, @"applicationIdentifier");
                if (bundleID.length == 0 || [seen containsObject:bundleID]) continue;
                if (CLSendBool(proxy, @"isPlaceholder")) continue;
                id tags = CLSendObject(proxy, @"appTags");
                if ([tags isKindOfClass:[NSArray class]] && [(NSArray *)tags containsObject:@"hidden"]) continue;
                NSString *name = CLSendString(proxy, @"localizedName");
                if (name.length == 0) continue;   // services and plug-in hosts have none
                [seen addObject:bundleID];

                id modes = CLInfoValue(proxy, @"UIBackgroundModes", [NSArray class]);
                BOOL plays = ([modes isKindOfClass:[NSArray class]] && [(NSArray *)modes containsObject:@"audio"]) ||
                             [CLAppleAudioApps() containsObject:bundleID];
                NSDictionary *app = @{ CLInstalledAppBundleIDKey: bundleID, CLInstalledAppNameKey: name };
                [(plays ? audio : other) addObject:app];
            }
        } @catch (NSException *exception) {
            NSLog(@"[carLy] listing installed apps raised %@: %@", exception.name, exception.reason);
        }
        NSComparator byName = ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[CLInstalledAppNameKey] localizedStandardCompare:b[CLInstalledAppNameKey]];
        };
        [audio sortUsingComparator:byName];
        [other sortUsingComparator:byName];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(audio, other); });
    });
}

+ (NSString *)nameForBundleIdentifier:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) return nil;
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:selector]) return nil;
    @try {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, selector, bundleIdentifier);
        if (CLSendBool(proxy, @"isPlaceholder")) return nil;
        if ([proxy respondsToSelector:NSSelectorFromString(@"isInstalled")] && !CLSendBool(proxy, @"isInstalled")) return nil;
        NSString *name = CLSendString(proxy, @"localizedName");
        return name.length > 0 ? name : nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

@end
