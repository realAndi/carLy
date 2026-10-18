#import "CLListController.h"

/// "Choose Apps…" on the Apps page: every installed app with its icon and a switch, audio apps
/// first (CLInstalledApps). A switch adds or removes the app's bundle identifier in "enabledApps"
/// and posts prefsChanged at once; the Apps page rebuilds its list when it appears again.
@interface CLAppPickerController : CLListController
@end
