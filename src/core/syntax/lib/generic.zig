//! A lexer for most languages, one line at a time, driven by a description
//! of each (`Spec`): its comments, strings and word lists. Languages that
//! need more than that have their own lexers (js, python, clike, ...).
//!
//! Words are sorted into the usual kinds: keywords, constants, types (from
//! the lists, and capitalized names where the language uses them for
//! types), functions (a name before `(`, or after `fn`-like keywords), and
//! ALL_CAPS constants.
const std = @import("std");
const token = @import("token.zig");

const Kind = token.Kind;
const Span = token.Span;

pub const Dialect = enum {
    // C family
    c,
    cpp,
    objc,
    csharp,
    java,
    kotlin,
    scala,
    groovy,
    swift,
    dart,
    php,
    solidity,
    /// GLSL, HLSL, Metal.
    shader,
    wgsl,
    protobuf,
    graphql,
    verilog,
    // Scripting
    shell,
    fish,
    powershell,
    batch,
    ruby,
    perl,
    r,
    julia,
    elixir,
    erlang,
    nim,
    crystal,
    gdscript,
    lua,
    tcl,
    coffeescript,
    // Functional
    haskell,
    elm,
    ocaml,
    fsharp,
    lisp,
    clojure,
    // Others
    sql,
    makefile,
    dockerfile,
    cmake,
    hcl,
    nix,
    fortran,
    pascal,
    ada,
    vhdl,
    vb,
    assembly,
    tex,
};

/// How a language is written.
pub const Spec = struct {
    line_comments: []const []const u8 = &.{},
    /// Pairs of opening and closing delimiters.
    block_comments: []const [2][]const u8 = &.{},
    /// Block comments nest (Rust-style).
    nested_comments: bool = false,
    /// A `#` comment needs a space (or the line start) before it, as in
    /// shells, where `a#b` and `${#x}` aren't comments.
    hash_after_space: bool = false,
    /// Characters that open strings.
    quotes: []const u8 = "\"'",
    /// A backslash escapes the next character in strings.
    escapes: bool = true,
    /// `"""` (and `'''`, if `'` quotes) strings span lines.
    triple_quotes: bool = false,
    /// A string left open at the end of a line goes on to the next.
    multiline_strings: bool = false,
    /// Lua's `[[long strings]]` and `--[[long comments]]`.
    long_brackets: bool = false,
    /// Words match whatever their case; lists are written in lowercase.
    case_insensitive: bool = false,
    /// `$name` and `${...}` are variables; with `dollar_parens`, `$(name)`
    /// too (Make).
    dollar_vars: bool = false,
    dollar_parens: bool = false,
    /// What `@name` is: a decorator or annotation, an instance variable, or
    /// a keyword (Objective-C's @interface).
    at_names: enum { none, attribute, property, keyword } = .none,
    /// `:name` is a symbol (Ruby, Elixir) or keyword (Clojure).
    colon_symbols: bool = false,
    /// C preprocessor lines: `#include <x>`, `#define`.
    preprocessor: bool = false,
    /// `<?php` and `?>`.
    php_tags: bool = false,
    /// `\command` (TeX).
    backslash_commands: bool = false,
    /// Characters that may continue a name, besides letters, digits and `_`.
    ident_extra: []const u8 = "",
    /// `name:` at the start of a line is a label or target (Make, assembly).
    labels: bool = false,
    /// The first word on a line is a keyword (assembly mnemonics).
    first_word_keyword: bool = false,
    /// Keywords count only as the first word of a line (Dockerfile).
    keywords_at_line_start: bool = false,
    /// The name right after `(` is being called (Lisp).
    call_after_paren: bool = false,
    /// Capitalized names are types (or classes, modules, constructors).
    upper_is_type: bool = true,
    /// ALL_CAPS names are constants.
    caps_constants: bool = true,

    keywords: []const []const u8 = &.{},
    constants: []const []const u8 = &.{},
    types: []const []const u8 = &.{},
    /// Built-in commands and functions.
    builtins: []const []const u8 = &.{},
    /// Keywords after which the next name is a function / type being declared.
    declares_function: []const []const u8 = &.{},
    declares_type: []const []const u8 = &.{},
};

pub const State = struct {
    /// Open block comment: its index in the spec's list plus 1, or 0.
    comment: u8 = 0,
    depth: u8 = 0,
    /// Quote of a string that continues on the next line, or 0.
    quote: u8 = 0,
    triple: bool = false,
    /// Open Lua long bracket: its level (number of `=`) plus 1, or 0.
    long: u8 = 0,
    long_comment: bool = false,
};

pub const Lexer = struct {
    line: []const u8,
    pos: usize = 0,
    state: State,
    lang: *const Language,
    declaring: enum { none, function, type } = .none,
    /// Nothing but whitespace so far on this line.
    line_start: bool = true,
    /// The previous token was `(`.
    after_paren: bool = false,
    /// The previous token was a name being declared: a `(` after it opens
    /// parameters, not a call (Lisp's `(defun name (args)`).
    declared: bool = false,
    /// After `#include`: `<path>` is a string.
    include: bool = false,

    pub fn init(line: []const u8, state: State, dialect: Dialect) Lexer {
        return .{ .line = line, .state = state, .lang = language(dialect) };
    }

    pub fn next(self: *Lexer) ?Span {
        if (self.pos >= self.line.len) return null;
        const start = self.pos;
        const kind = if (self.state.comment > 0)
            self.blockComment()
        else if (self.state.long > 0)
            self.longRest()
        else if (self.state.quote != 0)
            self.stringRest()
        else
            self.code();
        return .{ .start = start, .end = self.pos, .kind = kind };
    }

    fn peek(self: *const Lexer, offset: usize) ?u8 {
        const i = self.pos + offset;
        return if (i < self.line.len) self.line[i] else null;
    }

    fn rest(self: *const Lexer) []const u8 {
        return self.line[self.pos..];
    }

    fn code(self: *Lexer) Kind {
        const spec = &self.lang.spec;
        const l = self.line;
        const c = l[self.pos];
        if (self.isSpace(c)) {
            while (self.peek(0)) |w| : (self.pos += 1) if (!self.isSpace(w)) break;
            return .plain;
        }
        const at_line_start = self.line_start;
        self.line_start = false;
        const after_paren = self.after_paren;
        self.after_paren = false;
        const declared = self.declared;
        self.declared = false;

        // Block comments before line comments: `#=` isn't `#`, `(*` isn't `(`.
        for (spec.block_comments, 0..) |b, i| if (std.mem.startsWith(u8, self.rest(), b[0])) {
            self.pos += b[0].len;
            self.state.comment = @intCast(i + 1);
            self.state.depth = 1;
            return self.blockComment();
        };
        if (spec.long_brackets) {
            if (std.mem.startsWith(u8, self.rest(), "--")) if (longLevel(l, self.pos + 2)) |level| {
                self.pos += 2 + level + 2;
                self.state.long = @intCast(@min(level + 1, 255));
                self.state.long_comment = true;
                return self.longRest();
            };
            if (c == '[') if (longLevel(l, self.pos)) |level| {
                self.pos += level + 2;
                self.state.long = @intCast(@min(level + 1, 255));
                self.state.long_comment = false;
                return self.longRest();
            };
        }
        for (spec.line_comments) |p| if (self.lineCommentHere(p, at_line_start)) {
            self.pos = l.len;
            return .comment;
        };
        if (spec.preprocessor and at_line_start and c == '#') return self.directive();
        if (spec.php_tags) for ([_][]const u8{ "<?php", "<?=", "?>" }) |tag| if (std.mem.startsWith(u8, self.rest(), tag)) {
            self.pos += tag.len;
            return .keyword;
        };
        if (self.include and c == '<') {
            self.pos = if (std.mem.indexOfScalarPos(u8, l, self.pos, '>')) |end| end + 1 else l.len;
            return .string;
        }
        if (std.mem.indexOfScalar(u8, spec.quotes, c) != null) {
            if (spec.triple_quotes and self.peek(1) == c and self.peek(2) == c) {
                self.pos += 3;
                self.state.quote = c;
                self.state.triple = true;
                return self.stringRest();
            }
            self.pos += 1;
            self.state.quote = c;
            self.state.triple = false;
            return self.stringRest();
        }
        if (c == '$' and spec.dollar_vars) return self.variable();
        if (c == '@' and spec.at_names != .none and self.peek(1) != null and isIdentStart(self.peek(1).?)) {
            self.pos += 1;
            self.word();
            return switch (spec.at_names) {
                .attribute => .attribute,
                .property => .property,
                else => .keyword,
            };
        }
        if (c == ':' and spec.colon_symbols and self.peek(1) != null and isIdentStart(self.peek(1).?) and
            (self.pos == 0 or l[self.pos - 1] != ':'))
        {
            self.pos += 1;
            self.word();
            return .constant;
        }
        if (c == '\\' and spec.backslash_commands and self.peek(1) != null) {
            self.pos += 1;
            if (std.ascii.isAlphabetic(l[self.pos])) {
                while (self.peek(0)) |w| : (self.pos += 1) if (!std.ascii.isAlphabetic(w)) break;
            } else self.pos += 1; // \\, \{, \%
            return .keyword;
        }
        if (std.ascii.isDigit(c)) return self.number();
        if (isIdentStart(c)) return self.identifier(at_line_start, after_paren);
        self.declaring = .none;
        self.after_paren = c == '(' and !declared;
        self.pos += 1;
        return .punctuation;
    }

    /// Clojure counts commas as whitespace.
    fn isSpace(self: *const Lexer, c: u8) bool {
        return c == ' ' or c == '\t' or c == '\r' or (c == ',' and self.lang.dialect == .clojure);
    }

    fn lineCommentHere(self: *const Lexer, prefix: []const u8, at_line_start: bool) bool {
        const spec = &self.lang.spec;
        const r = self.rest();
        if (r.len < prefix.len) return false;
        const head = r[0..prefix.len];
        if (!(if (spec.case_insensitive) std.ascii.eqlIgnoreCase(head, prefix) else std.mem.eql(u8, head, prefix))) return false;
        // A word like `rem` (batch files): a whole first word.
        if (std.ascii.isAlphabetic(prefix[0])) return at_line_start and (r.len == prefix.len or !isIdentChar(r[prefix.len]));
        if (prefix[0] == '#' and spec.hash_after_space and self.pos > 0) {
            return std.mem.indexOfScalar(u8, " \t;|&(", self.line[self.pos - 1]) != null;
        }
        return true;
    }

    fn word(self: *Lexer) void {
        const extra = self.lang.spec.ident_extra;
        while (self.peek(0)) |w| : (self.pos += 1) {
            if (!isIdentChar(w) and std.mem.indexOfScalar(u8, extra, w) == null) break;
        }
    }

    fn identifier(self: *Lexer, at_line_start: bool, after_paren: bool) Kind {
        const lang = self.lang;
        const spec = &lang.spec;
        const start = self.pos;
        self.word();
        const w = self.line[start..self.pos];
        var buf: [64]u8 = undefined;
        const key = if (spec.case_insensitive and w.len <= buf.len) std.ascii.lowerString(buf[0..w.len], w) else w;

        const declaring = self.declaring;
        self.declaring = .none;
        if (declaring != .none) self.declared = true;
        switch (declaring) {
            .function => return .function,
            .type => return .type,
            .none => {},
        }
        if (spec.labels and at_line_start and self.peek(0) == ':' and self.peek(1) != '=' and self.peek(1) != ':') return .function;
        if (spec.first_word_keyword and at_line_start) return .keyword;
        if (lang.constants.has(key)) return .constant;
        if (lang.keywords.has(key) and (!spec.keywords_at_line_start or at_line_start)) {
            if (lang.declares_function.has(key)) self.declaring = .function;
            if (lang.declares_type.has(key)) self.declaring = .type;
            return .keyword;
        }
        if (lang.types.has(key)) return .type;
        if (lang.builtins.has(key)) return .function;
        if (spec.call_after_paren and after_paren) return .function;
        // PowerShell's Verb-Noun commands.
        if (lang.dialect == .powershell and std.mem.indexOfScalar(u8, w, '-') != null) return .function;
        const after = std.mem.trimStart(u8, self.rest(), " \t");
        if (after.len > 0 and after[0] == '(' and !spec.call_after_paren) return .function;
        if (spec.caps_constants and isAllCaps(w)) return .constant;
        if (spec.upper_is_type and std.ascii.isUpper(w[0])) return .type;
        return .plain;
    }

    /// `#include`, `# define`: the `#` and the directive's name.
    fn directive(self: *Lexer) Kind {
        self.pos += 1;
        while (self.peek(0)) |w| : (self.pos += 1) if (w != ' ' and w != '\t') break;
        const start = self.pos;
        while (self.peek(0)) |w| : (self.pos += 1) if (!std.ascii.isAlphabetic(w)) break;
        const name = self.line[start..self.pos];
        self.include = std.mem.eql(u8, name, "include") or std.mem.eql(u8, name, "import");
        return .keyword;
    }

    /// `$name`, `$1`, `$?`, `${...}`, and in Make `$(name)`.
    fn variable(self: *Lexer) Kind {
        const l = self.line;
        self.pos += 1;
        const n = self.peek(0) orelse return .punctuation;
        const close: ?u8 = if (n == '{') '}' else if (n == '(' and self.lang.spec.dollar_parens) ')' else null;
        if (close) |cl| {
            self.pos = if (std.mem.indexOfScalarPos(u8, l, self.pos, cl)) |end| end + 1 else l.len;
        } else if (isIdentChar(n)) {
            self.word();
        } else if (std.mem.indexOfScalar(u8, "?!#@*$-", n) != null) {
            self.pos += 1;
        } else return .punctuation;
        return .property;
    }

    /// The rest of the open string on this line.
    fn stringRest(self: *Lexer) Kind {
        const spec = &self.lang.spec;
        const l = self.line;
        const q = self.state.quote;
        while (self.pos < l.len) {
            const s = l[self.pos];
            if (s == '\\' and spec.escapes) {
                self.pos = @min(l.len, self.pos + 2);
                continue;
            }
            self.pos += 1;
            if (s != q) continue;
            if (!self.state.triple) {
                self.state.quote = 0;
                return .string;
            }
            if (self.peek(0) == q and self.peek(1) == q) {
                self.pos += 2;
                self.state.quote = 0;
                self.state.triple = false;
                return .string;
            }
        }
        if (!self.state.triple and !spec.multiline_strings) self.state.quote = 0;
        return .string;
    }

    fn blockComment(self: *Lexer) Kind {
        const spec = &self.lang.spec;
        const pair = spec.block_comments[self.state.comment - 1];
        while (self.pos < self.line.len) {
            if (std.mem.startsWith(u8, self.rest(), pair[1])) {
                self.pos += pair[1].len;
                self.state.depth -|= 1;
                if (self.state.depth == 0) {
                    self.state.comment = 0;
                    return .comment;
                }
            } else if (spec.nested_comments and std.mem.startsWith(u8, self.rest(), pair[0])) {
                self.pos += pair[0].len;
                self.state.depth +|= 1;
            } else self.pos += 1;
        }
        return .comment;
    }

    /// The rest of a Lua long string or comment: up to `]`, its `=`s, `]`.
    fn longRest(self: *Lexer) Kind {
        const l = self.line;
        const kind: Kind = if (self.state.long_comment) .comment else .string;
        const level = self.state.long - 1;
        while (std.mem.indexOfScalarPos(u8, l, self.pos, ']')) |at| {
            self.pos = at + 1;
            if (l.len - self.pos > level and std.mem.allEqual(u8, l[self.pos..][0..level], '=') and l[self.pos + level] == ']') {
                self.pos += level + 1;
                self.state.long = 0;
                return kind;
            }
        }
        self.pos = l.len;
        return kind;
    }

    fn number(self: *Lexer) Kind {
        const l = self.line;
        const start = self.pos;
        const hex = l.len > start + 1 and l[start] == '0' and (l[start + 1] | 0x20) == 'x';
        self.pos += 1;
        while (self.peek(0)) |d| {
            const prev = l[self.pos - 1] | 0x20;
            const exponent_sign = !hex and (d == '+' or d == '-') and prev == 'e';
            // `0..10` is a range; `1.foo` a call on a number.
            const decimal_point = d == '.' and self.peek(1) != null and std.ascii.isDigit(self.peek(1).?);
            if (!(std.ascii.isAlphanumeric(d) or d == '_' or (d == '\'' and self.lang.dialect == .cpp) or decimal_point or exponent_sign)) break;
            self.pos += 1;
        }
        return .number;
    }
};

/// At `at`, a Lua long bracket opening: `[`, any `=`s, `[`. Its level.
fn longLevel(l: []const u8, at: usize) ?usize {
    if (at >= l.len or l[at] != '[') return null;
    var i = at + 1;
    while (i < l.len and l[i] == '=') i += 1;
    return if (i < l.len and l[i] == '[') i - at - 1 else null;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

fn isAllCaps(w: []const u8) bool {
    if (w.len < 2) return false;
    var letters: usize = 0;
    for (w) |c| {
        if (std.ascii.isLower(c)) return false;
        if (std.ascii.isUpper(c)) letters += 1;
    }
    return letters >= 2;
}

// ---------------------------------------------------------------- languages

/// A spec with its word lists made into sets.
pub const Language = struct {
    dialect: Dialect,
    spec: Spec,
    keywords: std.StaticStringMap(void),
    constants: std.StaticStringMap(void),
    types: std.StaticStringMap(void),
    builtins: std.StaticStringMap(void),
    declares_function: std.StaticStringMap(void),
    declares_type: std.StaticStringMap(void),
};

fn wordSet(comptime words: []const []const u8) std.StaticStringMap(void) {
    comptime var kvs: [words.len]struct { []const u8 } = undefined;
    inline for (words, 0..) |w, i| kvs[i] = .{w};
    return .initComptime(kvs);
}

const languages = blk: {
    @setEvalBranchQuota(2_000_000);
    const fields = @typeInfo(Dialect).@"enum".fields;
    var list: [fields.len]Language = undefined;
    for (fields, 0..) |f, i| {
        const s = specOf(@enumFromInt(f.value));
        list[i] = .{
            .dialect = @enumFromInt(f.value),
            .spec = s,
            .keywords = wordSet(s.keywords),
            .constants = wordSet(s.constants),
            .types = wordSet(s.types),
            .builtins = wordSet(s.builtins),
            .declares_function = wordSet(s.declares_function),
            .declares_type = wordSet(s.declares_type),
        };
    }
    break :blk list;
};

pub fn language(dialect: Dialect) *const Language {
    return &languages[@intFromEnum(dialect)];
}

// Shared pieces.
const c_comments: Spec = .{ .line_comments = &.{"//"}, .block_comments = &.{.{ "/*", "*/" }} };
const c_keywords = [_][]const u8{
    "auto",    "break",  "case",     "const",     "continue",       "default",       "do",       "else",     "enum",
    "extern",  "for",    "goto",     "if",        "inline",         "register",      "restrict", "return",   "sizeof",
    "static",  "struct", "switch",   "typedef",   "union",          "volatile",      "while",    "_Alignas", "_Alignof",
    "_Atomic", "_Bool",  "_Generic", "_Noreturn", "_Static_assert", "_Thread_local",
};
const c_types = [_][]const u8{
    "bool",     "char",    "double",  "float",   "int",       "long",     "short",     "signed",
    "unsigned", "void",    "size_t",  "ssize_t", "ptrdiff_t", "intptr_t", "uintptr_t", "int8_t",
    "int16_t",  "int32_t", "int64_t", "uint8_t", "uint16_t",  "uint32_t", "uint64_t",  "wchar_t",
    "FILE",
};
const c_constants = [_][]const u8{ "NULL", "true", "false", "EOF", "stdin", "stdout", "stderr" };
const cpp_keywords = c_keywords ++ [_][]const u8{
    "alignas",       "alignof",     "and",          "asm",          "catch",    "class",            "concept",
    "consteval",     "constexpr",   "constinit",    "const_cast",   "co_await", "co_return",        "co_yield",
    "decltype",      "delete",      "dynamic_cast", "explicit",     "export",   "final",            "friend",
    "module",        "mutable",     "namespace",    "new",          "noexcept", "not",              "operator",
    "or",            "override",    "private",      "protected",    "public",   "reinterpret_cast", "requires",
    "static_assert", "static_cast", "template",     "thread_local", "throw",    "try",              "typeid",
    "typename",      "using",       "virtual",      "import",
};
const cpp_types = c_types ++ [_][]const u8{ "char8_t", "char16_t", "char32_t", "string", "vector", "map", "unique_ptr", "shared_ptr" };
const cpp_constants = c_constants ++ [_][]const u8{ "nullptr", "this" };
const java_like_keywords = [_][]const u8{
    "abstract",   "assert",  "break",      "case",      "catch",    "class",   "continue", "default",
    "do",         "else",    "enum",       "extends",   "final",    "finally", "for",      "if",
    "implements", "import",  "instanceof", "interface", "native",   "new",     "package",  "private",
    "protected",  "public",  "return",     "static",    "strictfp", "super",   "switch",   "synchronized",
    "throw",      "throws",  "transient",  "try",       "volatile", "while",   "var",      "record",
    "sealed",     "permits", "yield",
};
const java_types = [_][]const u8{ "boolean", "byte", "char", "double", "float", "int", "long", "short", "void", "String", "Object", "Integer" };
const shader_types = [_][]const u8{
    "bool",        "int",       "uint",      "float",        "double",   "half",     "void",     "vec2",      "vec3",
    "vec4",        "ivec2",     "ivec3",     "ivec4",        "uvec2",    "uvec3",    "uvec4",    "bvec2",     "bvec3",
    "bvec4",       "dvec2",     "dvec3",     "dvec4",        "mat2",     "mat3",     "mat4",     "mat2x2",    "mat3x3",
    "mat4x4",      "float2",    "float3",    "float4",       "float2x2", "float3x3", "float4x4", "half2",     "half3",
    "half4",       "int2",      "int3",      "int4",         "uint2",    "uint3",    "uint4",    "sampler2D", "sampler3D",
    "samplerCube", "texture2d", "Texture2D", "SamplerState", "image2D",
};
const lisp_like: Spec = .{
    .line_comments = &.{";"},
    .block_comments = &.{.{ "#|", "|#" }},
    .nested_comments = true,
    .quotes = "\"",
    .ident_extra = "-?!*+<>=/.%&",
    .call_after_paren = true,
    .upper_is_type = false,
    .caps_constants = false,
};
const shell_builtins = [_][]const u8{
    "alias", "bg",      "bind", "builtin", "cd",   "command", "complete", "echo",    "eval",  "exec",
    "fg",    "getopts", "hash", "jobs",    "kill", "let",     "printf",   "pwd",     "read",  "set",
    "shift", "source",  "test", "trap",    "type", "ulimit",  "umask",    "unalias", "unset", "wait",
};

fn specOf(comptime dialect: Dialect) Spec {
    return switch (dialect) {
        .c => merge(c_comments, .{
            .preprocessor = true,
            .keywords = &c_keywords,
            .types = &c_types,
            .constants = &c_constants,
            .declares_type = &.{ "struct", "enum", "union" },
            .upper_is_type = false,
        }),
        .cpp => merge(c_comments, .{
            .preprocessor = true,
            .keywords = &cpp_keywords,
            .types = &cpp_types,
            .constants = &cpp_constants,
            .declares_type = &.{ "struct", "enum", "union", "class", "namespace", "concept" },
        }),
        .objc => merge(c_comments, .{
            .preprocessor = true,
            .at_names = .keyword,
            .keywords = &(c_keywords ++ [_][]const u8{ "self", "super", "id", "in", "out", "inout", "bycopy", "byref", "oneway", "nonatomic", "atomic", "strong", "weak", "copy", "assign", "readonly", "readwrite", "nullable", "nonnull" }),
            .types = &(c_types ++ [_][]const u8{ "BOOL", "NSInteger", "NSUInteger", "CGFloat", "SEL", "IMP", "Class", "instancetype" }),
            .constants = &(c_constants ++ [_][]const u8{ "nil", "Nil", "YES", "NO" }),
            .declares_type = &.{ "struct", "enum", "union" },
        }),
        .csharp => merge(c_comments, .{
            .preprocessor = true,
            .triple_quotes = true,
            .keywords = &.{
                "abstract", "as",      "async",     "await",     "base",       "break",    "case",      "catch",
                "checked",  "class",   "const",     "continue",  "default",    "delegate", "do",        "else",
                "enum",     "event",   "explicit",  "extern",    "finally",    "fixed",    "for",       "foreach",
                "get",      "goto",    "if",        "implicit",  "in",         "init",     "interface", "internal",
                "is",       "lock",    "namespace", "new",       "operator",   "out",      "override",  "params",
                "partial",  "private", "protected", "public",    "readonly",   "record",   "ref",       "required",
                "return",   "sealed",  "set",       "sizeof",    "stackalloc", "static",   "struct",    "switch",
                "throw",    "try",     "typeof",    "unchecked", "unsafe",     "using",    "var",       "virtual",
                "volatile", "when",    "where",     "while",     "yield",      "with",     "and",       "or",
                "not",      "global",  "file",      "scoped",
            },
            .types = &.{ "bool", "byte", "char", "decimal", "double", "dynamic", "float", "int", "long", "nint", "nuint", "object", "sbyte", "short", "string", "uint", "ulong", "ushort", "void" },
            .constants = &.{ "true", "false", "null", "this", "value" },
            .declares_type = &.{ "class", "struct", "interface", "enum", "record", "namespace", "delegate" },
        }),
        .java => merge(c_comments, .{
            .triple_quotes = true,
            .at_names = .attribute,
            .keywords = &java_like_keywords,
            .types = &java_types,
            .constants = &.{ "true", "false", "null", "this" },
            .declares_type = &.{ "class", "interface", "enum", "record" },
        }),
        .kotlin => merge(c_comments, .{
            .nested_comments = true,
            .triple_quotes = true,
            .at_names = .attribute,
            .dollar_vars = true,
            .keywords = &.{
                "abstract",  "actual",  "annotation",  "as",        "break",       "by",        "catch",    "class",
                "companion", "const",   "constructor", "continue",  "crossinline", "data",      "do",       "else",
                "enum",      "expect",  "external",    "final",     "finally",     "for",       "fun",      "get",
                "if",        "import",  "in",          "infix",     "init",        "inline",    "inner",    "interface",
                "internal",  "is",      "lateinit",    "noinline",  "object",      "open",      "operator", "out",
                "override",  "package", "private",     "protected", "public",      "reified",   "return",   "sealed",
                "set",       "suspend", "tailrec",     "throw",     "try",         "typealias", "val",      "value",
                "var",       "vararg",  "when",        "where",     "while",
            },
            .types = &.{ "Any", "Boolean", "Byte", "Char", "Double", "Float", "Int", "Long", "Nothing", "Short", "String", "Unit" },
            .constants = &.{ "true", "false", "null", "this", "super", "it" },
            .declares_function = &.{"fun"},
            .declares_type = &.{ "class", "interface", "object", "typealias" },
        }),
        .scala => merge(c_comments, .{
            .nested_comments = true,
            .triple_quotes = true,
            .at_names = .attribute,
            .keywords = &.{
                "abstract", "case",   "catch",    "class",     "def",         "derives", "do",        "else",
                "enum",     "export", "extends",  "extension", "final",       "finally", "for",       "forSome",
                "given",    "if",     "implicit", "import",    "inline",      "lazy",    "match",     "new",
                "object",   "opaque", "open",     "override",  "package",     "private", "protected", "return",
                "sealed",   "then",   "throw",    "trait",     "transparent", "try",     "type",      "using",
                "val",      "var",    "while",    "with",      "yield",
            },
            .types = &.{ "Any", "AnyRef", "AnyVal", "Boolean", "Byte", "Char", "Double", "Float", "Int", "Long", "Nothing", "Short", "String", "Unit", "Option", "List", "Seq", "Map" },
            .constants = &.{ "true", "false", "null", "this", "super", "None", "Nil" },
            .declares_function = &.{"def"},
            .declares_type = &.{ "class", "trait", "object", "type", "enum" },
        }),
        .groovy => merge(c_comments, .{
            .triple_quotes = true,
            .at_names = .attribute,
            .dollar_vars = true,
            .keywords = &(java_like_keywords ++ [_][]const u8{ "def", "as", "in", "trait" }),
            .types = &java_types,
            .constants = &.{ "true", "false", "null", "this", "it" },
            .declares_function = &.{"def"},
            .declares_type = &.{ "class", "interface", "enum", "trait" },
        }),
        .swift => merge(c_comments, .{
            .nested_comments = true,
            .triple_quotes = true,
            .quotes = "\"",
            .at_names = .attribute,
            .keywords = &.{
                "actor",    "any",      "as",       "associatedtype", "async",     "await",       "break",       "case",
                "catch",    "class",    "continue", "convenience",    "default",   "defer",       "deinit",      "didSet",
                "do",       "dynamic",  "else",     "enum",           "extension", "fallthrough", "fileprivate", "final",
                "for",      "func",     "get",      "guard",          "if",        "import",      "in",          "indirect",
                "init",     "inout",    "internal", "is",             "lazy",      "let",         "mutating",    "nonisolated",
                "open",     "operator", "optional", "override",       "private",   "protocol",    "public",      "repeat",
                "required", "rethrows", "return",   "set",            "some",      "static",      "struct",      "subscript",
                "switch",   "throw",    "throws",   "try",            "typealias", "unowned",     "var",         "weak",
                "where",    "while",    "willSet",
            },
            .types = &.{ "Any", "AnyObject", "Bool", "Character", "Double", "Float", "Int", "Int8", "Int16", "Int32", "Int64", "Never", "Optional", "String", "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Void", "Self" },
            .constants = &.{ "true", "false", "nil", "self", "super" },
            .declares_function = &.{"func"},
            .declares_type = &.{ "class", "struct", "enum", "protocol", "extension", "actor", "typealias" },
        }),
        .dart => merge(c_comments, .{
            .nested_comments = true,
            .triple_quotes = true,
            .at_names = .attribute,
            .dollar_vars = true,
            .keywords = &.{
                "abstract", "as",        "assert", "async",    "await",     "base",      "break",      "case",
                "catch",    "class",     "const",  "continue", "covariant", "default",   "deferred",   "do",
                "dynamic",  "else",      "enum",   "export",   "extends",   "extension", "external",   "factory",
                "final",    "finally",   "for",    "get",      "hide",      "if",        "implements", "import",
                "in",       "interface", "is",     "late",     "library",   "mixin",     "new",        "of",
                "on",       "operator",  "part",   "required", "rethrow",   "return",    "sealed",     "set",
                "show",     "static",    "super",  "switch",   "sync",      "throw",     "try",        "typedef",
                "var",      "when",      "while",  "with",     "yield",
            },
            .types = &.{ "bool", "double", "int", "num", "void", "String", "List", "Map", "Set", "Future", "Stream", "Object", "Never", "Null" },
            .constants = &.{ "true", "false", "null", "this" },
            .declares_type = &.{ "class", "mixin", "enum", "extension", "typedef" },
        }),
        .php => .{
            .line_comments = &.{ "//", "#" },
            .block_comments = &.{.{ "/*", "*/" }},
            .multiline_strings = true,
            .dollar_vars = true,
            .php_tags = true,
            .case_insensitive = true,
            .keywords = &.{
                "abstract",  "and",       "as",         "break",      "callable",   "case",         "catch",      "class",
                "clone",     "const",     "continue",   "declare",    "default",    "do",           "echo",       "else",
                "elseif",    "empty",     "enddeclare", "endfor",     "endforeach", "endif",        "endswitch",  "endwhile",
                "enum",      "extends",   "final",      "finally",    "fn",         "for",          "foreach",    "function",
                "global",    "goto",      "if",         "implements", "include",    "include_once", "instanceof", "insteadof",
                "interface", "isset",     "list",       "match",      "namespace",  "new",          "or",         "print",
                "private",   "protected", "public",     "readonly",   "require",    "require_once", "return",     "static",
                "switch",    "throw",     "trait",      "try",        "unset",      "use",          "var",        "while",
                "xor",       "yield",
            },
            .types = &.{ "array", "bool", "float", "int", "iterable", "mixed", "never", "object", "string", "void" },
            .constants = &.{ "true", "false", "null", "self", "parent" },
            .declares_function = &.{"function"},
            .declares_type = &.{ "class", "interface", "trait", "enum" },
        },
        .solidity => merge(c_comments, .{
            .keywords = &.{
                "abstract",    "anonymous", "as",        "assembly", "break",   "calldata", "catch",   "constant",
                "constructor", "continue",  "contract",  "delete",   "do",      "else",     "emit",    "enum",
                "error",       "event",     "external",  "fallback", "for",     "function", "if",      "immutable",
                "import",      "indexed",   "interface", "internal", "is",      "library",  "mapping", "memory",
                "modifier",    "new",       "override",  "payable",  "pragma",  "private",  "public",  "pure",
                "receive",     "return",    "returns",   "revert",   "storage", "struct",   "try",     "type",
                "unchecked",   "using",     "view",      "virtual",  "while",
            },
            .types = &.{ "address", "bool", "bytes", "bytes32", "bytes4", "int", "int256", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uint128", "uint256" },
            .constants = &.{ "true", "false", "this", "msg", "block", "tx", "wei", "gwei", "ether" },
            .declares_function = &.{ "function", "modifier", "event" },
            .declares_type = &.{ "contract", "interface", "library", "struct", "enum" },
        }),
        .shader => merge(c_comments, .{
            .preprocessor = true,
            .keywords = &.{
                "attribute", "break",       "buffer",    "case",      "cbuffer", "centroid", "const",  "continue",
                "default",   "discard",     "do",        "else",      "flat",    "for",      "highp",  "if",
                "in",        "inout",       "invariant", "layout",    "lowp",    "mediump",  "out",    "precision",
                "register",  "return",      "sample",    "shared",    "smooth",  "static",   "struct", "switch",
                "uniform",   "varying",     "while",     "kernel",    "vertex",  "fragment", "device", "constant",
                "thread",    "threadgroup", "using",     "namespace",
            },
            .types = &shader_types,
            .constants = &.{ "true", "false" },
            .declares_type = &.{"struct"},
            .upper_is_type = false,
        }),
        .wgsl => merge(c_comments, .{
            .nested_comments = true,
            .at_names = .attribute,
            .keywords = &.{
                "alias",      "break",    "case",      "const",   "const_assert", "continue", "continuing", "default",
                "diagnostic", "discard",  "else",      "enable",  "fn",           "for",      "if",         "let",
                "loop",       "override", "requires",  "return",  "struct",       "switch",   "var",        "while",
                "function",   "private",  "workgroup", "uniform", "storage",      "read",     "write",      "read_write",
            },
            .types = &.{
                "bool",   "f16",   "f32",     "i32",        "u32",   "vec2",  "vec3",   "vec4",   "vec2f",  "vec3f",   "vec4f",
                "vec2i",  "vec3i", "vec4i",   "vec2u",      "vec3u", "vec4u", "mat2x2", "mat3x3", "mat4x4", "mat4x4f", "array",
                "atomic", "ptr",   "sampler", "texture_2d",
            },
            .constants = &.{ "true", "false" },
            .declares_function = &.{"fn"},
            .declares_type = &.{ "struct", "alias" },
        }),
        .protobuf => merge(c_comments, .{
            .keywords = &.{ "syntax", "edition", "package", "import", "public", "weak", "option", "message", "enum", "service", "rpc", "returns", "stream", "repeated", "optional", "required", "oneof", "map", "reserved", "extend", "extensions", "to", "max" },
            .types = &.{ "double", "float", "int32", "int64", "uint32", "uint64", "sint32", "sint64", "fixed32", "fixed64", "sfixed32", "sfixed64", "bool", "string", "bytes" },
            .constants = &.{ "true", "false" },
            .declares_function = &.{"rpc"},
            .declares_type = &.{ "message", "enum", "service" },
        }),
        .graphql => .{
            .line_comments = &.{"#"},
            .quotes = "\"",
            .triple_quotes = true,
            .dollar_vars = true,
            .at_names = .attribute,
            .keywords = &.{ "query", "mutation", "subscription", "fragment", "on", "type", "interface", "union", "enum", "input", "scalar", "schema", "extend", "directive", "implements", "repeatable" },
            .types = &.{ "Int", "Float", "String", "Boolean", "ID" },
            .constants = &.{ "true", "false", "null" },
            .declares_type = &.{ "type", "interface", "union", "enum", "input", "scalar", "fragment" },
        },
        .verilog => merge(c_comments, .{
            .keywords = &.{
                "always",      "always_comb",  "always_ff",   "assign",    "begin",   "case",       "default",  "else",
                "end",         "endcase",      "endfunction", "endmodule", "endtask", "for",        "function", "generate",
                "endgenerate", "if",           "initial",     "inout",     "input",   "localparam", "module",   "negedge",
                "output",      "parameter",    "posedge",     "task",      "while",   "import",     "package",  "endpackage",
                "interface",   "endinterface", "typedef",     "enum",      "struct",  "logic",      "wire",     "reg",
            },
            .types = &.{ "bit", "byte", "int", "integer", "logic", "real", "reg", "wire", "time" },
            .declares_type = &.{ "module", "interface", "package" },
            .declares_function = &.{ "function", "task" },
            .upper_is_type = false,
        }),
        .shell => .{
            .line_comments = &.{"#"},
            .hash_after_space = true,
            .quotes = "\"'`",
            .multiline_strings = true,
            .dollar_vars = true,
            .ident_extra = "-",
            .upper_is_type = false,
            .keywords = &.{ "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "select", "return", "exit", "local", "export", "readonly", "declare", "typeset", "break", "continue", "time", "coproc" },
            .constants = &.{ "true", "false" },
            .builtins = &shell_builtins,
            .declares_function = &.{"function"},
        },
        .fish => .{
            .line_comments = &.{"#"},
            .hash_after_space = true,
            .multiline_strings = true,
            .dollar_vars = true,
            .ident_extra = "-",
            .upper_is_type = false,
            .keywords = &.{ "if", "else", "end", "for", "in", "while", "switch", "case", "function", "return", "break", "continue", "and", "or", "not", "begin", "set", "set_color", "status", "argparse" },
            .constants = &.{ "true", "false" },
            .builtins = &shell_builtins,
            .declares_function = &.{"function"},
        },
        .powershell => .{
            .line_comments = &.{"#"},
            .block_comments = &.{.{ "<#", "#>" }},
            .escapes = false,
            .multiline_strings = true,
            .dollar_vars = true,
            .case_insensitive = true,
            .ident_extra = "-",
            .upper_is_type = false,
            .keywords = &.{
                "begin",   "break",  "catch",    "class",  "continue", "data",   "do",      "dynamicparam",
                "else",    "elseif", "end",      "enum",   "exit",     "filter", "finally", "for",
                "foreach", "from",   "function", "hidden", "if",       "in",     "param",   "process",
                "return",  "static", "switch",   "throw",  "trap",     "try",    "until",   "using",
                "var",     "while",  "workflow",
            },
            .declares_function = &.{ "function", "filter", "workflow" },
            .declares_type = &.{ "class", "enum" },
        },
        .batch => .{
            .line_comments = &.{ "rem", "::" },
            .quotes = "\"",
            .escapes = false,
            .case_insensitive = true,
            .upper_is_type = false,
            .caps_constants = false,
            .keywords = &.{ "call", "cd", "chdir", "cls", "copy", "defined", "del", "do", "echo", "else", "endlocal", "equ", "erase", "errorlevel", "exist", "exit", "for", "geq", "goto", "gtr", "if", "in", "leq", "lss", "md", "mkdir", "move", "neq", "not", "off", "on", "pause", "popd", "pushd", "rd", "ren", "rmdir", "set", "setlocal", "shift", "start", "title", "type" },
        },
        .ruby => .{
            .line_comments = &.{"#"},
            .quotes = "\"'`",
            .multiline_strings = true,
            .at_names = .property,
            .colon_symbols = true,
            .ident_extra = "?!",
            .keywords = &.{
                "alias",       "and",         "begin",         "break",   "case",      "class",   "def",              "defined?", "do",
                "else",        "elsif",       "end",           "ensure",  "for",       "if",      "in",               "module",   "next",
                "not",         "or",          "redo",          "rescue",  "retry",     "return",  "super",            "then",     "undef",
                "unless",      "until",       "when",          "while",   "yield",     "require", "require_relative", "include",  "extend",
                "attr_reader", "attr_writer", "attr_accessor", "private", "protected", "public",  "raise",            "lambda",   "proc",
            },
            .constants = &.{ "true", "false", "nil", "self", "__FILE__", "__LINE__", "__dir__" },
            .declares_function = &.{"def"},
            .declares_type = &.{ "class", "module" },
        },
        .perl => .{
            .line_comments = &.{"#"},
            .hash_after_space = true,
            .quotes = "\"'`",
            .multiline_strings = true,
            .dollar_vars = true,
            .keywords = &.{ "if", "elsif", "else", "unless", "while", "until", "for", "foreach", "do", "last", "next", "redo", "return", "sub", "my", "our", "local", "use", "no", "require", "package", "and", "or", "not", "eq", "ne", "lt", "gt", "le", "ge", "cmp", "qw", "print", "die", "BEGIN", "END" },
            .constants = &.{"undef"},
            .declares_function = &.{"sub"},
            .declares_type = &.{"package"},
        },
        .r => .{
            .line_comments = &.{"#"},
            .multiline_strings = true,
            .ident_extra = ".",
            .upper_is_type = false,
            .caps_constants = false,
            .keywords = &.{ "if", "else", "repeat", "while", "function", "for", "in", "next", "break", "return", "library", "require", "source" },
            .constants = &.{ "TRUE", "FALSE", "NULL", "NA", "NaN", "Inf", "T", "F", "NA_integer_", "NA_real_", "NA_character_" },
        },
        .julia => .{
            .line_comments = &.{"#"},
            .block_comments = &.{.{ "#=", "=#" }},
            .nested_comments = true,
            .quotes = "\"",
            .triple_quotes = true,
            .at_names = .attribute,
            .ident_extra = "!",
            .keywords = &.{ "abstract", "baremodule", "begin", "break", "catch", "const", "continue", "do", "else", "elseif", "end", "export", "finally", "for", "function", "global", "if", "import", "in", "isa", "let", "local", "macro", "module", "mutable", "primitive", "quote", "return", "struct", "try", "type", "using", "where", "while" },
            .types = &.{ "Any", "Bool", "Char", "Float32", "Float64", "Int", "Int8", "Int16", "Int32", "Int64", "Nothing", "Number", "Real", "String", "Symbol", "UInt", "UInt8", "Vector", "Matrix", "Array", "Dict" },
            .constants = &.{ "true", "false", "nothing", "missing", "NaN", "Inf", "pi" },
            .declares_function = &.{ "function", "macro" },
            .declares_type = &.{ "struct", "module", "type" },
        },
        .elixir => .{
            .line_comments = &.{"#"},
            .triple_quotes = true,
            .multiline_strings = true,
            .at_names = .attribute,
            .colon_symbols = true,
            .ident_extra = "?!",
            .keywords = &.{ "after", "alias", "and", "case", "catch", "cond", "def", "defp", "defmacro", "defmacrop", "defmodule", "defprotocol", "defimpl", "defstruct", "defdelegate", "defguard", "defexception", "do", "else", "end", "fn", "for", "if", "import", "in", "not", "or", "quote", "raise", "receive", "require", "rescue", "try", "unless", "unquote", "use", "when", "with" },
            .constants = &.{ "true", "false", "nil" },
            .declares_function = &.{ "def", "defp", "defmacro", "defmacrop", "defguard", "defdelegate" },
            .declares_type = &.{ "defmodule", "defprotocol" },
        },
        .erlang => .{
            .line_comments = &.{"%"},
            .upper_is_type = false,
            .caps_constants = false,
            .keywords = &.{ "after", "and", "andalso", "band", "begin", "bnot", "bor", "bsl", "bsr", "bxor", "case", "catch", "cond", "div", "end", "fun", "if", "let", "maybe", "not", "of", "or", "orelse", "receive", "rem", "try", "when", "xor", "module", "export", "import", "record", "define", "include", "spec", "type" },
            .constants = &.{ "true", "false", "ok", "error", "undefined" },
        },
        .nim => .{
            .line_comments = &.{"#"},
            .block_comments = &.{.{ "#[", "]#" }},
            .nested_comments = true,
            .triple_quotes = true,
            .keywords = &.{ "addr", "and", "as", "asm", "bind", "block", "break", "case", "cast", "concept", "const", "continue", "converter", "defer", "discard", "distinct", "div", "do", "elif", "else", "end", "enum", "except", "export", "finally", "for", "from", "func", "if", "import", "in", "include", "interface", "is", "isnot", "iterator", "let", "macro", "method", "mixin", "mod", "not", "notin", "object", "of", "or", "out", "proc", "ptr", "raise", "ref", "return", "shl", "shr", "static", "template", "try", "tuple", "type", "using", "var", "when", "while", "xor", "yield" },
            .types = &.{ "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "float", "float32", "float64", "bool", "char", "string", "cstring", "seq", "array", "set", "void", "auto", "untyped", "typed" },
            .constants = &.{ "true", "false", "nil", "result" },
            .declares_function = &.{ "proc", "func", "method", "iterator", "template", "macro", "converter" },
        },
        .crystal => .{
            .line_comments = &.{"#"},
            .multiline_strings = true,
            .at_names = .property,
            .colon_symbols = true,
            .ident_extra = "?!",
            .keywords = &.{ "abstract", "alias", "annotation", "as", "begin", "break", "case", "class", "def", "do", "else", "elsif", "end", "ensure", "enum", "extend", "for", "fun", "if", "in", "include", "lib", "macro", "module", "next", "of", "out", "private", "protected", "require", "rescue", "return", "select", "struct", "super", "then", "type", "union", "unless", "until", "when", "while", "with", "yield" },
            .constants = &.{ "true", "false", "nil", "self" },
            .declares_function = &.{ "def", "macro", "fun" },
            .declares_type = &.{ "class", "module", "struct", "enum", "lib", "annotation" },
        },
        .gdscript => .{
            .line_comments = &.{"#"},
            .triple_quotes = true,
            .at_names = .attribute,
            .dollar_vars = true,
            .keywords = &.{ "and", "as", "assert", "await", "break", "breakpoint", "class", "class_name", "const", "continue", "elif", "else", "enum", "extends", "for", "func", "if", "in", "is", "match", "not", "or", "pass", "preload", "return", "signal", "static", "super", "var", "void", "when", "while", "yield" },
            .types = &.{ "bool", "int", "float", "String", "Vector2", "Vector3", "Color", "Array", "Dictionary", "Node", "Object" },
            .constants = &.{ "true", "false", "null", "self", "PI", "TAU", "INF", "NAN" },
            .declares_function = &.{ "func", "signal" },
            .declares_type = &.{ "class", "class_name", "enum" },
        },
        .lua => .{
            .line_comments = &.{"--"},
            .long_brackets = true,
            .upper_is_type = false,
            .keywords = &.{ "and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in", "local", "not", "or", "repeat", "return", "then", "until", "while" },
            .constants = &.{ "true", "false", "nil", "self" },
            .builtins = &.{ "assert", "error", "ipairs", "next", "pairs", "pcall", "print", "rawget", "rawset", "require", "select", "setmetatable", "getmetatable", "tonumber", "tostring", "type", "unpack", "xpcall" },
            .declares_function = &.{"function"},
        },
        .tcl => .{
            .line_comments = &.{"#"},
            .hash_after_space = true,
            .quotes = "\"",
            .multiline_strings = true,
            .dollar_vars = true,
            .upper_is_type = false,
            .keywords = &.{ "after", "append", "array", "break", "catch", "continue", "dict", "else", "elseif", "error", "eval", "expr", "for", "foreach", "global", "if", "incr", "info", "lappend", "lindex", "list", "llength", "namespace", "package", "proc", "puts", "return", "set", "source", "string", "switch", "unset", "upvar", "variable", "while" },
            .declares_function = &.{"proc"},
        },
        .coffeescript => .{
            .line_comments = &.{"#"},
            .block_comments = &.{.{ "###", "###" }},
            .quotes = "\"'`",
            .triple_quotes = true,
            .at_names = .property,
            .keywords = &.{ "and", "break", "by", "catch", "class", "continue", "delete", "do", "else", "extends", "finally", "for", "if", "in", "instanceof", "is", "isnt", "loop", "new", "not", "of", "or", "return", "super", "switch", "then", "throw", "try", "typeof", "unless", "until", "when", "while", "yield", "import", "export", "from", "await" },
            .constants = &.{ "true", "false", "null", "undefined", "yes", "no", "on", "off", "this" },
            .declares_type = &.{"class"},
        },
        .haskell => .{
            .line_comments = &.{"--"},
            .block_comments = &.{.{ "{-", "-}" }},
            .nested_comments = true,
            .quotes = "\"",
            .ident_extra = "'",
            .keywords = &.{ "as", "case", "class", "data", "default", "deriving", "do", "else", "family", "forall", "foreign", "hiding", "if", "import", "in", "infix", "infixl", "infixr", "instance", "let", "mdo", "module", "newtype", "of", "proc", "qualified", "rec", "then", "type", "where" },
            .constants = &.{ "True", "False", "Nothing", "Just", "Left", "Right", "otherwise" },
            .declares_type = &.{ "data", "newtype", "type", "class" },
        },
        .elm => .{
            .line_comments = &.{"--"},
            .block_comments = &.{.{ "{-", "-}" }},
            .nested_comments = true,
            .quotes = "\"",
            .triple_quotes = true,
            .ident_extra = "'",
            .keywords = &.{ "alias", "as", "case", "else", "exposing", "if", "import", "in", "let", "module", "of", "port", "then", "type", "where" },
            .constants = &.{ "True", "False", "Nothing", "Just", "Ok", "Err" },
            .declares_type = &.{ "type", "alias" },
        },
        .ocaml => .{
            .block_comments = &.{.{ "(*", "*)" }},
            .nested_comments = true,
            .quotes = "\"",
            .ident_extra = "'",
            .keywords = &.{ "and", "as", "assert", "begin", "class", "constraint", "do", "done", "downto", "else", "end", "exception", "external", "for", "fun", "function", "functor", "if", "in", "include", "inherit", "initializer", "lazy", "let", "match", "method", "module", "mutable", "new", "nonrec", "object", "of", "open", "or", "private", "rec", "sig", "struct", "then", "to", "try", "type", "val", "virtual", "when", "while", "with" },
            .types = &.{ "int", "float", "bool", "char", "string", "unit", "list", "array", "option", "ref", "bytes" },
            .constants = &.{ "true", "false", "None", "Some" },
            .declares_type = &.{ "type", "module", "exception" },
        },
        .fsharp => .{
            .line_comments = &.{"//"},
            .block_comments = &.{.{ "(*", "*)" }},
            .nested_comments = true,
            .quotes = "\"",
            .triple_quotes = true,
            .ident_extra = "'",
            .keywords = &.{ "abstract", "and", "as", "assert", "base", "begin", "class", "default", "delegate", "do", "done", "downcast", "downto", "elif", "else", "end", "exception", "extern", "finally", "for", "fun", "function", "global", "if", "in", "inherit", "inline", "interface", "internal", "lazy", "let", "match", "member", "module", "mutable", "namespace", "new", "not", "of", "open", "or", "override", "private", "public", "rec", "return", "static", "struct", "then", "to", "try", "type", "upcast", "use", "val", "void", "when", "while", "with", "yield", "async", "task" },
            .types = &.{ "int", "float", "bool", "char", "string", "unit", "list", "array", "option", "seq", "decimal", "byte", "int64" },
            .constants = &.{ "true", "false", "null", "None", "Some" },
            .declares_type = &.{ "type", "module", "exception", "namespace" },
        },
        .lisp => merge(lisp_like, .{
            .keywords = &.{
                "defun",     "defmacro",   "defvar",      "defparameter", "defconstant",   "defclass",    "defmethod",      "defgeneric",
                "defstruct", "defpackage", "in-package",  "define",       "define-syntax", "lambda",      "let",            "let*",
                "letrec",    "if",         "cond",        "when",         "unless",        "case",        "and",            "or",
                "not",       "progn",      "begin",       "do",           "loop",          "setq",        "setf",           "quote",
                "require",   "provide",    "use-package", "defcustom",    "defface",       "interactive", "save-excursion", "module",
                "struct",
            },
            .constants = &.{ "t", "nil" },
            .declares_function = &.{ "defun", "defmacro", "defmethod", "defgeneric" },
        }),
        .clojure => merge(lisp_like, .{
            .line_comments = &.{";"},
            .block_comments = &.{},
            .colon_symbols = true,
            .keywords = &.{ "def", "defn", "defn-", "defmacro", "defmulti", "defmethod", "defprotocol", "defrecord", "deftype", "defonce", "fn", "let", "loop", "recur", "if", "if-let", "when", "when-let", "when-not", "cond", "case", "do", "doseq", "dotimes", "for", "ns", "require", "import", "try", "catch", "finally", "throw", "and", "or", "not", "quote" },
            .constants = &.{ "true", "false", "nil" },
            .declares_function = &.{ "defn", "defn-", "defmacro", "defmulti", "defmethod" },
            .declares_type = &.{ "defprotocol", "defrecord", "deftype" },
        }),
        .sql => .{
            .line_comments = &.{ "--", "#" },
            .block_comments = &.{.{ "/*", "*/" }},
            .quotes = "'\"`",
            .escapes = false,
            .case_insensitive = true,
            .upper_is_type = false,
            .caps_constants = false,
            .keywords = &.{
                "add",        "all",       "alter",     "and",       "any",        "as",      "asc",          "autoincrement",
                "begin",      "between",   "by",        "cascade",   "case",       "check",   "column",       "commit",
                "constraint", "create",    "cross",     "database",  "default",    "delete",  "desc",         "distinct",
                "drop",       "else",      "end",       "except",    "exists",     "explain", "foreign",      "from",
                "full",       "function",  "grant",     "group",     "having",     "if",      "in",           "index",
                "inner",      "insert",    "intersect", "into",      "is",         "join",    "key",          "left",
                "like",       "limit",     "not",       "offset",    "on",         "or",      "order",        "outer",
                "over",       "partition", "primary",   "procedure", "references", "replace", "returning",    "revoke",
                "right",      "rollback",  "select",    "set",       "table",      "then",    "transaction",  "trigger",
                "truncate",   "union",     "unique",    "update",    "using",      "values",  "view",         "when",
                "where",      "window",    "with",      "returns",   "language",   "declare", "materialized", "schema",
            },
            .types = &.{ "bigint", "binary", "bit", "blob", "boolean", "bool", "char", "date", "datetime", "decimal", "double", "float", "int", "integer", "interval", "json", "jsonb", "money", "numeric", "real", "serial", "smallint", "text", "time", "timestamp", "timestamptz", "tinyint", "uuid", "varchar", "varbinary" },
            .constants = &.{ "true", "false", "null" },
            .builtins = &.{ "count", "sum", "avg", "min", "max", "coalesce", "nullif", "cast", "now", "lower", "upper", "length", "substring", "trim", "round", "row_number", "rank" },
        },
        .makefile => .{
            .line_comments = &.{"#"},
            .quotes = "\"'",
            .dollar_vars = true,
            .dollar_parens = true,
            .labels = true,
            .ident_extra = "-.%",
            .upper_is_type = false,
            .keywords = &.{ "ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "include", "sinclude", "override", "export", "unexport", "define", "endef", "vpath" },
        },
        .dockerfile => .{
            .line_comments = &.{"#"},
            .hash_after_space = true,
            .dollar_vars = true,
            .case_insensitive = true,
            .keywords_at_line_start = true,
            .upper_is_type = false,
            .caps_constants = false,
            .keywords = &.{ "from", "run", "cmd", "label", "maintainer", "expose", "env", "add", "copy", "entrypoint", "volume", "user", "workdir", "arg", "onbuild", "stopsignal", "healthcheck", "shell" },
        },
        .cmake => .{
            .line_comments = &.{"#"},
            .quotes = "\"",
            .multiline_strings = true,
            .dollar_vars = true,
            .case_insensitive = true,
            .upper_is_type = false,
            .keywords = &.{ "if", "elseif", "else", "endif", "foreach", "endforeach", "while", "endwhile", "function", "endfunction", "macro", "endmacro", "return", "break", "continue", "block", "endblock" },
            .constants = &.{ "on", "off", "true", "false", "yes", "no" },
            .declares_function = &.{ "function", "macro" },
        },
        .hcl => .{
            .line_comments = &.{ "#", "//" },
            .block_comments = &.{.{ "/*", "*/" }},
            .quotes = "\"",
            .ident_extra = "-",
            .upper_is_type = false,
            .keywords = &.{ "resource", "data", "variable", "output", "module", "provider", "locals", "terraform", "backend", "required_providers", "dynamic", "for", "for_each", "in", "if", "count", "depends_on", "lifecycle", "moved", "import", "check" },
            .types = &.{ "string", "number", "bool", "list", "map", "set", "object", "tuple", "any" },
            .constants = &.{ "true", "false", "null" },
        },
        .nix => .{
            .line_comments = &.{"#"},
            .block_comments = &.{.{ "/*", "*/" }},
            .quotes = "\"",
            .multiline_strings = true,
            .ident_extra = "-'",
            .upper_is_type = false,
            .keywords = &.{ "assert", "else", "if", "in", "inherit", "let", "or", "rec", "then", "with" },
            .constants = &.{ "true", "false", "null" },
            .builtins = &.{ "import", "builtins", "derivation", "throw", "abort", "map", "toString" },
        },
        .fortran => .{
            .line_comments = &.{"!"},
            .escapes = false,
            .case_insensitive = true,
            .upper_is_type = false,
            .caps_constants = false,
            .keywords = &.{ "allocatable", "allocate", "call", "case", "character", "complex", "contains", "cycle", "deallocate", "dimension", "do", "else", "elseif", "end", "exit", "function", "if", "implicit", "in", "inout", "intent", "interface", "logical", "module", "none", "out", "parameter", "print", "procedure", "program", "read", "return", "select", "stop", "subroutine", "then", "type", "use", "while", "write" },
            .types = &.{ "integer", "real", "double", "precision", "character", "logical", "complex" },
            .declares_function = &.{ "function", "subroutine", "program" },
            .declares_type = &.{"module"},
        },
        .pascal => .{
            .line_comments = &.{"//"},
            .block_comments = &.{ .{ "(*", "*)" }, .{ "{", "}" } },
            .quotes = "'",
            .escapes = false,
            .case_insensitive = true,
            .caps_constants = false,
            .keywords = &.{ "and", "array", "as", "asm", "begin", "case", "class", "const", "constructor", "destructor", "div", "do", "downto", "else", "end", "except", "exports", "file", "finally", "for", "function", "goto", "if", "implementation", "in", "inherited", "initialization", "interface", "is", "label", "library", "mod", "nil", "not", "object", "of", "or", "out", "packed", "procedure", "program", "property", "raise", "record", "repeat", "set", "shl", "shr", "then", "to", "try", "type", "unit", "until", "uses", "var", "while", "with", "xor", "private", "public", "protected", "published", "override", "virtual" },
            .types = &.{ "integer", "cardinal", "shortint", "smallint", "longint", "int64", "byte", "word", "boolean", "char", "string", "real", "single", "double", "extended", "pointer" },
            .constants = &.{ "true", "false", "nil", "self" },
            .declares_function = &.{ "function", "procedure", "constructor", "destructor" },
        },
        .ada => .{
            .line_comments = &.{"--"},
            .quotes = "\"",
            .escapes = false,
            .case_insensitive = true,
            .caps_constants = false,
            .keywords = &.{ "abort", "abs", "abstract", "accept", "access", "aliased", "all", "and", "array", "at", "begin", "body", "case", "constant", "declare", "delay", "delta", "digits", "do", "else", "elsif", "end", "entry", "exception", "exit", "for", "function", "generic", "goto", "if", "in", "interface", "is", "limited", "loop", "mod", "new", "not", "null", "of", "or", "others", "out", "overriding", "package", "pragma", "private", "procedure", "protected", "raise", "range", "record", "rem", "renames", "requeue", "return", "reverse", "select", "separate", "some", "subtype", "synchronized", "tagged", "task", "terminate", "then", "type", "until", "use", "when", "while", "with", "xor" },
            .types = &.{ "integer", "natural", "positive", "float", "boolean", "character", "string", "duration" },
            .constants = &.{ "true", "false" },
            .declares_function = &.{ "function", "procedure" },
            .declares_type = &.{ "type", "subtype", "package" },
        },
        .vhdl => .{
            .line_comments = &.{"--"},
            .block_comments = &.{.{ "/*", "*/" }},
            .quotes = "\"",
            .escapes = false,
            .case_insensitive = true,
            .upper_is_type = false,
            .caps_constants = false,
            .keywords = &.{ "abs", "after", "alias", "all", "and", "architecture", "array", "assert", "attribute", "begin", "block", "body", "buffer", "bus", "case", "component", "configuration", "constant", "downto", "else", "elsif", "end", "entity", "exit", "file", "for", "function", "generate", "generic", "if", "in", "inout", "is", "library", "loop", "map", "mod", "nand", "new", "next", "nor", "not", "null", "of", "on", "open", "or", "others", "out", "package", "port", "procedure", "process", "range", "record", "report", "return", "select", "severity", "signal", "subtype", "then", "to", "type", "until", "use", "variable", "wait", "when", "while", "with", "xnor", "xor" },
            .types = &.{ "bit", "bit_vector", "boolean", "integer", "natural", "positive", "real", "std_logic", "std_logic_vector", "std_ulogic", "signed", "unsigned", "string", "time" },
            .constants = &.{ "true", "false" },
            .declares_type = &.{ "entity", "architecture", "package", "component" },
        },
        .vb => .{
            .line_comments = &.{ "'", "rem" },
            .quotes = "\"",
            .escapes = false,
            .case_insensitive = true,
            .caps_constants = false,
            .keywords = &.{ "addhandler", "and", "andalso", "as", "byref", "byval", "call", "case", "catch", "class", "const", "continue", "declare", "dim", "do", "each", "else", "elseif", "end", "enum", "erase", "error", "event", "exit", "finally", "for", "friend", "function", "get", "goto", "handles", "if", "implements", "imports", "in", "inherits", "interface", "is", "isnot", "let", "like", "loop", "me", "mod", "module", "mustinherit", "mustoverride", "mybase", "namespace", "new", "next", "not", "of", "on", "option", "optional", "or", "orelse", "overloads", "overridable", "overrides", "paramarray", "partial", "private", "property", "protected", "public", "raiseevent", "readonly", "redim", "resume", "return", "select", "set", "shadows", "shared", "static", "step", "structure", "sub", "then", "throw", "to", "try", "typeof", "until", "using", "wend", "when", "while", "with", "withevents", "writeonly", "xor" },
            .types = &.{ "boolean", "byte", "char", "date", "decimal", "double", "integer", "long", "object", "sbyte", "short", "single", "string", "uinteger", "ulong", "ushort", "variant" },
            .constants = &.{ "true", "false", "nothing" },
            .declares_function = &.{ "function", "sub" },
            .declares_type = &.{ "class", "module", "structure", "interface", "enum" },
        },
        .assembly => .{
            .line_comments = &.{ ";", "//", "#" },
            .block_comments = &.{.{ "/*", "*/" }},
            .hash_after_space = true,
            .labels = true,
            .first_word_keyword = true,
            .ident_extra = ".",
            .upper_is_type = false,
            .caps_constants = false,
        },
        .tex => .{
            .line_comments = &.{"%"},
            .quotes = "",
            .backslash_commands = true,
            .upper_is_type = false,
            .caps_constants = false,
        },
    };
}

/// `base` with the fields `extra` sets replaced.
fn merge(comptime base: Spec, comptime extra: anytype) Spec {
    var s = base;
    for (@typeInfo(@TypeOf(extra)).@"struct".fields) |f| @field(s, f.name) = @field(extra, f.name);
    return s;
}

test {
    _ = @import("../tests/generic_test.zig");
}
