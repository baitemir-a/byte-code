//! Tests for clike.zig.
const std = @import("std");
const token = @import("../lib/token.zig");
const clike = @import("../lib/clike.zig");

const expect = token.expectTokens;

test "go" {
    _ = try expect(clike.Lexer.init("func (s *Server) Run(n int) error { return nil } // ok", .{}, .go), "func (s *Server) Run(n int) error { return nil } // ok", &.{
        "keyword:func",  "punctuation:(", "plain:s",       "punctuation:*", "type:Server",   "punctuation:)",  "function:Run", "punctuation:(",
        "plain:n",       "type:int",      "punctuation:)", "type:error",    "punctuation:{", "keyword:return", "constant:nil", "punctuation:}",
        "comment:// ok",
    });
    const lx = try expect(clike.Lexer.init("q := `select", .{}, .go), "q := `select", &.{ "plain:q", "punctuation::", "punctuation:=", "string:`select" });
    _ = try expect(clike.Lexer.init("*` + 'x'", lx.state, .go), "*` + 'x'", &.{ "string:*`", "punctuation:+", "string:'x'" });
}

test "rust" {
    _ = try expect(clike.Lexer.init("#[derive(Debug)] pub fn get<'a>(x: &'a str) -> Option<u32> {", .{}, .rust), "#[derive(Debug)] pub fn get<'a>(x: &'a str) -> Option<u32> {", &.{
        "attribute:#[derive(Debug)]", "keyword:pub",   "keyword:fn",    "function:get",  "punctuation:<", "constant:'a",   "punctuation:>",
        "punctuation:(",              "plain:x",       "punctuation::", "punctuation:&", "constant:'a",   "type:str",      "punctuation:)",
        "punctuation:-",              "punctuation:>", "type:Option",   "punctuation:<", "type:u32",      "punctuation:>", "punctuation:{",
    });
    _ = try expect(clike.Lexer.init("println!(\"{}\", 'c', b'x', 0..10, 1.5e-3);", .{}, .rust), "println!(\"{}\", 'c', b'x', 0..10, 1.5e-3);", &.{
        "function:println!", "punctuation:(", "string:\"{}\"", "punctuation:,", "string:'c'", "punctuation:,", "string:b'x'",
        "punctuation:,",     "number:0",      "punctuation:.", "punctuation:.", "number:10",  "punctuation:,", "number:1.5e-3",
        "punctuation:)",     "punctuation:;",
    });
    const raw = try expect(clike.Lexer.init("let s = r#\"a \"quoted\"", .{}, .rust), "let s = r#\"a \"quoted\"", &.{ "keyword:let", "plain:s", "punctuation:=", "string:r#\"a \"quoted\"" });
    try std.testing.expectEqual(@as(u8, 2), raw.state.raw);
    _ = try expect(clike.Lexer.init("end\"#; x", raw.state, .rust), "end\"#; x", &.{ "string:end\"#", "punctuation:;", "plain:x" });
    const c = try expect(clike.Lexer.init("/* a /* nested */ still", .{}, .rust), "/* a /* nested */ still", &.{"comment:/* a /* nested */ still"});
    try std.testing.expectEqual(@as(u8, 1), c.state.comment_depth);
}

test "zig" {
    _ = try expect(clike.Lexer.init("const std = @import(\"std\");", .{}, .zig), "const std = @import(\"std\");", &.{
        "keyword:const", "plain:std", "punctuation:=", "function:@import", "punctuation:(", "string:\"std\"", "punctuation:)", "punctuation:;",
    });
    _ = try expect(clike.Lexer.init("pub fn main(cp: u21) !void {", .{}, .zig), "pub fn main(cp: u21) !void {", &.{
        "keyword:pub",   "keyword:fn", "function:main", "punctuation:(", "plain:cp", "punctuation::", "type:u21", "punctuation:)",
        "punctuation:!", "type:void",  "punctuation:{",
    });
    _ = try expect(clike.Lexer.init("    \\\\multi-line \"text\"", .{}, .zig), "    \\\\multi-line \"text\"", &.{"string:\\\\multi-line \"text\""});
    _ = try expect(clike.Lexer.init("for (0..n) |i| x += 0x1p-3; // loop", .{}, .zig), "for (0..n) |i| x += 0x1p-3; // loop", &.{
        "keyword:for", "punctuation:(", "number:0", "punctuation:.", "punctuation:.", "plain:n",       "punctuation:)", "punctuation:|",
        "plain:i",     "punctuation:|", "plain:x",  "punctuation:+", "punctuation:=", "number:0x1p-3", "punctuation:;", "comment:// loop",
    });
}
