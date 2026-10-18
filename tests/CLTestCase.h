// CLTestCase.h — a tiny, dependency-free assertion framework for the cltests tool.
//
// No XCTest (it is not on-device / not linkable into a Theos "tool" target). Every assertion
// macro records a pass or fail into a process-wide, lock-protected counter; CLTestSummarize()
// prints the totals and returns the process exit code (0 all green, 1 otherwise). Assertions are
// safe to call from any thread (the counters are guarded), but the framework does not itself pump
// a run loop for you — tests that exercise asynchronous code (network providers, the provider
// chain, disk writes) must do that themselves; see CLTestWaitUntil() below.
//
// CL_ASSERT_EQ is intentionally generic (C11 _Generic) so the same macro reads naturally for
// integers, unsigned integers, floating point (compared with a small default tolerance) and
// objects (compared with -isEqual:, nil-safe both ways). It dispatches on the *type of the second
// argument* (`expected`), so:
//   CL_ASSERT_EQ(count, 3)                 -> integer compare
//   CL_ASSERT_EQ(line.time, 12.5)          -> double compare, default tolerance
//   CL_ASSERT_EQ(lyrics.plainText, @"hi")  -> -isEqual: compare
// A fixed-underlying-type NS_ENUM (CLLyricsKind, CLProtobufWireType, CLPlaybackStateOrigin, ...)
// is its own distinct C type, not interchangeable with `long` for _Generic dispatch, so callers
// must cast an enum operand to `(long)` on BOTH sides before comparing, e.g.
//   CL_ASSERT_EQ((long)lyrics.kind, (long)CLLyricsKindSynced)
// Use CL_ASSERT_NEAR when a specific floating-point tolerance matters more than the default.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Default absolute tolerance used by CL_ASSERT_EQ for float/double comparisons.
extern const double CLTestDefaultTolerance;

/// Starts a named group in the printed output. Purely cosmetic; does not nest.
void CLTestBeginSuite(const char *name);

/// Total pass/fail counters so far (thread-safe snapshot).
NSUInteger CLTestPassCount(void);
NSUInteger CLTestFailCount(void);

/// Prints a summary line and returns the process exit code (0 = all assertions passed).
int CLTestSummarize(void);

/// Records a single boolean assertion result. Used directly by CL_ASSERT_TRUE/CL_ASSERT_FALSE;
/// exposed so a test file can build its own higher-level assertions on top of it.
void CLTestRecordResult(BOOL passed, const char *exprText, const char *file, int line);

/// nilness check with a clear failure message either way.
void CLTestAssertNilCheck(id _Nullable value, BOOL expectNil, const char *exprText,
                           const char *file, int line);

/// The four concrete comparisons CL_ASSERT_EQ dispatches to. Called directly only if a test needs
/// a specific numeric width or an explicit tolerance (CL_ASSERT_NEAR uses this one).
void CLTestAssertLongEqual(long actual, long expected, const char *actualText,
                            const char *expectedText, const char *file, int line);
void CLTestAssertULongEqual(unsigned long actual, unsigned long expected, const char *actualText,
                             const char *expectedText, const char *file, int line);
void CLTestAssertDoubleEqualTol(double actual, double expected, double tolerance,
                                 const char *actualText, const char *expectedText,
                                 const char *file, int line);
void CLTestAssertObjectEqual(id _Nullable actual, id _Nullable expected, const char *actualText,
                              const char *expectedText, const char *file, int line);

/// CL_ASSERT_EQ's default-tolerance entry point for float/double (declared separately from
/// CLTestAssertDoubleEqualTol so the _Generic table below has a same-arity match for every branch).
void CLTestAssertDoubleEqualDefault(double actual, double expected, const char *actualText,
                                     const char *expectedText, const char *file, int line);

/// Pumps the current thread's run loop until `conditionBlock` returns YES or `timeout` seconds
/// elapse. Returns YES if the condition was met. Use this — never a blind sleep() — to wait for
/// async completions (dispatch_async to the main queue only runs while something services the
/// main run loop, which a plain command-line tool does not do on its own).
typedef BOOL (^CLTestConditionBlock)(void);
BOOL CLTestWaitUntil(NSTimeInterval timeout, CLTestConditionBlock conditionBlock);

#define CL_ASSERT_TRUE(expr) \
    CLTestRecordResult((expr) ? YES : NO, #expr, __FILE__, __LINE__)

#define CL_ASSERT_FALSE(expr) \
    CLTestRecordResult((expr) ? NO : YES, "!(" #expr ")", __FILE__, __LINE__)

#define CL_ASSERT_NIL(expr) \
    CLTestAssertNilCheck((expr), YES, #expr, __FILE__, __LINE__)

#define CL_ASSERT_NOT_NIL(expr) \
    CLTestAssertNilCheck((expr), NO, #expr, __FILE__, __LINE__)

#define CL_ASSERT_NEAR(actual, expected, tolerance) \
    CLTestAssertDoubleEqualTol((double)(actual), (double)(expected), (double)(tolerance), \
                                #actual, #expected, __FILE__, __LINE__)

#define CL_ASSERT_EQ(actual, expected) \
    _Generic((expected), \
        float:              CLTestAssertDoubleEqualDefault, \
        double:             CLTestAssertDoubleEqualDefault, \
        _Bool:              CLTestAssertLongEqual, \
        char:               CLTestAssertLongEqual, \
        signed char:        CLTestAssertLongEqual, \
        short:              CLTestAssertLongEqual, \
        int:                CLTestAssertLongEqual, \
        long:               CLTestAssertLongEqual, \
        long long:          CLTestAssertLongEqual, \
        unsigned char:      CLTestAssertULongEqual, \
        unsigned short:     CLTestAssertULongEqual, \
        unsigned int:       CLTestAssertULongEqual, \
        unsigned long:      CLTestAssertULongEqual, \
        unsigned long long: CLTestAssertULongEqual, \
        default:            CLTestAssertObjectEqual \
    )((actual), (expected), #actual, #expected, __FILE__, __LINE__)

NS_ASSUME_NONNULL_END
