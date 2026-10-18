#import "CLLyricsListController.h"
#import <Preferences/PSSpecifier.h>
#import "CLPrefsShared.h"
#import "Util/CLPrefsKeys.h"

/// -setValues:titles: exists on every iOS PSSpecifier but is not in the vendored header; it is
/// called only after a respondsToSelector: check, with the properties set by hand as the fallback.
@interface PSSpecifier (CLFontList)
- (void)setValues:(NSArray *)values titles:(NSArray *)titles;
@end

static NSString *const kCLBackgroundRowID = @"lyricsBackground";
static NSString *const kCLBackgroundColorRowID = @"lyricsBackgroundColor";
static NSString *const kCLBackgroundAlphaRowID = @"lyricsBackgroundAlpha";
/// The rows that push the colour picker and show their colour as the row's value.
static NSArray<NSString *> *CLColorRowIDs(void) {
    return @[ @"lyricsCurrentColor", @"lyricsNextColor", kCLBackgroundColorRowID ];
}

@implementation CLLyricsListController {
    /// The plist's rows that come and go (id -> specifier), kept so the very same objects are
    /// inserted back after being removed.
    NSDictionary<NSString *, PSSpecifier *> *_dependentRows;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *all = [self loadSpecifiersFromPlistName:@"Lyrics" target:self];
        [self cl_fillFontListIn:all];

        NSMutableDictionary<NSString *, PSSpecifier *> *dependent = [NSMutableDictionary dictionary];
        NSArray<NSString *> *colorRows = CLColorRowIDs();
        for (PSSpecifier *specifier in all) {
            NSString *identifier = specifier.identifier;
            if ([identifier isEqualToString:kCLBackgroundColorRowID] || [identifier isEqualToString:kCLBackgroundAlphaRowID]) {
                dependent[identifier] = specifier;
            }
            if ([colorRows containsObject:identifier]) [self cl_refreshColorRowTitle:specifier];
        }
        _dependentRows = dependent;

        if ([CLPrefsShared integerForKey:CLPrefKeyLyricsBackground default:0] == 0) {
            [all removeObjectsInArray:dependent.allValues];
        }
        _specifiers = all;
    }
    return _specifiers;
}

/// Font: "System" (the empty string) followed by every installed font family, sorted.
- (void)cl_fillFontListIn:(NSArray<PSSpecifier *> *)specifiers {
    PSSpecifier *font = nil;
    for (PSSpecifier *specifier in specifiers) {
        if ([specifier.identifier isEqualToString:@"lyricsFontFamily"]) { font = specifier; break; }
    }
    if (!font) return;
    NSArray<NSString *> *families = [UIFont.familyNames sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableArray *values = [NSMutableArray arrayWithObject:@""];
    NSMutableArray *titles = [NSMutableArray arrayWithObject:@"System"];
    [values addObjectsFromArray:families];
    [titles addObjectsFromArray:families];
    [font setProperty:values forKey:PSValidValuesKey];
    [font setProperty:titles forKey:PSValidTitlesKey];
    if ([font respondsToSelector:@selector(setValues:titles:)]) {
        [font setValues:values titles:titles];
    } else {
        font.titleDictionary = [NSDictionary dictionaryWithObjects:titles forKeys:values];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Back from the colour picker: the rows show the colour it wrote. The background colour row
    // is only reloaded while a background is chosen (it is not in the table otherwise).
    for (NSString *identifier in CLColorRowIDs()) {
        PSSpecifier *row = [self specifierForID:identifier];
        if (!row) continue;
        [self cl_refreshColorRowTitle:row];
        [self reloadSpecifierID:identifier animated:NO];
    }
    PSSpecifier *hiddenColor = _dependentRows[kCLBackgroundColorRowID];
    if (hiddenColor && ![self specifierForID:kCLBackgroundColorRowID]) [self cl_refreshColorRowTitle:hiddenColor];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    if ([specifier.identifier isEqualToString:kCLBackgroundRowID]) {
        BOOL wantsRows = [value isKindOfClass:NSNumber.class] && [(NSNumber *)value integerValue] != 0;
        [self cl_setBackgroundRowsVisible:wantsRows];
    }
}

- (void)cl_setBackgroundRowsVisible:(BOOL)visible {
    PSSpecifier *color = _dependentRows[kCLBackgroundColorRowID];
    PSSpecifier *alpha = _dependentRows[kCLBackgroundAlphaRowID];
    if (!color || !alpha) return;
    BOOL present = ([self specifierForID:kCLBackgroundColorRowID] != nil);
    if (visible && !present) {
        [self insertContiguousSpecifiers:@[ color, alpha ] afterSpecifierID:kCLBackgroundRowID animated:YES];
    } else if (!visible && present) {
        [self removeContiguousSpecifiers:@[ color, alpha ] animated:YES];
    }
}

@end
