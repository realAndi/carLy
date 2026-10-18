#import "CLProviderOrderController.h"
#import "CLPrefsShared.h"
#import "Util/CLPrefsKeys.h"

static NSString *const kCLCellReuseID = @"CLProviderRow";

@interface CLProviderOrderController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, copy) NSArray<NSString *> *providerOrder;   // identifiers, current order
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *displayNames;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *subtitles;
@end

@implementation CLProviderOrderController

- (NSArray<NSString *> *)cl_allKnownProviderIdentifiers {
    // The identifiers CLProviderFactory understands, in its default order.
    return @[ @"embedded", @"apple-music", @"spotify", @"spotify-cache", @"lrclib", @"custom" ];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Same names as the switches on the Sources page, which links here as "Source Order".
    self.title = @"Source Order";

    self.displayNames = @{
        @"embedded": @"Embedded Lyrics",
        @"apple-music": @"Apple Music Lyrics",
        @"spotify": @"Spotify Lyrics",
        @"spotify-cache": @"Spotify Cache",
        @"lrclib": @"LRCLIB",
        @"custom": @"Custom Endpoint",
    };
    self.subtitles = @{
        @"embedded": @"Lyrics saved in your own song files",
        @"apple-music": @"Apple's synced lyrics for Apple Music songs",
        @"spotify": @"Spotify's own lyrics for Spotify songs",
        @"spotify-cache": @"Lyrics Spotify already downloaded on this iPhone",
        @"lrclib": @"Free community database, no account",
        @"custom": @"Your own address",
    };

    [self cl_loadProviderOrder];

    UITableView *tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tableView.dataSource = self;
    tableView.delegate = self;
    tableView.editing = YES;
    tableView.allowsSelectionDuringEditing = NO;
    [self.view addSubview:tableView];
    self.tableView = tableView;
}

- (void)cl_loadProviderOrder {
    NSArray<NSString *> *known = [self cl_allKnownProviderIdentifiers];
    NSArray<NSString *> *stored = [CLPrefsShared stringArrayForKey:CLPrefKeyProviderOrder default:known];

    NSMutableArray<NSString *> *ordered = [NSMutableArray arrayWithCapacity:known.count];
    for (NSString *identifier in stored) {
        if ([known containsObject:identifier] && ![ordered containsObject:identifier]) {
            [ordered addObject:identifier];
        }
    }
    // An order saved before a source existed cannot list it ("embedded" and "apple-music" came in
    // 0.8.0, "spotify" in 0.9.0). Each goes right before the first listed source that the default
    // order puts after it — CLProviderFactory's rule, so this list shows the order the tweak uses.
    for (NSString *identifier in @[ @"embedded", @"apple-music", @"spotify" ]) {
        if ([ordered containsObject:identifier]) continue;
        NSUInteger rank = [known indexOfObject:identifier];
        NSUInteger position = ordered.count;
        for (NSUInteger index = 0; index < ordered.count; index++) {
            if ([known indexOfObject:ordered[index]] > rank) {
                position = index;
                break;
            }
        }
        [ordered insertObject:identifier atIndex:position];
    }
    // Defensive: append any known provider missing from the stored (possibly stale/corrupt)
    // array, so the user always sees and can position all of them.
    for (NSString *identifier in known) {
        if (![ordered containsObject:identifier]) [ordered addObject:identifier];
    }
    self.providerOrder = ordered;
}

- (void)cl_persistProviderOrder {
    [CLPrefsShared setValue:self.providerOrder forKey:CLPrefKeyProviderOrder];
    [CLPrefsShared notifyPrefsChanged];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.providerOrder.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"Drag to reorder. Sources are tried top to bottom; the first one with synced lyrics wins (plain text only when none has timed lines). Sources switched off on the previous page are skipped.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCLCellReuseID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kCLCellReuseID];
    }
    NSString *identifier = self.providerOrder[(NSUInteger)indexPath.row];
    cell.textLabel.text = self.displayNames[identifier] ?: identifier;
    cell.detailTextLabel.text = self.subtitles[identifier];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.showsReorderControl = YES;
    return cell;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone; // reorder only, no delete/insert
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES; // required by UIKit for the reorder control to show even with no delete affordance
}

- (void)tableView:(UITableView *)tableView
    moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath
           toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (sourceIndexPath.row == destinationIndexPath.row) return;
    NSMutableArray<NSString *> *order = [self.providerOrder mutableCopy];
    NSUInteger from = (NSUInteger)sourceIndexPath.row;
    NSUInteger to = (NSUInteger)destinationIndexPath.row;
    if (from >= order.count || to >= order.count) return;
    NSString *moved = order[from];
    [order removeObjectAtIndex:from];
    [order insertObject:moved atIndex:to];
    self.providerOrder = order;
    [self cl_persistProviderOrder];
}

@end
