#import "CLAppPickerController.h"
#import <Preferences/PSSpecifier.h>
#import "CLInstalledApps.h"
#import "CLPrefsShared.h"

static NSString *const kCLBundleIDProperty = @"cl_bundleID";

@implementation CLAppPickerController {
    NSArray<NSDictionary *> *_audioApps;
    NSArray<NSDictionary *> *_otherApps;
    BOOL _loaded;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Choose Apps";
    __weak typeof(self) weakSelf = self;
    [CLInstalledApps loadWithCompletion:^(NSArray<NSDictionary *> *audioApps, NSArray<NSDictionary *> *otherApps) {
        CLAppPickerController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_audioApps = audioApps;
        strongSelf->_otherApps = otherApps;
        strongSelf->_loaded = YES;
        [strongSelf reloadSpecifiers];
    }];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specifiers = [NSMutableArray array];
        if (!_loaded) {
            PSSpecifier *group = [PSSpecifier groupSpecifierWithName:nil];
            [group setProperty:@"Loading installed apps…" forKey:@"footerText"];
            [specifiers addObject:group];
        } else {
            [self cl_addGroupNamed:@"Audio Apps"
                            footer:@"Apps that play audio in the background. Lyrics show for Apple Music and for apps whose CarPlay player is CarPlay's standard one, such as Spotify, Audible and podcast apps."
                              apps:_audioApps
                       toSpecifiers:specifiers];
            [self cl_addGroupNamed:@"Other Apps" footer:nil apps:_otherApps toSpecifiers:specifiers];
            if (_audioApps.count + _otherApps.count == 0) {
                PSSpecifier *group = [PSSpecifier groupSpecifierWithName:nil];
                [group setProperty:@"The installed apps could not be listed." forKey:@"footerText"];
                [specifiers addObject:group];
            }
        }
        _specifiers = specifiers;
    }
    return _specifiers;
}

- (void)cl_addGroupNamed:(NSString *)name
                  footer:(NSString *)footer
                    apps:(NSArray<NSDictionary *> *)apps
             toSpecifiers:(NSMutableArray *)specifiers {
    if (apps.count == 0) return;
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:name];
    if (footer) [group setProperty:footer forKey:@"footerText"];
    [specifiers addObject:group];
    for (NSDictionary *app in apps) {
        NSString *bundleID = app[CLInstalledAppBundleIDKey];
        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:app[CLInstalledAppNameKey]
                                                          target:self
                                                             set:@selector(cl_setAppEnabled:specifier:)
                                                             get:@selector(cl_appEnabled:)
                                                          detail:Nil
                                                            cell:PSSwitchCell
                                                            edit:Nil];
        row.identifier = bundleID;
        [row setProperty:bundleID forKey:kCLBundleIDProperty];
        [row setProperty:@YES forKey:PSLazyIconLoading];
        [row setProperty:bundleID forKey:PSLazyIconAppID];
        [specifiers addObject:row];
    }
}

- (id)cl_appEnabled:(PSSpecifier *)specifier {
    NSString *bundleID = [specifier propertyForKey:kCLBundleIDProperty];
    return @(bundleID.length > 0 && [[CLPrefsShared enabledApps] containsObject:bundleID]);
}

- (void)cl_setAppEnabled:(id)value specifier:(PSSpecifier *)specifier {
    NSString *bundleID = [specifier propertyForKey:kCLBundleIDProperty];
    if (bundleID.length == 0) return;
    NSMutableArray<NSString *> *apps = [[CLPrefsShared enabledApps] mutableCopy];
    BOOL enable = [value respondsToSelector:@selector(boolValue)] && [value boolValue];
    if (enable && ![apps containsObject:bundleID]) [apps addObject:bundleID];
    if (!enable) [apps removeObject:bundleID];
    [CLPrefsShared setEnabledApps:apps];
}

@end
