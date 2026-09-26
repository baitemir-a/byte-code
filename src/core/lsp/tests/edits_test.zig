//! Tests for edits.zig.
const std = @import("std");
const edits = @import("../edits.zig");
const Buffer = @import("../../buffer/Buffer.zig");

const testing = std.testing;

fn parse(arena: std.mem.Allocator, json: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
}

test "a workspace edit, in either of its shapes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const changes = try edits.parseWorkspaceEdit(a, try parse(a,
        \\{"changes": {"file:///p/a.ts": [{"range": {"start": {"line": 0, "character": 4}, "end": {"line": 0, "character": 7}}, "newText": "bar"}]}}
    ));
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqualStrings("/p/a.ts", changes[0].path);
    try testing.expectEqualStrings("bar", changes[0].edits[0].text);

    const docs = try edits.parseWorkspaceEdit(a, try parse(a,
        \\{"documentChanges": [{"textDocument": {"uri": "file:///p/b.go", "version": 3}, "edits": []}, {"kind": "create", "uri": "file:///p/c"}]}
    ));
    try testing.expectEqual(@as(usize, 1), docs.len);
    try testing.expectEqualStrings("/p/b.go", docs[0].path);
}

test "edits apply in any order, to text and to a buffer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = [_]edits.TextEdit{
        .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 3 }, .text = "foo" },
        .{ .start = .{ .line = 0, .character = 6 }, .end = .{ .line = 0, .character = 9 }, .text = "foo" },
        .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 }, .text = "import x;\n" },
    };
    const text = "const bar = 1;\nbar();\n";
    try testing.expectEqualStrings("import x;\nconst foo = 1;\nfoo();\n", try edits.applyToText(a, text, &list));

    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load(text);
    b.moveTo(16, false); // in "bar()" on the second line
    try edits.applyToBuffer(a, &b, &list);
    try testing.expectEqualStrings("import x;\nconst foo = 1;\nfoo();\n", b.items());
    try testing.expectEqual(@as(usize, 16 + 10), b.cursor);
    try b.undo();
    try testing.expectEqualStrings(text, b.items());
}
