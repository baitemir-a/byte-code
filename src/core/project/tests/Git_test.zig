//! Tests for Git.zig.
const std = @import("std");
const Git = @import("../Git.zig");

test "parses porcelain status" {
    var g = Git.init(std.testing.allocator);
    defer g.deinit();
    try g.parse("## main...origin/main [ahead 1]\x00 M src/app.ts\x00A  new.ts\x00R  moved.ts\x00old.ts\x00?? notes.md\x00MM both.zig\x00");
    try std.testing.expectEqualStrings("main", g.branch);
    try std.testing.expectEqual(@as(usize, 5), g.entries.items.len);
    const e = g.entries.items; // sorted by path
    try std.testing.expectEqualStrings("both.zig", e[0].path);
    try std.testing.expect(e[0].isStaged() and e[0].isUnstaged());
    try std.testing.expectEqualStrings("moved.ts", e[1].path);
    try std.testing.expect(e[1].isStaged() and !e[1].isUnstaged());
    try std.testing.expectEqualStrings("notes.md", e[3].path);
    try std.testing.expect(!e[3].isStaged() and e[3].isUnstaged());

    try g.parse("## No commits yet on dev\x00");
    try std.testing.expectEqualStrings("dev", g.branch);
}

test "real repository: status, stage, commit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var g = Git.init(gpa);
    defer g.deinit();
    try g.refresh(io, root);
    if (g.state == .no_git) return error.SkipZigTest;
    // The temporary folder may sit inside another repository (this
    // project's own): then git finds that one, higher up.
    if (g.state == .ok) try std.testing.expect(!std.mem.eql(u8, g.toplevel, root));

    // Set up a repository with a local identity (so commit works anywhere).
    for ([_][]const []const u8{
        &.{"init"},
        &.{ "config", "user.email", "test@example.com" },
        &.{ "config", "user.name", "Test" },
    }) |args| try g.expectOk(io, root, args);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hi" });

    try g.refresh(io, root);
    try std.testing.expectEqual(Git.State.ok, g.state);
    try std.testing.expectEqualStrings(root, g.toplevel); // our new repository
    try std.testing.expectEqual(@as(usize, 1), g.entries.items.len);
    try std.testing.expectEqual(@as(u8, '?'), g.entries.items[0].unstaged);

    try g.stage(io, root, "a.txt");
    try g.refresh(io, root);
    try std.testing.expect(g.entries.items[0].isStaged());

    try g.commit(io, root, "first");
    try g.refresh(io, root);
    try std.testing.expectEqual(@as(usize, 0), g.entries.items.len);

    // Nothing staged: git refuses, and says why.
    try std.testing.expectError(error.GitFailed, g.commit(io, root, "empty"));
    try std.testing.expect(g.last_error.items.len > 0);
}

test "real repository: throwing changes away keeps what is staged" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var g = Git.init(gpa);
    defer g.deinit();
    try g.refresh(io, root);
    if (g.state == .no_git) return error.SkipZigTest;
    for ([_][]const []const u8{
        &.{"init"},
        &.{ "config", "user.email", "test@example.com" },
        &.{ "config", "user.name", "Test" },
    }) |args| try g.expectOk(io, root, args);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "two\n" });
    try g.expectOk(io, root, &.{ "add", "." });
    try g.expectOk(io, root, &.{ "commit", "--quiet", "-m", "first" });

    // b.txt has a staged change on top of which the work tree changed
    // again; a.txt changed in the work tree only.
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "staged\n" });
    try g.expectOk(io, root, &.{ "add", "b.txt" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "and then some\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one changed\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "new.txt", .data = "untracked\n" });

    // One file at a time: a.txt goes back to the commit.
    try g.discard(io, root, "a.txt");
    const a = try tmp.dir.readFileAlloc(io, "a.txt", gpa, .limited(64));
    defer gpa.free(a);
    try std.testing.expectEqualStrings("one\n", a);

    // All of them: b.txt goes back to what is staged, which stays staged,
    // and the file git doesn't know is left where it is.
    try g.discardAll(io, root);
    const b = try tmp.dir.readFileAlloc(io, "b.txt", gpa, .limited(64));
    defer gpa.free(b);
    try std.testing.expectEqualStrings("staged\n", b);
    const untracked = try tmp.dir.readFileAlloc(io, "new.txt", gpa, .limited(64));
    defer gpa.free(untracked);
    try std.testing.expectEqualStrings("untracked\n", untracked);

    try g.refresh(io, root);
    try std.testing.expectEqual(@as(usize, 2), g.entries.items.len); // b.txt staged, new.txt untracked
    for (g.entries.items) |e| {
        if (std.mem.eql(u8, e.path, "b.txt")) try std.testing.expect(e.isStaged() and !e.isUnstaged());
    }
}
