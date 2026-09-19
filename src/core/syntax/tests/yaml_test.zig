//! Tests for yaml.zig.
const std = @import("std");
const token = @import("../lib/token.zig");
const yaml = @import("../lib/yaml.zig");

test "mappings, lists, scalars" {
    const expect = token.expectTokens;
    _ = try expect(yaml.Lexer.init("name: web # svc", .{}, false), "name: web # svc", &.{ "property:name", "punctuation::", "string:web", "comment:# svc" });
    _ = try expect(yaml.Lexer.init("  - port: 8080", .{}, false), "  - port: 8080", &.{ "punctuation:-", "property:port", "punctuation::", "number:8080" });
    _ = try expect(yaml.Lexer.init("- \"x\"", .{}, false), "- \"x\"", &.{ "punctuation:-", "string:\"x\"" });
    _ = try expect(yaml.Lexer.init("url: http://a.io", .{}, false), "url: http://a.io", &.{ "property:url", "punctuation::", "string:http://a.io" });
    _ = try expect(yaml.Lexer.init("tags: [a, true, 3]", .{}, false), "tags: [a, true, 3]", &.{
        "property:tags", "punctuation::", "punctuation:[", "string:a", "punctuation:,", "constant:true", "punctuation:,", "number:3", "punctuation:]",
    });
    _ = try expect(yaml.Lexer.init("base: &b !!map", .{}, false), "base: &b !!map", &.{ "property:base", "punctuation::", "constant:&b", "keyword:!!map" });
}

test "block scalars span lines" {
    const expect = token.expectTokens;
    const a = try expect(yaml.Lexer.init("run: |", .{}, false), "run: |", &.{ "property:run", "punctuation::", "punctuation:|" });
    const b = try expect(yaml.Lexer.init("  echo: hi", a.state, false), "  echo: hi", &.{"string:  echo: hi"});
    const c = try expect(yaml.Lexer.init("next: 1", b.state, false), "next: 1", &.{ "property:next", "punctuation::", "number:1" });
    try std.testing.expectEqual(@as(i32, -1), c.state.block_indent);
}

test "yarn.lock" {
    const expect = token.expectTokens;
    _ = try expect(yaml.Lexer.init("\"@babel/core@^7.0.0\", \"@babel/core@^7.1\":", .{}, true), "\"@babel/core@^7.0.0\", \"@babel/core@^7.1\":", &.{
        "property:\"@babel/core@^7.0.0\", \"@babel/core@^7.1\"", "punctuation::",
    });
    _ = try expect(yaml.Lexer.init("  version \"7.2.0\"", .{}, true), "  version \"7.2.0\"", &.{ "property:version", "string:\"7.2.0\"" });
    _ = try expect(yaml.Lexer.init("    \"@babel/types\" \"^7.0.0\"", .{}, true), "    \"@babel/types\" \"^7.0.0\"", &.{ "property:\"@babel/types\"", "string:\"^7.0.0\"" });
    _ = try expect(yaml.Lexer.init("  integrity sha512-abc==", .{}, true), "  integrity sha512-abc==", &.{ "property:integrity", "string:sha512-abc==" });
}
