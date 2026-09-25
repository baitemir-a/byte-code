//! Tests for generic.zig.
const std = @import("std");
const token = @import("../lib/token.zig");
const generic = @import("../lib/generic.zig");

const Lexer = generic.Lexer;

fn expect(line: []const u8, state: generic.State, dialect: generic.Dialect, expected: []const []const u8) !Lexer {
    return token.expectTokens(Lexer.init(line, state, dialect), line, expected);
}

test "c: preprocessor, types, macros, block comments" {
    _ = try expect("#include <stdio.h>", .{}, .c, &.{ "keyword:#include", "string:<stdio.h>" });
    _ = try expect("static int max(int a) { return MAX_N; } // x", .{}, .c, &.{
        "keyword:static", "type:int",      "function:max",   "punctuation:(",  "type:int",      "plain:a",
        "punctuation:)",  "punctuation:{", "keyword:return", "constant:MAX_N", "punctuation:;", "punctuation:}",
        "comment:// x",
    });
    const lx = try expect("x = 1; /* open", .{}, .c, &.{ "plain:x", "punctuation:=", "number:1", "punctuation:;", "comment:/* open" });
    _ = try expect("still */ y", lx.state, .c, &.{ "comment:still */", "plain:y" });
}

test "kotlin: declarations, annotations, triple-quoted strings" {
    _ = try expect("@Test fun run(x: Int) = listOf(1)", .{}, .kotlin, &.{
        "attribute:@Test", "keyword:fun",   "function:run",  "punctuation:(",   "plain:x",       "punctuation::",
        "type:Int",        "punctuation:)", "punctuation:=", "function:listOf", "punctuation:(", "number:1",
        "punctuation:)",
    });
    const lx = try expect("val s = \"\"\"a", .{}, .kotlin, &.{ "keyword:val", "plain:s", "punctuation:=", "string:\"\"\"a" });
    _ = try expect("b\"\"\" + 1", lx.state, .kotlin, &.{ "string:b\"\"\"", "punctuation:+", "number:1" });
}

test "shell: variables, comments, multi-line strings" {
    _ = try expect("echo \"$HOME\" ${#x} $1 # done", .{}, .shell, &.{
        "function:echo", "string:\"$HOME\"", "property:${#x}", "property:$1", "comment:# done",
    });
    _ = try expect("a#b", .{}, .shell, &.{ "plain:a", "punctuation:#", "plain:b" });
    const lx = try expect("msg='one", .{}, .shell, &.{ "plain:msg", "punctuation:=", "string:'one" });
    _ = try expect("two' fi", lx.state, .shell, &.{ "string:two'", "keyword:fi" });
}

test "ruby: symbols, instance variables, def" {
    _ = try expect("def empty?(x) = @items[:all].nil?", .{}, .ruby, &.{
        "keyword:def",     "function:empty?", "punctuation:(", "plain:x",       "punctuation:)", "punctuation:=",
        "property:@items", "punctuation:[",   "constant::all", "punctuation:]", "punctuation:.", "plain:nil?",
    });
}

test "lua: long comments and strings" {
    const lx = try expect("local s = [==[ a ]] b", .{}, .lua, &.{ "keyword:local", "plain:s", "punctuation:=", "string:[==[ a ]] b" });
    _ = try expect("]==] --[[ c ]] x", lx.state, .lua, &.{ "string:]==]", "comment:--[[ c ]]", "plain:x" });
    _ = try expect("-- note", .{}, .lua, &.{"comment:-- note"});
}

test "sql: case-insensitive keywords" {
    _ = try expect("SELECT count(*) FROM users WHERE name = 'o''k'", .{}, .sql, &.{
        "keyword:SELECT", "function:count", "punctuation:(", "punctuation:*", "punctuation:)", "keyword:FROM",
        "plain:users",    "keyword:WHERE",  "plain:name",    "punctuation:=", "string:'o'",    "string:'k'",
    });
}

test "haskell: nested comments, primes" {
    const lx = try expect("f' x = x {- a {- b -}", .{}, .haskell, &.{ "plain:f'", "plain:x", "punctuation:=", "plain:x", "comment:{- a {- b -}" });
    _ = try expect("-} Just", lx.state, .haskell, &.{ "comment:-}", "constant:Just" });
}

test "lisp: calls after parens" {
    _ = try expect("(defun add-one (n) (+ n 1)) ; inc", .{}, .lisp, &.{
        "punctuation:(", "keyword:defun", "function:add-one", "punctuation:(", "plain:n",       "punctuation:)",
        "punctuation:(", "punctuation:+", "plain:n",          "number:1",      "punctuation:)", "punctuation:)",
        "comment:; inc",
    });
}

test "makefile: targets and variables" {
    _ = try expect("build: $(SRC) # all", .{}, .makefile, &.{ "function:build", "punctuation::", "property:$(SRC)", "comment:# all" });
}

test "dockerfile: instructions at the start of lines only" {
    _ = try expect("FROM alpine AS base", .{}, .dockerfile, &.{ "keyword:FROM", "plain:alpine", "plain:AS", "plain:base" });
    _ = try expect("  run echo from", .{}, .dockerfile, &.{ "keyword:run", "plain:echo", "plain:from" });
}

test "batch: rem comments" {
    _ = try expect("REM hello", .{}, .batch, &.{"comment:REM hello"});
    _ = try expect("echo remark", .{}, .batch, &.{ "keyword:echo", "plain:remark" });
}

test "powershell: commands" {
    _ = try expect("Get-Item $path -Force", .{}, .powershell, &.{ "function:Get-Item", "property:$path", "punctuation:-", "plain:Force" });
}

test "every dialect tiles any line, and never gets stuck" {
    const pieces = [_][]const u8{
        "",    "\"",  "'",     "\\",  "$",  "${", "$(",  "@",         ":",    "#",        "[[",          "[=",
        "[==", "--[", "--[==", "(*",  "{-", "/*", "*/",  "\"\"\"",    "'''",  "#include", "# include <", "<?",
        "?>",  "0x",  "1e",    "1e+", "1.", "a'", "rem", "REM",       "::",   "<#",       "#[",          "#=",
        "#|",  "###", "%",     "!",   ";",  "'a", ",",   "x = \"a\\", "1..2", "0'1",      "`",           "\\x",
        "\t",
    };
    var buf: [64]u8 = undefined;
    for (std.enums.values(generic.Dialect)) |d| {
        for (pieces) |a| for (pieces) |b| for ([_][]const u8{ "", " " }) |sep| {
            const text = try std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ a, sep, b });
            // Twice, the second line starting in the state the first ended in.
            var state: generic.State = .{};
            for (0..2) |_| {
                var lx = Lexer.init(text, state, d);
                var end: usize = 0;
                while (lx.next()) |t| {
                    try std.testing.expectEqual(end, t.start);
                    try std.testing.expect(t.end > t.start);
                    end = t.end;
                }
                try std.testing.expectEqual(text.len, end);
                state = lx.state;
            }
        };
    }
}
