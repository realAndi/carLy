// PLAN.md §5 "Phase 0 — Probe". One-shot, log-only, gated behind the debugLogging preference:
// a single drive has to answer every open question in the plan (network? Spotify container?
// writable cache? MediaRemote in this process? what does the view hierarchy actually look like?).
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the Phase 0 probe at most once per process, the first time a Now Playing screen appears
/// while `debugLogging` is on (turning the pref on later still arms it). Reads UIKit state on the
/// calling thread — which must be the main thread — and does every disk/network check on a
/// background queue. Every line is logged with CLLogInfo and the "[probe]" prefix.
void CLRunPhase0ProbeOnce(UIViewController *_Nullable controller);

NS_ASSUME_NONNULL_END
