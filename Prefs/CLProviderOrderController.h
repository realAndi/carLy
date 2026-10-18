#import <Preferences/PSViewController.h>

/// Pushed from Sources.plist's "Provider Order" link cell. A plain drag-to-reorder list of the
/// three lyrics providers; persists "providerOrder" via CFPreferences on every move and posts the
/// prefsChanged Darwin notification so a running tweak instance re-reads the chain immediately.
@interface CLProviderOrderController : PSViewController
@end
