#import "CLListController.h"
#import <Preferences/PSSpecifier.h>

@implementation CLListController

- (UITableViewStyle)tableViewStyle {
    return UITableViewStyleInsetGrouped;
}

- (void)cl_refreshColorRowTitle:(PSSpecifier *)specifier {
    if (!specifier) return;
    // Through the page's own reader: the Layout page answers with the staged value.
    id value = [self readPreferenceValue:specifier];
    NSString *hex = [value isKindOfClass:NSString.class] ? (NSString *)value : @"";
    NSString *title = hex.length > 0 ? hex.uppercaseString : @"Default";
    specifier.titleDictionary = @{ hex: title };
}

@end
