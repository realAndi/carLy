#import "CLAppsListController.h"
#import <Preferences/PSSpecifier.h>
#import "CLInstalledApps.h"
#import "CLPrefsShared.h"
#import "Util/CLPrefsKeys.h"

// Only the dynamically-inserted bundle-id rows use this cell type; every static row in Apps.plist
// uses a different cell, so checking cellType is enough to tell them apart for editing.
static const PSCellType kCLAppRowCellType = PSStaticTextCell;
static NSString *const kCLAppsGroupSpecifierID = @"appsGroup";
static NSString *const kCLAddAppSpecifierID = @"addApp";
static NSString *const kCLAllAppsSpecifierID = @"allApps";
// "addApp" is the Choose Apps… link (CLAppPickerController); the id predates the picker.

@implementation CLAppsListController

- (NSArray<NSString *> *)cl_currentEnabledApps {
    return [CLPrefsShared enabledApps];
}

- (void)cl_persistEnabledApps:(NSArray<NSString *> *)apps {
    [CLPrefsShared setEnabledApps:apps];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Back from Choose Apps…, which edits the list directly.
    if (_specifiers) [self cl_reloadAppRows];
}

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [self loadSpecifiersFromPlistName:@"Apps" target:self];
        if ([CLPrefsShared boolForKey:CLPrefKeyAllApps default:NO]) {
            // All Apps: the list means nothing, so the group, its rows and Add App… stay out.
            NSMutableArray *kept = [NSMutableArray arrayWithCapacity:specs.count];
            for (PSSpecifier *specifier in specs) {
                NSString *identifier = specifier.identifier;
                if ([identifier isEqualToString:kCLAppsGroupSpecifierID] || [identifier isEqualToString:kCLAddAppSpecifierID]) continue;
                [kept addObject:specifier];
            }
            specs = kept;
        } else {
            [self cl_insertAppRowsIntoSpecifiers:specs];
        }
        _specifiers = specs;
    }
    return _specifiers;
}

- (void)cl_insertAppRowsIntoSpecifiers:(NSMutableArray *)specifiers {
    NSUInteger insertionIndex = NSNotFound;
    for (NSUInteger i = 0; i < specifiers.count; i++) {
        PSSpecifier *s = specifiers[i];
        if ([s.identifier isEqualToString:kCLAppsGroupSpecifierID]) {
            insertionIndex = i + 1;
            break;
        }
    }
    if (insertionIndex == NSNotFound) insertionIndex = specifiers.count;

    NSArray<NSString *> *apps = [self cl_currentEnabledApps];
    NSMutableArray<PSSpecifier *> *rows = [NSMutableArray arrayWithCapacity:apps.count];
    for (NSString *bundleID in apps) {
        // The app's Home Screen name; the bundle identifier when it is not installed.
        NSString *title = [CLInstalledApps nameForBundleIdentifier:bundleID] ?: bundleID;
        PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:title
                                                             target:self
                                                                set:NULL
                                                                get:NULL
                                                             detail:Nil
                                                               cell:kCLAppRowCellType
                                                               edit:Nil];
        spec.identifier = bundleID;
        [spec setProperty:title forKey:PSTitleKey];
        // Settings draws the installed app's icon for a bundle id (a blank one when it is not
        // installed).
        [spec setProperty:@YES forKey:PSLazyIconLoading];
        [spec setProperty:bundleID forKey:PSLazyIconAppID];
        [rows addObject:spec];
    }
    if (rows.count > 0) {
        NSIndexSet *idx = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(insertionIndex, rows.count)];
        [specifiers insertObjects:rows atIndexes:idx];
    }
}

- (void)cl_reloadAppRows {
    // Rebuilding from scratch keeps this correct regardless of how many rows changed; the app
    // list is small (a handful of bundle ids at most) so a full reload is cheap. -reloadSpecifiers
    // drops _specifiers, rebuilds them through -specifiers and reloads the table. Never the
    // -tableView getter: PSListController on 17.3 implements -table only, and the unrecognised
    // selector aborted Settings on every All Apps toggle (0.9.1).
    [self reloadSpecifiers];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    if ([specifier.identifier isEqualToString:kCLAllAppsSpecifierID]) {
        [self cl_reloadAppRows];       // -specifiers reads allApps and keeps or drops the group
    }
}

#pragma mark - Editing (swipe to delete)

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger index = [self indexForIndexPath:indexPath];
    if (index < 0 || index >= (NSInteger)self.specifiers.count) return NO;
    PSSpecifier *spec = [self specifierAtIndex:index];
    return spec.cellType == kCLAppRowCellType;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self tableView:tableView canEditRowAtIndexPath:indexPath] ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSInteger index = [self indexForIndexPath:indexPath];
    if (index < 0 || index >= (NSInteger)self.specifiers.count) return;
    PSSpecifier *spec = [self specifierAtIndex:index];
    if (spec.cellType != kCLAppRowCellType) return;

    NSString *bundleID = spec.identifier;
    NSMutableArray<NSString *> *apps = [[self cl_currentEnabledApps] mutableCopy];
    [apps removeObject:bundleID];
    [self cl_persistEnabledApps:apps];

    // PSListController's own removal keeps its group bookkeeping in step with the table.
    [self removeSpecifier:spec animated:YES];
}

@end
