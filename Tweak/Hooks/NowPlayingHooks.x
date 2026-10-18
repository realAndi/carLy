// CarPlay Now Playing hooks.
//
// Everything in this file runs inside com.apple.CarPlayTemplateUIHost, the system process that
// draws the Now Playing screen for CarPlay template apps, and (since 0.8.0) inside com.apple.Music,
// whose CarPlay UI uses the same CarPlayUI classes in its own process. An exception or a bad ivar read here
// does not break "our feature", it tears down the whole CarPlay display while the user is
// driving. So: every class is resolved at runtime, every selector is checked (and, for the
// private observer callbacks, its type encoding is checked too, because hooking a method whose
// arguments are not what we think they are corrupts registers), every ivar read goes through
// CLIvar(), every hook body calls %orig first and does our work behind CLSafePerform(), and the
// master switch (CLHooksActive) turns all of it back into a plain %orig.
//
// The hooks do five things and nothing else:
//   1. attach / feed / detach the ui slice's CLLayoutCustomizer over the controller's lifecycle,
//   2. forward CPUINowPlayingSnapshot metadata into CLNowPlayingSource (PLAN.md §6: the fallback
//      for when MediaRemote is silent inside this process),
//   3. tell the customizer when the artwork changed, for the artwork tint and backdrop,
//   4. arm the Phase 0 probe the first time a Now Playing screen appears,
//   5. give the host's Now Playing view a left-hand column for side by side (lyricsMode 4).

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

#import "CLHooks.h"
#import "CLPhase0Probe.h"
#import "CarPlayUI.h"

#import "Core/CLNowPlayingSource.h"
#import "UI/CLLayoutCustomizer.h"
#import "Util/CLLog.h"
#import "Util/CLRuntime.h"

#pragma mark - State (main thread only)

/// Mirrors the `enabled` preference. Read by every hook body before it does any of our work.
static BOOL gActive = NO;
/// Re-entrancy guard: a customizer's -relayout may change frames, which calls -layoutSubviews
/// again. Without this a mis-written customizer would spin the main thread forever.
static BOOL gInRelayout = NO;
/// Our own handle on the customizer. The ui slice keeps its own association; we keep this one so
/// that a lookup during -dealloc never has to allocate or touch a weak table.
static const void *kCLCustomizerAssociationKey = &kCLCustomizerAssociationKey;

/// Weakly-held set of the controllers we attached to, for the "re-apply prefs to everything" and
/// "switch the tweak off" sweeps. Entries disappear on their own when a controller dies.
static NSHashTable<UIViewController *> *CLAttachedControllers(void) {
    static NSHashTable *table;
    if (!table) table = [NSHashTable weakObjectsHashTable];
    return table;
}

/// Bounces to the main queue when needed. Returns YES when the caller may continue inline.
static BOOL CLOnMainThread(void (*function)(void)) {
    if ([NSThread isMainThread]) return YES;
    dispatch_async(dispatch_get_main_queue(), ^{ function(); });
    return NO;
}

/// One log line per distinct message, ever. Used for "the ui slice does not implement X" style
/// complaints that would otherwise repeat on every layout pass.
static void CLLogOnce(NSString *key, NSString *message) {
    static NSMutableSet<NSString *> *seen;
    if (!seen) seen = [NSMutableSet set];
    if (key.length == 0 || [seen containsObject:key]) return;
    [seen addObject:key];
    CLLogInfo(@"%@", message);
}

#pragma mark - Message-sending helpers

void CLSafePerform(NSString *what, dispatch_block_t block) {
    if (!block) return;
    @try {
        block();
    } @catch (NSException *exception) {
        CLLogError(@"[hook] %@ raised %@: %@", what ?: @"(work)", exception.name, exception.reason);
    }
}

// A typed objc_msgSend cast rather than -performSelector:, so ARC knows the exact signature and
// -Warc-performSelector-leaks never fires. Callers have already checked respondsToSelector:.
static id CLSendObject(id target, SEL selector) {
    if (!target || selector == NULL) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

#pragma mark - Runtime inspection helpers

/// A method type encoding with the frame offsets stripped: "v40@0:8@16@24" -> "v@:@@".
static NSString *CLNormalizedTypeEncoding(const char *encoding) {
    if (encoding == NULL) return nil;
    size_t length = strlen(encoding);
    char *buffer = (char *)malloc(length + 1);
    if (buffer == NULL) return nil;
    size_t out = 0;
    for (size_t i = 0; i < length; i++) {
        if (encoding[i] < '0' || encoding[i] > '9') buffer[out++] = encoding[i];
    }
    buffer[out] = '\0';
    NSString *normalized = [NSString stringWithUTF8String:buffer];
    free(buffer);
    return normalized;
}

/// YES when `className` (or an ancestor) implements `selectorName` with the expected signature.
/// Hooking a selector nobody implements makes %orig a null call; hooking one whose arguments are
/// not all objects when we declared them as objects reads the wrong registers. Both are fatal in
/// this process, so both are checked before the group is initialised.
/// Pass nil for `expectedEncoding` to skip the signature check (UIKit methods we already know).
static BOOL CLClassImplements(NSString *className, NSString *selectorName, NSString *expectedEncoding) {
    Class cls = CLClass(className);
    if (!cls) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (selector == NULL) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) return NO;
    if (expectedEncoding.length == 0) return YES;

    NSString *actual = CLNormalizedTypeEncoding(method_getTypeEncoding(method));
    if ([actual isEqualToString:expectedEncoding]) return YES;
    CLLogInfo(@"[hook] %@ -%@ has signature '%@', expected '%@' — not hooking it",
              className, selectorName, actual ?: @"(unknown)", expectedEncoding);
    return NO;
}

/// Dumps a private class's method list once per class, at debug level. This is how the unknown
/// shape of `_durationSnapshot` / `_responseItem` gets recorded from a single drive.
static void CLLogMethodListOnce(Class cls, NSString *context) {
    if (!cls || !CLLogDebugEnabled()) return;
    static NSMutableSet<NSString *> *reported;
    if (!reported) reported = [NSMutableSet set];
    NSString *name = NSStringFromClass(cls);
    if (name.length == 0 || [reported containsObject:name]) return;
    [reported addObject:name];

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int i = 0; i < count; i++) {
        SEL selector = method_getName(methods[i]);
        NSString *selectorName = selector ? NSStringFromSelector(selector) : nil;
        if (selectorName.length) [names addObject:selectorName];
    }
    free(methods);
    [names sortUsingSelector:@selector(compare:)];
    CLLogDebug(@"[hook] %@ class %@ (%u methods): %@", context ?: @"", name, count,
               names.count ? [names componentsJoinedByString:@", "] : @"(none)");
}

/// Trimmed NSString out of whatever a private ivar happens to hold. nil for empty or non-text.
static NSString *CLTrimmedString(id value) {
    NSString *string = nil;
    if ([value isKindOfClass:[NSString class]]) {
        string = (NSString *)value;
    } else if ([value isKindOfClass:[NSAttributedString class]]) {
        string = [(NSAttributedString *)value string];
    }
    if (![string isKindOfClass:[NSString class]]) return nil;
    string = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return string.length ? string : nil;
}

static NSString *CLStringIvar(id object, NSString *name) {
    return CLTrimmedString(CLIvar(object, name));
}

/// Calls a zero-argument getter and coerces whatever it returns to a double. `found` reports
/// whether a usable number came back. NSInvocation, not objc_msgSend, because the return type is
/// unknown until the signature is asked for and a wrong cast on arm64 reads garbage registers.
static double CLNumericResultOfSelector(id object, SEL selector, BOOL *found) {
    if (found) *found = NO;
    if (!object || selector == NULL || ![object respondsToSelector:selector]) return 0;

    NSMethodSignature *signature = nil;
    @try {
        signature = [object methodSignatureForSelector:selector];
    } @catch (NSException *exception) {
        return 0;
    }
    if (!signature || signature.numberOfArguments != 2) return 0;
    const char *returnType = signature.methodReturnType;
    if (returnType == NULL || returnType[0] == 'v') return 0;

    NSInvocation *invocation = nil;
    @try {
        invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.selector = selector;
        [invocation invokeWithTarget:object];
    } @catch (NSException *exception) {
        return 0;
    }

    double value = 0;
    switch (returnType[0]) {
        case 'd': { double raw = 0; [invocation getReturnValue:&raw]; value = raw; break; }
        case 'f': { float raw = 0; [invocation getReturnValue:&raw]; value = raw; break; }
        case 'q': { long long raw = 0; [invocation getReturnValue:&raw]; value = (double)raw; break; }
        case 'Q': { unsigned long long raw = 0; [invocation getReturnValue:&raw]; value = (double)raw; break; }
        case 'l': { long raw = 0; [invocation getReturnValue:&raw]; value = (double)raw; break; }
        case 'L': { unsigned long raw = 0; [invocation getReturnValue:&raw]; value = (double)raw; break; }
        case 'i': { int raw = 0; [invocation getReturnValue:&raw]; value = (double)raw; break; }
        case 'I': { unsigned int raw = 0; [invocation getReturnValue:&raw]; value = (double)raw; break; }
        case 's': { short raw = 0; [invocation getReturnValue:&raw]; value = (double)raw; break; }
        case 'S': { unsigned short raw = 0; [invocation getReturnValue:&raw]; value = (double)raw; break; }
        case '@': {
            void *raw = NULL;
            [invocation getReturnValue:&raw];
            id result = (__bridge id)raw;
            if (![result isKindOfClass:[NSNumber class]]) return 0;
            value = [(NSNumber *)result doubleValue];
            break;
        }
        default: return 0;
    }
    if (!isfinite(value)) return 0;
    if (found) *found = YES;
    return value;
}

/// The names a CarPlay duration snapshot might expose. Probed in order; every one of them is a
/// plain getter, so asking has no effect on the host's state.
static NSArray<NSString *> *CLDurationSelectorNames(void) {
    static NSArray<NSString *> *names;
    if (!names) {
        names = @[ @"duration", @"totalTime", @"trackLength", @"playbackDuration",
                   @"durationInSeconds", @"durationSeconds", @"totalDuration", @"length" ];
    }
    return names;
}

/// Best-effort track length in seconds out of `_durationSnapshot` (or the snapshot itself).
/// 0 when nothing plausible turned up — CLNowPlayingSource reads 0 as "unknown" and keeps
/// whatever MediaRemote told it, so guessing wrong is worse than answering 0.
static NSTimeInterval CLDurationFromObject(id object, NSString *context) {
    if (!object) return 0;
    CLLogMethodListOnce(object_getClass(object), context);

    for (NSString *name in CLDurationSelectorNames()) {
        SEL selector = NSSelectorFromString(name);
        if (selector == NULL || ![object respondsToSelector:selector]) continue;
        BOOL found = NO;
        double value = CLNumericResultOfSelector(object, selector, &found);
        if (!found || value <= 0) continue;
        CLLogDebug(@"[hook] %@ -%@ = %.3f (raw)", context ?: @"duration", name, value);
        // Some media stacks report milliseconds. Nothing on a Now Playing screen is ten hours
        // long, so a number that large is a unit mismatch, not a very long podcast.
        if (value > 36000.0) value /= 1000.0;
        if (value <= 0 || value > 86400.0) continue;
        return (NSTimeInterval)value;
    }
    return 0;
}

#pragma mark - Layout customizer

// CLLayoutCustomizer (the ui slice) is compiled into this same dylib, so the hooks message it
// directly: typed, compile-checked sends instead of the NSSelectorFromString dispatch this file
// carried while the two slices were being written in parallel. If the two ever disagree again,
// that is now a build error here rather than a silent no-op in the car. Messages to a nil
// customizer are no-ops, so every call site below is nil-safe without a wrapper.
//
// One piece of indirection stays: we keep our own association alongside the ui slice's private
// one. -[CPUINowPlayingViewController dealloc] has to be able to ask "is there a customizer?"
// without allocating, without the weak table, and without passing the deallocating controller as
// an ARC-strong argument to anything — and objc_getAssociatedObject on our own key answers that.

/// The customizer for `viewController`, creating and registering one when `create` is YES.
/// Main thread only (the ui slice enforces that too and returns nil off it).
static CLLayoutCustomizer *CLCustomizerForViewController(UIViewController *viewController, BOOL create) {
    if (!viewController) return nil;

    id existing = objc_getAssociatedObject(viewController, kCLCustomizerAssociationKey);
    if ([existing isKindOfClass:[CLLayoutCustomizer class]]) return existing;
    if (!create) return nil;

    // +customizerForViewController:create:YES also attaches and stores the ui slice's own
    // association; ours is the dealloc-safe mirror of it.
    CLLayoutCustomizer *customizer = [CLLayoutCustomizer customizerForViewController:viewController
                                                                              create:YES];
    if (!customizer) return nil;

    objc_setAssociatedObject(viewController, kCLCustomizerAssociationKey, customizer,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [CLAttachedControllers() addObject:viewController];
    return customizer;
}

/// Drops the customizer for `viewController` — the ui slice restores the host's own layout — and
/// forgets both associations.
static void CLDetachCustomizer(UIViewController *viewController) {
    if (!viewController) return;
    [CLLayoutCustomizer detachFromViewController:viewController];
    objc_setAssociatedObject(viewController, kCLCustomizerAssociationKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Controller lifecycle

static void CLRequestRelayout(UIViewController *controller) {
    if (!controller || gInRelayout) return;
    CLLayoutCustomizer *customizer = CLCustomizerForViewController(controller, NO);
    if (!customizer) return;
    gInRelayout = YES;
    @try {
        [customizer relayout];
    } @catch (NSException *exception) {
        CLLogError(@"[hook] relayout raised %@: %@", exception.name, exception.reason);
    } @finally {
        gInRelayout = NO;
    }
}

NSString *const CLNowPlayingScreenWillAppearNotification = @"CLNowPlayingScreenWillAppearNotification";

static void CLControllerDidAppear(UIViewController *controller) {
    if (!controller) return;
    [[NSNotificationCenter defaultCenter] postNotificationName:CLNowPlayingScreenWillAppearNotification
                                                        object:controller];
    CLLayoutCustomizer *customizer = CLCustomizerForViewController(controller, YES);
    // +customizerForViewController:create:YES attached it; -attachToViewController: is only
    // needed when an earlier -detach left the object behind (the tweak was switched off and on).
    if (!customizer.isAttached) [customizer attachToViewController:controller];
    [customizer setPaused:NO];
    [customizer applyPrefs];
    CLRunPhase0ProbeOnce(controller);
}

static void CLControllerWillDisappear(UIViewController *controller) {
    // Deliberately still attached: the screen comes straight back when the user returns to Now
    // Playing, and re-running the whole layout surgery on every appearance is both expensive and
    // a chance to get the restore wrong. We only ask the customizer to stop animating.
    [CLCustomizerForViewController(controller, NO) setPaused:YES];
}

/// -dealloc path. `controller` is __unsafe_unretained on purpose: retaining an object that is
/// already deallocating (which a block capture or a strong parameter can do) resurrects it and
/// crashes on the second release. For the same reason this never touches the weak hash table
/// (it clears itself) and never writes an associated object (the runtime tears them down for us).
static void CLControllerWillDealloc(__unsafe_unretained UIViewController *controller) {
    if (!controller) return;
    id customizer = objc_getAssociatedObject(controller, kCLCustomizerAssociationKey);
    if (![customizer isKindOfClass:[CLLayoutCustomizer class]]) return;
    // -detach, never +detachFromViewController:: the class method would hand the deallocating
    // controller to ARC. The customizer itself is a normal live object, so messaging it is fine.
    [(CLLayoutCustomizer *)customizer detach];
    CLLogDebug(@"[hook] now playing controller deallocating; customizer detached");
}

/// The CPUINowPlayingViewController that owns `view`, via the responder chain. Bounded so a
/// pathological chain cannot spin the main thread.
static UIViewController *CLOwningNowPlayingController(UIView *view) {
    Class controllerClass = CLClass(@"CPUINowPlayingViewController");
    if (!controllerClass || ![view isKindOfClass:[UIView class]]) return nil;
    UIResponder *responder = view;
    for (NSInteger step = 0; responder != nil && step < 32; step++) {
        if ([responder isKindOfClass:controllerClass]) return (UIViewController *)responder;
        responder = responder.nextResponder;
    }
    return nil;
}

#pragma mark - Snapshot ingestion

static NSString *CLContentIdentifierFromResponseItem(id responseItem) {
    if (!responseItem) return nil;
    CLLogMethodListOnce(object_getClass(responseItem), @"responseItem");
    for (NSString *name in @[ @"contentItemIdentifier", @"contentIdentifier", @"identifier",
                              @"externalContentIdentifier" ]) {
        SEL selector = NSSelectorFromString(name);
        if (selector == NULL || ![responseItem respondsToSelector:selector]) continue;
        id value = nil;
        @try {
            value = CLSendObject(responseItem, selector);
        } @catch (NSException *exception) {
            continue;
        }
        NSString *identifier = CLTrimmedString(value);
        if (identifier) {
            CLLogDebug(@"[hook] responseItem -%@ supplied the content identifier", name);
            return identifier;
        }
    }
    return nil;
}

static void CLIngestSnapshot(id snapshot, id manager, UIViewController *controller) {
    if (!snapshot) {
        CLLogDebug(@"[hook] didUpdateSnapshot: nil snapshot");
        return;
    }
    CLLogMethodListOnce(object_getClass(snapshot), @"snapshot");

    NSString *title = CLStringIvar(snapshot, @"_title");
    NSString *artist = CLStringIvar(snapshot, @"_artist");
    NSString *album = CLStringIvar(snapshot, @"_album");
    NSString *bundleIdentifier = CLStringIvar(snapshot, @"_bundleIdentifier");
    if (!bundleIdentifier) bundleIdentifier = CLStringIvar(manager, @"_bundleIdentifier");
    if (!bundleIdentifier) bundleIdentifier = CLStringIvar(controller, @"_bundleIdentifier");

    id durationSnapshot = CLIvar(snapshot, @"_durationSnapshot");
    NSTimeInterval duration = CLDurationFromObject(durationSnapshot, @"durationSnapshot");
    if (duration <= 0) duration = CLDurationFromObject(snapshot, @"snapshot");

    // PLAN.md §3.2: this is where "spotify:track:<id>#<uuid>" comes from when MediaRemote is
    // silent, and it is what the Spotify on-disk lyrics provider keys on.
    NSString *contentIdentifier = CLStringIvar(manager, @"_lastContentItemIdentifier");
    id responseItem = CLIvar(snapshot, @"_responseItem");
    if (!contentIdentifier) contentIdentifier = CLContentIdentifierFromResponseItem(responseItem);

    // Titles and artists are the user's listening history: debug level only, never in a release log.
    CLLogDebug(@"[hook] snapshot bundle=%@ title=%@ artist=%@ album=%@ duration=%.2f content=%@ "
               @"durationSnapshotClass=%@ responseItemClass=%@",
               bundleIdentifier ?: @"(nil)", title ?: @"(nil)", artist ?: @"(nil)",
               album ?: @"(nil)", duration, contentIdentifier ?: @"(nil)",
               durationSnapshot ? NSStringFromClass(object_getClass(durationSnapshot)) : @"(nil)",
               responseItem ? NSStringFromClass(object_getClass(responseItem)) : @"(nil)");

    if (!title && !artist && !bundleIdentifier && !contentIdentifier) return;

    [[CLNowPlayingSource sharedSource] ingestExternalTitle:title
                                                    artist:artist
                                                     album:album
                                                  duration:duration
                                          bundleIdentifier:bundleIdentifier
                                         contentIdentifier:contentIdentifier];
}

#pragma mark - Hooks: CPUINowPlayingViewController lifecycle

%group CLGroupNowPlayingController

%hook CPUINowPlayingViewController

- (void)viewDidLoad {
    %orig;
    if (!gActive) return;
    CLSafePerform(@"viewDidLoad", ^{
        CLLogDebug(@"[hook] %@ viewDidLoad (view %@, bundle %@)",
                   NSStringFromClass([self class]),
                   self.isViewLoaded ? NSStringFromClass(object_getClass(self.view)) : @"(not loaded)",
                   CLStringIvar(self, @"_bundleIdentifier") ?: @"(nil)");
    });
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!gActive) return;
    CLSafePerform(@"viewWillAppear:", ^{ CLControllerDidAppear(self); });
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (!gActive) return;
    CLSafePerform(@"viewDidLayoutSubviews", ^{ CLRequestRelayout(self); });
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (!gActive) return;
    CLSafePerform(@"viewWillDisappear:", ^{ CLControllerWillDisappear(self); });
}

// Full-screen lyrics hide the host's player, and with it the one button its own answer names
// (its play/pause button): hand the knob our buttons instead while they are up.
- (NSArray *)preferredFocusEnvironments {
    NSArray *ours = nil;
    if (gActive) {
        @try {
            ours = [CLLayoutCustomizer focusEnvironmentsForViewController:self];
        } @catch (NSException *exception) {
            CLLogError(@"[hook] preferredFocusEnvironments raised %@: %@", exception.name, exception.reason);
            ours = nil;
        }
    }
    return ours.count ? ours : %orig;
}

- (void)dealloc {
    // No block, and no strong reference to self: see CLControllerWillDealloc.
    @try {
        CLControllerWillDealloc(self);
    } @catch (NSException *exception) {
        CLLogError(@"[hook] dealloc cleanup raised %@: %@", exception.name, exception.reason);
    }
    %orig;
}

%end

%end  // CLGroupNowPlayingController

#pragma mark - Hooks: snapshot delivery

%group CLGroupNowPlayingSnapshot

%hook CPUINowPlayingViewController

- (void)nowPlayingManager:(CPUINowPlayingManager *)manager
        didUpdateSnapshot:(CPUINowPlayingSnapshot *)snapshot {
    %orig;
    if (!gActive) return;
    CLSafePerform(@"nowPlayingManager:didUpdateSnapshot:", ^{
        CLIngestSnapshot(snapshot, manager, self);
    });
}

%end

%end  // CLGroupNowPlayingSnapshot

#pragma mark - Hooks: artwork availability

%group CLGroupNowPlayingArtwork

%hook CPUINowPlayingViewController

- (void)nowPlayingManager:(CPUINowPlayingManager *)manager
        artworkDataDidBecomeAvailable:(id)data
                           identifier:(id)identifier {
    %orig;
    if (!gActive) return;
    CLSafePerform(@"artworkDataDidBecomeAvailable", ^{
        // %orig has already handed the image to _artworkView, so the customizer can read it now.
        [CLCustomizerForViewController(self, NO) artworkDidChange];
    });
}

%end

%end  // CLGroupNowPlayingArtwork

#pragma mark - Hooks: CPUINowPlayingView layout

%group CLGroupNowPlayingView

%hook CPUINowPlayingView

- (void)layoutSubviews {
    %orig;
    if (!gActive || gInRelayout) return;
    CLSafePerform(@"CPUINowPlayingView layoutSubviews", ^{
        CLRequestRelayout(CLOwningNowPlayingController(self));
    });
}

%end

%end  // CLGroupNowPlayingView

#pragma mark - Hooks: side by side (lyricsMode 4)

// Verified on iOS 17.3 (docs/research/CarPlayUI-17.3-layout.md): -[CPUINowPlayingViewController
// viewDidLayoutSubviews] calls -_recalculateLayout: on every pass. That calls -[CPUINowPlayingView
// recalculateLayout:…] with the controller view's frame and safe-area frame, whose layout chooser
// stacks the art above the controls when the safe area is narrower than 1.35:1, and then rebuilds
// _nowPlayingSizeConstraints to pin the Now Playing view across the whole safe area.
//
// Mode 4 hands the view a left-hand player area's rects instead (so the host itself lays out a
// stacked player there, or on short screens its art-left side layout) and swaps the size
// constraints for the area's afterwards. Mode 2 hands it a full-width bottom strip without
// artwork, or on short screens a leading column without artwork. All of it lives in
// CLLayoutCustomizer; these hooks only call it at the right moments.

%group CLGroupSideBySide

%hook CPUINowPlayingViewController

- (void)_recalculateLayout:(BOOL)force {
    if (!gActive) {
        %orig;
        return;
    }
    CLSafePerform(@"_recalculateLayout: (before)", ^{
        [CLLayoutCustomizer hostWillRecalculateLayoutForViewController:self];
    });
    %orig;
    CLSafePerform(@"_recalculateLayout: (after)", ^{
        [CLLayoutCustomizer hostDidRecalculateLayoutForViewController:self];
    });
}

%end

%hook CPUINowPlayingView

- (void)recalculateLayout:(BOOL)force
           allowsAlbumArt:(BOOL)allowsAlbumArt
            hasDataSource:(BOOL)hasDataSource
                 viewArea:(CGRect)viewArea
                 safeArea:(CGRect)safeArea
           rightHandDrive:(BOOL)rightHandDrive {
    if (!gActive) {
        %orig;
        return;
    }
    CGRect columnViewArea = viewArea;
    CGRect columnSafeArea = safeArea;
    if (CLPlayerColumnRects(self, &columnViewArea, &columnSafeArea)) {
        // Right-hand drive is only the chooser's pick between the two side layouts, and YES picks
        // LeftArtwork: the art on the left, whichever side the driver actually sits. A stacked
        // layout ignores it. No album art makes the chooser return its artwork-less stacked layout
        // (the full panel's bottom strip), which hides the artwork square itself.
        BOOL hidesArtwork = CLHostLayoutHidesArtwork(self);
        // A trailing column (Lyrics Side: Left) mirrors that: NO picks RightArtwork, art on the right.
        BOOL artOnLeft = CLHostLayoutArtworkOnLeft(self);
        %orig(force, allowsAlbumArt && !hidesArtwork, hasDataSource, columnViewArea, columnSafeArea, artOnLeft);
    } else {
        %orig;
    }
}

%end

%end  // CLGroupSideBySide

#pragma mark - Hooks: the play-mode buttons' visibility (0.7.4)

%group CLGroupPlayModesState

%hook CPUINowPlayingViewController

// -_updatePlayModesState shows or hides the play-mode buttons by the app's abilities, including the
// playback-speed ("1×") button that Layout > Hide Playback Speed Button hides (verified, iOS 17.3).
- (void)_updatePlayModesState {
    %orig;
    if (!gActive) return;
    CLSafePerform(@"_updatePlayModesState", ^{
        [CLLayoutCustomizer hostPlayModesDidUpdateForViewController:self];
    });
}

%end

%end  // CLGroupPlayModesState

#pragma mark - Hooks: the play-mode row and the transport row (full-screen lyrics, 0.7.0)

// -[CPUIPlayModeControlView setMediaButtons:] appends the template's buttons after our microphone
// on every reload, and marks only its own view for layout, so none of the hooks above sees it.
%group CLGroupPlayModeRow

%hook CPUIPlayModeControlView

- (void)setMediaButtons:(NSArray *)buttons {
    %orig;
    if (!gActive) return;
    CLSafePerform(@"setMediaButtons:", ^{
        [CLLayoutCustomizer hostPlayModeRowDidChangeForViewController:CLOwningNowPlayingController((UIView *)self)];
    });
}

%end

%end  // CLGroupPlayModeRow

// The host swaps its play/pause glyph here when playback changes (the steering wheel, Siri, the
// phone): the full-screen view mirrors that glyph.
%group CLGroupTransportRow

%hook CPUITransportControlView

- (void)_updatePlayPauseButton {
    %orig;
    if (!gActive) return;
    CLSafePerform(@"_updatePlayPauseButton", ^{
        [CLLayoutCustomizer hostTransportDidUpdateForViewController:CLOwningNowPlayingController((UIView *)self)];
    });
}

%end

%end  // CLGroupTransportRow

#pragma mark - Hooks: Apple Music placeholder (PLAN.md §5 Phase 4)

%group CLGroupMusicCarDisplay

%hook MCDNowPlayingViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!gActive) return;
    CLSafePerform(@"MCD viewWillAppear:", ^{
        // Log only. The lyrics engine is app-agnostic, but this stack has its own layout and its
        // own data source, so wiring it up is future work.
        CLLogOnce(@"mcd-appeared",
                  @"[hook] MCDNowPlayingViewController appeared (Apple Music stack, not handled yet)");
    });
}

%end

%end  // CLGroupMusicCarDisplay

#pragma mark - Focus logging (debug)

/// "UIButton {{112, 180}, {44, 44}} in CPUINowPlayingView [lyrics]" for a focus item.
static NSString *CLDescribeFocusItem(id item) {
    if (!item) return @"(none)";
    NSString *name = NSStringFromClass([item class]) ?: @"?";
    if (![item isKindOfClass:[UIView class]]) return name;
    UIView *view = (UIView *)item;
    CGRect frame = view.window ? [view convertRect:view.bounds toView:nil] : view.frame;
    NSString *container = @"";
    BOOL inLyrics = NO;
    Class panelClass = NSClassFromString(@"CLLyricsPanelView");
    for (UIView *ancestor = view.superview; ancestor != nil; ancestor = ancestor.superview) {
        if (panelClass && [ancestor isKindOfClass:panelClass]) inLyrics = YES;
        if (container.length == 0 && [NSStringFromClass([ancestor class]) hasPrefix:@"CPUI"]) {
            container = [NSString stringWithFormat:@" in %@", NSStringFromClass([ancestor class])];
        }
    }
    return [NSString stringWithFormat:@"%@ %@%@%@", name, NSStringFromCGRect(frame), container,
            inLyrics ? @" [lyrics]" : @""];
}

/// One line per focus move, at debug level: the only way to see where the rotary knob's focus goes
/// without a debugger attached to the car's screen.
static void CLInstallFocusLoggingOnce(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    [[NSNotificationCenter defaultCenter] addObserverForName:UIFocusDidUpdateNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *notification) {
        if (!gActive || !CLLogDebugEnabled()) return;
        CLSafePerform(@"focus log", ^{
            id context = notification.userInfo[UIFocusUpdateContextKey];
            if (![context isKindOfClass:[UIFocusUpdateContext class]]) return;
            UIFocusUpdateContext *update = (UIFocusUpdateContext *)context;
            CLLogDebug(@"[focus] %@ -> %@ (heading %lu)", CLDescribeFocusItem(update.previouslyFocusedItem),
                       CLDescribeFocusItem(update.nextFocusedItem), (unsigned long)update.focusHeading);
        });
    }];
}

#pragma mark - Installation and master switch

void CLHooksSetActive(BOOL active) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ CLHooksSetActive(active); });
        return;
    }
    if (gActive == active) return;
    gActive = active;
    CLLogInfo(@"[hook] hooks are now %@", active ? @"active" : @"inert (enabled = NO)");
}

BOOL CLHooksActive(void) { return gActive; }

void CLHooksApplyPrefsToAttachedControllers(void) {
    if (!CLOnMainThread(CLHooksApplyPrefsToAttachedControllers)) return;
    CLSafePerform(@"applyPrefs sweep", ^{
        for (UIViewController *controller in CLAttachedControllers().allObjects) {
            [CLCustomizerForViewController(controller, NO) applyPrefs];
            CLRequestRelayout(controller);
        }
    });
}

void CLHooksDetachAll(void) {
    if (!CLOnMainThread(CLHooksDetachAll)) return;
    CLSafePerform(@"detach sweep", ^{
        NSArray<UIViewController *> *controllers = CLAttachedControllers().allObjects;
        for (UIViewController *controller in controllers) {
            CLDetachCustomizer(controller);
        }
        [CLAttachedControllers() removeAllObjects];
        CLLogInfo(@"[hook] detached %lu now playing controller(s)", (unsigned long)controllers.count);
    });
}

void CLInstallNowPlayingHooks(void) {
    if (!CLOnMainThread(CLInstallNowPlayingHooks)) return;

    // Each group is initialised at most once. A second %init would hook the same method twice and
    // make %orig call our own replacement, which recurses until the stack runs out.
    static BOOL installedController = NO;
    static BOOL installedSnapshot = NO;
    static BOOL installedArtwork = NO;
    static BOOL installedView = NO;
    static BOOL installedSideBySide = NO;
    static BOOL installedMusic = NO;
    static BOOL installedPlayModeRow = NO;
    static BOOL installedTransportRow = NO;
    static BOOL installedPlayModesState = NO;

    CLSafePerform(@"install hooks", ^{
        CLInstallFocusLoggingOnce();
        if (!installedController && CLClass(@"CPUINowPlayingViewController")) {
            installedController = YES;
            %init(CLGroupNowPlayingController);
            CLLogInfo(@"[hook] installed CPUINowPlayingViewController lifecycle hooks");
        }
        if (!installedSnapshot &&
            CLClassImplements(@"CPUINowPlayingViewController",
                              @"nowPlayingManager:didUpdateSnapshot:", @"v@:@@")) {
            installedSnapshot = YES;
            %init(CLGroupNowPlayingSnapshot);
            CLLogInfo(@"[hook] installed nowPlayingManager:didUpdateSnapshot:");
        }
        if (!installedArtwork &&
            CLClassImplements(@"CPUINowPlayingViewController",
                              @"nowPlayingManager:artworkDataDidBecomeAvailable:identifier:",
                              @"v@:@@@")) {
            installedArtwork = YES;
            %init(CLGroupNowPlayingArtwork);
            CLLogInfo(@"[hook] installed nowPlayingManager:artworkDataDidBecomeAvailable:identifier:");
        }
        if (!installedView && CLClass(@"CPUINowPlayingView")) {
            installedView = YES;
            %init(CLGroupNowPlayingView);
            CLLogInfo(@"[hook] installed CPUINowPlayingView layoutSubviews");
        }
        // All four or nothing: a column the host is not told about, or constraints it cannot take
        // back, would leave its Now Playing view half-moved.
        if (!installedSideBySide &&
            CLClassImplements(@"CPUINowPlayingViewController", @"_recalculateLayout:", @"v@:B") &&
            CLClassImplements(@"CPUINowPlayingViewController", @"nowPlayingSizeConstraints", @"@@:") &&
            CLClassImplements(@"CPUINowPlayingViewController", @"setNowPlayingSizeConstraints:", @"v@:@") &&
            CLClassImplements(@"CPUINowPlayingView",
                              @"recalculateLayout:allowsAlbumArt:hasDataSource:viewArea:safeArea:rightHandDrive:",
                              @"v@:BBB{CGRect={CGPoint=dd}{CGSize=dd}}{CGRect={CGPoint=dd}{CGSize=dd}}B")) {
            installedSideBySide = YES;
            %init(CLGroupSideBySide);
            CLLayoutCustomizer.hostColumnHooksInstalled = YES;
            CLLogInfo(@"[hook] installed side-by-side layout hooks");
        }
        if (!installedPlayModeRow &&
            CLClassImplements(@"CPUIPlayModeControlView", @"setMediaButtons:", @"v@:@")) {
            installedPlayModeRow = YES;
            %init(CLGroupPlayModeRow);
            CLLogInfo(@"[hook] installed CPUIPlayModeControlView setMediaButtons:");
        }
        if (!installedTransportRow &&
            CLClassImplements(@"CPUITransportControlView", @"_updatePlayPauseButton", @"v@:")) {
            installedTransportRow = YES;
            %init(CLGroupTransportRow);
            CLLogInfo(@"[hook] installed CPUITransportControlView _updatePlayPauseButton");
        }
        if (!installedPlayModesState &&
            CLClassImplements(@"CPUINowPlayingViewController", @"_updatePlayModesState", @"v@:")) {
            installedPlayModesState = YES;
            %init(CLGroupPlayModesState);
            CLLogInfo(@"[hook] installed CPUINowPlayingViewController _updatePlayModesState");
        }
        if (!installedMusic && CLClass(@"MCDNowPlayingViewController")) {
            installedMusic = YES;
            %init(CLGroupMusicCarDisplay);
            CLLogInfo(@"[hook] installed MCDNowPlayingViewController placeholder");
        }

        if (CLLogDebugEnabled()) {
            // Where does the observer protocol actually live on this build? One drive answers it.
            for (NSString *name in @[ @"CPUINowPlayingViewController", @"CPUINowPlayingManager",
                                      @"CPUINowPlayingView", @"CPUINowPlayingSnapshot" ]) {
                CLLogDebug(@"[hook] %@: present=%d snapshot=%d artwork=%d", name,
                           (int)(CLClass(name) != nil),
                           (int)CLClassImplements(name, @"nowPlayingManager:didUpdateSnapshot:", nil),
                           (int)CLClassImplements(name,
                                                  @"nowPlayingManager:artworkDataDidBecomeAvailable:identifier:",
                                                  nil));
            }
        }
        if (!installedController) {
            CLLogInfo(@"[hook] CarPlayUI is not loaded yet; will retry");
        }
    });
}
