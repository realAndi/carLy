#import <Preferences/PSViewController.h>

/// Pushed from any PSLinkCell whose "detail" is this class and whose specifier carries a "key"
/// for a hex-string colour preference (see Lyrics.plist / Layout.plist). Wraps
/// UIColorPickerViewController (iOS 14+), shows the current hex value, and writes the new hex
/// value back through CFPreferences on change, posting the prefsChanged Darwin notification.
@interface CLColorPickerController : PSViewController
@end
