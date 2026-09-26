//! Tests for comment.zig.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const comment = @import("../lib/comment.zig");

const testing = std.testing;

const slashes: comment.Style = .{ .line = "//", .block = .{ "/*", "*/" } };
const markup: comment.Style = .{ .block = .{ "<!--", "-->" } };

fn bufferWith(s: []const u8) !Buffer {
    var b = Buffer.init(testing.allocator);
    try b.load(s);
    return b;
}

test "comments lines out in the column of the least indented" {
    var b = try bufferWith("if (x) {\n    y();\n\n}");
    defer b.deinit();
    b.selectAll();
    _ = try comment.toggle(&b, slashes, null);
    try testing.expectEqualStrings("// if (x) {\n//     y();\n\n// }", b.items());
    _ = try comment.toggle(&b, slashes, null);
    try testing.expectEqualStrings("if (x) {\n    y();\n\n}", b.items());
}

test "a line is commented after its indentation, and the cursor moves along" {
    var b = try bufferWith("    x = 1");
    defer b.deinit();
    b.moveTo(6, false);
    _ = try comment.toggle(&b, .{ .line = "#" }, null);
    try testing.expectEqualStrings("    # x = 1", b.items());
    try testing.expectEqual(@as(usize, 8), b.cursor);
    try b.undo();
    try testing.expectEqualStrings("    x = 1", b.items());
}

test "mixed lines are all commented" {
    var b = try bufferWith("// a\nb");
    defer b.deinit();
    b.selectAll();
    _ = try comment.toggle(&b, slashes, null);
    try testing.expectEqualStrings("// // a\n// b", b.items());
}

test "uncommenting works without a space after the prefix" {
    var b = try bufferWith("  //a\n  // b");
    defer b.deinit();
    b.selectAll();
    _ = try comment.toggle(&b, slashes, null);
    try testing.expectEqualStrings("  a\n  b", b.items());
}

test "block comments wrap the lines" {
    var b = try bufferWith("  <p>hi</p>\n");
    defer b.deinit();
    b.moveTo(3, false);
    _ = try comment.toggle(&b, markup, null);
    try testing.expectEqualStrings("  <!-- <p>hi</p> -->\n", b.items());
    _ = try comment.toggle(&b, markup, null);
    try testing.expectEqualStrings("  <p>hi</p>\n", b.items());
}

test "styles for languages" {
    try testing.expectEqualStrings("#", comment.styleFor(.python).line.?);
    try testing.expectEqualStrings("//", comment.styleFor(.zig).line.?);
    try testing.expect(comment.styleFor(.css).line == null);
    try testing.expectEqualStrings("--", comment.styleFor(.sql).line.?);
}
