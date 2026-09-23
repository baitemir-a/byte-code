//! Tests for Diff.zig.
const std = @import("std");
const Diff = @import("../Diff.zig");

/// A diff of two texts, already "in" a repository so it compares them.
fn diffOf(d: *Diff, base: []const u8, now: []const u8) !void {
    try d.setFile("/repo/a.txt", "/repo", "a.txt", .index);
    try d.setBase(base, true);
    try d.compute(now, 1);
}

test "unchanged text has no changes" {
    var d = Diff.init(std.testing.allocator);
    defer d.deinit();
    try diffOf(&d, "one\ntwo\nthree\n", "one\ntwo\nthree\n");
    try std.testing.expectEqual(@as(usize, 0), d.hunks.items.len);
}

test "added, changed and removed lines" {
    var d = Diff.init(std.testing.allocator);
    defer d.deinit();
    try diffOf(&d, "a\nb\nc\nd\ne\n", "a\nnew\nb\nC\nd\n");
    // "new" added after "a", "c" changed to "C", "e" removed.
    try std.testing.expectEqual(@as(usize, 3), d.hunks.items.len);
    const h = d.hunks.items;
    try std.testing.expectEqual(Diff.Kind.added, h[0].kind());
    try std.testing.expectEqual(@as(u32, 1), h[0].new_start);
    try std.testing.expectEqual(@as(u32, 1), h[0].new_len);
    try std.testing.expectEqual(Diff.Kind.modified, h[1].kind());
    try std.testing.expectEqual(@as(u32, 3), h[1].new_start);
    try std.testing.expectEqual(Diff.Kind.deleted, h[2].kind());
    try std.testing.expectEqualStrings("e\n", d.removedText(h[2]));
    try std.testing.expectEqual(@as(u32, 4), d.markedLine(h[2]));

    // Every line knows the change it belongs to.
    try std.testing.expectEqual(null, d.hunkAt(0));
    try std.testing.expectEqual(@as(u32, 0), d.hunkAt(1).?);
    try std.testing.expectEqual(@as(u32, 1), d.hunkAt(3).?);
}

test "a file git doesn't know is all new" {
    var d = Diff.init(std.testing.allocator);
    defer d.deinit();
    try d.setFile("/repo/new.txt", "/repo", "new.txt", .index);
    try d.setBase("", false);
    try d.compute("one\ntwo\n", 1);
    try std.testing.expectEqual(@as(usize, 1), d.hunks.items.len);
    try std.testing.expectEqual(Diff.Kind.added, d.hunks.items[0].kind());
    try std.testing.expectEqual(@as(u32, 2), d.hunks.items[0].new_len);
}

test "lines removed from the end are marked on the last line" {
    var d = Diff.init(std.testing.allocator);
    defer d.deinit();
    try diffOf(&d, "a\nb\nc\n", "a\n");
    try std.testing.expectEqual(@as(usize, 1), d.hunks.items.len);
    const h = d.hunks.items[0];
    try std.testing.expectEqual(Diff.Kind.deleted, h.kind());
    try std.testing.expectEqual(@as(u32, 0), d.markedLine(h));
    try std.testing.expectEqual(@as(u32, 0), d.hunkAt(0).?);
}

test "a change becomes a patch git can apply" {
    const gpa = std.testing.allocator;
    var d = Diff.init(gpa);
    defer d.deinit();
    const now = "a\nB\nc\n";
    try diffOf(&d, "a\nb\nc\n", now);
    const patch = try d.hunkPatch(gpa, d.hunks.items[0]);
    defer gpa.free(patch);
    try std.testing.expectEqualStrings(
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,3 +1,3 @@
        \\ a
        \\-b
        \\+B
        \\ c
        \\
    , patch);
}

test "a last line without a newline is noted in the patch" {
    const gpa = std.testing.allocator;
    var d = Diff.init(gpa);
    defer d.deinit();
    const now = "a\nB";
    try diffOf(&d, "a\nb", now);
    const patch = try d.hunkPatch(gpa, d.hunks.items[0]);
    defer gpa.free(patch);
    try std.testing.expect(std.mem.count(u8, patch, "\\ No newline at end of file") == 2);
}

test "many scattered changes" {
    const gpa = std.testing.allocator;
    var d = Diff.init(gpa);
    defer d.deinit();
    var base: std.ArrayList(u8) = .empty;
    defer base.deinit(gpa);
    var now: std.ArrayList(u8) = .empty;
    defer now.deinit(gpa);
    for (0..200) |i| {
        try base.print(gpa, "line {d}\n", .{i});
        try now.print(gpa, "line {d}{s}\n", .{ i, if (i % 20 == 0) " changed" else "" });
    }
    try diffOf(&d, base.items, now.items);
    try std.testing.expectEqual(@as(usize, 10), d.hunks.items.len);
    for (d.hunks.items) |h| try std.testing.expectEqual(Diff.Kind.modified, h.kind());
}

test "real repository: staging one change leaves the others alone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Git = @import("../Git.zig");
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
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "1\n2\n3\n4\n5\n6\n7\n8\n9\n" });
    try g.expectOk(io, root, &.{ "add", "a.txt" });
    try g.expectOk(io, root, &.{ "commit", "--quiet", "-m", "first" });

    // Two changes in the editor, far enough apart to stay separate.
    const now = "1\n2\nTHREE\n4\n5\n6\n7\n8\nNINE\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = now });

    var d = Diff.init(gpa);
    defer d.deinit();
    const staged = (try Git.showIndex(gpa, io, root, "a.txt")).?;
    defer gpa.free(staged);
    try d.setFile("a.txt", root, "a.txt", .index);
    try d.setBase(staged, true);
    try d.compute(now, 1);
    try std.testing.expectEqual(@as(usize, 2), d.hunks.items.len);

    const patch = try d.hunkPatch(gpa, d.hunks.items[0]);
    defer gpa.free(patch);
    try g.apply(io, root, patch, .index, false);

    // Only the first change is staged now.
    const after = (try Git.showIndex(gpa, io, root, "a.txt")).?;
    defer gpa.free(after);
    try std.testing.expectEqualStrings("1\n2\nTHREE\n4\n5\n6\n7\n8\n9\n", after);
}

test "both copies in one text, removed lines and all" {
    const gpa = std.testing.allocator;
    var d = Diff.init(gpa);
    defer d.deinit();
    try diffOf(&d, "a\nb\nc\nd\n", "a\nB\nd\nE\n");
    try d.buildCombined();
    try std.testing.expectEqualStrings("a\nb\nc\nB\nd\nE\n", d.combined.items);
    const lines = d.combined_lines.items;
    try std.testing.expectEqual(@as(usize, 6), lines.len);
    try std.testing.expectEqual(Diff.LineKind.context, lines[0].kind);
    try std.testing.expectEqual(Diff.LineKind.removed, lines[1].kind);
    try std.testing.expectEqual(Diff.LineKind.removed, lines[2].kind);
    try std.testing.expectEqual(Diff.LineKind.added, lines[3].kind);
    try std.testing.expectEqual(Diff.LineKind.context, lines[4].kind);
    try std.testing.expectEqual(Diff.LineKind.added, lines[5].kind);
    // Each line keeps the number it has in its own copy.
    try std.testing.expectEqual(@as(u32, 2), lines[1].number);
    try std.testing.expectEqual(@as(u32, 3), lines[2].number);
    try std.testing.expectEqual(@as(u32, 2), lines[3].number);
    try std.testing.expectEqual(@as(u32, 4), lines[5].number);
    // And knows the change it belongs to, which starts where it does.
    try std.testing.expectEqual(@as(u32, 0), lines[1].hunk.?);
    try std.testing.expectEqual(null, lines[4].hunk);
    try std.testing.expectEqual(@as(u32, 1), d.combined_starts.items[0]);
    try std.testing.expectEqual(@as(u32, 5), d.combined_starts.items[1]);
}

test "real repository: the staged changes can be taken back out" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Git = @import("../Git.zig");
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
    const committed = "1\n2\n3\n4\n5\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = committed });
    try g.expectOk(io, root, &.{ "add", "a.txt" });
    try g.expectOk(io, root, &.{ "commit", "--quiet", "-m", "first" });

    // A change is staged; the tab for the staged changes compares what's
    // staged with the commit.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "1\n2\nTHREE\n4\n5\n" });
    try g.expectOk(io, root, &.{ "add", "a.txt" });

    var d = Diff.init(gpa);
    defer d.deinit();
    const head = (try Git.showHead(gpa, io, root, "a.txt")).?;
    defer gpa.free(head);
    const staged = (try Git.showIndex(gpa, io, root, "a.txt")).?;
    defer gpa.free(staged);
    try d.setFile("a.txt", root, "a.txt", .head);
    try d.setBase(head, true);
    try d.compute(staged, 1);
    try std.testing.expectEqual(@as(usize, 1), d.hunks.items.len);

    const patch = try d.hunkPatch(gpa, d.hunks.items[0]);
    defer gpa.free(patch);
    try g.apply(io, root, patch, .index, true); // unstage it again
    const after = (try Git.showIndex(gpa, io, root, "a.txt")).?;
    defer gpa.free(after);
    try std.testing.expectEqualStrings(committed, after);
}
