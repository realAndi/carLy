#import "CLColorPickerController.h"
#import <Preferences/PSSpecifier.h>
#import "CLPrefsShared.h"
#import "CLPrefsColor.h"

@interface CLColorPickerController () <UIColorPickerViewControllerDelegate>
@property (nonatomic, strong) UIColorPickerViewController *picker;
@property (nonatomic, strong) UILabel *hexLabel;
@property (nonatomic, copy) NSString *prefKey;
@property (nonatomic, copy) NSString *pendingHex;   // debounced write target
@end

@implementation CLColorPickerController

- (NSString *)cl_specifierKey {
    id key = [self.specifier propertyForKey:PSKeyNameKey];
    if ([key isKindOfClass:[NSString class]] && [(NSString *)key length] > 0) return key;
    return nil;
}

- (NSString *)cl_specifierDefaultHex {
    id def = [self.specifier propertyForKey:PSDefaultValueKey];
    if ([def isKindOfClass:[NSString class]]) return def;
    return @"#000000";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.prefKey = [self cl_specifierKey];

    NSString *label = nil;
    id labelProp = [self.specifier propertyForKey:PSTitleKey];
    if ([labelProp isKindOfClass:[NSString class]]) label = labelProp;
    self.title = label.length > 0 ? label : @"Color";

    // Through the specifier's getter when it has one: on the Layout page that is the staged
    // value, elsewhere the stored one. Falls back to a direct read for a specifier without a target.
    NSString *currentHex = nil;
    if (self.specifier.target) {
        id value = [self.specifier performGetter];
        if ([value isKindOfClass:[NSString class]]) currentHex = value;
    } else if (self.prefKey) {
        currentHex = [CLPrefsShared stringForKey:self.prefKey default:[self cl_specifierDefaultHex]];
    }
    if (currentHex.length == 0) currentHex = [self cl_specifierDefaultHex];
    UIColor *initialColor = [CLPrefsColor colorWithHex:currentHex fallback:[UIColor whiteColor]];

    UILabel *hexLabel = [[UILabel alloc] init];
    hexLabel.font = [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightRegular];
    hexLabel.textAlignment = NSTextAlignmentCenter;
    hexLabel.text = [CLPrefsColor hexFromColor:initialColor];
    hexLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:hexLabel];
    self.hexLabel = hexLabel;

    UIColorPickerViewController *picker = [[UIColorPickerViewController alloc] init];
    picker.delegate = self;
    picker.selectedColor = initialColor;
    picker.supportsAlpha = YES;
    [self addChildViewController:picker];
    picker.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:picker.view];
    [picker didMoveToParentViewController:self];
    self.picker = picker;

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [hexLabel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [hexLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        [picker.view.topAnchor constraintEqualToAnchor:hexLabel.bottomAnchor constant:8],
        [picker.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [picker.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [picker.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Flush any colour picked since the last debounced write, so navigating back immediately
    // after a drag never drops the final value.
    [self cl_flushPendingWriteIfNeeded];
}

#pragma mark - UIColorPickerViewControllerDelegate

- (void)colorPickerViewController:(UIColorPickerViewController *)viewController
                    didSelectColor:(UIColor *)color
                      continuously:(BOOL)continuously {
    NSString *hex = [CLPrefsColor hexFromColor:color];
    self.hexLabel.text = hex;
    self.pendingHex = hex;
    if (continuously) {
        // Debounce disk writes while the user is actively dragging in the picker.
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(cl_flushPendingWriteIfNeeded) object:nil];
        [self performSelector:@selector(cl_flushPendingWriteIfNeeded) withObject:nil afterDelay:0.2];
    } else {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(cl_flushPendingWriteIfNeeded) object:nil];
        [self cl_flushPendingWriteIfNeeded];
    }
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController {
    // Only fires if the picker is ever presented modally with a close button; harmless no-op
    // for the inline-embedded case used here, kept for defensive completeness.
    [self cl_flushPendingWriteIfNeeded];
}

- (void)cl_flushPendingWriteIfNeeded {
    if (self.pendingHex.length == 0 || self.prefKey.length == 0) return;
    NSString *hex = self.pendingHex;
    self.pendingHex = nil;
    if (self.specifier.target) {
        // The parent page's setter: PSListController writes the preference and posts the
        // specifier's PostNotification; the Layout page stages it for its Apply button instead.
        [self.specifier performSetterWithValue:hex];
        return;
    }
    [CLPrefsShared setValue:hex forKey:self.prefKey];
    [CLPrefsShared notifyPrefsChanged];
}

- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

@end
