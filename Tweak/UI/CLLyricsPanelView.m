#import "UI/CLLyricsPanelView.h"
#import "UI/CLLayoutGeometry.h"
#import "UI/CLLyricsStyle.h"
#import "Util/CLLog.h"

const NSTimeInterval CLLyricsPanelAutoScrollPause = 4.0;

static NSString *const CLLyricsPanelCellIdentifier = @"CLLyricsPanelCell";
static const NSInteger CLLyricsPanelLabelTag = 9101;
/// Space above and below each lyric line (so 2x between two lines), and the height of a blank
/// stanza-break row.
static const CGFloat CLLyricsPanelRowPadding = 4.0;
static const CGFloat CLLyricsPanelBlankRowHeight = 12.0;

@interface CLLyricsPanelView () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation CLLyricsPanelView {
    CLLyricsStyle *_style;
    /// Every row uses this one font: lyricsFontSize, capped to what the panel's size can show (see
    /// -cl_fittedFontSize). One font for all rows means a line becoming current never changes its
    /// height, so nothing re-wraps, truncates or jumps; the current line stands out by colour.
    UIFont *_rowFont;
    UIView *_backgroundView;
    UITableView *_tableView;
    NSArray<NSString *> *_rows;
    BOOL _rowsAreTimed;              ///< synced lyrics: rows map 1:1 to lyrics.lines and can be tapped
    NSTimer *_resumeTimer;
    CFAbsoluteTime _autoScrollBlockedUntil;
    BOOL _userIsDragging;
}

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) [self cl_commonInit];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self cl_commonInit];
    return self;
}

- (void)dealloc {
    [_resumeTimer invalidate];
    _resumeTimer = nil;
    _tableView.dataSource = nil;
    _tableView.delegate = nil;
}

- (void)cl_commonInit {
    _currentLineIndex = -1;          // CLLyricsNoLine
    _rows = @[];
    _rowsAreTimed = NO;
    _fit = CLLayoutPanelFitColumn;

    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    self.clipsToBounds = YES;
    // Display only. CarPlay's focus behavior puts a view controller's content scroll view among the
    // preferred focus environments (_UIFocusBehavior_CarPlay includesContentScrollViewInPreferred-
    // FocusEnvironments), and UIKit adopts this table as the Now Playing controller's content scroll
    // view: the rotary knob's focus went to the lyrics (0.2.0: a lyric row, 0.2.1: the list itself,
    // drawn as up/down arrows) and stopped reaching the player's buttons. A view that does not take
    // user interaction is never eligible for focus, so the knob and touch both stay with the host.
    self.userInteractionEnabled = NO;

    _backgroundView = [[UIView alloc] initWithFrame:CGRectZero];
    _backgroundView.translatesAutoresizingMaskIntoConstraints = NO;
    _backgroundView.userInteractionEnabled = NO;
    _backgroundView.hidden = YES;
    [self addSubview:_backgroundView];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.backgroundView = nil;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.showsVerticalScrollIndicator = NO;
    _tableView.userInteractionEnabled = NO;       // see -cl_commonInit: never a focus target
    // Nor something the knob may scroll: CarPlay's focus system treats a scroll-enabled content
    // scroll view as rotary-scrollable and drew its up/down arrows on this table (a cyan "X" at its
    // trailing edge, 0.2.1 – 0.6.0). The panel only ever scrolls itself, through -setContentOffset:
    // and -scrollToRowAtIndexPath:, which work with scrolling disabled.
    _tableView.scrollEnabled = NO;
    _tableView.showsHorizontalScrollIndicator = NO;
    _tableView.allowsSelection = YES;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 32.0;
    // Lyrics are for reading, not for the knob or touchpad: focus stays on the player controls.
    _tableView.remembersLastFocusedIndexPath = NO;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    if (@available(iOS 15.0, *)) {
        _tableView.sectionHeaderTopPadding = 0.0;
    }
    _tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_backgroundView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_backgroundView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_backgroundView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_backgroundView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_tableView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];

    [self applyPrefs];
}

#pragma mark - Public API

- (void)setLyrics:(CLLyrics *)lyrics {
    CLUIRunOnMain(^{
        if (lyrics == self->_lyrics) return;
        self->_lyrics = lyrics;
        self->_currentLineIndex = -1;
        [self cl_rebuildRows];
        [self->_tableView reloadData];
        [self cl_updateBackgroundVisibility];
        [self->_tableView setContentOffset:CGPointMake(0.0, -self->_tableView.contentInset.top) animated:NO];
    });
}

- (void)setCurrentLineIndex:(NSInteger)index animated:(BOOL)animated {
    CLUIRunOnMain(^{
        if (index == self->_currentLineIndex) return;
        self->_currentLineIndex = index;
        if (!self->_rowsAreTimed) return;
        [self cl_restyleVisibleCells];
        [self cl_scrollToCurrentLineAnimated:animated force:NO];
    });
}

- (void)setFit:(CLLayoutPanelFit)fit {
    if (_fit == fit) return;
    _fit = fit;
    _rowFont = nil;                            // a different rule: re-measure from scratch
    if ([self cl_updateRowFont]) [_tableView reloadData];
    [self setNeedsLayout];
}

- (void)applyPrefs {
    CLUIRunOnMain(^{
        CLLyricsStyle *style = [CLLyricsStyle currentStyle];
        BOOL sameStyle = [style isEqualToStyle:self->_style];
        self->_style = style;
        if (sameStyle) return;
        self->_rowFont = nil;
        [self cl_updateRowFont];
        [self cl_applyBackgroundStyle];
        [self cl_rebuildRows];                 // showNoteOnGap / showPlainWhenUnsynced can change
        [self->_tableView reloadData];         // fonts changed: row heights must be re-measured
        [self cl_updateBackgroundVisibility];
        [self cl_scrollToCurrentLineAnimated:NO force:NO];
    });
}

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat radius = 0.0;
    if (_style.backgroundStyle == 1) {
        radius = MIN(18.0, CGRectGetHeight(self.bounds) / 2.0);
    } else if (_style.backgroundStyle == 2) {
        radius = 4.0;
    }
    if (fabs(_backgroundView.layer.cornerRadius - radius) > 0.01) {
        _backgroundView.layer.cornerRadius = radius;
    }

    if ([self cl_updateRowFont]) {
        [_tableView reloadData];               // a new size: every row must be re-measured
    }

    // Half-height insets so the first and last line can still be centred.
    CGFloat rowHeight = ceil(_rowFont.lineHeight) + 2.0 * CLLyricsPanelRowPadding;
    CGFloat vertical = MAX(0.0, CGRectGetHeight(self.bounds) / 2.0 - rowHeight / 2.0);
    UIEdgeInsets insets = UIEdgeInsetsMake(vertical, 0.0, vertical, 0.0);
    if (!UIEdgeInsetsEqualToEdgeInsets(_tableView.contentInset, insets)) {
        _tableView.contentInset = insets;
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf cl_scrollToCurrentLineAnimated:NO force:NO];
        });
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        [_resumeTimer invalidate];
        _resumeTimer = nil;
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        [self cl_restyleVisibleCells];
        [self setNeedsLayout];
    }
}

#pragma mark - Font

/// lyricsFontSize, capped by the fit rule: CLLayoutPanelFontSize in UI/CLLayoutGeometry.h, the
/// one copy of the arithmetic (the settings preview draws with it too).
///   Column — about seven lines at once and roughly a dozen characters per line before wrapping:
///     a 210x180 pt panel (a 1920x720 @3x display) gets 19 pt, a 400x420 pt one keeps the preference.
///   Rows — three rows (each ceil(1.2 * size) + 8 tall) must fit the height; no width term, long
///     lines wrap: a 216–320 pt artwork square keeps 24 pt, a 300x80 pt panel gets 16.
- (CGFloat)cl_fittedFontSize {
    return CLLayoutPanelFontSize(self.bounds.size, _fit, _style.fontSize);
}

/// YES when the row font changed (the caller reloads the table).
- (BOOL)cl_updateRowFont {
    if (!_style) return NO;
    CGFloat size = [self cl_fittedFontSize];
    if (_rowFont && fabs(_rowFont.pointSize - size) < 0.01) return NO;
    _rowFont = [_style fontWithSize:size weight:_style.fontWeight];
    _tableView.estimatedRowHeight = ceil(_rowFont.lineHeight) + 2.0 * CLLyricsPanelRowPadding;
    return YES;
}

#pragma mark - Content

- (void)cl_rebuildRows {
    CLLyrics *lyrics = _lyrics;
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    BOOL timed = NO;

    if (lyrics.kind == CLLyricsKindSynced && lyrics.lines.count > 0) {
        timed = YES;
        for (CLLyricLine *line in lyrics.lines) {
            NSString *text = [(line.text ?: @"") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (CLLyricsTextIsGap(text)) text = _style.showNoteOnGap ? CLLyricsNoteGlyph : @"";
            [rows addObject:text];
        }
    } else if (lyrics.kind == CLLyricsKindInstrumental) {
        if (_style.showNoteOnGap) [rows addObject:CLLyricsNoteGlyph];
    } else if (lyrics && _style.showPlainWhenUnsynced) {
        NSString *plain = lyrics.plainText;
        for (NSString *raw in [(plain ?: @"") componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *text = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            // A line of notes follows the gap switch here too; an empty line stays a stanza break.
            if (text.length > 0 && CLLyricsTextIsGap(text)) text = _style.showNoteOnGap ? CLLyricsNoteGlyph : @"";
            [rows addObject:text];
        }
        while (rows.count > 0 && ((NSString *)rows.lastObject).length == 0) [rows removeLastObject];
    }

    _rows = [rows copy];
    _rowsAreTimed = timed;
    _hasVisibleContent = (_rows.count > 0);
}

- (void)cl_applyBackgroundStyle {
    _backgroundView.backgroundColor = _style.backgroundFill ?: UIColor.clearColor;
    [self cl_updateBackgroundVisibility];
    [self setNeedsLayout];
}

- (void)cl_updateBackgroundVisibility {
    BOOL visible = (_style.backgroundStyle != 0) && _hasVisibleContent;
    if (_backgroundView.hidden == visible) _backgroundView.hidden = !visible;
}

#pragma mark - Cells

- (UILabel *)cl_labelInCell:(UITableViewCell *)cell {
    UILabel *label = (UILabel *)[cell.contentView viewWithTag:CLLyricsPanelLabelTag];
    if ([label isKindOfClass:UILabel.class]) return label;

    label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.tag = CLLyricsPanelLabelTag;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.numberOfLines = 0;
    label.backgroundColor = UIColor.clearColor;
    label.adjustsFontForContentSizeCategory = NO;
    [cell.contentView addSubview:label];

    CGFloat padY = CLLyricsPanelRowPadding;
    CGFloat padX = CLLayoutPanelTextInset;
    NSLayoutConstraint *height = [cell.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:0.0];
    height.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:padY],
        [cell.contentView.bottomAnchor constraintEqualToAnchor:label.bottomAnchor constant:padY],
        [label.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:padX],
        [cell.contentView.trailingAnchor constraintEqualToAnchor:label.trailingAnchor constant:padX],
        height,
    ]];
    return label;
}

- (void)cl_configureCell:(UITableViewCell *)cell forRow:(NSInteger)row {
    UILabel *label = [self cl_labelInCell:cell];
    NSString *text = (row >= 0 && row < (NSInteger)_rows.count) ? _rows[(NSUInteger)row] : @"";
    if (![label.text isEqualToString:text]) label.text = text;
    label.textAlignment = _style.alignment;

    BOOL isCurrent = _rowsAreTimed && (row == _currentLineIndex);
    BOOL dimmed = _rowsAreTimed && !isCurrent;
    UIFont *font = _rowFont ?: _style.currentLineFont;
    if (label.font != font) label.font = font;
    // Unsynced text has no "current" line, so it is rendered at full strength rather than dimmed.
    label.textColor = dimmed ? _style.nextColor : _style.currentColor;

    // A blank row is a stanza break (or a gap marker with the note glyph turned off): it keeps its
    // place in the list with a little air, not a full line's height.
    CGFloat minimumHeight = (text.length == 0) ? CLLyricsPanelBlankRowHeight : 0.0;
    NSLayoutConstraint *heightConstraint = [self cl_minimumHeightConstraintInCell:cell];
    if (heightConstraint && fabs(heightConstraint.constant - minimumHeight) > 0.5) {
        heightConstraint.constant = minimumHeight;
    }
}

/// The `contentView.height >= n` constraint installed by -cl_labelInCell:, or nil.
- (NSLayoutConstraint *)cl_minimumHeightConstraintInCell:(UITableViewCell *)cell {
    for (NSLayoutConstraint *constraint in cell.contentView.constraints) {
        if (constraint.firstAttribute == NSLayoutAttributeHeight &&
            constraint.relation == NSLayoutRelationGreaterThanOrEqual &&
            constraint.secondItem == nil &&
            constraint.firstItem == cell.contentView) {
            return constraint;
        }
    }
    return nil;
}

- (void)cl_restyleVisibleCells {
    NSArray<NSIndexPath *> *visible = _tableView.indexPathsForVisibleRows;
    if (visible.count == 0) return;
    // Instant: a label's font cannot be interpolated, and cross-dissolving the whole table while
    // it is scrolling looks worse than a hard switch. The motion comes from the auto-scroll.
    for (NSIndexPath *indexPath in visible) {
        UITableViewCell *cell = [self->_tableView cellForRowAtIndexPath:indexPath];
        if (cell) [self cl_configureCell:cell forRow:indexPath.row];
    }
}

#pragma mark - Auto-scroll

- (void)cl_scrollToCurrentLineAnimated:(BOOL)animated force:(BOOL)force {
    if (!_rowsAreTimed) return;
    NSInteger row = _currentLineIndex;
    if (row < 0 || row >= (NSInteger)_rows.count) return;
    if (_tableView.numberOfSections < 1) return;
    if (row >= [_tableView numberOfRowsInSection:0]) return;      // reloadData has not landed yet
    if (!force) {
        if (_userIsDragging || _tableView.isDragging || _tableView.isTracking) return;
        if (CFAbsoluteTimeGetCurrent() < _autoScrollBlockedUntil) return;
    }
    [_tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]
                      atScrollPosition:UITableViewScrollPositionMiddle
                              animated:(animated && _style.animations)];
}

- (void)cl_suspendAutoScroll {
    _autoScrollBlockedUntil = CFAbsoluteTimeGetCurrent() + CLLyricsPanelAutoScrollPause;
    [_resumeTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _resumeTimer = [NSTimer scheduledTimerWithTimeInterval:CLLyricsPanelAutoScrollPause
                                                   repeats:NO
                                                     block:^(NSTimer *timer) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_autoScrollBlockedUntil = 0.0;
        if (strongSelf->_userIsDragging) return;
        [strongSelf cl_scrollToCurrentLineAnimated:YES force:YES];
    }];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CLLyricsPanelCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:CLLyricsPanelCellIdentifier];
        cell.backgroundColor = UIColor.clearColor;
        cell.contentView.backgroundColor = UIColor.clearColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    [self cl_configureCell:cell forRow:indexPath.row];
    return cell;
}

#pragma mark - UITableViewDelegate

- (BOOL)tableView:(UITableView *)tableView canFocusRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return _rowsAreTimed;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    if (!_rowsAreTimed) return;
    NSInteger row = indexPath.row;
    if (row < 0 || row >= (NSInteger)_rows.count) return;
    id<CLLyricsPanelViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(lyricsPanel:didSelectLineAtIndex:)]) {
        [delegate lyricsPanel:self didSelectLineAtIndex:row];
    }
    // The seek will produce a line change; let it re-centre immediately.
    _autoScrollBlockedUntil = 0.0;
    [_resumeTimer invalidate];
    _resumeTimer = nil;
}

#pragma mark - UIScrollViewDelegate

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    _userIsDragging = YES;
    _autoScrollBlockedUntil = CFAbsoluteTimeGetCurrent() + CLLyricsPanelAutoScrollPause;
    [_resumeTimer invalidate];
    _resumeTimer = nil;
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    _userIsDragging = NO;
    if (!decelerate) [self cl_suspendAutoScroll];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    _userIsDragging = NO;
    [self cl_suspendAutoScroll];
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    // Our own animated scrolls end here too; nothing to do, but keep the flag honest.
    _userIsDragging = NO;
}

@end
