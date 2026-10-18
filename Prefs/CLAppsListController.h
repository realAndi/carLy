#import "CLListController.h"

/// "Apps" page: the allApps switch plus the enabled now-playing apps, by name, with their icons
/// (remove with a swipe; add with Choose Apps…, CLAppPickerController, which lists the installed
/// apps). Reads/writes the "enabledApps" array through CLPrefsShared. The list (and Choose
/// Apps…) is left out while All Apps is on.
@interface CLAppsListController : CLListController
@end
