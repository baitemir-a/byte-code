//! Tests for scope.zig.
const std = @import("std");
const Range = @import("../../buffer/Buffer.zig").Range;
const scope = @import("../lib/scope.zig");

fn expectSteps(src: []const u8, cursor: usize, steps: []const []const u8) !void {
    var sel: Range = .{ .start = cursor, .end = cursor };
    for (steps) |want| {
        sel = (try scope.expand(std.testing.allocator, src, sel)).?;
        try std.testing.expectEqualStrings(want, src[sel.start..sel.end]);
    }
}

test "grows from a word out through strings and brackets" {
    const src = "fn main() {\n    call(a, \"hi there\");\n}\n";
    try expectSteps(src, std.mem.indexOf(u8, src, "there").? + 1, &.{
        "there",
        "hi there",
        "\"hi there\"",
        "a, \"hi there\"",
        "(a, \"hi there\")",
        "call(a, \"hi there\");", // the line (and the block's trimmed inside)
        "\n    call(a, \"hi there\");\n",
        "{\n    call(a, \"hi there\");\n}",
        src,
    });
    try std.testing.expectEqual(@as(?Range, null), try scope.expand(std.testing.allocator, src, .{ .start = 0, .end = src.len }));
}

test "brackets in strings and comments, and apostrophes, don't count" {
    const src = "f(\"(\", x) // )\nit's (y)";
    try expectSteps(src, std.mem.indexOf(u8, src, "x").?, &.{ "x", "\"(\", x", "(\"(\", x)" });
    try expectSteps(src, std.mem.indexOf(u8, src, "y").?, &.{ "y", "(y)", "it's (y)" });
}
