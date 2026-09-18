//! Text document: a flat UTF-8 byte array, a cursor with an optional
//! selection anchor, and its undo history. Every change goes through `replace`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("text.zig");
const History = @import("History.zig");

const Buffer = @This();

pub const Range = struct { start: usize, end: usize };

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

/// Shared by all buffers; see `version`.
var version_counter: u64 = 0;

fn nextVersion() u64 {
    version_counter += 1;
    return version_counter;
}

pub fn init(gpa: Allocator) Buffer {
    return .{ .gpa = gpa, .version = nextVersion() };
}

pub fn deinit(self: *Buffer) void {
    self.bytes.deinit(self.gpa);
    self.history.deinit(self.gpa);
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
    try self.bytes.replaceRange(self.gpa, start, end - start, new);
    self.version = nextVersion();
    self.cursor = new_cursor;
    self.anchor = null;
    self.goal_col = null;
}

/// Replaces the whole text, e.g. with a file just opened. Not undoable:
/// history starts fresh.
pub fn load(self: *Buffer, content: []const u8) !void {
    try self.bytes.replaceRange(self.gpa, 0, self.bytes.items.len, content);
    self.history.deinit(self.gpa);
    self.history = .{};
    self.version = nextVersion();
    self.cursor = 0;
    self.anchor = null;
    self.goal_col = null;
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

pub fn undo(self: *Buffer) !void {
    const e = try self.history.popUndo(self.gpa) orelse return;
    try self.bytes.replaceRange(self.gpa, e.pos, e.inserted.len, e.removed);
    self.version = nextVersion();
    self.cursor = e.cursor_before;
    self.anchor = e.anchor_before;
    self.goal_col = null;
}

pub fn redo(self: *Buffer) !void {
    const e = try self.history.popRedo(self.gpa) orelse return;
    try self.bytes.replaceRange(self.gpa, e.pos, e.removed.len, e.inserted);
    self.version = nextVersion();
    self.cursor = e.cursor_after;
    self.anchor = null;
    self.goal_col = null;
}

// ------------------------------------------------------ cursor & selection

/// Moves the cursor to `pos`. With `extend`, grows the selection instead.
pub fn moveTo(self: *Buffer, pos: usize, extend: bool) void {
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
    return std.mem.count(u8, self.bytes.items[0..pos], "\n");
}

pub fn lineCount(self: *const Buffer) usize {
    return std.mem.count(u8, self.bytes.items, "\n") + 1;
}

/// Zero-based on-screen column of `pos` within its line (tabs expanded).
pub fn column(self: *const Buffer, pos: usize) usize {
    return text.visualColumn(self.bytes.items[self.lineStart(pos)..pos]);
}

/// Byte offset of on-screen (line, col), clamped to the buffer / line end.
pub fn posAt(self: *const Buffer, line: usize, col: usize) usize {
    const b = self.bytes.items;
    var start: usize = 0;
    for (0..line) |_| {
        start = (std.mem.indexOfScalarPos(u8, b, start, '\n') orelse return b.len) + 1;
    }
    return start + text.offsetAtColumn(b[start..self.lineEnd(start)], col);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "positions and lines" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("hello\nwörld");
    try testing.expectEqual(@as(usize, 2), b.lineCount());
    try testing.expectEqual(@as(usize, 1), b.lineIndex(b.cursor));
    try testing.expectEqual(@as(usize, 5), b.column(b.cursor));
    try testing.expectEqual(@as(usize, 9), b.posAt(1, 2)); // after 'ö'
    try testing.expectEqual(@as(usize, 5), b.posAt(0, 99));
}

test "columns count tabs to the next tab stop" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("\tx\nabcdefgh");
    try testing.expectEqual(@as(usize, 5), b.column(2)); // after "\tx"
    try testing.expectEqual(@as(usize, 1), b.posAt(0, 4)); // right after the tab
    try testing.expectEqual(@as(usize, 0), b.posAt(0, 2)); // mid-tab snaps to its start
}

test "selection" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("hello world");
    b.moveTo(6, false);
    b.moveTo(11, true);
    try testing.expectEqualStrings("world", b.selectedText().?);
    try b.insert("there");
    try testing.expectEqualStrings("hello there", b.items());
    try testing.expectEqual(@as(?Range, null), b.selection());
}

test "undo and redo" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("hello world");
    b.selectAll();
    try b.insert("x");
    try b.undo();
    try testing.expectEqualStrings("hello world", b.items());
    try testing.expectEqualStrings("hello world", b.selectedText().?);
    try b.redo();
    try testing.expectEqualStrings("x", b.items());
}
