//! Tests for js.zig.
const std = @import("std");
const js = @import("../lib/js.zig");

const testing = std.testing;

/// Renders the non-whitespace tokens of a line as "kind:text" for comparison.
fn expectTokens(line: []const u8, state: js.State, expected: []const []const u8) !js.State {
    var lx = js.Lexer.init(line, state);
    var got: std.ArrayList([]const u8) = .empty;
    defer {
        for (got.items) |s| testing.allocator.free(s);
        got.deinit(testing.allocator);
    }
    while (lx.next()) |t| {
        const s = line[t.start..t.end];
        if (std.mem.trim(u8, s, " \t").len == 0) continue;
        try got.append(testing.allocator, try std.fmt.allocPrint(testing.allocator, "{t}:{s}", .{ t.kind, s }));
    }
    try testing.expectEqual(expected.len, got.items.len);
    for (expected, got.items) |e, g| try testing.expectEqualStrings(e, g);
    return lx.state;
}

test "declarations and calls" {
    _ = try expectTokens("const x: number = parseInt(\"4\", 10);", .{}, &.{
        "keyword:const",     "plain:x",       "punctuation::", "type:number",   "punctuation:=",
        "function:parseInt", "punctuation:(", "string:\"4\"",  "punctuation:,", "number:10",
        "punctuation:)",     "punctuation:;",
    });
}

test "members are not keywords" {
    _ = try expectTokens("node.type = Foo.new(this)", .{}, &.{
        "plain:node",    "punctuation:.", "plain:type",    "punctuation:=", "type:Foo",
        "punctuation:.", "function:new",  "punctuation:(", "constant:this", "punctuation:)",
    });
}

test "regex vs division" {
    _ = try expectTokens("a = b / c / d", .{}, &.{
        "plain:a", "punctuation:=", "plain:b", "punctuation:/", "plain:c", "punctuation:/", "plain:d",
    });
    _ = try expectTokens("return /[/]x/g.test(s)", .{}, &.{
        "keyword:return", "regex:/[/]x/g", "punctuation:.", "function:test",
        "punctuation:(",  "plain:s",       "punctuation:)",
    });
}

test "block comment spans lines" {
    const s1 = try expectTokens("x /* start", .{}, &.{ "plain:x", "comment:/* start" });
    try testing.expectEqual(js.State.Mode.block_comment, s1.mode);
    const s2 = try expectTokens("end */ y // tail", s1, &.{ "comment:end */", "plain:y", "comment:// tail" });
    try testing.expectEqual(js.State.Mode.code, s2.mode);
}

test "template strings with nested code" {
    const s1 = try expectTokens("`a ${f({ k: `b` })} c", .{}, &.{
        "string:`a ",    "punctuation:${", "function:f", "punctuation:(", "punctuation:{",
        "plain:k",       "punctuation::",  "string:`b`", "punctuation:}", "punctuation:)",
        "punctuation:}", "string: c",
    });
    try testing.expectEqual(js.State.Mode.template, s1.mode);
    const s2 = try expectTokens("d` + 1", s1, &.{ "string:d`", "punctuation:+", "number:1" });
    try testing.expectEqual(js.State.Mode.code, s2.mode);
}

test "numbers" {
    _ = try expectTokens("1e-5 + 0xff - .5 + 10n", .{}, &.{
        "number:1e-5",   "punctuation:+", "number:0xff", "punctuation:-", "number:.5",
        "punctuation:+", "number:10n",
    });
}
