#import "CLRuntime.h"
#import "CLLog.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

id CLIvar(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name.UTF8String);
    if (!ivar) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || (type[0] != '@' && type[0] != '#')) return nil;
    return object_getIvar(object, ivar);
}

BOOL CLIvarSet(id object, NSString *name, id value) {
    if (!object || name.length == 0) return NO;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name.UTF8String);
    if (!ivar) return NO;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') return NO;
    object_setIvar(object, ivar, value);
    return YES;
}

id CLValueForKey(id object, NSString *key) {
    if (!object || key.length == 0) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (NSException *exception) {
        return nil;
    }
}

BOOL CLSetValueForKey(id object, NSString *key, id value) {
    if (!object || key.length == 0 || value == nil) return NO;
    @try {
        [object setValue:value forKey:key];
        return YES;
    } @catch (NSException *exception) {
        CLLogDebug(@"setValue:forKey:%@ on %@ raised %@: %@", key,
                   NSStringFromClass(object_getClass(object)), exception.name, exception.reason);
        return NO;
    }
}

Class CLClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) {
        static NSMutableSet *reported;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ reported = [NSMutableSet new]; });
        @synchronized (reported) {
            if (![reported containsObject:name]) {
                [reported addObject:name];
                CLLogDebug(@"class %@ not present", name);
            }
        }
    }
    return cls;
}

BOOL CLResponds(id object, NSString *selectorName) {
    if (!object || selectorName.length == 0) return NO;
    return [object respondsToSelector:NSSelectorFromString(selectorName)];
}

/// Depth- and visit-bounded so a pathological (or simply very deep) hierarchy cannot turn this
/// into a long walk on the main thread: this runs inside the host's own layout pass.
static const NSUInteger kCLFindSubviewMaxDepth = 12;
static const NSUInteger kCLFindSubviewMaxVisits = 512;

static UIView *CLFindSubviewBounded(UIView *view, Class cls, NSUInteger depth, NSUInteger *visits) {
    if (!view || depth >= kCLFindSubviewMaxDepth || *visits >= kCLFindSubviewMaxVisits) return nil;
    for (UIView *sub in view.subviews) {
        if (++(*visits) > kCLFindSubviewMaxVisits) return nil;
        if ([sub isKindOfClass:cls]) return sub;
        UIView *found = CLFindSubviewBounded(sub, cls, depth + 1, visits);
        if (found) return found;
    }
    return nil;
}

id CLFindSubview(id view, NSString *className) {
    if (![view isKindOfClass:UIView.class]) return nil;
    Class cls = NSClassFromString(className);
    if (!cls) return nil;
    NSUInteger visits = 0;
    return CLFindSubviewBounded((UIView *)view, cls, 0, &visits);
}

NSString *CLViewHierarchy(id view) {
    if (!view) return @"(nil)";
    SEL sel = NSSelectorFromString(@"recursiveDescription");
    if ([view respondsToSelector:sel]) {
        NSString *description = CLValueForKey(view, @"recursiveDescription");
        if (description) return description;
    }
    return [view description] ?: @"(no description)";
}
