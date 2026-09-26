//! Commands on whole lines: indenting and unindenting them, duplicating
//! and deleting them. Each works on the lines the cursor or its selection
//! is on.
//!
//! With several cursors a command runs once per cursor (see
//! `Buffer.eachCursor`). Like `edit.moveLines`, each takes the block of
//! lines the previous cursor changed (`skip`) and returns its own, so a
//! block with two cursors on it changes once.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const text = @import("text.zig");

const Range = Buffer.Range;

/// The lines the selection (or cursor) is on: from the start of the first
/// to the end of the last, without its newline. A selection ending at the
/// start of a line doesn't take that line.
pub fn selectedLines(buf: *const Buffer) Range {
    const sel = buf.selectionOrCursor();
    const ends_at_line_start = sel.end > sel.start and sel.end == buf.lineStart(sel.end);
    return .{
        .start = buf.lineStart(sel.start),
        .end = buf.lineEnd(if (ends_at_line_start) sel.end - 1 else sel.end),
    };
}

/// Whether `lines` touches the block another cursor already did.
fn done(lines: Range, skip: ?Range) bool {
    const r = skip orelse return false;
    return lines.start <= r.end and lines.end >= r.start;
}

/// One change among several made together: `remove` bytes at `pos`
/// replaced by `insert`.
pub const Edit = struct { pos: usize, remove: usize = 0, insert: []const u8 = "" };

/// Makes `edits` (in document order, not overlapping) as one undo step,
/// keeping the cursor and selection on the same text. Text inserted where
/// one of them sits goes before it.
pub fn applyEdits(buf: *Buffer, edits: []const Edit) !void {
    var cursor = buf.cursor;
    var anchor = buf.anchor;
    const goal = buf.goal_col;
    // Inside `eachCursor` the edits already join that group.
    const own_group = !buf.history.grouping;
    if (own_group) buf.history.beginGroup();
    defer if (own_group) buf.history.endGroup();
    var i = edits.len;
    while (i > 0) {
        i -= 1;
        const e = edits[i];
        try buf.replace(e.pos, e.pos + e.remove, e.insert, 0, .other);
        cursor = mapPos(cursor, e);
        if (anchor) |a| anchor = mapPos(a, e);
    }
    buf.cursor = cursor;
    buf.anchor = anchor;
    buf.goal_col = goal;
}

fn mapPos(p: usize, e: Edit) usize {
    if (p < e.pos) return p;
    if (p < e.pos + e.remove) return e.pos;
    return p - e.remove + e.insert.len;
}

/// How far `edits` move the end of the text they're in.
fn growth(edits: []const Edit) isize {
    var d: isize = 0;
    for (edits) |e| d += @as(isize, @intCast(e.insert.len)) - @as(isize, @intCast(e.remove));
    return d;
}

fn grown(pos: usize, d: isize) usize {
    return @intCast(@as(isize, @intCast(pos)) + d);
}

/// Where each line of `lines` starts.
fn lineStarts(gpa: std.mem.Allocator, bytes: []const u8, lines: Range) !std.ArrayList(usize) {
    var starts: std.ArrayList(usize) = .empty;
    errdefer starts.deinit(gpa);
    var s = lines.start;
    while (true) {
        try starts.append(gpa, s);
        const e = std.mem.indexOfScalarPos(u8, bytes, s, '\n') orelse break;
        if (e >= lines.end) break;
        s = e + 1;
    }
    return starts;
}

fn isBlank(line: []const u8) bool {
    return std.mem.indexOfNone(u8, line, " \t\r") == null;
}

/// Cmd+]: one more level of indentation on each of the lines (blank ones
/// stay empty).
pub fn indentLines(buf: *Buffer, skip: ?Range) !Range {
    const lines = selectedLines(buf);
    if (done(lines, skip)) return skip.?;
    const b = buf.items();
    var starts = try lineStarts(buf.gpa, b, lines);
    defer starts.deinit(buf.gpa);
    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(buf.gpa);
    for (starts.items) |s| {
        if (starts.items.len > 1 and isBlank(b[s..buf.lineEnd(s)])) continue;
        try edits.append(buf.gpa, .{ .pos = s, .insert = buf.indent });
    }
    const d = growth(edits.items);
    try applyEdits(buf, edits.items);
    return .{ .start = lines.start, .end = grown(lines.end, d) };
}

/// Shift+Tab, Cmd+[: one level of indentation less on each of the lines,
/// as far as they have one.
pub fn outdentLines(buf: *Buffer, skip: ?Range) !Range {
    const lines = selectedLines(buf);
    if (done(lines, skip)) return skip.?;
    const b = buf.items();
    // A level is a tab, or the indentation's width in spaces.
    const width = if (std.mem.eql(u8, buf.indent, "\t")) text.tab_width else buf.indent.len;
    var starts = try lineStarts(buf.gpa, b, lines);
    defer starts.deinit(buf.gpa);
    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(buf.gpa);
    for (starts.items) |s| {
        const line = b[s..buf.lineEnd(s)];
        var n: usize = 0;
        if (line.len > 0 and line[0] == '\t') {
            n = 1;
        } else {
            while (n < line.len and n < width and line[n] == ' ') n += 1;
        }
        if (n > 0) try edits.append(buf.gpa, .{ .pos = s, .remove = n });
    }
    const d = growth(edits.items);
    try applyEdits(buf, edits.items);
    return .{ .start = lines.start, .end = grown(lines.end, d) };
}

/// Copies the lines below themselves; the cursor and selection go with
/// the copy.
pub fn duplicateLines(buf: *Buffer, skip: ?Range) !Range {
    const lines = selectedLines(buf);
    if (done(lines, skip)) return skip.?;
    const len = lines.end - lines.start + 1;
    const copy = try std.mem.concat(buf.gpa, u8, &.{ "\n", buf.items()[lines.start..lines.end] });
    defer buf.gpa.free(copy);
    const cursor = buf.cursor + len;
    const anchor = if (buf.anchor) |a| a + len else null;
    const goal = buf.goal_col;
    try buf.replace(lines.end, lines.end, copy, 0, .other);
    buf.cursor = cursor;
    buf.anchor = anchor;
    buf.goal_col = goal;
    return .{ .start = lines.start, .end = lines.end + len };
}

/// Deletes the lines; the cursor keeps its column on the line after them.
/// Run it for the cursors from the last up (it returns where the lines
/// were), so a cursor on a line just deleted is recognised.
pub fn deleteLines(buf: *Buffer, skip: ?Range) !Range {
    const lines = selectedLines(buf);
    if (done(lines, skip)) return skip.?;
    const b = buf.items();
    const col = buf.goal_col orelse buf.column(buf.cursor);
    // With its newline; the last line takes the one before it instead.
    const r: Range = if (lines.end < b.len)
        .{ .start = lines.start, .end = lines.end + 1 }
    else
        .{ .start = lines.start -| 1, .end = lines.end };
    try buf.replace(r.start, r.end, "", 0, .other);
    const at = buf.lineStart(@min(r.start, buf.items().len));
    const line = buf.items()[at..buf.lineEnd(at)];
    buf.cursor = at + text.offsetAtColumn(line, col);
    buf.goal_col = col;
    return .{ .start = at, .end = at };
}

test {
    _ = @import("../tests/lines_test.zig");
}
