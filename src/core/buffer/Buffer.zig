//! Text document: a flat UTF-8 byte array, a cursor with an optional
//! selection anchor (plus any extra cursors), and its undo history. Every
//! change goes through `replace`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("../editing/lib/text.zig");
const History = @import("History.zig");
const cursors = @import("lib/cursors.zig");

const Buffer = @This();

pub const Range = struct { start: usize, end: usize };

/// A cursor with its selection, for multi-cursor editing.
pub const Cursor = struct {
    cursor: usize,
    anchor: ?usize = null,
    goal_col: ?usize = null,
    /// Marks the main cursor while all of them sit in `extra`.
    primary: bool = false,

    pub fn range(c: Cursor) Range {
        const a = c.anchor orelse c.cursor;
        return .{ .start = @min(a, c.cursor), .end = @max(a, c.cursor) };
    }
};

gpa: Allocator,
bytes: std.ArrayList(u8) = .empty,
/// Byte offset into `bytes`, always on a UTF-8 codepoint boundary.
cursor: usize = 0,
/// Other end of the selection; the selection is empty when null or == cursor.
anchor: ?usize = null,
/// Column the cursor wants to be on when moving up/down across short lines.
goal_col: ?usize = null,
history: History = .{},
/// Changes on every text change, so caches (highlighting, search,
/// completion) know to rebuild. Unique across all buffers: a cache can't
/// mistake one tab's buffer for another's.
version: u64,
/// One level of indentation: what Tab and auto-indent insert.
indent: []const u8 = "    ",
/// More cursors besides `cursor` (Option+click). Changes shift them so
/// they stay on the same text.
extra: std.ArrayList(Cursor) = .empty,
/// While `eachCursor` runs: the `extra` slot being edited (every cursor
/// sits in `extra` then). `moveTo` keeps the other cursors meanwhile.
active: ?usize = null,
/// Folded blocks, by where their first (still shown) line starts; sorted.
/// Changes shift them along with the text, like the cursors. What each
/// one hides is worked out from the text (see editing/lib/fold.zig).
folds: std.ArrayList(usize) = .empty,
/// Changes whenever `folds` does (unique like `version`), so the view
/// knows to lay its rows out again.
folds_version: u64 = 0,
/// Where each line starts, kept up to date with every change: finding a
/// line is a binary search, not a count of every newline before it.
line_starts: std.ArrayList(usize) = .empty,
/// The last changes, so whatever caches something about the text (the
/// highlighter) can redo only what they touched (see `changedSince`).
log: [log_len]LogEntry = undefined,
log_count: usize = 0,

const log_len = 64;

/// One change: the version before and after it, and where it was.
const LogEntry = struct { before: u64, after: u64, start: usize, old_end: usize, new_end: usize };

/// Shared by all buffers; see `version`.
var version_counter: u64 = 0;

// Multiple cursors, in cursors.zig.
pub const hasExtraCursors = cursors.hasExtraCursors;
pub const toggleCursor = cursors.toggleCursor;
pub const selectColumns = cursors.selectColumns;
pub const allCursors = cursors.allCursors;
pub const eachCursor = cursors.eachCursor;
pub const selectNextOccurrence = cursors.selectNextOccurrence;
pub const Occurrence = cursors.Occurrence;

fn nextVersion() u64 {
    version_counter += 1;
    return version_counter;
}

pub fn init(gpa: Allocator) Buffer {
    var b: Buffer = .{ .gpa = gpa, .version = nextVersion() };
    // An empty text is one line; nothing to allocate for it until a change.
    b.line_starts.append(gpa, 0) catch {};
    return b;
}

pub fn deinit(self: *Buffer) void {
    self.bytes.deinit(self.gpa);
    self.history.deinit(self.gpa);
    self.extra.deinit(self.gpa);
    self.folds.deinit(self.gpa);
    self.line_starts.deinit(self.gpa);
}

pub fn items(self: *const Buffer) []const u8 {
    return self.bytes.items;
}

// ---------------------------------------------------------------- changes

/// The single mutation primitive. Replaces [start, end) with `new`, puts the
/// cursor at `start + cursor_offset`, clears the selection and records undo.
pub fn replace(self: *Buffer, start: usize, end: usize, new: []const u8, cursor_offset: usize, kind: History.Kind) !void {
    const new_cursor = start + cursor_offset;
    try self.history.record(self.gpa, .{
        .pos = start,
        .removed = self.bytes.items[start..end],
        .inserted = new,
        .kind = kind,
        .cursor_before = self.cursor,
        .anchor_before = self.anchor,
        .cursor_after = new_cursor,
    });
    try self.setBytes(start, end, new);
    self.shiftCursors(start, end, new.len);
    self.shiftFolds(start, end, new);
    self.cursor = new_cursor;
    self.anchor = null;
    self.goal_col = null;
}

/// Swaps [s, m1) with [m2, e), keeping [m1, m2) between them: "A mid B"
/// becomes "B mid A". Every cursor (and selection end) moves with the text
/// it's on; a position at the end of A or B stays with it.
pub fn swapRanges(self: *Buffer, s: usize, m1: usize, m2: usize, e: usize) !void {
    const new = try std.mem.concat(self.gpa, u8, &.{ self.bytes.items[m2..e], self.bytes.items[m1..m2], self.bytes.items[s..m1] });
    defer self.gpa.free(new);
    const Map = struct {
        s: usize,
        m1: usize,
        m2: usize,
        e: usize,
        fn f(m: @This(), p: usize) usize {
            if (p < m.s or p > m.e) return p;
            if (p <= m.m1) return p + (m.e - m.m1); // in A
            if (p >= m.m2) return p - (m.m2 - m.s); // in B
            return p + (m.e - m.m2) - (m.m1 - m.s); // in the middle
        }
    };
    const map: Map = .{ .s = s, .m1 = m1, .m2 = m2, .e = e };
    const cursor = map.f(self.cursor);
    const anchor = if (self.anchor) |a| map.f(a) else null;
    const goal = self.goal_col;
    // Mapped here instead of `replace`'s shifting, which can't tell where
    // text went.
    for (self.extra.items, 0..) |*c, i| {
        if (self.active == i) continue;
        c.cursor = map.f(c.cursor);
        if (c.anchor) |a| c.anchor = map.f(a);
    }
    const saved = self.active;
    self.active = null;
    const extra = self.extra;
    self.extra = .empty; // so `replace` leaves them alone
    defer {
        self.extra = extra;
        self.active = saved;
    }
    try self.replace(s, e, new, 0, .other);
    self.cursor = cursor;
    self.anchor = anchor;
    self.goal_col = goal;
}

/// Replaces the whole text, e.g. with a file just opened. Not undoable:
/// history starts fresh.
pub fn load(self: *Buffer, content: []const u8) !void {
    try self.bytes.replaceRange(self.gpa, 0, self.bytes.items.len, content);
    try self.rebuildLineStarts();
    self.log_count = 0;
    self.history.deinit(self.gpa);
    self.history = .{};
    self.version = nextVersion();
    self.cursor = 0;
    self.anchor = null;
    self.goal_col = null;
    self.extra.clearRetainingCapacity();
    self.unfoldAll();
}

/// Replaces the selection (or inserts at the cursor) with `new`.
pub fn insert(self: *Buffer, new: []const u8) !void {
    const r = self.selectionOrCursor();
    try self.replace(r.start, r.end, new, new.len, .other);
}

pub fn deleteRange(self: *Buffer, r: Range) !void {
    if (r.start == r.end) return;
    try self.replace(r.start, r.end, "", 0, .other);
}

/// Undoes the last step: one edit, or all of a multi-cursor keystroke's.
pub fn undo(self: *Buffer) !void {
    var e = try self.history.popUndo(self.gpa) orelse return;
    while (true) {
        try self.setBytes(e.pos, e.pos + e.inserted.len, e.removed);
        self.shiftFolds(e.pos, e.pos + e.inserted.len, e.removed);
        if (!e.joined) break;
        e = try self.history.popUndo(self.gpa) orelse break;
    }
    self.extra.clearRetainingCapacity();
    self.cursor = e.cursor_before;
    self.anchor = e.anchor_before;
    self.goal_col = null;
}

pub fn redo(self: *Buffer) !void {
    var e = try self.history.popRedo(self.gpa) orelse return;
    while (true) {
        try self.setBytes(e.pos, e.pos + e.removed.len, e.inserted);
        self.shiftFolds(e.pos, e.pos + e.removed.len, e.inserted);
        if (!self.history.redoContinues()) break;
        e = try self.history.popRedo(self.gpa) orelse break;
    }
    self.extra.clearRetainingCapacity();
    self.cursor = e.cursor_after;
    self.anchor = null;
    self.goal_col = null;
}

// ------------------------------------------------------ cursor & selection

/// Moves the cursor to `pos`. With `extend`, grows the selection instead.
/// Other cursors go away (except while `eachCursor` runs).
pub fn moveTo(self: *Buffer, pos: usize, extend: bool) void {
    if (self.active == null) self.extra.clearRetainingCapacity();
    self.moveHead(pos, extend);
}

/// Moves the main cursor like `moveTo`, keeping the other cursors (e.g.
/// dragging out a selection for a cursor just added).
pub fn moveHead(self: *Buffer, pos: usize, extend: bool) void {
    if (extend) {
        if (self.anchor == null) self.anchor = self.cursor;
    } else {
        self.anchor = null;
    }
    self.cursor = @min(pos, self.bytes.items.len);
    self.goal_col = null;
    self.history.seal();
}

pub fn selection(self: *const Buffer) ?Range {
    const a = self.anchor orelse return null;
    if (a == self.cursor) return null;
    return .{ .start = @min(a, self.cursor), .end = @max(a, self.cursor) };
}

/// The selection, or an empty range at the cursor.
pub fn selectionOrCursor(self: *const Buffer) Range {
    return self.selection() orelse .{ .start = self.cursor, .end = self.cursor };
}

pub fn selectedText(self: *const Buffer) ?[]const u8 {
    const s = self.selection() orelse return null;
    return self.bytes.items[s.start..s.end];
}

pub fn selectAll(self: *Buffer) void {
    self.moveTo(0, false);
    self.moveTo(self.bytes.items.len, true);
}

/// The cursor's whole line including its trailing newline.
pub fn currentLineRange(self: *const Buffer) Range {
    const end = self.lineEnd(self.cursor);
    return .{
        .start = self.lineStart(self.cursor),
        .end = if (end < self.bytes.items.len) end + 1 else end,
    };
}

// ----------------------------------------------------------- multi-cursor

/// Keeps the other cursors on the same text after [start, end) was
/// replaced by `new_len` bytes.
fn shiftCursors(self: *Buffer, start: usize, end: usize, new_len: usize) void {
    for (self.extra.items, 0..) |*c, i| {
        if (self.active == i) continue;
        c.cursor = shift(c.cursor, start, end, new_len);
        if (c.anchor) |a| c.anchor = shift(a, start, end, new_len);
    }
}

// ------------------------------------------------------------ line starts

/// Replaces bytes [start, end) with `new`: the text, the line starts, a
/// new version and its entry in the log. Every change goes through here.
fn setBytes(self: *Buffer, start: usize, end: usize, new: []const u8) !void {
    try self.bytes.replaceRange(self.gpa, start, end - start, new);
    try self.updateLineStarts(start, end, new);
    const before = self.version;
    self.version = nextVersion();
    const entry: LogEntry = .{ .before = before, .after = self.version, .start = start, .old_end = end, .new_end = start + new.len };
    if (self.log_count == log_len) {
        std.mem.copyForwards(LogEntry, self.log[0 .. log_len - 1], self.log[1..]);
        self.log_count -= 1;
    }
    self.log[self.log_count] = entry;
    self.log_count += 1;
}

/// The starts of lines after [start, end) move by the change in length;
/// those of lines inside it go, and each newline in `new` adds one.
fn updateLineStarts(self: *Buffer, start: usize, end: usize, new: []const u8) !void {
    const starts = self.line_starts.items;
    // Line starts in (start, end] had their newline removed.
    const first = std.sort.upperBound(usize, starts, start, orderUsize);
    const last = std.sort.upperBound(usize, starts, end, orderUsize);
    const grow = @as(isize, @intCast(new.len)) - @as(isize, @intCast(end - start));
    for (starts[last..]) |*s| s.* = @intCast(@as(isize, @intCast(s.*)) + grow);
    var added: std.ArrayList(usize) = .empty;
    defer added.deinit(self.gpa);
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, new, i, '\n')) |nl| : (i = nl + 1) {
        try added.append(self.gpa, start + nl + 1);
    }
    try self.line_starts.replaceRange(self.gpa, first, last - first, added.items);
}

fn orderUsize(a: usize, b: usize) std.math.Order {
    return std.math.order(a, b);
}

fn rebuildLineStarts(self: *Buffer) !void {
    self.line_starts.clearRetainingCapacity();
    try self.line_starts.append(self.gpa, 0);
    const b = self.bytes.items;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, b, i, '\n')) |nl| : (i = nl + 1) {
        try self.line_starts.append(self.gpa, nl + 1);
    }
}

/// Where line `line` (zero-based) starts; past the last, the end.
pub fn lineStartOf(self: *const Buffer, line: usize) usize {
    const s = self.line_starts.items;
    return if (line < s.len) s[line] else self.bytes.items.len;
}

/// What changed since version `v` of the text: one range covering every
/// change since, in the current text. Null when `v` is too old to know
/// (or the text was loaded anew): then everything counts as changed.
pub fn changedSince(self: *const Buffer, v: u64) ?Range {
    if (v == self.version) return .{ .start = 0, .end = 0 };
    const log = self.log[0..self.log_count];
    const from = for (log, 0..) |e, i| {
        if (e.before == v) break i;
    } else return null;
    var r: ?Range = null;
    for (log[from..]) |e| {
        if (r) |*x| {
            // Carry the range so far through this change.
            const end = if (x.end >= e.old_end) x.end - e.old_end + e.new_end else if (x.end > e.start) e.new_end else x.end;
            const s = if (x.start > e.start and x.start < e.old_end) e.start else if (x.start >= e.old_end) x.start - e.old_end + e.new_end else x.start;
            x.* = .{ .start = @min(s, e.start), .end = @max(end, e.new_end) };
        } else r = .{ .start = e.start, .end = e.new_end };
    }
    return r;
}

// ---------------------------------------------------------------- folds

/// Folds the block whose first line starts at `line_start`.
pub fn fold(self: *Buffer, line_start: usize) !void {
    var i: usize = 0;
    while (i < self.folds.items.len and self.folds.items[i] < line_start) i += 1;
    if (i < self.folds.items.len and self.folds.items[i] == line_start) return;
    try self.folds.insert(self.gpa, i, line_start);
    self.folds_version = nextVersion();
}

/// Unfolds the block starting on that line; false if it wasn't folded.
pub fn unfold(self: *Buffer, line_start: usize) bool {
    const i = std.mem.indexOfScalar(usize, self.folds.items, line_start) orelse return false;
    _ = self.folds.orderedRemove(i);
    self.folds_version = nextVersion();
    return true;
}

pub fn isFolded(self: *const Buffer, line_start: usize) bool {
    return std.mem.indexOfScalar(usize, self.folds.items, line_start) != null;
}

pub fn unfoldAll(self: *Buffer) void {
    if (self.folds.items.len == 0) return;
    self.folds.clearRetainingCapacity();
    self.folds_version = nextVersion();
}

/// Keeps the folds on their lines after [start, end) was replaced by
/// `new`. A fold whose first line started in the replaced text is gone
/// with it; lines inserted right before its first line push it down.
fn shiftFolds(self: *Buffer, start: usize, end: usize, new: []const u8) void {
    if (self.folds.items.len == 0) return;
    var n: usize = 0;
    for (self.folds.items) |p| {
        if (p >= start and p < end) continue;
        const q = if (p == start)
            p + if (std.mem.lastIndexOfScalar(u8, new, '\n')) |i| i + 1 else 0
        else
            shift(p, start, end, new.len);
        if (n > 0 and self.folds.items[n - 1] == q) continue;
        self.folds.items[n] = q;
        n += 1;
    }
    self.folds.shrinkRetainingCapacity(n);
    self.folds_version = nextVersion();
}

fn shift(p: usize, start: usize, end: usize, new_len: usize) usize {
    if (p <= start) return p;
    if (p >= end) return p - (end - start) + new_len;
    return start + new_len; // inside the replaced text
}

// ---------------------------------------------------------------- queries

pub fn byteAt(self: *const Buffer, pos: usize) ?u8 {
    return if (pos < self.bytes.items.len) self.bytes.items[pos] else null;
}

pub fn byteBefore(self: *const Buffer, pos: usize) ?u8 {
    return if (pos > 0) self.bytes.items[pos - 1] else null;
}

pub fn prevPos(self: *const Buffer, pos: usize) usize {
    return text.prevBoundary(self.bytes.items, pos);
}

pub fn nextPos(self: *const Buffer, pos: usize) usize {
    return text.nextBoundary(self.bytes.items, pos);
}

pub fn lineStart(self: *const Buffer, pos: usize) usize {
    const i = std.mem.lastIndexOfScalar(u8, self.bytes.items[0..pos], '\n') orelse return 0;
    return i + 1;
}

pub fn lineEnd(self: *const Buffer, pos: usize) usize {
    const b = self.bytes.items;
    return std.mem.indexOfScalarPos(u8, b, pos, '\n') orelse b.len;
}

/// Zero-based line number containing `pos`.
pub fn lineIndex(self: *const Buffer, pos: usize) usize {
    // The last line start at or before `pos`.
    return std.sort.upperBound(usize, self.line_starts.items, pos, orderUsize) - 1;
}

pub fn lineCount(self: *const Buffer) usize {
    return self.line_starts.items.len;
}

/// Zero-based on-screen column of `pos` within its line (tabs expanded).
pub fn column(self: *const Buffer, pos: usize) usize {
    return text.visualColumn(self.bytes.items[self.lineStart(pos)..pos]);
}

/// Byte offset of on-screen (line, col), clamped to the buffer / line end.
pub fn posAt(self: *const Buffer, line: usize, col: usize) usize {
    const b = self.bytes.items;
    if (line >= self.line_starts.items.len) return b.len;
    const start = self.line_starts.items[line];
    return start + text.offsetAtColumn(b[start..self.lineEnd(start)], col);
}

test {
    _ = @import("tests/Buffer_test.zig");
}
