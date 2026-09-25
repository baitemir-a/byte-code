//! Tests for tsconfig.zig.
const std = @import("std");
const tsconfig = @import("../lib/tsconfig.zig");

const testing = std.testing;

test "strips comments and trailing commas" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try tsconfig.stripJsonc(arena.allocator(),
        \\{
        \\  // comment
        \\  "a": "x // not a comment", /* block */
        \\  "b": [1, 2,],
        \\}
    );
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), out, .{});
    try testing.expectEqualStrings("x // not a comment", v.object.get("a").?.string);
    try testing.expectEqual(@as(usize, 2), v.object.get("b").?.array.items.len);
}

test "reads paths through references" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/pages");
    try tmp.dir.writeFile(io, .{ .sub_path = "tsconfig.json", .data =
        \\{ "files": [], "references": [{ "path": "./tsconfig.app.json" }] }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "tsconfig.app.json", .data =
        \\{
        \\  "compilerOptions": {
        \\    "baseUrl": ".",
        \\    "paths": { "@/*": ["./src/*"], "config": ["./src/config.ts"] }, // aliases
        \\  },
        \\}
    });
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const pages = try std.fs.path.join(testing.allocator, &.{ root, "src", "pages" });
    defer testing.allocator.free(pages);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const config = tsconfig.load(arena.allocator(), io, pages);
    try testing.expectEqualStrings(root, config.base_url.?);
    try testing.expectEqual(@as(usize, 2), config.aliases.len);
    for (config.aliases) |a| {
        if (a.wildcard) {
            try testing.expectEqualStrings("@/", a.prefix);
            try testing.expect(std.mem.endsWith(u8, a.target, "/src"));
        } else try testing.expectEqualStrings("config", a.prefix);
    }
}
