//! Cursor movements: where each motion lands and how it moves the cursor.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const text = @import("text.zig");

pub const Motion = enum {
    char_left,
    char_right,
    word_left,
    word_right,
    /// First non-blank character, or column 0 if already there.
    line_start,
    line_end,
    line_up,
    line_down,
    page_up,
    page_down,
    doc_start,
    doc_end,
};

/// Moves the cursor. With `extend` the selection grows; without it an
/// existing selection collapses.
pub fn apply(buf: *Buffer, m: Motion, extend: bool, page_lines: usize) void {
    const page: isize = @intCast(page_lines);
    switch (m) {
        .line_up => moveLines(buf, -1, extend),
        .line_down => moveLines(buf, 1, extend),
        .page_up => moveLines(buf, -page, extend),
        .page_down => moveLines(buf, page, extend),
        // Left/Right on a selection jumps to its edge instead of moving.
        .char_left => if (!extend and buf.selection() != null)
            buf.moveTo(buf.selection().?.start, false)
        else
            buf.moveTo(target(buf, m), extend),
        .char_right => if (!extend and buf.selection() != null)
            buf.moveTo(buf.selection().?.end, false)
        else
            buf.moveTo(target(buf, m), extend),
        else => buf.moveTo(target(buf, m), extend),
    }
}

/// Where a horizontal / document motion from the cursor would land.
pub fn target(buf: *const Buffer, m: Motion) usize {
    const pos = buf.cursor;
    return switch (m) {
        .char_left => buf.prevPos(pos),
        .char_right => buf.nextPos(pos),
        .word_left => wordLeft(buf.items(), pos),
        .word_right => wordRight(buf.items(), pos),
        .line_start => smartLineStart(buf, pos),
        .line_end => buf.lineEnd(pos),
        .doc_start => 0,
        .doc_end => buf.items().len,
        .line_up, .line_down, .page_up, .page_down => unreachable, // need goal column
    };
}

/// Moves `delta` lines up (negative) or down, keeping the goal column.
fn moveLines(buf: *Buffer, delta: isize, extend: bool) void {
    const col = buf.goal_col orelse buf.column(buf.cursor);
    const line = @as(isize, @intCast(buf.lineIndex(buf.cursor))) + delta;
    const pos = if (line < 0)
        0
    else if (line >= buf.lineCount())
        buf.items().len
    else
        buf.posAt(@intCast(line), col);
    buf.moveTo(pos, extend);
    buf.goal_col = col;
}

pub fn wordLeft(b: []const u8, pos: usize) usize {
    var p = pos;
    while (p > 0 and !text.isWordChar(b[p - 1])) p -= 1;
    while (p > 0 and text.isWordChar(b[p - 1])) p -= 1;
    return p;
}

pub fn wordRight(b: []const u8, pos: usize) usize {
    var p = pos;
    while (p < b.len and !text.isWordChar(b[p])) p += 1;
    while (p < b.len and text.isWordChar(b[p])) p += 1;
    return p;
}

/// The word around `pos`, for double-click selection: a run of word
/// characters, or — on a blank or a punctuation mark — the run of blanks
/// or the single character there. Clicking just past a word (`pos` right
/// after its last character) takes that word.
pub fn wordRange(b: []const u8, pos: usize) Buffer.Range {
    var p = pos;
    if (!isWord(b, p) and p > 0 and text.isWordChar(b[p - 1])) p -= 1;
    if (isWord(b, p)) return runAround(b, p, isWord);
    if (isBlank(b, p)) return runAround(b, p, isBlank);
    // Punctuation, or the end of a line: just the character clicked.
    if (p >= b.len or b[p] == '\n') return .{ .start = p, .end = p };
    return .{ .start = p, .end = text.nextBoundary(b, p) };
}

/// The line `pos` is on, with its newline, for triple-click selection:
/// copying or cutting it then takes a whole line.
pub fn lineRange(b: []const u8, pos: usize) Buffer.Range {
    const start = if (std.mem.lastIndexOfScalar(u8, b[0..pos], '\n')) |i| i + 1 else 0;
    const nl = std.mem.indexOfScalarPos(u8, b, pos, '\n');
    return .{ .start = start, .end = if (nl) |i| i + 1 else b.len };
}

/// The longest run of characters `matches` accepts that covers `p`.
fn runAround(b: []const u8, p: usize, comptime matches: fn ([]const u8, usize) bool) Buffer.Range {
    var start = p;
    var end = p;
    while (start > 0 and matches(b, start - 1)) start -= 1;
    while (end < b.len and matches(b, end)) end += 1;
    return .{ .start = start, .end = end };
}

fn isWord(b: []const u8, p: usize) bool {
    return p < b.len and text.isWordChar(b[p]);
}

fn isBlank(b: []const u8, p: usize) bool {
    return p < b.len and (b[p] == ' ' or b[p] == '\t');
}

pub fn smartLineStart(buf: *const Buffer, pos: usize) usize {
    const start = buf.lineStart(pos);
    var p = start;
    while (buf.byteAt(p)) |c| : (p += 1) {
        if (c != ' ' and c != '\t') break;
    }
    return if (pos == p) start else p;
}

test {
    _ = @import("../tests/motion_test.zig");
}
