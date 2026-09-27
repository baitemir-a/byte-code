//! Word wrap: splits text into screen rows no wider than a number of
//! columns. Lines break after their last space that fits, or mid-word when
//! a word alone is too long; spaces may hang past the edge rather than
//! start a row.
const std = @import("std");
const text = @import("text.zig");

/// One screen row: where it starts in the text, and the line it's part of.
pub const Row = struct { start: usize, line: u32 };

/// A stretch of text, in bytes.
pub const Range = @import("../../buffer/Buffer.zig").Range;

/// Replaces `rows` with the rows of `bytes`, whose lines start at
/// `starts` (see `Buffer.line_starts`). `cols` 0 means no wrapping: one
/// row per line, made without looking at the text. Lines starting inside
/// `hidden` (sorted ranges, the folded lines) get no rows.
pub fn buildRows(gpa: std.mem.Allocator, rows: *std.ArrayList(Row), bytes: []const u8, starts: []const usize, cols: usize, hidden: []const Range) !void {
    rows.clearRetainingCapacity();
    try rows.ensureTotalCapacity(gpa, starts.len);
    var h: usize = 0;
    for (starts, 0..) |start, i| {
        while (h < hidden.len and hidden[h].end < start) h += 1;
        if (h < hidden.len and hidden[h].start <= start) continue;
        const line: u32 = @intCast(i);
        try rows.append(gpa, .{ .start = start, .line = line });
        if (cols > 0) {
            const end = if (i + 1 < starts.len) starts[i + 1] - 1 else bytes.len;
            try wrapLine(gpa, rows, bytes[start..end], start, line, cols);
        }
    }
}

/// Where the lines of `bytes` start, for `buildRows` on a bare text.
pub fn lineStarts(gpa: std.mem.Allocator, bytes: []const u8) !std.ArrayList(usize) {
    var starts: std.ArrayList(usize) = .empty;
    try starts.append(gpa, 0);
    for (bytes, 0..) |c, i| if (c == '\n') try starts.append(gpa, i + 1);
    return starts;
}

/// Adds a line's continuation rows.
fn wrapLine(gpa: std.mem.Allocator, rows: *std.ArrayList(Row), s: []const u8, base: usize, line: u32, cols: usize) !void {
    var row_start: usize = 0;
    var col: usize = 0;
    var after_space: ?usize = null;
    var i: usize = 0;
    while (i < s.len) {
        const next_col = text.advance(col, s[i]);
        if (next_col > cols and i > row_start and s[i] != ' ') {
            const at = after_space orelse i;
            try rows.append(gpa, .{ .start = base + at, .line = line });
            row_start = at;
            after_space = null;
            col = text.visualColumn(s[at..i]);
            continue; // measure this character again on the new row
        }
        col = next_col;
        const next = text.nextBoundary(s, i);
        if (s[i] == ' ' or s[i] == '\t') after_space = next;
        i = next;
    }
}

test {
    _ = @import("../tests/wrap_test.zig");
}
