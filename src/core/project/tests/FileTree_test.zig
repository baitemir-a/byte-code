//! Tests for FileTree.zig.
const std = @import("std");
const FileTree = @import("../FileTree.zig");

const testing = std.testing;

fn rowNames(tree: *const FileTree, out: *[16][]const u8) [][]const u8 {
    for (tree.rows.items, 0..) |r, i| out[i] = tree.node(r).name;
    return out[0..tree.rows.items.len];
}

fn expectRows(tree: *const FileTree, expected: []const []const u8) !void {
    var buf: [16][]const u8 = undefined;
    const got = rowNames(tree, &buf);
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try testing.expectEqualStrings(e, g);
}

test "lists folders first, expands lazily, refreshes" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/lib");
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = "b.ts", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "A.md", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.ts", .data = "" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);
    var tree = try FileTree.open(testing.allocator, io, dir_path);
    defer tree.deinit();

    try expectRows(&tree, &.{ "src", "A.md", "b.ts" });
    try tree.toggle(io, tree.rows.items[0]);
    try expectRows(&tree, &.{ "src", "lib", "main.ts", "A.md", "b.ts" });
    try testing.expectEqual(@as(u16, 1), tree.node(tree.rows.items[1]).depth);

    try tmp.dir.writeFile(io, .{ .sub_path = "src/new.ts", .data = "" });
    try tree.refresh(io);
    try expectRows(&tree, &.{ "src", "lib", "main.ts", "new.ts", "A.md", "b.ts" });

    try tree.toggle(io, tree.rows.items[0]);
    try expectRows(&tree, &.{ "src", "A.md", "b.ts" });

    // Collapse all, also nested folders.
    try tree.toggle(io, tree.rows.items[0]);
    try tree.toggle(io, tree.rows.items[1]); // src/lib
    try tree.collapseAll();
    try expectRows(&tree, &.{ "src", "A.md", "b.ts" });

    try testing.expectEqual(tree.rows.items[0], tree.folderOf(tree.rows.items[0]));

    const main_path = try std.fs.path.join(testing.allocator, &.{ dir_path, "src", "main.ts" });
    defer testing.allocator.free(main_path);
    try testing.expectEqual(@as(?usize, 2), try tree.reveal(io, main_path));
    try testing.expectEqual(@as(?usize, null), try tree.reveal(io, "/elsewhere/x.ts"));
}

test "create files and folders" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);
    var tree = try FileTree.open(testing.allocator, io, dir_path);
    defer tree.deinit();

    const folder = try tree.create(io, 0, "src", .folder);
    defer testing.allocator.free(folder);
    const src = tree.find(folder).?;

    // Nested path: intermediate folders are created and revealed.
    const file = try tree.create(io, src, "lib/math.ts", .file);
    defer testing.allocator.free(file);
    try testing.expect(std.mem.endsWith(u8, file, "/src/lib/math.ts"));
    try expectRows(&tree, &.{ "src", "lib", "math.ts" });
    try testing.expectEqual(tree.find(file).?, tree.rows.items[2]);
    try testing.expectEqual(tree.rows.items[1], tree.folderOf(tree.rows.items[2]));

    try testing.expectError(error.PathAlreadyExists, tree.create(io, src, "lib/math.ts", .file));
    try testing.expectError(error.PathAlreadyExists, tree.create(io, 0, "src", .folder));
    try testing.expectError(error.InvalidName, tree.create(io, 0, "../escape", .file));
    try testing.expectError(error.InvalidName, tree.create(io, 0, "  ", .file));
}

test "rename and delete" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.ts", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.ts", .data = "" });
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);
    var tree = try FileTree.open(testing.allocator, io, dir_path);
    defer tree.deinit();
    try tree.toggle(io, tree.rows.items[0]);
    try expectRows(&tree, &.{ "src", "a.ts", "b.ts" });

    // Rename a file; its content moves along.
    const renamed = try tree.rename(io, tree.rows.items[1], "main.ts");
    defer testing.allocator.free(renamed);
    try expectRows(&tree, &.{ "src", "main.ts", "b.ts" });
    const data = try tmp.dir.readFileAlloc(io, "src/main.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("x", data);

    try testing.expectError(error.PathAlreadyExists, tree.rename(io, tree.rows.items[2], "src"));
    try testing.expectError(error.InvalidName, tree.rename(io, tree.rows.items[0], "src/inner"));

    // Rename a folder: paths below it change too.
    const moved = try tree.rename(io, tree.rows.items[0], "lib");
    defer testing.allocator.free(moved);
    try testing.expect(FileTree.isAtOrUnder(tree.node(tree.rows.items[1]).path, moved));
    try testing.expect(!FileTree.isAtOrUnder("/x/library", "/x/lib"));

    try tree.deletePermanently(io, tree.rows.items[0]);
    try expectRows(&tree, &.{"b.ts"});
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "lib", .{}));
}

test "move into folders" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a/inner");
    try tmp.dir.createDirPath(io, "b");
    try tmp.dir.writeFile(io, .{ .sub_path = "x.ts", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b/x.ts", .data = "" });
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);
    var tree = try FileTree.open(testing.allocator, io, dir_path);
    defer tree.deinit();
    try expectRows(&tree, &.{ "a", "b", "x.ts" });
    const a = tree.rows.items[0];
    const b = tree.rows.items[1];
    const x = tree.rows.items[2];

    try testing.expect(!tree.canMove(x, 0)); // already there
    try testing.expect(!tree.canMove(a, a)); // into itself
    try tree.toggle(io, a);
    try testing.expect(!tree.canMove(a, tree.rows.items[1])); // into its own subfolder
    try testing.expect(tree.canMove(x, a));

    try testing.expectError(error.PathAlreadyExists, tree.move(io, x, b)); // b/x.ts exists

    const moved = try tree.move(io, x, a);
    defer testing.allocator.free(moved);
    try testing.expect(std.mem.endsWith(u8, moved, "/a/x.ts"));
    try expectRows(&tree, &.{ "a", "inner", "x.ts", "b" });

    // Moving a folder keeps it expanded (and its new parent opens).
    const a_moved = try tree.move(io, tree.rows.items[0], tree.rows.items[3]);
    defer testing.allocator.free(a_moved);
    try expectRows(&tree, &.{ "b", "a", "inner", "x.ts", "x.ts" });
}
