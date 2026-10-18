#import "CLLog.h"
#import <os/log.h>

static BOOL sDebug = NO;
static dispatch_queue_t sQueue;
static NSString *sPath;
static NSString *sPreviousPath;
static os_log_t sLog;
/// Bytes in log.txt, as far as this process knows. Touched only on sQueue.
static unsigned long long sSize;

/// The file log is an append-only debugging aid in the *caches* directory, which is also where
/// the lyrics cache writes. With debugLogging on the tweak logs on every snapshot update and
/// every line change, so without a cap one long drive — or a user who leaves debug logging on
/// after reporting a problem — grows it without bound and eventually makes cache writes fail.
/// One previous generation is kept (log.1.txt) so a rotation mid-drive does not lose the
/// evidence that was being collected.
static const unsigned long long kCLLogMaxBytes = 2 * 1024 * 1024;

/// sQueue only. Moves log.txt to log.1.txt (replacing any older one) once it is over the cap.
static void CLLogRotateIfNeeded(void) {
    if (sSize <= kCLLogMaxBytes || sPath.length == 0 || sPreviousPath.length == 0) return;
    NSFileManager *manager = [NSFileManager defaultManager];
    [manager removeItemAtPath:sPreviousPath error:NULL];
    if (![manager moveItemAtPath:sPath toPath:sPreviousPath error:NULL]) {
        // Could not rotate (read-only volume, permissions): truncate instead of growing forever.
        [manager removeItemAtPath:sPath error:NULL];
    }
    sSize = 0;
}

static void CLLogSetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sQueue = dispatch_queue_create("com.andi.carly.log", DISPATCH_QUEUE_SERIAL);
        sLog = os_log_create("com.andi.carly", "carLy");
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
        NSString *dir = [caches stringByAppendingPathComponent:@"carLy"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        sPath = [dir stringByAppendingPathComponent:@"log.txt"];
        sPreviousPath = [dir stringByAppendingPathComponent:@"log.1.txt"];
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:sPath error:NULL];
        sSize = attributes ? [attributes fileSize] : 0;
        dispatch_async(sQueue, ^{ CLLogRotateIfNeeded(); });
    });
}

void CLLogSetDebugEnabled(BOOL enabled) { sDebug = enabled; }
BOOL CLLogDebugEnabled(void) { return sDebug; }
NSString *CLLogFilePath(void) { CLLogSetup(); return sPath; }

void CLLogWrite(CLLogLevel level, NSString *format, ...) {
    if (level == CLLogLevelDebug && !sDebug) return;
    CLLogSetup();
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    const char *tag = level == CLLogLevelError ? "E" : level == CLLogLevelInfo ? "I" : "D";
    os_log_with_type(sLog, level == CLLogLevelError ? OS_LOG_TYPE_ERROR : OS_LOG_TYPE_DEFAULT, "[%{public}s] %{public}@", tag, message);
    NSString *line = [NSString stringWithFormat:@"%@ [%s] %@\n", [NSDate date], tag, message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) return;
    dispatch_async(sQueue, ^{
        CLLogRotateIfNeeded();
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:sPath];
        if (!handle) {
            [[NSFileManager defaultManager] createFileAtPath:sPath contents:nil attributes:nil];
            handle = [NSFileHandle fileHandleForWritingAtPath:sPath];
            sSize = 0;
        }
        if (!handle) return;
        @try {
            unsigned long long end = [handle seekToEndOfFile];
            [handle writeData:data];
            sSize = end + data.length;
        } @catch (NSException *e) {}
        [handle closeFile];
    });
}
