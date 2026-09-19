//! Tests for html.zig.
const std = @import("std");
const token = @import("../lib/token.zig");
const html = @import("../lib/html.zig");

test "tags, attributes, entities, comments" {
    const expect = token.expectTokens;
    _ = try expect(html.Lexer.init("<a href=\"/x\" hidden>Hi &amp; bye</a><!-- note -->", .{}, false), "<a href=\"/x\" hidden>Hi &amp; bye</a><!-- note -->", &.{
        "punctuation:<", "tag:a",          "attribute:href", "punctuation:=",  "string:\"/x\"", "attribute:hidden", "punctuation:>",
        "plain:Hi ",     "constant:&amp;", "plain: bye",     "punctuation:</", "tag:a",         "punctuation:>",    "comment:<!-- note -->",
    });
    _ = try expect(html.Lexer.init("<!DOCTYPE html>", .{}, false), "<!DOCTYPE html>", &.{ "punctuation:<!", "keyword:DOCTYPE", "attribute:html", "punctuation:>" });
}

test "script and style content" {
    const expect = token.expectTokens;
    const lx = try expect(html.Lexer.init("<script>let x = 1;", .{}, false), "<script>let x = 1;", &.{
        "punctuation:<", "tag:script", "punctuation:>", "keyword:let", "plain:x", "punctuation:=", "number:1", "punctuation:;",
    });
    try std.testing.expectEqual(html.Mode.script, lx.state.mode);
    _ = try expect(html.Lexer.init("f(x)</script>", lx.state, false), "f(x)</script>", &.{
        "function:f", "punctuation:(", "plain:x", "punctuation:)", "punctuation:</", "tag:script", "punctuation:>",
    });
    _ = try expect(html.Lexer.init("<style>p { color: red }</style>", .{}, false), "<style>p { color: red }</style>", &.{
        "punctuation:<",  "tag:style", "punctuation:>", "tag:p", "punctuation:{", "property:color", "punctuation::", "constant:red", "punctuation:}",
        "punctuation:</", "tag:style", "punctuation:>",
    });
}

test "multi-line tags and xml" {
    const expect = token.expectTokens;
    const lx = try expect(html.Lexer.init("<div class=\"a", .{}, false), "<div class=\"a", &.{ "punctuation:<", "tag:div", "attribute:class", "punctuation:=", "string:\"a" });
    _ = try expect(html.Lexer.init("b\" id=x>", lx.state, false), "b\" id=x>", &.{ "string:b\"", "attribute:id", "punctuation:=", "attribute:x", "punctuation:>" });
    _ = try expect(html.Lexer.init("<?xml version=\"1.0\"?><script/>", .{}, true), "<?xml version=\"1.0\"?><script/>", &.{
        "punctuation:<?", "keyword:xml", "attribute:version", "punctuation:=", "string:\"1.0\"", "punctuation:?>",
        "punctuation:<",  "tag:script",  "punctuation:/>",
    });
}
