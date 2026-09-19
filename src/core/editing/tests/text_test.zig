//! Tests for text.zig.
const std = @import("std");
const text = @import("../lib/text.zig");

test "tab stops" {
    try std.testing.expectEqual(@as(usize, 4), text.visualColumn("\t"));
    try std.testing.expectEqual(@as(usize, 4), text.visualColumn("ab\t"));
    try std.testing.expectEqual(@as(usize, 9), text.visualColumn("\tab\tx"));
    try std.testing.expectEqual(@as(usize, 2), text.visualColumn("ö\u{e9}")); // multi-byte chars are one column

    const line = "\tx";
    try std.testing.expectEqual(@as(usize, 0), text.offsetAtColumn(line, 1)); // closer to the tab's start
    try std.testing.expectEqual(@as(usize, 1), text.offsetAtColumn(line, 3)); // closer to its end
    try std.testing.expectEqual(@as(usize, 2), text.offsetAtColumn(line, 5));
    try std.testing.expectEqual(@as(usize, 2), text.offsetAtColumn(line, 99));
}

test "indent detection" {
    try std.testing.expectEqualStrings("\t", text.detectIndent("a {\n\tb\n\t\tc\n}"));
    try std.testing.expectEqualStrings("  ", text.detectIndent("a {\n  b {\n    c\n  }\n}"));
    try std.testing.expectEqualStrings("    ", text.detectIndent("a {\n    b\n    /**\n     * doc\n     */\n}"));
    try std.testing.expectEqualStrings("    ", text.detectIndent("no indentation"));
}

test "utf-8 boundaries" {
    const s = "aöb";
    try std.testing.expectEqual(@as(usize, 3), text.codepointCount(s));
    try std.testing.expectEqual(@as(usize, 3), text.nextBoundary(s, 1));
    try std.testing.expectEqual(@as(usize, 1), text.prevBoundary(s, 3));
}
