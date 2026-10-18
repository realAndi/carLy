#import "CLRootListController.h"
#import <Preferences/PSSpecifier.h>
#import "CLPrefsShared.h"
#import "UI/CLLayoutGeometry.h"
#import "Util/CLPrefsKeys.h"

@implementation CLRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // An Apply on the Layout page changes the value this row shows.
    if ([self specifierForID:@"layout"]) [self reloadSpecifierID:@"layout" animated:NO];
}

/// The Layout row's value: the committed lyricsMode, normalised (a legacy 1 reads as 4, anything
/// outside 0...4 clamps) so the row always names one of its four titles.
- (id)cl_layoutModeValue:(PSSpecifier *)specifier {
    NSInteger stored = [CLPrefsShared integerForKey:CLPrefKeyLyricsMode default:CLLayoutModeSideBySide];
    return @(CLLayoutModeNormalize(stored));
}

/// The Version row's value: this bundle's CFBundleShortVersionString (kept equal to the deb's
/// version by scripts/check-prefs-plists.py).
- (id)cl_version:(PSSpecifier *)specifier {
    id version = [NSBundle bundleForClass:self.class].infoDictionary[@"CFBundleShortVersionString"];
    return [version isKindOfClass:NSString.class] ? version : @"";
}

@end
