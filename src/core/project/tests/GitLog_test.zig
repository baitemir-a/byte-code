//! Tests for GitLog.zig.
const std = @import("std");
const GitLog = @import("../GitLog.zig");

test "parses the log and a commit's files" {
    var log = GitLog.init(std.testing.allocator);
    defer log.deinit();
    try log.parseLog("aaaaaaaaaa\x1fAda\x1f1700000000\x1fFix: a | b\x1e\nbbbbbbbbbb\x1fBob\x1f1600000000\x1fFirst\x1e\n");
    try std.testing.expectEqual(@as(usize, 2), log.commits.items.len);
    const c = log.commits.items[0];
    try std.testing.expectEqualStrings("aaaaaaa", c.shortHash());
    try std.testing.expectEqualStrings("Ada", c.author);
    try std.testing.expectEqual(@as(i64, 1700000000), c.time);
    try std.testing.expectEqualStrings("Fix: a | b", c.subject);

    try log.parseFiles(1, "M\x00src/a.zig\x00R087\x00old.zig\x00new.zig\x00A\x00b.zig\x00");
    try std.testing.expectEqual(@as(?u32, 1), log.open);
    const f = log.files.items;
    try std.testing.expectEqual(@as(usize, 3), f.len);
    try std.testing.expectEqualStrings("src/a.zig", f[0].path);
    try std.testing.expectEqual(@as(u8, 'R'), f[1].status);
    try std.testing.expectEqualStrings("new.zig", f[1].path);
    try std.testing.expectEqualStrings("old.zig", f[1].old_path);

    // Read again with a new commit on top: the open one stays open.
    try log.parseLog("cccccccccc\x1fCy\x1f1800000000\x1fNew\x1eaaaaaaaaaa\x1fAda\x1f1700000000\x1fx\x1ebbbbbbbbbb\x1fBob\x1f1600000000\x1fFirst\x1e");
    try std.testing.expectEqual(@as(?u32, 2), log.open);
    try std.testing.expectEqual(@as(usize, 3), log.files.items.len);
    try log.parseLog("");
    try std.testing.expectEqual(@as(?u32, null), log.open);
    try std.testing.expectEqual(@as(usize, 0), log.files.items.len);
}
