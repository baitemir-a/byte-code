//! Tests for python.zig.
const std = @import("std");
const token = @import("../lib/token.zig");
const python = @import("../lib/python.zig");

test "definitions, strings, decorators" {
    const expect = token.expectTokens;
    _ = try expect(python.Lexer.init("@app.route(\"/\")", .{}), "@app.route(\"/\")", &.{ "function:@app.route", "punctuation:(", "string:\"/\"", "punctuation:)" });
    _ = try expect(python.Lexer.init("def run(self, n: int = 0x1F) -> None:  # go", .{}), "def run(self, n: int = 0x1F) -> None:  # go", &.{
        "keyword:def",   "function:run", "punctuation:(", "constant:self", "punctuation:,", "plain:n",       "punctuation::", "type:int",
        "punctuation:=", "number:0x1F",  "punctuation:)", "punctuation:-", "punctuation:>", "constant:None", "punctuation::", "comment:# go",
    });
    _ = try expect(python.Lexer.init("class User(Base): x = f'{a}' + rb'\\d'", .{}), "class User(Base): x = f'{a}' + rb'\\d'", &.{
        "keyword:class", "type:User",     "punctuation:(",  "type:Base", "punctuation:)", "punctuation::", "plain:x", "punctuation:=",
        "string:f'{a}'", "punctuation:+", "string:rb'\\d'",
    });
}

test "triple-quoted strings span lines" {
    const expect = token.expectTokens;
    const lx = try expect(python.Lexer.init("doc = \"\"\"Hello", .{}), "doc = \"\"\"Hello", &.{ "plain:doc", "punctuation:=", "string:\"\"\"Hello" });
    try std.testing.expectEqual(@as(u8, '"'), lx.state.triple);
    const end = try expect(python.Lexer.init("world\"\"\" if x else y", lx.state), "world\"\"\" if x else y", &.{ "string:world\"\"\"", "keyword:if", "plain:x", "keyword:else", "plain:y" });
    try std.testing.expectEqual(@as(u8, 0), end.state.triple);
}
