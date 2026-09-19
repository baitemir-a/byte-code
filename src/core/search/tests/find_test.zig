//! Tests for find.zig.
const std = @import("std");
const find = @import("../lib/find.zig");

test "case and whole-word options" {
    const s = "user User username getUser user_id user";
    try std.testing.expectEqual(@as(?usize, 5), find.next(s, 1, "user", .{}));
    try std.testing.expectEqual(@as(?usize, 10), find.next(s, 1, "user", .{ .match_case = true })); // "username"
    try std.testing.expectEqual(@as(?usize, 5), find.next(s, 1, "User", .{ .match_case = true }));
    try std.testing.expectEqual(@as(?usize, null), find.next(s, 6, "User", .{ .match_case = true, .whole_word = true }));
    // Whole word: skips "username", "getUser" and "user_id" ('_' is part of a word).
    try std.testing.expectEqual(@as(?usize, 5), find.next(s, 1, "user", .{ .whole_word = true }));
    try std.testing.expectEqual(@as(?usize, 35), find.next(s, 6, "user", .{ .whole_word = true }));
    try std.testing.expectEqual(@as(?usize, 22), find.next(s, 6, "User", .{ .match_case = true })); // in getUser
    try std.testing.expectEqual(@as(?usize, null), find.next(s, 6, "User", .{ .whole_word = true, .match_case = true }));
    try std.testing.expect(find.matchesAt(s, 5, "user", .{}));
    try std.testing.expect(!find.matchesAt(s, 5, "user", .{ .match_case = true }));
    try std.testing.expect(!find.matchesAt(s, 10, "user", .{ .whole_word = true }));
}
