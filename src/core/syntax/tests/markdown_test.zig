//! Tests for markdown.zig.
const std = @import("std");
const token = @import("../lib/token.zig");
const markdown = @import("../lib/markdown.zig");

test "blocks and inline" {
    const expect = token.expectTokens;
    _ = try expect(markdown.Lexer.init("## Title", .{}), "## Title", &.{"heading:## Title"});
    _ = try expect(markdown.Lexer.init("- a **b** `c` [d](http://e) snake_case", .{}), "- a **b** `c` [d](http://e) snake_case", &.{
        "keyword:-", "plain: a ", "emphasis:**b**", "code:`c`", "link:[d]", "string:(http://e)", "plain: snake_case",
    });
    _ = try expect(markdown.Lexer.init("> 1. *quote*", .{}), "> 1. *quote*", &.{ "comment:>", "plain: 1. ", "emphasis:*quote*" });
    _ = try expect(markdown.Lexer.init("---", .{}), "---", &.{"punctuation:---"});
}

test "fenced code is highlighted in its language" {
    const expect = token.expectTokens;
    const open = try expect(markdown.Lexer.init("```ts", .{}), "```ts", &.{ "punctuation:```", "keyword:ts" });
    try std.testing.expectEqual(markdown.Fence.js, open.state.fence);
    const body = try expect(markdown.Lexer.init("const x = 1;", open.state), "const x = 1;", &.{ "keyword:const", "plain:x", "punctuation:=", "number:1", "punctuation:;" });
    const close = try expect(markdown.Lexer.init("```", body.state), "```", &.{"punctuation:```"});
    try std.testing.expectEqual(markdown.Fence.none, close.state.fence);

    const other = try expect(markdown.Lexer.init("~~~text", .{}), "~~~text", &.{ "punctuation:~~~", "keyword:text" });
    _ = try expect(markdown.Lexer.init("# not a heading", other.state), "# not a heading", &.{"code:# not a heading"});
}
