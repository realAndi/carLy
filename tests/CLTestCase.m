#import "CLTestCase.h"
#import <os/lock.h>
#import <math.h>

const double CLTestDefaultTolerance = 1e-6;

static os_unfair_lock sCLTestLock = OS_UNFAIR_LOCK_INIT;
static NSUInteger sCLTestPass = 0;
static NSUInteger sCLTestFail = 0;

static NSString *CLTestFileName(const char *file) {
    if (!file) return @"?";
    NSString *path = [NSString stringWithUTF8String:file] ?: @"?";
    return path.lastPathComponent;
}

void CLTestBeginSuite(const char *name) {
    printf("\n== %s ==\n", name ? name : "(suite)");
}

NSUInteger CLTestPassCount(void) {
    os_unfair_lock_lock(&sCLTestLock);
    NSUInteger value = sCLTestPass;
    os_unfair_lock_unlock(&sCLTestLock);
    return value;
}

NSUInteger CLTestFailCount(void) {
    os_unfair_lock_lock(&sCLTestLock);
    NSUInteger value = sCLTestFail;
    os_unfair_lock_unlock(&sCLTestLock);
    return value;
}

static void CLTestNote(BOOL passed, NSString *detail, const char *file, int line) {
    os_unfair_lock_lock(&sCLTestLock);
    if (passed) sCLTestPass++; else sCLTestFail++;
    os_unfair_lock_unlock(&sCLTestLock);
    if (!passed) {
        fprintf(stderr, "  FAIL %s:%d — %s\n", CLTestFileName(file).UTF8String, line, detail.UTF8String);
    }
}

void CLTestRecordResult(BOOL passed, const char *exprText, const char *file, int line) {
    NSString *detail = [NSString stringWithFormat:@"expected true: %s", exprText ?: "?"];
    CLTestNote(passed, detail, file, line);
}

void CLTestAssertNilCheck(id value, BOOL expectNil, const char *exprText, const char *file, int line) {
    BOOL isNil = (value == nil);
    BOOL passed = (isNil == expectNil);
    NSString *detail = [NSString stringWithFormat:@"%s %s nil (was %@)", exprText ?: "?",
                         expectNil ? "expected" : "expected NOT", isNil ? @"nil" : value];
    CLTestNote(passed, detail, file, line);
}

void CLTestAssertLongEqual(long actual, long expected, const char *actualText,
                            const char *expectedText, const char *file, int line) {
    BOOL passed = (actual == expected);
    NSString *detail = [NSString stringWithFormat:@"%s (%ld) == %s (%ld)", actualText ?: "?",
                         actual, expectedText ?: "?", expected];
    CLTestNote(passed, detail, file, line);
}

void CLTestAssertULongEqual(unsigned long actual, unsigned long expected, const char *actualText,
                             const char *expectedText, const char *file, int line) {
    BOOL passed = (actual == expected);
    NSString *detail = [NSString stringWithFormat:@"%s (%lu) == %s (%lu)", actualText ?: "?",
                         actual, expectedText ?: "?", expected];
    CLTestNote(passed, detail, file, line);
}

void CLTestAssertDoubleEqualTol(double actual, double expected, double tolerance,
                                 const char *actualText, const char *expectedText,
                                 const char *file, int line) {
    BOOL bothFinite = isfinite(actual) && isfinite(expected);
    BOOL passed = bothFinite ? (fabs(actual - expected) <= tolerance) : (actual == expected);
    NSString *detail = [NSString stringWithFormat:@"%s (%.6f) ~= %s (%.6f) [tol %.6g]",
                         actualText ?: "?", actual, expectedText ?: "?", expected, tolerance];
    CLTestNote(passed, detail, file, line);
}

void CLTestAssertDoubleEqualDefault(double actual, double expected, const char *actualText,
                                     const char *expectedText, const char *file, int line) {
    CLTestAssertDoubleEqualTol(actual, expected, CLTestDefaultTolerance, actualText, expectedText,
                                file, line);
}

void CLTestAssertObjectEqual(id actual, id expected, const char *actualText,
                              const char *expectedText, const char *file, int line) {
    BOOL passed;
    if (actual == expected) {
        passed = YES;
    } else if (actual == nil || expected == nil) {
        passed = NO;
    } else {
        passed = [actual isEqual:expected];
    }
    NSString *detail = [NSString stringWithFormat:@"%s (%@) == %s (%@)", actualText ?: "?",
                         actual ?: @"nil", expectedText ?: "?", expected ?: @"nil"];
    CLTestNote(passed, detail, file, line);
}

int CLTestSummarize(void) {
    NSUInteger pass = CLTestPassCount();
    NSUInteger fail = CLTestFailCount();
    printf("\n---\n%lu passed, %lu failed (of %lu)\n", (unsigned long)pass, (unsigned long)fail,
           (unsigned long)(pass + fail));
    return fail == 0 ? 0 : 1;
}

BOOL CLTestWaitUntil(NSTimeInterval timeout, CLTestConditionBlock conditionBlock) {
    if (!conditionBlock) return NO;
    if (conditionBlock()) return YES;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline timeIntervalSinceNow] > 0) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        if (conditionBlock()) return YES;
    }
    return conditionBlock();
}
