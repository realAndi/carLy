#import "CLLogViewController.h"

/// The tweak's log (CLLog: <NSCachesDirectory>/carLy/log.txt inside CarPlayTemplateUIHost,
/// whose caches directory is the plain /var/mobile one). Settings' own NSCachesDirectory is its
/// sandbox container, not the host's, so the path is spelled out rather than derived here.
static NSString *const kCLLogFilePath = @"/var/mobile/Library/Caches/carLy/log.txt";
static const NSUInteger kCLLogMaxLines = 300;

@interface CLLogViewController ()
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIBarButtonItem *refreshItem;
@end

@implementation CLLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Log";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UITextView *textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    textView.editable = NO;
    textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    textView.alwaysBounceVertical = YES;
    [self.view addSubview:textView];
    self.textView = textView;

    self.refreshItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                       target:self
                                                                       action:@selector(cl_reload)];
    self.navigationItem.rightBarButtonItem = self.refreshItem;

    [self cl_reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self cl_reload];
}

- (void)cl_reload {
    self.textView.text = [self cl_tailOfLogFile];
    if (self.textView.text.length > 0) {
        [self.textView scrollRangeToVisible:NSMakeRange(self.textView.text.length - 1, 1)];
    }
}

/// Reads the last kCLLogMaxLines lines of the log file. Returns a human-readable placeholder
/// instead of throwing or crashing when the file is missing, unreadable or not plain text.
- (NSString *)cl_tailOfLogFile {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm isReadableFileAtPath:kCLLogFilePath]) {
        return [NSString stringWithFormat:@"No readable log file at:\n%@\n\nEnable Debug Logging under Maintenance, then trigger the tweak (open CarPlay Now Playing) to generate log output.", kCLLogFilePath];
    }

    NSError *error = nil;
    // The log file can grow large over a long drive; read it as data and decode defensively
    // rather than assuming NSString file-reading will always succeed on partial/binary content.
    NSData *data = [NSData dataWithContentsOfFile:kCLLogFilePath options:0 error:&error];
    if (!data) {
        return [NSString stringWithFormat:@"Could not read log file:\n%@", error.localizedDescription ?: @"unknown error"];
    }
    NSString *contents = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!contents) {
        contents = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    if (!contents) {
        return @"Log file is not readable as text.";
    }
    if (contents.length == 0) {
        return @"Log file is empty.";
    }

    NSArray<NSString *> *allLines = [contents componentsSeparatedByString:@"\n"];
    if (allLines.count <= kCLLogMaxLines) return contents;

    NSArray<NSString *> *tail = [allLines subarrayWithRange:NSMakeRange(allLines.count - kCLLogMaxLines, kCLLogMaxLines)];
    return [tail componentsJoinedByString:@"\n"];
}

@end
