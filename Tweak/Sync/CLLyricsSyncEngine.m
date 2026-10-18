#import "Sync/CLLyricsSyncEngine.h"
#import "Util/CLLog.h"

const NSInteger CLLyricsNoLine = -1;

static const NSTimeInterval kCLMinTick = 0.02;
static const NSTimeInterval kCLMaxTick = 1.0;
static const NSTimeInterval kCLMaxOffset = 30.0;

static void CLSyncRunOnMain(dispatch_block_t block) {
    if (!block) return;
    if (NSThread.isMainThread) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

static NSTimeInterval CLClamp(NSTimeInterval value, NSTimeInterval low, NSTimeInterval high) {
    if (!isfinite(value)) return low;
    if (value < low) return low;
    if (value > high) return high;
    return value;
}

@implementation CLLyricsSyncEngine {
    dispatch_source_t _timer;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _currentLineIndex = CLLyricsNoLine;
    _tickInterval = 0.1;
    _finalLineDuration = 5.0;
    return self;
}

- (void)dealloc {
    if (_timer) dispatch_source_cancel(_timer);
}

#pragma mark - Inputs

- (void)setLines:(NSArray<CLLyricLine *> *)lines {
    NSArray<CLLyricLine *> *sanitized = [self.class sanitizedLines:lines];
    CLSyncRunOnMain(^{
        self->_lines = sanitized;
        self->_currentLineIndex = CLLyricsNoLine;   // force a change callback for the new set
        CLLogDebug(@"Sync engine loaded %lu lines", (unsigned long)sanitized.count);
        [self reevaluate];
        [self updateTimerState];
    });
}

/// Drops anything that is not a usable line and guarantees ascending order without disturbing
/// lines that already share a timestamp.
+ (NSArray<CLLyricLine *> *)sanitizedLines:(NSArray<CLLyricLine *> *)lines {
    if (![lines isKindOfClass:NSArray.class] || lines.count == 0) return @[];
    NSMutableArray<CLLyricLine *> *clean = [NSMutableArray arrayWithCapacity:lines.count];
    BOOL sorted = YES;
    NSTimeInterval previous = -INFINITY;
    for (id candidate in lines) {
        if (![candidate isKindOfClass:CLLyricLine.class]) continue;
        CLLyricLine *line = candidate;
        if (!isfinite(line.time)) continue;
        if (line.time < previous) sorted = NO;
        previous = line.time;
        [clean addObject:line];
    }
    if (sorted) return [clean copy];
    return [clean sortedArrayWithOptions:NSSortStable
                         usingComparator:^NSComparisonResult(CLLyricLine *a, CLLyricLine *b) {
        if (a.time < b.time) return NSOrderedAscending;
        if (a.time > b.time) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

- (void)setOffset:(NSTimeInterval)offset {
    NSTimeInterval clamped = CLClamp(offset, -kCLMaxOffset, kCLMaxOffset);
    CLSyncRunOnMain(^{
        if (self->_offset == clamped) return;
        self->_offset = clamped;
        [self reevaluate];
    });
}

- (void)setTickInterval:(NSTimeInterval)tickInterval {
    NSTimeInterval clamped = CLClamp(tickInterval, kCLMinTick, kCLMaxTick);
    CLSyncRunOnMain(^{
        if (self->_tickInterval == clamped) return;
        self->_tickInterval = clamped;
        if (self->_timer) {       // restart so the new period takes effect
            [self stopTimer];
            [self updateTimerState];
        }
    });
}

- (void)setFinalLineDuration:(NSTimeInterval)finalLineDuration {
    NSTimeInterval clamped = CLClamp(finalLineDuration, 0.5, 60.0);
    CLSyncRunOnMain(^{ self->_finalLineDuration = clamped; });
}

- (void)updateWithPlaybackState:(CLPlaybackState *)state {
    CLSyncRunOnMain(^{
        self->_playbackState = state;
        [self reevaluate];
        [self updateTimerState];
    });
}

- (void)stop {
    CLSyncRunOnMain(^{
        [self stopTimer];
        self->_playbackState = nil;
        [self setCurrentLineIndex:CLLyricsNoLine];
    });
}

#pragma mark - Evaluation

- (NSTimeInterval)effectiveElapsed {
    CLPlaybackState *state = _playbackState;
    NSTimeInterval elapsed = state ? state.elapsedNow : 0;
    return elapsed + _offset;
}

- (void)reevaluate {
    CLSyncRunOnMain(^{
        if (self->_lines.count == 0) {
            [self setCurrentLineIndex:CLLyricsNoLine];
            return;
        }
        [self setCurrentLineIndex:[self indexForEffectiveElapsed:[self effectiveElapsed]]];
    });
}

/// Main queue only.
- (void)setCurrentLineIndex:(NSInteger)index {
    if (index == _currentLineIndex) return;
    _currentLineIndex = index;
    CLLyricsSyncLineChangedBlock block = self.onLineChanged;
    if (block) block(index);
}

- (NSInteger)lineIndexForElapsed:(NSTimeInterval)elapsed {
    if (!isfinite(elapsed)) return CLLyricsNoLine;
    return [self indexForEffectiveElapsed:elapsed + _offset];
}

- (NSInteger)indexForEffectiveElapsed:(NSTimeInterval)effective {
    NSArray<CLLyricLine *> *lines = _lines;
    NSInteger count = (NSInteger)lines.count;
    if (count == 0 || !isfinite(effective)) return CLLyricsNoLine;

    NSInteger low = 0, high = count - 1, result = CLLyricsNoLine;
    while (low <= high) {
        NSInteger mid = low + (high - low) / 2;
        if (lines[(NSUInteger)mid].time <= effective) {
            result = mid;
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }
    return result;
}

- (NSTimeInterval)progressWithinCurrentLine {
    NSArray<CLLyricLine *> *lines = _lines;
    NSInteger index = _currentLineIndex;
    if (index < 0 || index >= (NSInteger)lines.count) return 0;

    NSTimeInterval start = lines[(NSUInteger)index].time;
    NSTimeInterval end;
    if (index + 1 < (NSInteger)lines.count) {
        end = lines[(NSUInteger)(index + 1)].time;
    } else {
        NSTimeInterval duration = _playbackState.duration;
        end = duration > 0 ? duration + _offset : start + _finalLineDuration;
    }
    if (end <= start) end = start + _finalLineDuration;

    NSTimeInterval progress = ([self effectiveElapsed] - start) / (end - start);
    return CLClamp(progress, 0.0, 1.0);
}

- (NSTimeInterval)playbackTimeForLineAtIndex:(NSInteger)index {
    NSArray<CLLyricLine *> *lines = _lines;
    if (index < 0 || index >= (NSInteger)lines.count) return -1;
    NSTimeInterval time = lines[(NSUInteger)index].time - _offset;
    return time > 0 ? time : 0;
}

#pragma mark - Timer

- (BOOL)isRunning {
    return _timer != nil;
}

/// Main queue only. The timer only runs while there is something to move through.
- (void)updateTimerState {
    BOOL shouldRun = _lines.count > 0 && _playbackState.isPlaying && _playbackState.effectiveRate != 0;
    if (shouldRun) [self startTimer];
    else [self stopTimer];
}

- (void)startTimer {
    if (_timer) return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!timer) return;
    uint64_t interval = (uint64_t)(_tickInterval * NSEC_PER_SEC);
    if (interval == 0) interval = (uint64_t)(0.1 * NSEC_PER_SEC);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval), interval, interval / 4);
    __weak typeof(self) weakSelf = self;
    // A dispatch source handler has no exception handler above it: anything that escapes here
    // aborts the process (inside CarPlayTemplateUIHost, that is the whole CarPlay screen). The
    // work below ends in the onLineChanged block, which the UI layer owns.
    dispatch_source_set_event_handler(timer, ^{
        @try {
            [weakSelf reevaluate];
        } @catch (NSException *exception) {
            CLLogError(@"[sync] tick raised %@: %@", exception.name, exception.reason);
        }
    });
    _timer = timer;
    dispatch_resume(timer);
}

- (void)stopTimer {
    if (!_timer) return;
    dispatch_source_cancel(_timer);
    _timer = nil;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<CLLyricsSyncEngine lines=%lu index=%ld offset=%.2f running=%d>",
            (unsigned long)_lines.count, (long)_currentLineIndex, _offset, _timer != nil];
}

@end
