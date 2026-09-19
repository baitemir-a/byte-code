//! Tests for toml.zig.
const std = @import("std");
const token = @import("../lib/token.zig");
const toml = @import("../lib/toml.zig");

test "tables, keys, values" {
    const expect = token.expectTokens;
    _ = try expect(toml.Lexer.init("[[package]]", .{}), "[[package]]", &.{"tag:[[package]]"});
    _ = try expect(toml.Lexer.init("name = \"serde\" # lib", .{}), "name = \"serde\" # lib", &.{ "property:name", "punctuation:=", "string:\"serde\"", "comment:# lib" });
    _ = try expect(toml.Lexer.init("opt = { version = 1.2, default-features = false }", .{}), "opt = { version = 1.2, default-features = false }", &.{
        "property:opt",              "punctuation:=", "punctuation:{",  "property:version", "punctuation:=", "number:1.2", "punctuation:,",
        "property:default-features", "punctuation:=", "constant:false", "punctuation:}",
    });
    _ = try expect(toml.Lexer.init("; ini comment", .{}), "; ini comment", &.{"comment:; ini comment"});
}

test "multi-line arrays and strings" {
    const expect = token.expectTokens;
    const lx = try expect(toml.Lexer.init("deps = [", .{}), "deps = [", &.{ "property:deps", "punctuation:=", "punctuation:[" });
    const lx2 = try expect(toml.Lexer.init("  \"a\", 2024-01-02,", lx.state), "  \"a\", 2024-01-02,", &.{ "string:\"a\"", "punctuation:,", "number:2024-01-02", "punctuation:," });
    const lx3 = try expect(toml.Lexer.init("]", lx2.state), "]", &.{"punctuation:]"});
    try std.testing.expectEqual(@as(u8, 0), lx3.state.array_depth);
    const s = try expect(toml.Lexer.init("text = '''raw", .{}), "text = '''raw", &.{ "property:text", "punctuation:=", "string:'''raw" });
    try std.testing.expectEqual(@as(u8, '\''), s.state.triple);
}
