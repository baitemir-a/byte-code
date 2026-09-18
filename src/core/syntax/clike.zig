//! Lexer for C-family languages — Go, Rust and Zig — one line at a time.
//! They share comments, strings, numbers and identifiers; each dialect adds
//! its own keywords and quirks:
//! - Go: `backtick` raw strings (can span lines), runes;
//! - Rust: nested /* */ comments, r#"raw"# strings (can span lines),
//!   'lifetimes' vs 'c'har literals, macro! calls, #[attributes];
//! - Zig: `\\` multi-line string lines, @builtins, u21-style integer types.
const std = @import("std");
const token = @import("token.zig");

const Kind = token.Kind;
const Span = token.Span;

pub const Dialect = enum { go, rust, zig };

pub const State = struct {
    /// Depth of open block comments (Rust nests them).
    comment_depth: u8 = 0,
    /// Inside a raw string that continues on the next line: for Go 1, for
    /// Rust the number of `#`s plus 1. 0 when not in one.
    raw: u8 = 0,
};

pub const Lexer = struct {
    line: []const u8,
    pos: usize = 0,
    state: State,
    dialect: Dialect,
    /// The next name is being declared: after `fn`/`func`, or after
    /// `struct`/`enum`/`trait`/`type`...
    declaring: enum { none, function, type } = .none,

    pub fn init(line: []const u8, state: State, dialect: Dialect) Lexer {
        return .{ .line = line, .state = state, .dialect = dialect };
    }

    pub fn next(self: *Lexer) ?Span {
        if (self.pos >= self.line.len) return null;
        const start = self.pos;
        const kind = if (self.state.comment_depth > 0)
            self.blockComment()
        else if (self.state.raw > 0)
            self.rawRest()
        else
            self.code();
        return .{ .start = start, .end = self.pos, .kind = kind };
    }

    fn peek(self: *const Lexer, offset: usize) ?u8 {
        const i = self.pos + offset;
        return if (i < self.line.len) self.line[i] else null;
    }

    fn code(self: *Lexer) Kind {
        const l = self.line;
        const c = l[self.pos];
        if (c == ' ' or c == '\t' or c == '\r') {
            while (self.peek(0)) |w| : (self.pos += 1) if (w != ' ' and w != '\t' and w != '\r') break;
            return .plain;
        }
        if (c == '/' and self.peek(1) == '/') {
            self.pos = l.len;
            return .comment;
        }
        if (c == '/' and self.peek(1) == '*' and self.dialect != .zig) {
            self.pos += 2;
            self.state.comment_depth = 1;
            return self.blockComment();
        }
        switch (self.dialect) {
            .zig => switch (c) {
                // \\ multi-line string: the rest of the line.
                '\\' => if (self.peek(1) == '\\') {
                    self.pos = l.len;
                    return .string;
                },
                '@' => if (self.peek(1)) |n| if (std.ascii.isAlphabetic(n)) {
                    self.pos += 1;
                    self.word();
                    return .function; // @import, @intCast
                } else if (n == '"') {
                    self.pos += 1;
                    return self.string('"'); // @"quoted identifier"
                },
                else => {},
            },
            .go => if (c == '`') {
                self.pos += 1;
                self.state.raw = 1;
                return self.rawRest();
            },
            .rust => {
                if (c == '#' and (self.peek(1) == '[' or (self.peek(1) == '!' and self.peek(2) == '['))) return self.attribute();
                if (self.rustRawString()) |k| return k;
            },
        }
        switch (c) {
            '"' => return self.string('"'),
            '\'' => return self.quote(),
            '0'...'9' => return self.number(),
            else => {},
        }
        if (isIdentStart(c)) return self.identifier();
        // `func (r *T) Name(`: the receiver's `(` means no name follows `func`.
        self.declaring = .none;
        self.pos += 1;
        return .punctuation;
    }

    fn word(self: *Lexer) void {
        while (self.peek(0)) |w| : (self.pos += 1) if (!isIdentChar(w)) break;
    }

    fn identifier(self: *Lexer) Kind {
        const start = self.pos;
        self.word();
        const w = self.line[start..self.pos];
        const words = wordsFor(self.dialect);

        const declaring = self.declaring;
        self.declaring = .none;
        switch (declaring) {
            .function => return .function,
            .type => return .type,
            .none => {},
        }
        if (words.constants.has(w)) return .constant;
        if (words.keywords.has(w)) {
            if (words.declares_function.has(w)) self.declaring = .function;
            if (words.declares_type.has(w)) self.declaring = .type;
            return .keyword;
        }
        if (words.types.has(w) or (self.dialect != .go and isSizedInt(w))) return .type;
        // Rust macros: name!(...), name![...], name!{...}
        if (self.dialect == .rust and self.peek(0) == '!' and self.peek(1) != '=') {
            self.pos += 1;
            return .function;
        }
        const rest = std.mem.trimStart(u8, self.line[self.pos..], " \t");
        if (rest.len > 0 and rest[0] == '(') return .function;
        if (std.ascii.isUpper(w[0])) return .type;
        return .plain;
    }

    fn string(self: *Lexer, q: u8) Kind {
        const l = self.line;
        self.pos += 1;
        while (self.pos < l.len) {
            const s = l[self.pos];
            self.pos = if (s == '\\') @min(l.len, self.pos + 2) else self.pos + 1;
            if (s == q) break;
        }
        return .string;
    }

    /// `'x'`, `'\n'`, `'\u{1F600}'` — or, in Rust, a lifetime like `'a`.
    fn quote(self: *Lexer) Kind {
        const l = self.line;
        const after = self.pos + 1;
        if (after < l.len and l[after] != '\\') {
            // One (possibly multi-byte) character, then the closing quote?
            const len = std.unicode.utf8ByteSequenceLength(l[after]) catch 1;
            const closes = after + len < l.len and l[after + len] == '\'';
            if (!closes and self.dialect == .rust and isIdentStart(l[after])) {
                self.pos = after;
                self.word();
                return .constant; // lifetime
            }
        }
        return self.string('\'');
    }

    fn number(self: *Lexer) Kind {
        const l = self.line;
        const start = self.pos;
        const hex = l.len > start + 1 and l[start] == '0' and (l[start + 1] | 0x20) == 'x';
        self.pos += 1;
        while (self.peek(0)) |d| {
            const prev = l[self.pos - 1] | 0x20;
            const exponent_sign = (d == '+' or d == '-') and ((!hex and prev == 'e') or (hex and prev == 'p'));
            // `0..10` is a range, not a number with a dot.
            const decimal_point = d == '.' and self.peek(1) != '.' and !(self.peek(1) != null and isIdentStart(self.peek(1).?) and !hex);
            if (!(std.ascii.isAlphanumeric(d) or d == '_' or decimal_point or exponent_sign)) break;
            self.pos += 1;
        }
        return .number;
    }

    /// Rust `#[derive(Debug)]` / `#![allow(dead_code)]`, to the matching `]`.
    fn attribute(self: *Lexer) Kind {
        const l = self.line;
        var depth: usize = 0;
        while (self.pos < l.len) : (self.pos += 1) {
            switch (l[self.pos]) {
                '[' => depth += 1,
                ']' => {
                    depth -= 1;
                    if (depth == 0) {
                        self.pos += 1;
                        break;
                    }
                },
                else => {},
            }
        }
        return .attribute;
    }

    /// Rust byte strings and raw strings: b"..", r"..", r#"..."#, br#"..."#.
    fn rustRawString(self: *Lexer) ?Kind {
        const l = self.line;
        var i = self.pos;
        if (i < l.len and l[i] == 'b') i += 1;
        const raw = i < l.len and l[i] == 'r';
        if (raw) i += 1;
        if (!raw and i == self.pos) return null;
        var hashes: usize = 0;
        while (raw and i < l.len and l[i] == '#') : (i += 1) hashes += 1;
        if (i >= l.len) return null;
        if (!raw) {
            // b"bytes" and b'b'
            if (l[i] == '"' or l[i] == '\'') {
                self.pos = i;
                return self.string(l[i]);
            }
            return null;
        }
        if (l[i] != '"') return null;
        self.pos = i + 1;
        self.state.raw = @intCast(@min(hashes + 1, 255));
        return self.rawRest();
    }

    /// The rest of a raw string on this line: Go's until a backtick, Rust's
    /// until `"` followed by its number of `#`s.
    fn rawRest(self: *Lexer) Kind {
        const l = self.line;
        if (self.dialect == .go) {
            if (std.mem.indexOfScalarPos(u8, l, self.pos, '`')) |end| {
                self.pos = end + 1;
                self.state.raw = 0;
            } else self.pos = l.len;
            return .string;
        }
        const hashes = self.state.raw - 1;
        while (std.mem.indexOfScalarPos(u8, l, self.pos, '"')) |q| {
            self.pos = q + 1;
            if (l.len - self.pos >= hashes and std.mem.allEqual(u8, l[self.pos..][0..hashes], '#')) {
                self.pos += hashes;
                self.state.raw = 0;
                return .string;
            }
        }
        self.pos = l.len;
        return .string;
    }

    fn blockComment(self: *Lexer) Kind {
        const l = self.line;
        while (self.pos < l.len) {
            if (std.mem.startsWith(u8, l[self.pos..], "*/")) {
                self.pos += 2;
                self.state.comment_depth -= 1;
                if (self.state.comment_depth == 0) return .comment;
            } else if (self.dialect == .rust and std.mem.startsWith(u8, l[self.pos..], "/*")) {
                self.pos += 2;
                self.state.comment_depth +|= 1;
            } else self.pos += 1;
        }
        return .comment;
    }
};

pub fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

pub fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

/// Rust and Zig integer types: i8, u64, and in Zig any width like u21.
fn isSizedInt(w: []const u8) bool {
    if (w.len < 2 or (w[0] != 'i' and w[0] != 'u')) return false;
    for (w[1..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

// -------------------------------------------------------------- word lists

fn wordSet(comptime words: []const []const u8) std.StaticStringMap(void) {
    @setEvalBranchQuota(20_000); // sorting the lists at compile time
    comptime var kvs: [words.len]struct { []const u8 } = undefined;
    inline for (words, 0..) |w, i| kvs[i] = .{w};
    return .initComptime(kvs);
}

pub const WordLists = struct {
    keyword_list: []const []const u8,
    constant_list: []const []const u8,
    type_list: []const []const u8,
    keywords: std.StaticStringMap(void),
    constants: std.StaticStringMap(void),
    types: std.StaticStringMap(void),
    /// Keywords after which the next name is a function / type being declared.
    declares_function: std.StaticStringMap(void),
    declares_type: std.StaticStringMap(void),
};

fn lists(
    comptime keywords: []const []const u8,
    comptime constants: []const []const u8,
    comptime types: []const []const u8,
    comptime declares_function: []const []const u8,
    comptime declares_type: []const []const u8,
) WordLists {
    return .{
        .keyword_list = keywords,
        .constant_list = constants,
        .type_list = types,
        .keywords = wordSet(keywords),
        .constants = wordSet(constants),
        .types = wordSet(types),
        .declares_function = wordSet(declares_function),
        .declares_type = wordSet(declares_type),
    };
}

const go_words = lists(&.{
    "break",     "case",   "chan",   "const",  "continue", "default", "defer",  "else",
    "fallthrough", "for",  "func",   "go",     "goto",     "if",      "import", "interface",
    "map",       "package", "range", "return", "select",   "struct",  "switch", "type",
    "var",
}, &.{ "true", "false", "nil", "iota" }, &.{
    "bool",    "byte",    "complex64", "complex128", "error",  "float32", "float64", "int",
    "int8",    "int16",   "int32",     "int64",      "rune",   "string",  "uint",    "uint8",
    "uint16",  "uint32",  "uint64",    "uintptr",    "any",    "comparable",
}, &.{"func"}, &.{"type"});

const rust_words = lists(&.{
    "as",     "async", "await",  "break",  "const", "continue", "crate", "dyn",
    "else",   "enum",  "extern", "fn",     "for",   "if",       "impl",  "in",
    "let",    "loop",  "match",  "mod",    "move",  "mut",      "pub",   "ref",
    "return", "static", "struct", "super", "trait", "type",     "unsafe", "use",
    "where",  "while", "yield",  "union",  "macro_rules",
}, &.{ "true", "false", "self" }, &.{
    "isize", "usize", "f32",  "f64",    "bool",   "char", "str",  "String",
    "Vec",   "Option", "Result", "Box", "Self",
}, &.{"fn"}, &.{ "struct", "enum", "trait", "type", "union" });

const zig_words = lists(&.{
    "addrspace",   "align",    "allowzero", "and",        "anyframe", "anytype",    "asm",
    "break",       "callconv", "catch",     "comptime",   "const",    "continue",   "defer",
    "else",        "enum",     "errdefer",  "error",      "export",   "extern",     "fn",
    "for",         "if",       "inline",    "noalias",    "noinline", "nosuspend",  "opaque",
    "or",          "orelse",   "packed",    "pub",        "resume",   "return",     "linksection",
    "struct",      "suspend",  "switch",    "test",       "threadlocal", "try",     "union",
    "unreachable", "var",      "volatile",  "while",
}, &.{ "true", "false", "null", "undefined" }, &.{
    "isize",         "usize",          "f16",       "f32",      "f64",       "f80",       "f128",
    "bool",          "void",           "noreturn",  "type",     "anyerror",  "anyopaque", "comptime_int",
    "comptime_float", "c_int",         "c_uint",    "c_long",   "c_ulong",   "c_char",    "c_short",
    "c_ushort",      "c_longlong",     "c_ulonglong", "c_longdouble",
}, &.{"fn"}, &.{});

pub fn wordsFor(dialect: Dialect) *const WordLists {
    return switch (dialect) {
        .go => &go_words,
        .rust => &rust_words,
        .zig => &zig_words,
    };
}

// ------------------------------------------------------------------ tests

const expect = token.expectTokens;

test "go" {
    _ = try expect(Lexer.init("func (s *Server) Run(n int) error { return nil } // ok", .{}, .go), "func (s *Server) Run(n int) error { return nil } // ok", &.{
        "keyword:func", "punctuation:(", "plain:s", "punctuation:*", "type:Server", "punctuation:)", "function:Run", "punctuation:(",
        "plain:n",      "type:int",      "punctuation:)", "type:error", "punctuation:{", "keyword:return", "constant:nil", "punctuation:}",
        "comment:// ok",
    });
    const lx = try expect(Lexer.init("q := `select", .{}, .go), "q := `select", &.{ "plain:q", "punctuation::", "punctuation:=", "string:`select" });
    _ = try expect(Lexer.init("*` + 'x'", lx.state, .go), "*` + 'x'", &.{ "string:*`", "punctuation:+", "string:'x'" });
}

test "rust" {
    _ = try expect(Lexer.init("#[derive(Debug)] pub fn get<'a>(x: &'a str) -> Option<u32> {", .{}, .rust), "#[derive(Debug)] pub fn get<'a>(x: &'a str) -> Option<u32> {", &.{
        "attribute:#[derive(Debug)]", "keyword:pub", "keyword:fn", "function:get", "punctuation:<", "constant:'a", "punctuation:>",
        "punctuation:(",              "plain:x",     "punctuation::", "punctuation:&", "constant:'a", "type:str", "punctuation:)",
        "punctuation:-",              "punctuation:>", "type:Option", "punctuation:<", "type:u32", "punctuation:>", "punctuation:{",
    });
    _ = try expect(Lexer.init("println!(\"{}\", 'c', b'x', 0..10, 1.5e-3);", .{}, .rust), "println!(\"{}\", 'c', b'x', 0..10, 1.5e-3);", &.{
        "function:println!", "punctuation:(", "string:\"{}\"", "punctuation:,", "string:'c'", "punctuation:,", "string:b'x'",
        "punctuation:,",      "number:0",      "punctuation:.", "punctuation:.", "number:10", "punctuation:,", "number:1.5e-3",
        "punctuation:)",      "punctuation:;",
    });
    const raw = try expect(Lexer.init("let s = r#\"a \"quoted\"", .{}, .rust), "let s = r#\"a \"quoted\"", &.{ "keyword:let", "plain:s", "punctuation:=", "string:r#\"a \"quoted\"" });
    try std.testing.expectEqual(@as(u8, 2), raw.state.raw);
    _ = try expect(Lexer.init("end\"#; x", raw.state, .rust), "end\"#; x", &.{ "string:end\"#", "punctuation:;", "plain:x" });
    const c = try expect(Lexer.init("/* a /* nested */ still", .{}, .rust), "/* a /* nested */ still", &.{"comment:/* a /* nested */ still"});
    try std.testing.expectEqual(@as(u8, 1), c.state.comment_depth);
}

test "zig" {
    _ = try expect(Lexer.init("const std = @import(\"std\");", .{}, .zig), "const std = @import(\"std\");", &.{
        "keyword:const", "plain:std", "punctuation:=", "function:@import", "punctuation:(", "string:\"std\"", "punctuation:)", "punctuation:;",
    });
    _ = try expect(Lexer.init("pub fn main(cp: u21) !void {", .{}, .zig), "pub fn main(cp: u21) !void {", &.{
        "keyword:pub", "keyword:fn", "function:main", "punctuation:(", "plain:cp", "punctuation::", "type:u21", "punctuation:)",
        "punctuation:!", "type:void", "punctuation:{",
    });
    _ = try expect(Lexer.init("    \\\\multi-line \"text\"", .{}, .zig), "    \\\\multi-line \"text\"", &.{"string:\\\\multi-line \"text\""});
    _ = try expect(Lexer.init("for (0..n) |i| x += 0x1p-3; // loop", .{}, .zig), "for (0..n) |i| x += 0x1p-3; // loop", &.{
        "keyword:for", "punctuation:(", "number:0", "punctuation:.", "punctuation:.", "plain:n", "punctuation:)", "punctuation:|",
        "plain:i",     "punctuation:|", "plain:x",  "punctuation:+", "punctuation:=", "number:0x1p-3", "punctuation:;", "comment:// loop",
    });
}
