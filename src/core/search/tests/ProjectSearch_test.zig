//! Tests for ProjectSearch.zig.
const std = @import("std");
const ProjectSearch = @import("../ProjectSearch.zig");

test "finds matches across files with lines and positions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.ts", .data = "const user = 1;\nfunction getUser() {\n  return USER;\n}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.md", .data = "no match here" });
    try tmp.dir.writeFile(io, .{ .sub_path = "img.bin", .data = "user\x00\x01" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var ps = ProjectSearch.init(gpa);
    defer ps.deinit();
    try ps.run(io, root, &.{ "src/a.ts", "b.md", "img.bin" }, "user", .{}, null);
    try std.testing.expectEqual(@as(usize, 1), ps.files.items.len); // binary skipped
    try std.testing.expectEqual(@as(u32, 3), ps.files.items[0].count); // user, User, USER
    const m = ps.matches.items[1];
    try std.testing.expectEqual(@as(u32, 1), m.line);
    try std.testing.expectEqualStrings("function getUser() {", m.preview);
    try std.testing.expectEqualStrings("User", m.preview[m.preview_start..m.preview_end]);

    try ps.run(io, root, &.{"src/a.ts"}, "USER", .{ .match_case = true }, null);
    try std.testing.expectEqual(@as(usize, 1), ps.matches.items.len);
    try std.testing.expectEqual(@as(u32, 2), ps.matches.items[0].line);

    try ps.run(io, root, &.{"src/a.ts"}, "user", .{ .whole_word = true }, null);
    try std.testing.expectEqual(@as(usize, 2), ps.matches.items.len); // not getUser

    // An open tab's text is searched instead of the file on disk.
    const Tabs = struct {
        fn get(_: *const anyopaque, path: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, path, "b.md")) "edited: user" else null;
        }
    };
    try ps.run(io, root, &.{"b.md"}, "user", .{}, .{ .ctx = undefined, .get = Tabs.get });
    try std.testing.expectEqual(@as(usize, 8), ps.matches.items[0].start);
}

test "replace all in text" {
    const gpa = std.testing.allocator;
    const r = try ProjectSearch.replaceAll(gpa, "user User USER", "user", "member", .{});
    defer gpa.free(r.text.?);
    try std.testing.expectEqual(@as(usize, 3), r.count);
    try std.testing.expectEqualStrings("member member member", r.text.?);

    const exact = try ProjectSearch.replaceAll(gpa, "user User", "User", "X", .{ .match_case = true });
    defer gpa.free(exact.text.?);
    try std.testing.expectEqualStrings("user X", exact.text.?);

    const word = try ProjectSearch.replaceAll(gpa, "user users user", "user", "X", .{ .whole_word = true });
    defer gpa.free(word.text.?);
    try std.testing.expectEqualStrings("X users X", word.text.?);

    try std.testing.expectEqual(@as(?[]u8, null), (try ProjectSearch.replaceAll(gpa, "abc", "zzz", "q", .{})).text);
}
