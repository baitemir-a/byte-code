//! Tests for format.zig.
const std = @import("std");
const format = @import("../format.zig");
const checkers = @import("../../diagnostics/lib/checkers.zig");

const testing = std.testing;

test "the change between two texts is only what differs" {
    const c = format.change("a  = 1;\nb = 2;\n", "a = 1;\nb = 2;\n").?;
    try testing.expectEqual(@as(usize, 2), c.start);
    try testing.expectEqual(@as(usize, 3), c.end);
    try testing.expectEqualStrings("", c.text);
    try testing.expect(format.change("same", "same") == null);
    const grow = format.change("ab", "aXb").?;
    try testing.expectEqual(@as(usize, 1), grow.start);
    try testing.expectEqual(@as(usize, 1), grow.end);
    try testing.expectEqualStrings("X", grow.text);
    // Repeated characters don't make the ends overlap.
    const rep = format.change("aaa", "aaaa").?;
    try testing.expectEqual(rep.start, rep.end);
    try testing.expectEqualStrings("a", rep.text);
}

test "formatters by language" {
    try testing.expectEqual(format.Formatter.prettier, format.formattersFor(.typescript)[0]);
    try testing.expectEqual(format.Formatter.ruff, format.formattersFor(.python)[1]);
    try testing.expectEqual(@as(usize, 0), format.formattersFor(.plain).len);
}

test "zig fmt, when zig is installed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const path = checkers.searchPath(alloc, testing.io, null);
    const r = try format.run(alloc, testing.io, .zig, "x.zig", "const  a=1;\n", path);
    switch (r) {
        .unavailable => return error.SkipZigTest,
        .formatted => |text| try testing.expectEqualStrings("const a = 1;\n", text),
        .failed => return error.TestUnexpectedResult,
    }
    const bad = try format.run(alloc, testing.io, .zig, "x.zig", "const a = ;\n", path);
    try testing.expect(bad == .failed);
    try testing.expect(bad.failed.message.len > 0);
}
