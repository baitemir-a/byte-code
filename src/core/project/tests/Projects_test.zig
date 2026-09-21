//! Tests for Projects.zig.
const std = @import("std");
const Projects = @import("../Projects.zig");

const testing = std.testing;

fn paths(list: *const Projects, out: *[Projects.max_entries][]const u8) []const []const u8 {
    for (list.entries.items, 0..) |e, i| out[i] = e.path;
    return out[0..list.entries.items.len];
}

fn expectOrder(list: *const Projects, expected: []const []const u8) !void {
    var buf: [Projects.max_entries][]const u8 = undefined;
    const got = paths(list, &buf);
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try testing.expectEqualStrings(e, g);
}

test "the newest folder comes first, and is only listed once" {
    var list: Projects = .init(testing.allocator);
    defer list.deinit();

    try list.record("/code/one");
    try list.record("/code/two");
    try list.record("/code/three");
    try expectOrder(&list, &.{ "/code/three", "/code/two", "/code/one" });

    // Opening an old one again moves it up rather than repeating it.
    try list.record("/code/one");
    try expectOrder(&list, &.{ "/code/one", "/code/three", "/code/two" });

    // The same folder, written with a trailing separator.
    try list.record("/code/two/");
    try expectOrder(&list, &.{ "/code/two", "/code/one", "/code/three" });
}

test "favorites keep their place, others fall off the end" {
    var list: Projects = .init(testing.allocator);
    defer list.deinit();

    try list.record("/code/keeper");
    list.toggleFavorite(0);
    for (0..Projects.max_recent + 3) |i| {
        var buf: [32]u8 = undefined;
        try list.record(try std.fmt.bufPrint(&buf, "/code/p{d}", .{i}));
    }
    // The favorite is still there, at the end of the history.
    try testing.expectEqual(Projects.max_recent + 1, list.entries.items.len);
    const last = list.entries.items[list.entries.items.len - 1];
    try testing.expectEqualStrings("/code/keeper", last.path);
    try testing.expect(last.favorite);

    // Giving up on it lets the history drop it.
    list.toggleFavorite(list.entries.items.len - 1);
    try testing.expectEqual(Projects.max_recent, list.entries.items.len);
    try testing.expectEqual(@as(?usize, null), list.indexOf("/code/keeper"));
}

test "written out and read back" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    var list: Projects = .init(testing.allocator);
    defer list.deinit();
    try list.record("/code/one");
    try list.record("/code/two");
    list.toggleFavorite(1); // /code/one
    try list.save(io, dir, "projects.json");

    var read = Projects.load(testing.allocator, io, dir, "projects.json");
    defer read.deinit();
    try expectOrder(&read, &.{ "/code/two", "/code/one" });
    try testing.expect(read.entries.items[1].favorite);
    try testing.expect(!read.entries.items[0].favorite);
}

test "a missing file is an empty list" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var list = Projects.load(testing.allocator, io, tmp.dir, "nothing.json");
    defer list.deinit();
    try testing.expectEqual(@as(usize, 0), list.entries.items.len);
}
