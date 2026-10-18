#import <Preferences/PSViewController.h>

/// Pushed from Maintenance.plist's "Show Log" link cell. Read-only viewer for the tail of the
/// running tweak's log file. No dependency on Tweak/Util/CLLog.m — the path is a plain constant
/// (the same path CLLog.h documents: <NSCachesDirectory>/carLy/log.txt, which on this rootless
/// jailbreak is the ordinary, unrooted /var/mobile/Library/Caches path — ordinary apps like
/// Settings.app never need the /var/jb rootless prefix).
@interface CLLogViewController : PSViewController
@end
