// Base class of every list page in this bundle. Its one job is the inset-grouped table style
// Settings uses on iOS 13 and later, so our pages look like the ones around them, plus one
// helper the pages with colour rows share. Nothing else: no theming, no cell classes, no
// header/footer views.
#import <Preferences/PSListController.h>

@class PSSpecifier;

@interface CLListController : PSListController

/// A colour row (a PSLinkListCell that pushes CLColorPickerController) shows its current value
/// on the row: "#RRGGBB" (or "#RRGGBBAA"), "Default" for the empty string. PSTableCell renders a
/// PSLinkListCell's value only through the specifier's titleDictionary (verified in the 17.3
/// cache: performGetter, then titleDictionary[value], then setValue:), so this rebuilds that
/// dictionary around the value the page currently reads for the row. Call it whenever the value
/// may have changed, then reload the row. Nil-safe.
- (void)cl_refreshColorRowTitle:(PSSpecifier *)specifier;

@end
