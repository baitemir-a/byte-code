//! Tests for wrap.zig.
const std = @import("std");
const wrap = @import("../lib/wrap.zig");
const Row = wrap.Row;
const buildRows = wrap.buildRows;

fn expectRows(src: []const u8, cols: usize, want: []const []const u8) !void {
    const gpa = std.testing.allocator;
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    try buildRows(gpa, &rows, src, cols);
    try std.testing.expectEqual(want.len, rows.items.len);
    for (rows.items, want, 0..) |r, w, i| {
        const end = if (i + 1 < rows.items.len)
            (if (rows.items[i + 1].line == r.line) rows.items[i + 1].start else rows.items[i + 1].start - 1)
        else
            src.len;
        try std.testing.expectEqualStrings(w, src[r.start..end]);
    }
}

test "wraps after spaces, mid-word only when needed" {
    try expectRows("the quick brown fox\nhi", 10, &.{ "the quick ", "brown fox", "hi" });
    try expectRows("abcdefghijklmno", 6, &.{ "abcdef", "ghijkl", "mno" });
    // Spaces hang at the end of a row instead of starting the next.
    try expectRows("abcdef   gh", 6, &.{ "abcdef   ", "gh" });
    try expectRows("short\n\nlines", 10, &.{ "short", "", "lines" });
    // No wrapping: one row per line.
    try expectRows("the quick brown fox\nhi", 0, &.{ "the quick brown fox", "hi" });
}

test "multi-byte characters count as one column" {
    try expectRows("привет мир", 7, &.{ "привет ", "мир" });
}
