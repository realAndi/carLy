#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, CLLogLevel) { CLLogLevelError = 0, CLLogLevelInfo = 1, CLLogLevelDebug = 2 };

/// os_log + append to <NSCachesDirectory>/carLy/log.txt. Thread-safe. Debug lines are dropped
/// unless CLLogSetDebugEnabled(YES) was called (wire it to the "debug" pref).
void CLLogSetDebugEnabled(BOOL enabled);
BOOL CLLogDebugEnabled(void);
NSString *CLLogFilePath(void);
void CLLogWrite(CLLogLevel level, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

#define CLLogError(fmt, ...) CLLogWrite(CLLogLevelError, fmt, ##__VA_ARGS__)
#define CLLogInfo(fmt, ...)  CLLogWrite(CLLogLevelInfo,  fmt, ##__VA_ARGS__)
#define CLLogDebug(fmt, ...) CLLogWrite(CLLogLevelDebug, fmt, ##__VA_ARGS__)
