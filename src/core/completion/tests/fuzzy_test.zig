//! Tests for fuzzy.zig.
const std = @import("std");
const fuzzy = @import("../lib/fuzzy.zig");

test "subsequence and ranking" {
    try std.testing.expect(fuzzy.match("console", "cns") != null);
    try std.testing.expect(fuzzy.match("console", "cx") == null);
    // Word starts count: "gebi" hits get-Element-By-Id humps.
    try std.testing.expect(fuzzy.match("getElementById", "gebi").?.score > fuzzy.match("gxexbxix", "gebi").?.score);
    // Prefix beats a scattered match.
    try std.testing.expect(fuzzy.match("map", "ma").?.score > fuzzy.match("Math", "mh").?.score);
    try std.testing.expectEqual(@as(u64, 0b101), fuzzy.match("abc", "ac").?.positions);
}
