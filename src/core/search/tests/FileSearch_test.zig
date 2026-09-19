//! Tests for FileSearch.zig.
const std = @import("std");
const FileSearch = @import("../FileSearch.zig");

test "lists files, skips hidden and dependency folders, ranks by name" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "src/App.zig", "src/ui/Sidebar.zig", "src/ui/app_icon.png", "README.md", ".git/config", "node_modules/x/index.js", ".env" }) |p| {
        if (std.fs.path.dirname(p)) |d| try tmp.dir.createDirPath(io, d);
        try tmp.dir.writeFile(io, .{ .sub_path = p, .data = "" });
    }
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var fs = FileSearch.init(gpa);
    defer fs.deinit();
    try fs.scan(io, root);
    try std.testing.expectEqual(@as(usize, 4), fs.files.items.len);
    try std.testing.expectEqualStrings("README.md", fs.files.items[0]);

    var results: std.ArrayList(FileSearch.Result) = .empty;
    defer results.deinit(gpa);

    // Both "app" files rank above paths that only contain a…p…p; exact
    // case decides between them.
    try fs.search("app", &results, 10);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try fs.search("App", &results, 10);
    try std.testing.expectEqualStrings("src/App.zig", fs.files.items[results.items[0].file]);

    try fs.search("sidebar", &results, 10);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("src/ui/Sidebar.zig", fs.files.items[results.items[0].file]);

    // With a '/', the path counts: "ui/app" finds the icon under ui/.
    try fs.search("ui/app", &results, 10);
    try std.testing.expectEqualStrings("src/ui/app_icon.png", fs.files.items[results.items[0].file]);

    try fs.search("", &results, 2);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
}
