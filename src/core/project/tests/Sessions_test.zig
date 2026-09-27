//! Tests for Sessions.zig.
const std = @import("std");
const Sessions = @import("../Sessions.zig");

const testing = std.testing;

test "sessions survive a round trip, newest first" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var s = Sessions.init(gpa);
    defer s.deinit();
    const folds = [_]u32{ 3, 10 };
    try s.put(.{ .root = "/p/a", .tabs = &.{ .{ .path = "/p/a/x.zig", .line = 4, .col = 2, .top = 1.5, .folds = &folds }, .{ .path = "/p/a/y.zig" } }, .active = 1 });
    try s.put(.{ .root = "/p/b", .tabs = &.{.{ .path = "/p/b/z.go" }} });
    // Putting a folder again replaces its session and brings it first.
    try s.put(.{ .root = "/p/a", .tabs = &.{ .{ .path = "/p/a/x.zig", .line = 4, .col = 2, .top = 1.5, .folds = &folds }, .{ .path = "/p/a/y.zig" } }, .active = 1 });
    try testing.expectEqual(@as(usize, 2), s.list.items.len);
    try testing.expectEqualStrings("/p/a", s.list.items[0].root);
    try s.save(io, tmp.dir, "conf/sessions.json");

    var back = Sessions.load(gpa, io, tmp.dir, "conf/sessions.json");
    defer back.deinit();
    const a = back.get("/p/a").?;
    try testing.expectEqual(@as(u32, 1), a.active);
    try testing.expectEqualStrings("/p/a/x.zig", a.tabs[0].path);
    try testing.expectEqual(@as(u32, 4), a.tabs[0].line);
    try testing.expectEqualSlices(u32, &folds, a.tabs[0].folds);
    try testing.expect(back.get("/p/c") == null);

    // Broken or missing: nothing, not an error.
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.json", .data = "{ nope" });
    var bad = Sessions.load(gpa, io, tmp.dir, "bad.json");
    defer bad.deinit();
    try testing.expectEqual(@as(usize, 0), bad.list.items.len);
}
