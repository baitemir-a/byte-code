//! Tests for css.zig.
const std = @import("std");
const token = @import("../lib/token.zig");
const css = @import("../lib/css.zig");

test "rules and declarations" {
    const expect = token.expectTokens;
    _ = try expect(css.Lexer.init("a.btn:hover, #main > p {", .{}, .css), "a.btn:hover, #main > p {", &.{
        "tag:a", "function:.btn", "function::hover", "punctuation:,", "function:#main", "punctuation:>", "tag:p", "punctuation:{",
    });
    _ = try expect(css.Lexer.init("  margin: 0 auto -1.5em; color: #fff !important;", .{}, .css), "  margin: 0 auto -1.5em; color: #fff !important;", &.{
        "property:margin", "punctuation::", "number:0",    "constant:auto",      "number:-1.5em", "punctuation:;",
        "property:color",  "punctuation::", "number:#fff", "keyword:!important", "punctuation:;",
    });
    _ = try expect(css.Lexer.init("background: url(http://x.io/a.png) rgb(0, 0, 0);", .{}, .scss), "background: url(http://x.io/a.png) rgb(0, 0, 0);", &.{
        "property:background", "punctuation::", "function:url", "punctuation:(", "constant:http", "punctuation::",
        "punctuation:/",       "punctuation:/", "constant:x",   "punctuation:.", "constant:io",   "punctuation:/",
        "constant:a",          "punctuation:.", "constant:png", "punctuation:)", "function:rgb",  "punctuation:(",
        "number:0",            "punctuation:,", "number:0",     "punctuation:,", "number:0",      "punctuation:)",
        "punctuation:;",
    });
}

test "scss" {
    const expect = token.expectTokens;
    _ = try expect(css.Lexer.init("$gap: 4px; // spacing", .{}, .scss), "$gap: 4px; // spacing", &.{
        "constant:$gap", "punctuation::", "number:4px", "punctuation:;", "comment:// spacing",
    });
    _ = try expect(css.Lexer.init("  &:hover { @include shadow(2); }", .{}, .scss), "  &:hover { @include shadow(2); }", &.{
        "keyword:&", "function::hover", "punctuation:{", "keyword:@include", "function:shadow", "punctuation:(", "number:2", "punctuation:)", "punctuation:;", "punctuation:}",
    });
    const lx = try expect(css.Lexer.init("a { /* multi", .{}, .css), "a { /* multi", &.{ "tag:a", "punctuation:{", "comment:/* multi" });
    try std.testing.expect(lx.state.in_comment);
}
