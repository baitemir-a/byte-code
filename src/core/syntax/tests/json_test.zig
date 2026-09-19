//! Tests for json.zig.
const std = @import("std");
const token = @import("../lib/token.zig");
const json = @import("../lib/json.zig");

test "keys, values and comments" {
    const expect = token.expectTokens;
    _ = try expect(json.Lexer.init("  \"name\": \"rl\", \"n\": -1.5e3, \"ok\": true, // note", .{}), "  \"name\": \"rl\", \"n\": -1.5e3, \"ok\": true, // note", &.{
        "property:\"name\"", "punctuation::", "string:\"rl\"", "punctuation:,",
        "property:\"n\"",    "punctuation::", "number:-1.5e3", "punctuation:,",
        "property:\"ok\"",   "punctuation::", "constant:true", "punctuation:,",
        "comment:// note",
    });
    const lx = try expect(json.Lexer.init("[1, /* a", .{}), "[1, /* a", &.{ "punctuation:[", "number:1", "punctuation:,", "comment:/* a" });
    try std.testing.expect(lx.state.in_comment);
}
