//! The text area: scrolling, mapping between screen and buffer positions,
//! and drawing the line-number gutter and the buffer with its selection
//! and caret.
//!
//! Text is laid out in screen rows. Normally each line is one row; with
//! word wrap on, a line too long for the view continues on the next rows
//! (broken after a space when there is one).
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");
const anim = @import("../anim.zig");
const View_draw = @import("View_draw.zig");
const View_diff = @import("View_diff.zig");

const Buffer = core.Buffer;
const Highlighter = core.syntax.Highlighter;
const text = core.text;
const View = @This();

pub const Row = core.wrap.Row;

gpa: std.mem.Allocator,
font: Font,
/// Content offset in pixels; (0, 0) shows the top-left of the buffer.
/// `scroll` is where the text is drawn and `scroll_to` where it is
/// headed: with smooth animations on, the first follows the second a few
/// frames behind (see ui/anim.zig). Everything that scrolls the view sets
/// the target; `setScroll` is for jumping straight there.
scroll: rl.Vector2 = .{ .x = 0, .y = 0 },
scroll_to: rl.Vector2 = .{ .x = 0, .y = 0 },
/// Where the view draws: right of the sidebar, below the tab bar.
area: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
/// Width of the line-number gutter, and the line count it was sized for.
/// Both set by `layout`.
gutter_width: f32 = 0,
line_count: usize = 1,
/// Width of the longest line in columns, for the horizontal scroll limit;
/// measured again only when the buffer changes.
max_cols: usize = 0,
max_cols_version: ?u64 = null,
/// Word wrap (Settings, Option+Z): long lines continue on the next row
/// instead of scrolling sideways.
wrap: bool = false,
/// The screen rows, rebuilt by `layout` when the text or wrap width changes.
rows: std.ArrayList(Row) = .empty,
rows_version: ?u64 = null,
/// Wrap width the rows were made for, in columns; 0 without wrapping.
rows_cols: usize = 0,
/// `Buffer.folds_version` the rows were made for: folded lines get none.
rows_folds: u64 = 0,

/// Extra ranges to mark, e.g. search matches.
pub const Highlights = struct {
    /// Sorted, non-overlapping.
    ranges: []const Buffer.Range,
    /// Index of the emphasized range.
    current: ?usize = null,
};

// Drawing, in View_draw.zig.
pub const draw = View_draw.draw;

// The file's Git changes, in View_diff.zig.
pub const Changes = View_diff.Changes;
pub const hunkButtonAt = View_diff.buttonAt;

pub fn init(gpa: std.mem.Allocator, font: Font) View {
    return .{ .gpa = gpa, .font = font };
}

pub fn deinit(self: *View) void {
    self.rows.deinit(self.gpa);
}

/// Call once per frame after the buffer changed and before hit-testing or
/// drawing: sizes the gutter to fit the largest line number, and lays out
/// the rows. `hidden`: the folded lines (see core/editing/lib/fold.zig),
/// worked out for the buffer's current folds.
pub fn layout(self: *View, buf: *const Buffer, area: rl.Rectangle, hidden: []const Buffer.Range) !void {
    self.area = area;
    self.line_count = buf.lineCount();
    const digits: f32 = @floatFromInt(@max(theme.gutter_min_digits, std.math.log10_int(self.line_count) + 1));
    self.gutter_width = theme.padding + digits * self.font.cell_width + theme.gutter_gap;
    const cols = if (self.wrap) self.wrapCols() else 0;
    if (self.rows_version != buf.version or self.rows_cols != cols or self.rows_folds != buf.folds_version) try self.buildRows(buf, cols, hidden);
}

/// Columns that fit across the view: the wrap width.
fn wrapCols(self: View) usize {
    const w = self.right() - self.textLeft() - theme.padding;
    return @max(8, @as(usize, @intFromFloat(@max(0, w / self.font.cell_width))));
}

fn buildRows(self: *View, buf: *const Buffer, cols: usize, hidden: []const Buffer.Range) !void {
    try core.wrap.buildRows(self.gpa, &self.rows, buf.items(), cols, hidden);
    self.rows_version = buf.version;
    self.rows_cols = cols;
    self.rows_folds = buf.folds_version;
}

/// Window x where column 0 of the text is drawn when not scrolled.
pub fn textLeft(self: View) f32 {
    return self.gutterRight() + theme.padding;
}

/// Window y of the first line when not scrolled.
fn textTop(self: View) f32 {
    return self.area.y + theme.padding;
}

/// Window x of the gutter's right edge; text scrolled left of it is hidden.
pub fn gutterRight(self: View) f32 {
    return self.area.x + self.gutter_width;
}

pub fn right(self: View) f32 {
    return self.area.x + self.area.width;
}

pub fn bottom(self: View) f32 {
    return self.area.y + self.area.height;
}

/// Number of whole lines that fit in the view.
pub fn pageLines(self: View) usize {
    const n: usize = @intFromFloat(@max(0, self.area.height / theme.line_height));
    return @max(1, n -| 1);
}

// ------------------------------------------------------------------- rows

pub fn rowCount(self: View) usize {
    return @max(1, self.rows.items.len);
}

/// Whether the rows match the buffer (they're rebuilt in `layout`, so an
/// edit earlier in the same frame leaves them stale).
pub fn rowsCurrent(self: View, buf: *const Buffer) bool {
    return self.rows_version == buf.version and self.rows_folds == buf.folds_version;
}

/// Whether `pos` is on a folded line, which has no row of its own.
pub fn hides(self: View, buf: *const Buffer, pos: usize) bool {
    if (self.rows.items.len == 0) return false;
    return pos > self.rowEnd(buf, self.rowOf(pos));
}

pub fn rowStart(self: View, buf: *const Buffer, row: usize) usize {
    if (row >= self.rows.items.len) return buf.items().len;
    return @min(self.rows.items[row].start, buf.items().len);
}

/// Where a row ends: the next row's start if the line continues there,
/// else the end of the line.
pub fn rowEnd(self: View, buf: *const Buffer, row: usize) usize {
    const rs = self.rows.items;
    if (row + 1 < rs.len and rs[row + 1].line == rs[row].line) return @min(rs[row + 1].start, buf.items().len);
    return buf.lineEnd(self.rowStart(buf, row));
}

/// Whether the row's line continues on the next row.
pub fn rowWraps(self: View, row: usize) bool {
    const rs = self.rows.items;
    return row + 1 < rs.len and rs[row + 1].line == rs[row].line;
}

/// The row showing `pos`. A position where a line wraps belongs to the
/// row it starts.
pub fn rowOf(self: View, pos: usize) usize {
    const rs = self.rows.items;
    var lo: usize = 0;
    var hi: usize = rs.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (rs[mid].start <= pos) lo = mid + 1 else hi = mid;
    }
    return lo -| 1;
}

/// The first row of a line.
pub fn rowOfLine(self: View, line: usize) usize {
    const rs = self.rows.items;
    var lo: usize = 0;
    var hi: usize = rs.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (rs[mid].line < line) lo = mid + 1 else hi = mid;
    }
    return @min(lo, rs.len -| 1);
}

/// Buffer position at on-screen column `col` of a row. Past the end of a
/// row that wraps, the cursor stays on it (before its last character).
fn posInRow(self: View, buf: *const Buffer, row: usize, col: usize) usize {
    if (row >= self.rows.items.len) return buf.items().len;
    const start = self.rowStart(buf, row);
    const slice = buf.items()[start..self.rowEnd(buf, row)];
    var off = text.offsetAtColumn(slice, col);
    if (off == slice.len and off > 0 and self.rowWraps(row)) off = text.prevBoundary(slice, off);
    return start + off;
}

/// Up / Down by screen rows (with word wrap, a long line has several).
/// Keeps the cursor's column like line-wise movement does.
pub fn moveRows(self: View, buf: *Buffer, delta: isize, extend: bool) void {
    const row = self.rowOf(buf.cursor);
    const col = buf.goal_col orelse text.visualColumn(buf.items()[self.rowStart(buf, row)..buf.cursor]);
    const target = @as(isize, @intCast(row)) + delta;
    const pos = if (target < 0)
        0
    else if (target >= self.rows.items.len)
        buf.items().len
    else
        self.posInRow(buf, @intCast(target), col);
    buf.moveTo(pos, extend);
    buf.goal_col = col;
}

/// The line at the top of the view, with the fraction scrolled past it.
pub fn topLine(self: View) f32 {
    if (self.rows.items.len == 0) return 0;
    const r = @max(0, self.scroll.y / theme.line_height);
    const i = @min(@as(usize, @intFromFloat(r)), self.rows.items.len - 1);
    return @as(f32, @floatFromInt(self.rows.items[i].line)) + (r - @floor(r));
}

/// About how many lines the view shows (fewer than its rows when lines
/// wrap).
pub fn visibleLines(self: View) f32 {
    const rows_shown = self.area.height / theme.line_height;
    if (self.rows.items.len == 0) return rows_shown;
    const top: usize = @intFromFloat(@max(0, self.scroll.y / theme.line_height));
    const last_row = top + @as(usize, @intFromFloat(rows_shown));
    const rs = self.rows.items;
    if (top >= rs.len) return rows_shown;
    if (last_row >= rs.len) return @as(f32, @floatFromInt(rs[rs.len - 1].line - rs[top].line + 1 + (last_row - (rs.len - 1))));
    return @as(f32, @floatFromInt(rs[last_row].line - rs[top].line + 1));
}

/// Scrolls so `line` (fractional) is at the top.
pub fn scrollToLine(self: *View, line: f32) void {
    const l: usize = @intFromFloat(@max(0, line));
    self.scroll_to.y = (@as(f32, @floatFromInt(self.rowOfLine(l))) + (@max(0, line) - @floor(@max(0, line)))) * theme.line_height;
    if (!anim.enabled) self.scroll.y = self.scroll_to.y;
}

// --------------------------------------------------------- hit-testing

/// The screen row at a window y (it may be past the last one).
pub fn rowAtY(self: View, y: f32) usize {
    const row = (y + self.scroll.y - self.textTop()) / theme.line_height;
    return if (row < 0) 0 else @intFromFloat(row);
}

/// Row and on-screen column under a point (the row may be past the end).
fn rowColAt(self: View, p: rl.Vector2) struct { row: usize, col: usize } {
    const row = @max(0, (p.y + self.scroll.y - self.textTop()) / theme.line_height);
    const col = @max(0, (p.x + self.scroll.x - self.textLeft()) / self.font.cell_width + 0.5);
    return .{ .row = @intFromFloat(row), .col = @intFromFloat(col) };
}

/// Line and on-screen column under a point, for column selections. Without
/// wrapping the column isn't clamped to the text.
pub fn lineColAt(self: View, buf: *const Buffer, p: rl.Vector2) struct { line: usize, col: usize } {
    const rc = self.rowColAt(p);
    if (self.rows_cols == 0) return .{ .line = rc.row, .col = rc.col };
    const pos = self.posAt(buf, p);
    return .{ .line = buf.lineIndex(pos), .col = buf.column(pos) };
}

/// Buffer position under a point in window coordinates.
pub fn posAt(self: View, buf: *const Buffer, p: rl.Vector2) usize {
    const rc = self.rowColAt(p);
    return self.posInRow(buf, rc.row, rc.col);
}

/// Scrolls while a selection is dragged to the top or bottom edge, so it
/// can reach text off screen. Called every frame of the drag; `p` is the
/// pointer in window coordinates.
pub fn dragScroll(self: *View, p: rl.Vector2) void {
    const lines = theme.dragScrollLines(p.y, self.area.y, self.bottom(), theme.line_height);
    self.scroll_to.y += lines * theme.line_height * rl.getFrameTime();
    if (!anim.enabled) self.scroll = self.scroll_to;
}

pub fn scrollBy(self: *View, wheel: rl.Vector2) void {
    self.scroll_to.y -= wheel.y * theme.line_height * 3;
    self.scroll_to.x -= wheel.x * self.font.cell_width * 3;
    if (!anim.enabled) self.scroll = self.scroll_to;
}

/// Straight to a position, with nothing to animate: another tab, another
/// file, a fresh view.
pub fn setScroll(self: *View, to: rl.Vector2) void {
    self.scroll = to;
    self.scroll_to = to;
}

/// One frame of following the target. Called once a frame, before the
/// layout that draws from it.
pub fn step(self: *View) void {
    anim.approachVec(&self.scroll, self.scroll_to, anim.scroll_speed);
}

/// Scrolls just enough to bring the cursor into view.
pub fn revealCursor(self: *View, buf: *const Buffer) void {
    const c = self.contentOffset(buf, buf.cursor);
    const w = self.right() - self.textLeft() - theme.padding;
    const h = self.area.height - 2 * theme.padding;
    if (c.y < self.scroll_to.y) self.scroll_to.y = c.y;
    if (c.y + theme.line_height > self.scroll_to.y + h) self.scroll_to.y = c.y + theme.line_height - h;
    if (c.x < self.scroll_to.x) self.scroll_to.x = c.x;
    if (c.x + self.font.cell_width > self.scroll_to.x + w) self.scroll_to.x = c.x + self.font.cell_width - w;
    if (!anim.enabled) self.scroll = self.scroll_to;
}

/// Keeps the scroll inside the content: the last row may reach the top,
/// and the end of the longest line (plus room for the cursor after it) the
/// right edge. With word wrap there's nothing to scroll sideways.
pub fn clampScroll(self: *View, buf: *const Buffer) void {
    const rows: f32 = @floatFromInt(self.rowCount());
    const last = @max(0, (rows - 1) * theme.line_height);
    self.scroll_to.y = std.math.clamp(self.scroll_to.y, 0, last);
    self.scroll.y = std.math.clamp(self.scroll.y, 0, last);
    if (self.rows_cols > 0) {
        self.scroll_to.x = 0;
        self.scroll.x = 0;
        return;
    }
    const content_w = @as(f32, @floatFromInt(self.longestLine(buf) + 1)) * self.font.cell_width;
    const visible_w = self.right() - self.textLeft() - theme.padding;
    self.scroll_to.x = std.math.clamp(self.scroll_to.x, 0, @max(0, content_w - visible_w));
    self.scroll.x = std.math.clamp(self.scroll.x, 0, @max(0, content_w - visible_w));
}

fn longestLine(self: *View, buf: *const Buffer) usize {
    if (self.max_cols_version == buf.version) return self.max_cols;
    var longest: usize = 0;
    var lines = std.mem.splitScalar(u8, buf.items(), '\n');
    while (lines.next()) |line| longest = @max(longest, text.visualColumn(line));
    self.max_cols = longest;
    self.max_cols_version = buf.version;
    return longest;
}

/// Top-left corner of the character at `pos`, in window coordinates.
pub fn screenPos(self: View, buf: *const Buffer, pos: usize) rl.Vector2 {
    const o = self.contentOffset(buf, pos);
    return .{ .x = self.textLeft() + o.x - self.scroll.x, .y = self.textTop() + o.y - self.scroll.y };
}

/// Position of `pos` in content pixels (before scrolling and padding).
fn contentOffset(self: View, buf: *const Buffer, pos: usize) rl.Vector2 {
    const p = @min(pos, buf.items().len);
    const row = self.rowOf(p);
    const start = @min(self.rowStart(buf, row), p);
    const col: f32 = @floatFromInt(text.visualColumn(buf.items()[start..p]));
    return .{ .x = col * self.font.cell_width, .y = @as(f32, @floatFromInt(row)) * theme.line_height };
}

pub fn rowTop(self: View, row: usize) f32 {
    return self.textTop() + @as(f32, @floatFromInt(row)) * theme.line_height - self.scroll.y;
}
