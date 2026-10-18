#import "CLSourcesListController.h"
#import <Preferences/PSSpecifier.h>
#import "CLPrefsShared.h"
#import "Util/CLPrefsKeys.h"

static NSString *const kCLEndpointSwitchID = @"customEndpointEnabled";
/// The last row of the Lyrics Sources group. The endpoint group has to go after it, not right
/// after the switch, or the inserted PSGroupCell would split the first group in two.
static NSString *const kCLEndpointAnchorID = @"providerOrder";

@implementation CLSourcesListController {
    /// The Custom Endpoint group and its three rows, in plist order, kept so the same objects are
    /// inserted back after being removed.
    NSArray<PSSpecifier *> *_endpointRows;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *all = [self loadSpecifiersFromPlistName:@"Sources" target:self];
        NSSet<NSString *> *endpointIDs = [NSSet setWithArray:@[ @"customEndpointGroup", @"customEndpointURL",
                                                                 @"customEndpointHeaderName", @"customEndpointHeaderValue" ]];
        NSMutableArray<PSSpecifier *> *rows = [NSMutableArray array];
        for (PSSpecifier *specifier in all) {
            if (specifier.identifier.length > 0 && [endpointIDs containsObject:specifier.identifier]) [rows addObject:specifier];
        }
        _endpointRows = rows;
        if (![CLPrefsShared boolForKey:CLPrefKeyCustomEndpointEnabled default:NO]) {
            [all removeObjectsInArray:rows];
        }
        _specifiers = all;
    }
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    if ([specifier.identifier isEqualToString:kCLEndpointSwitchID]) {
        BOOL on = [value isKindOfClass:NSNumber.class] && [(NSNumber *)value boolValue];
        [self cl_setEndpointRowsVisible:on];
    }
}

- (void)cl_setEndpointRowsVisible:(BOOL)visible {
    if (_endpointRows.count == 0) return;
    BOOL present = ([self specifierForID:@"customEndpointGroup"] != nil);
    if (visible && !present) {
        NSString *anchor = [self specifierForID:kCLEndpointAnchorID] ? kCLEndpointAnchorID : kCLEndpointSwitchID;
        [self insertContiguousSpecifiers:_endpointRows afterSpecifierID:anchor animated:YES];
    } else if (!visible && present) {
        [self removeContiguousSpecifiers:_endpointRows animated:YES];
    }
}

@end
