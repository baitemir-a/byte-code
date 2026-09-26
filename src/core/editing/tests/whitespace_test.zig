//! Tests for whitespace.zig.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const whitespace = @import("../lib/whitespace.zig");

const testing = std.testing;

test "trailing blanks go and a final newline comes" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("a  \n\t\nb\t c \r\nend");
    b.moveTo(b.items().len, false);
    try whitespace.tidy(&b, .{});
    try testing.expectEqualStrings("a\n\nb\t c\r\nend\n", b.items());
    try testing.expectEqual(b.items().len - 1, b.cursor);
    try b.undo();
    try testing.expectEqualStrings("a  \n\t\nb\t c \r\nend", b.items());
}

test "tidy text is left alone" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("ok\n");
    const v = b.version;
    try whitespace.tidy(&b, .{});
    try testing.expectEqual(v, b.version);
    try whitespace.tidy(&b, .{ .trim_trailing = false, .final_newline = false });
    try testing.expectEqual(v, b.version);
}

test "options" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("x  ");
    try whitespace.tidy(&b, .{ .trim_trailing = false });
    try testing.expectEqualStrings("x  \n", b.items());
}
