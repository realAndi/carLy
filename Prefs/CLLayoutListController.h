// The Layout page. Unlike every other page in the bundle, nothing here writes a preference when
// a control changes: values are staged on this instance, the preview in the table header shows
// them, and Apply (in the navigation bar) writes them all at once and posts the change to the
// car. Cancel, or leaving the page, discards them.
#import "CLListController.h"

@interface CLLayoutListController : CLListController
- (void)applyStagedChanges;
- (void)cancelStagedChanges;
@end
