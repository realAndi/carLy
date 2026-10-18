#import "CLLayoutListController.h"
#import <Preferences/PSSpecifier.h>
#import "CLLayoutPreviewHeaderView.h"
#import "CLPrefsShared.h"
#import "UI/CLLayoutGeometry.h"
#import "Util/CLPrefsKeys.h"

/// Which screen shape the preview shows; a Settings-session preference, not a tweak preference.
static NSInteger sPreviewScreen = 0;

// Rows that come and go with other staged values, and the row each is inserted after.
static NSString *const kCLCornerRadiusRowID = @"artworkCornerRadius";
static NSString *const kCLCornerRadiusAnchorID = @"progressBarStyle";
static NSString *const kCLBackdropOpacityRowID = @"backdropOpacity";
static NSString *const kCLBackdropOpacityAnchorID = @"backdropStyle";
static NSString *const kCLAccentColorRowID = @"accentColor";
static NSString *const kCLAccentColorAnchorID = @"tintFromArtwork";

@interface CLLayoutListController ()
@property (nonatomic, strong) CLLayoutPreviewHeaderView *header;
@property (nonatomic, strong) UIBarButtonItem *applyItem;
@property (nonatomic, strong) UIBarButtonItem *cancelItem;
@end

@implementation CLLayoutListController {
    /// Staged (key -> value) values of this page instance. Empty means nothing to apply.
    NSMutableDictionary<NSString *, id> *_staged;
    /// Every specifier the plist declares, in order, loaded once; `_specifiers` is the visible subset.
    NSArray<PSSpecifier *> *_allSpecifiers;
    /// Whether the next preview refresh crossfades (set by a card tap).
    BOOL _animateNextPreview;
}

/// Created on first use rather than in an initializer: PreferenceLoader may build the controller
/// through any of PSViewController's initializers.
- (NSMutableDictionary<NSString *, id> *)cl_staged {
    if (!_staged) _staged = [NSMutableDictionary dictionary];
    return _staged;
}

#pragma mark - Specifiers

/// The plist's specifiers minus the rows the staged values hide. Rebuilt only here: on first
/// load and after Apply or Cancel (through -reloadSpecifiers). Value changes insert and remove
/// single rows through the PSListController API instead.
- (NSArray *)specifiers {
    if (!_specifiers) {
        if (!_allSpecifiers) {
            _allSpecifiers = [[self loadSpecifiersFromPlistName:@"Layout" target:self] copy];
        }
        [self cl_refreshColorRowTitle:[self cl_declaredSpecifierWithID:kCLAccentColorRowID]];
        NSMutableArray *visible = [NSMutableArray arrayWithCapacity:_allSpecifiers.count];
        for (PSSpecifier *specifier in _allSpecifiers) {
            NSString *identifier = specifier.identifier;
            if (identifier.length > 0 && [self cl_isRowHidden:identifier]) continue;
            [visible addObject:specifier];
        }
        _specifiers = visible;
    }
    return _specifiers;
}

- (PSSpecifier *)cl_declaredSpecifierWithID:(NSString *)identifier {
    for (PSSpecifier *specifier in _allSpecifiers) {
        if ([specifier.identifier isEqualToString:identifier]) return specifier;
    }
    return nil;
}

/// Whether a dependent row is hidden for the staged values.
- (BOOL)cl_isRowHidden:(NSString *)identifier {
    if ([identifier isEqualToString:kCLCornerRadiusRowID]) {
        // Hidden only when no screen the preview offers shows an album cover for the staged
        // layout. No Artwork hides the cover on every one of them (the strip on Wide and Tall, the
        // cover-less column on Short) — the same plan the car makes.
        NSInteger mode = [self cl_stagedIntegerForKey:CLPrefKeyLyricsMode];
        if (mode == CLLayoutModeOff) return NO;
        for (NSInteger screen = CLPreviewScreenWide; screen <= CLPreviewScreenTall; screen++) {
            CGRect safe = [CLLayoutPreviewView safeAreaForScreen:(CLPreviewScreen)screen];
            if (!CLLayoutPlanMake(mode, safe, CLLayoutDefaultSideArtworkRatio, YES).hidesArtwork) return NO;
        }
        return YES;
    }
    if ([identifier isEqualToString:kCLBackdropOpacityRowID]) {
        return [self cl_stagedIntegerForKey:CLPrefKeyBackdropStyle] == 1;      // Plain
    }
    if ([identifier isEqualToString:kCLAccentColorRowID]) {
        return [self cl_stagedBoolForKey:CLPrefKeyTintFromArtwork];
    }
    return NO;
}

/// Inserts or removes the three dependent rows so the table matches the staged values, without
/// rebuilding `_specifiers`.
- (void)cl_updateRowVisibilityAnimated:(BOOL)animated {
    NSArray<NSArray<NSString *> *> *rows = @[ @[ kCLCornerRadiusRowID, kCLCornerRadiusAnchorID ],
                                              @[ kCLBackdropOpacityRowID, kCLBackdropOpacityAnchorID ],
                                              @[ kCLAccentColorRowID, kCLAccentColorAnchorID ] ];
    for (NSArray<NSString *> *pair in rows) {
        NSString *rowID = pair[0], *anchorID = pair[1];
        PSSpecifier *row = [self cl_declaredSpecifierWithID:rowID];
        if (!row) continue;
        BOOL wanted = ![self cl_isRowHidden:rowID];
        BOOL present = ([self specifierForID:rowID] != nil);
        if (wanted && !present && [self specifierForID:anchorID]) {
            [self insertContiguousSpecifiers:@[ row ] afterSpecifierID:anchorID animated:animated];
        } else if (!wanted && present) {
            [self removeContiguousSpecifiers:@[ row ] animated:animated];
        }
    }
}

#pragma mark - Staged values

/// The committed value the page compares staged values against: the stored value, or the
/// specifier's default, with the tweak's legacy mappings applied (lyricsMode 1 -> 4, progress
/// bar 1 -> 0) so an old plist reads as what the car shows.
- (id)cl_committedValueForKey:(NSString *)key default:(id)def {
    id stored = [CLPrefsShared rawValueForKey:key] ?: def;
    if ([key isEqualToString:CLPrefKeyLyricsMode]) {
        NSInteger mode = [stored isKindOfClass:NSNumber.class] ? [(NSNumber *)stored integerValue] : CLLayoutModeSideBySide;
        return @(CLLayoutModeNormalize(mode));
    }
    if ([key isEqualToString:CLPrefKeyProgressBarStyle]) {
        NSInteger style = [stored isKindOfClass:NSNumber.class] ? [(NSNumber *)stored integerValue] : 0;
        style = MAX((NSInteger)0, MIN((NSInteger)2, style));
        return @(style == 1 ? 0 : style);
    }
    return stored;
}

- (id)cl_stagedOrCommittedValueForKey:(NSString *)key default:(id)def {
    id staged = key.length > 0 ? self.cl_staged[key] : nil;
    return staged ?: [self cl_committedValueForKey:key default:def];
}

- (NSInteger)cl_stagedIntegerForKey:(NSString *)key {
    NSInteger def = [key isEqualToString:CLPrefKeyLyricsMode] ? CLLayoutModeSideBySide : 0;
    id value = [self cl_stagedOrCommittedValueForKey:key default:@(def)];
    return [value isKindOfClass:NSNumber.class] ? [(NSNumber *)value integerValue] : def;
}

- (BOOL)cl_stagedBoolForKey:(NSString *)key {
    id value = [self cl_stagedOrCommittedValueForKey:key default:@NO];
    return [value isKindOfClass:NSNumber.class] && [(NSNumber *)value boolValue];
}

/// Every control on this page reads through here: the staged value wins over the stored one.
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:PSKeyNameKey];
    if (key.length == 0) return [super readPreferenceValue:specifier];
    id staged = self.cl_staged[key];
    if (staged) return staged;
    if ([key isEqualToString:CLPrefKeyLyricsMode] || [key isEqualToString:CLPrefKeyProgressBarStyle]) {
        return [self cl_committedValueForKey:key default:[specifier propertyForKey:PSDefaultValueKey]];
    }
    return [super readPreferenceValue:specifier];
}

/// ...and writes through here: nothing reaches CFPreferences or the car until Apply. The colour
/// picker calls the specifier's setter, so it lands here too.
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:PSKeyNameKey];
    if (key.length == 0) return;
    [self cl_stageValue:value forKey:key default:[specifier propertyForKey:PSDefaultValueKey]];
    if ([specifier.identifier isEqualToString:kCLAccentColorRowID]) [self cl_refreshAccentRow];
}

/// The Accent Color row's value text follows the staged value.
- (void)cl_refreshAccentRow {
    [self cl_refreshColorRowTitle:[self cl_declaredSpecifierWithID:kCLAccentColorRowID]];
    if ([self specifierForID:kCLAccentColorRowID]) [self reloadSpecifierID:kCLAccentColorRowID animated:NO];
}

- (void)cl_stageValue:(id)value forKey:(NSString *)key default:(id)def {
    id committed = [self cl_committedValueForKey:key default:def];
    if (value == nil || (committed && [value isEqual:committed])) {
        [self.cl_staged removeObjectForKey:key];
    } else {
        self.cl_staged[key] = value;
    }
    [self cl_updateRowVisibilityAnimated:YES];
    [self cl_refreshPreview];
    [self cl_updateNavigationItems];
}

#pragma mark - Apply / Cancel

- (void)applyStagedChanges {
    NSDictionary<NSString *, id> *staged = [self.cl_staged copy];
    for (NSString *key in staged) {
        [CLPrefsShared setValue:staged[key] forKey:key];
    }
    [self.cl_staged removeAllObjects];
    if (staged.count > 0) [CLPrefsShared notifyPrefsChanged];
    [self reloadSpecifiers];
    [self cl_refreshPreview];
    [self cl_updateNavigationItems];
}

- (void)cancelStagedChanges {
    [self.cl_staged removeAllObjects];
    [self reloadSpecifiers];
    [self cl_refreshPreview];
    [self cl_updateNavigationItems];
}

/// Apply on the right, enabled while there is something to apply; then the back button gives
/// way to Cancel, so leaving the page is an explicit choice.
- (void)cl_updateNavigationItems {
    BOOL dirty = self.cl_staged.count > 0;
    self.applyItem.enabled = dirty;
    if (dirty) {
        [self.navigationItem setHidesBackButton:YES animated:YES];
        if (self.navigationItem.leftBarButtonItem != self.cancelItem) {
            [self.navigationItem setLeftBarButtonItem:self.cancelItem animated:YES];
        }
    } else {
        if (self.navigationItem.leftBarButtonItem) [self.navigationItem setLeftBarButtonItem:nil animated:YES];
        [self.navigationItem setHidesBackButton:NO animated:YES];
    }
}

#pragma mark - View

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Layout";
    self.applyItem = [[UIBarButtonItem alloc] initWithTitle:@"Apply" style:UIBarButtonItemStyleDone
                                                     target:self action:@selector(applyStagedChanges)];
    self.cancelItem = [[UIBarButtonItem alloc] initWithTitle:@"Cancel" style:UIBarButtonItemStylePlain
                                                      target:self action:@selector(cancelStagedChanges)];
    self.navigationItem.rightBarButtonItem = self.applyItem;

    CLLayoutPreviewHeaderView *header = [[CLLayoutPreviewHeaderView alloc] initWithFrame:CGRectZero];
    header.screen = (CLPreviewScreen)sPreviewScreen;
    __weak typeof(self) weakSelf = self;
    header.onLayoutPicked = ^(NSInteger layoutMode) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_animateNextPreview = YES;
        [strongSelf cl_stageValue:@(layoutMode) forKey:CLPrefKeyLyricsMode default:@(CLLayoutModeSideBySide)];
    };
    // Remembered for the next visit, however the page is left (nothing else needs to happen).
    header.onScreenChanged = ^(CLPreviewScreen screen) {
        sPreviewScreen = screen;
    };
    self.header = header;
    [self cl_installHeader];
    [self cl_refreshPreview];
    [self cl_updateNavigationItems];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The Lyrics page (font, colours) may have changed underneath us, and the colour picker
    // has just staged the accent.
    [self cl_refreshAccentRow];
    [self cl_refreshPreview];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // Popped (back button, swipe back): whatever was staged and not applied is gone.
    if (self.isMovingFromParentViewController) [self.cl_staged removeAllObjects];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    [self cl_installHeader];
}

- (void)cl_installHeader {
    UITableView *table = self.table;
    CLLayoutPreviewHeaderView *header = self.header;
    if (!table || !header) return;
    CGFloat width = CGRectGetWidth(table.bounds);
    if (width < 1.0) return;
    CGFloat height = [CLLayoutPreviewHeaderView preferredHeightForWidth:width];
    CGRect frame = CGRectMake(0.0, 0.0, width, height);
    if (table.tableHeaderView == header && CGRectEqualToRect(header.frame, frame)) return;
    header.frame = frame;
    table.tableHeaderView = header;      // re-assigning is what makes the table pick up a new height
}

- (void)cl_refreshPreview {
    CLLayoutPreviewHeaderView *header = self.header;
    [header setModel:[CLLayoutPreviewModel modelWithStagedValues:self.cl_staged] animated:_animateNextPreview];
    _animateNextPreview = NO;
    sPreviewScreen = header.screen;
}

@end
