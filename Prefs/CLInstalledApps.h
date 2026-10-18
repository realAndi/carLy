// The apps installed on this iPhone, for the Apps page's picker: LaunchServices'
// LSApplicationWorkspace / LSApplicationProxy, resolved at runtime (no private framework stubs in
// the SDK). Every selector used here is in the 17.3 shared cache: +defaultWorkspace,
// -allInstalledApplications, -applicationIdentifier, -localizedName, -appTags,
// -objectForInfoDictionaryKey:ofClass:, +applicationProxyForIdentifier:. Anything missing makes
// the list shorter, never a crash.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One app: @{ CLInstalledAppBundleIDKey: NSString, CLInstalledAppNameKey: NSString }.
extern NSString *const CLInstalledAppBundleIDKey;
extern NSString *const CLInstalledAppNameKey;

@interface CLInstalledApps : NSObject

/// Visible apps (no hidden system services, no placeholders), sorted by name, split in two:
/// `audioApps` — apps that play audio in the background (UIBackgroundModes "audio", or Apple's
/// Music, Podcasts and Books), the ones that can have a CarPlay Now Playing screen — and every
/// other app. Enumerated off the main thread; `completion` runs on the main queue.
+ (void)loadWithCompletion:(void (^)(NSArray<NSDictionary *> *audioApps, NSArray<NSDictionary *> *otherApps))completion;

/// The app's name as the Home Screen shows it, or nil when it is not installed.
+ (nullable NSString *)nameForBundleIdentifier:(NSString *)bundleIdentifier;

@end

NS_ASSUME_NONNULL_END
