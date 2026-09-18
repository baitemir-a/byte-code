//! JavaScript / TypeScript lexer for highlighting. It works one line at a
//! time; `State` carries what spans lines (block comments, template strings).
const std = @import("std");
const token = @import("token.zig");

const Kind = token.Kind;
const Span = token.Span;

/// Lexer state at a line boundary.
pub const State = struct {
    mode: Mode = .code,
    /// Brace depth inside each open `${ ... }`, innermost last.
    braces: [max_nesting]u8 = undefined,
    nesting: u8 = 0,

    pub const Mode = enum(u8) { code, block_comment, template };
    pub const max_nesting = 8;
};

/// State after lexing `line` starting from `state`.
pub fn endState(line: []const u8, state: State) State {
    var lx = Lexer.init(line, state);
    while (lx.next()) |_| {}
    return lx.state;
}

pub const Lexer = struct {
    line: []const u8,
    pos: usize = 0,
    state: State,
    /// Last token that wasn't whitespace or a comment: decides whether a
    /// `/` starts a regex or is division.
    prev: ?struct { kind: Kind, last: u8 } = null,

    pub fn init(line: []const u8, state: State) Lexer {
        return .{ .line = line, .state = state };
    }

    /// Next token; together the tokens cover every byte of the line.
    pub fn next(self: *Lexer) ?Span {
        if (self.pos >= self.line.len) return null;
        const start = self.pos;
        const kind = switch (self.state.mode) {
            .block_comment => self.blockComment(),
            .template => self.templateBody(),
            .code => self.code(),
        };
        return .{ .start = start, .end = self.pos, .kind = kind };
    }

    fn peek(self: *const Lexer, offset: usize) ?u8 {
        const i = self.pos + offset;
        return if (i < self.line.len) self.line[i] else null;
    }

    fn code(self: *Lexer) Kind {
        const c = self.line[self.pos];
        if (c == ' ' or c == '\t') {
            while (self.peek(0)) |w| : (self.pos += 1) if (w != ' ' and w != '\t') break;
            return .plain;
        }
        if (c == '/' and self.peek(1) == '/') {
            self.pos = self.line.len;
            return .comment;
        }
        if (c == '/' and self.peek(1) == '*') {
            self.pos += 2;
            self.state.mode = .block_comment;
            return self.blockComment();
        }
        const kind = self.significant(c);
        self.prev = .{ .kind = kind, .last = self.line[self.pos - 1] };
        return kind;
    }

    fn significant(self: *Lexer, c: u8) Kind {
        switch (c) {
            '"', '\'' => return self.string(c),
            '`' => {
                self.pos += 1;
                self.state.mode = .template;
                self.templateText();
                return .string;
            },
            '0'...'9' => return self.number(),
            '.' => if (self.peek(1)) |d| if (std.ascii.isDigit(d)) return self.number(),
            '/' => if (self.regexAllowed() and self.regex()) return .regex,
            '{' => if (self.state.nesting > 0) {
                self.state.braces[self.state.nesting - 1] += 1;
            },
            '}' => if (self.state.nesting > 0) {
                const depth = &self.state.braces[self.state.nesting - 1];
                if (depth.* == 0) {
                    // Closes a `${`: back inside the template string.
                    self.state.nesting -= 1;
                    self.state.mode = .template;
                } else depth.* -= 1;
            },
            else => if (isIdentStart(c)) return self.identifier(),
        }
        self.pos += 1;
        return .punctuation;
    }

    fn blockComment(self: *Lexer) Kind {
        if (std.mem.indexOfPos(u8, self.line, self.pos, "*/")) |end| {
            self.pos = end + 2;
            self.state.mode = .code;
        } else self.pos = self.line.len;
        return .comment;
    }

    /// Inside a template string: either its text or a `${` opening code.
    fn templateBody(self: *Lexer) Kind {
        if (self.peek(0) == '$' and self.peek(1) == '{' and self.state.nesting < State.max_nesting) {
            self.pos += 2;
            self.state.braces[self.state.nesting] = 0;
            self.state.nesting += 1;
            self.state.mode = .code;
            return .punctuation;
        }
        if (self.peek(0) == '$') self.pos += 1; // a `${` too deeply nested to track
        self.templateText();
        return .string;
    }

    /// Consumes template text up to the closing backtick, a `${` or line end.
    fn templateText(self: *Lexer) void {
        const l = self.line;
        while (self.pos < l.len) {
            switch (l[self.pos]) {
                '\\' => self.pos = @min(l.len, self.pos + 2),
                '`' => {
                    self.pos += 1;
                    self.state.mode = .code;
                    return;
                },
                '$' => if (self.peek(1) == '{') return else {
                    self.pos += 1;
                },
                else => self.pos += 1,
            }
        }
    }

    fn string(self: *Lexer, quote: u8) Kind {
        const l = self.line;
        self.pos += 1;
        while (self.pos < l.len) {
            const c = l[self.pos];
            if (c == '\\') {
                self.pos = @min(l.len, self.pos + 2);
                continue;
            }
            self.pos += 1;
            if (c == quote) break;
        }
        return .string;
    }

    fn number(self: *Lexer) Kind {
        const l = self.line;
        const start = self.pos;
        const hex = l.len > start + 1 and l[start] == '0' and (l[start + 1] | 0x20) == 'x';
        self.pos += 1;
        while (self.peek(0)) |c| {
            const exponent_sign = (c == '+' or c == '-') and !hex and (l[self.pos - 1] | 0x20) == 'e';
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or exponent_sign)) break;
            self.pos += 1;
        }
        return .number;
    }

    fn regexAllowed(self: *const Lexer) bool {
        const p = self.prev orelse return true;
        return switch (p.kind) {
            .keyword => true, // return /x/, typeof /x/ ...
            .punctuation => p.last != ')' and p.last != ']' and p.last != '}',
            else => false,
        };
    }

    /// Consumes a regex literal starting at `/`; false if it isn't closed on this line.
    fn regex(self: *Lexer) bool {
        const l = self.line;
        var i = self.pos + 1;
        var in_class = false;
        while (i < l.len) : (i += 1) {
            switch (l[i]) {
                '\\' => i += 1,
                '[' => in_class = true,
                ']' => in_class = false,
                '/' => if (!in_class) break,
                else => {},
            }
        } else return false;
        i += 1;
        while (i < l.len and std.ascii.isAlphabetic(l[i])) i += 1; // flags
        self.pos = i;
        return true;
    }

    fn identifier(self: *Lexer) Kind {
        const l = self.line;
        const start = self.pos;
        while (self.peek(0)) |c| : (self.pos += 1) if (!isIdentChar(c)) break;
        const word = l[start..self.pos];
        const next_char = self.nextNonSpace();
        // `obj.type` or `obj.delete()` are members, never keywords.
        const is_member = start > 0 and l[start - 1] == '.';

        if (!is_member) {
            if (constants.has(word)) return .constant;
            if (keywords.has(word)) return .keyword;
            // `type`, `from`, `as`... are ordinary names when used as one.
            const used_as_name = next_char != null and std.mem.indexOfScalar(u8, ":=,)", next_char.?) != null;
            if (contextual_keywords.has(word) and !used_as_name) return .keyword;
            if (builtin_types.has(word)) return .type;
        }
        if (next_char == '(') return .function;
        if (!is_member and std.ascii.isUpper(word[0])) return .type;
        return .plain;
    }

    fn nextNonSpace(self: *const Lexer) ?u8 {
        for (self.line[self.pos..]) |c| {
            if (c != ' ' and c != '\t') return c;
        }
        return null;
    }
};

pub fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$' or c >= 0x80;
}

pub fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

// -------------------------------------------------------------- word lists

fn wordSet(comptime words: []const []const u8) std.StaticStringMap(void) {
    comptime var kvs: [words.len]struct { []const u8 } = undefined;
    inline for (words, 0..) |w, i| kvs[i] = .{w};
    return .initComptime(kvs);
}

pub const keyword_list = [_][]const u8{
    "break",    "case",       "catch",     "class",   "const",     "continue", "debugger",
    "default",  "delete",     "do",        "else",    "export",    "extends",  "finally",
    "for",      "function",   "if",        "import",  "in",        "instanceof", "let",
    "new",      "return",     "switch",    "throw",   "try",       "typeof",   "var",
    "void",     "while",      "with",      "yield",   "await",     "enum",     "interface",
    "implements", "private",  "protected", "public",  "static",
};
const keywords = wordSet(&keyword_list);

/// TypeScript / modern JS keywords that are also valid identifiers.
pub const contextual_keyword_list = [_][]const u8{
    "async",    "of",       "get",       "set",     "from",      "as",       "type",
    "namespace", "declare", "abstract",  "readonly", "keyof",    "infer",    "is",
    "satisfies", "module",  "override",  "accessor", "unique",   "asserts",
};
const contextual_keywords = wordSet(&contextual_keyword_list);

pub const constant_list = [_][]const u8{
    "true", "false", "null", "undefined", "this", "super", "NaN", "Infinity",
};
const constants = wordSet(&constant_list);

pub const builtin_type_list = [_][]const u8{
    "string", "number", "boolean", "any", "unknown", "never", "object", "symbol", "bigint",
};
const builtin_types = wordSet(&builtin_type_list);

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// Renders the non-whitespace tokens of a line as "kind:text" for comparison.
fn expectTokens(line: []const u8, state: State, expected: []const []const u8) !State {
    var lx = Lexer.init(line, state);
    var got: std.ArrayList([]const u8) = .empty;
    defer {
        for (got.items) |s| testing.allocator.free(s);
        got.deinit(testing.allocator);
    }
    while (lx.next()) |t| {
        const s = line[t.start..t.end];
        if (std.mem.trim(u8, s, " \t").len == 0) continue;
        try got.append(testing.allocator, try std.fmt.allocPrint(testing.allocator, "{t}:{s}", .{ t.kind, s }));
    }
    try testing.expectEqual(expected.len, got.items.len);
    for (expected, got.items) |e, g| try testing.expectEqualStrings(e, g);
    return lx.state;
}

test "declarations and calls" {
    _ = try expectTokens("const x: number = parseInt(\"4\", 10);", .{}, &.{
        "keyword:const", "plain:x",   "punctuation::", "type:number", "punctuation:=",
        "function:parseInt", "punctuation:(", "string:\"4\"", "punctuation:,", "number:10",
        "punctuation:)", "punctuation:;",
    });
}

test "members are not keywords" {
    _ = try expectTokens("node.type = Foo.new(this)", .{}, &.{
        "plain:node", "punctuation:.", "plain:type", "punctuation:=", "type:Foo",
        "punctuation:.", "function:new", "punctuation:(", "constant:this", "punctuation:)",
    });
}

test "regex vs division" {
    _ = try expectTokens("a = b / c / d", .{}, &.{
        "plain:a", "punctuation:=", "plain:b", "punctuation:/", "plain:c", "punctuation:/", "plain:d",
    });
    _ = try expectTokens("return /[/]x/g.test(s)", .{}, &.{
        "keyword:return", "regex:/[/]x/g", "punctuation:.", "function:test",
        "punctuation:(", "plain:s", "punctuation:)",
    });
}

test "block comment spans lines" {
    const s1 = try expectTokens("x /* start", .{}, &.{ "plain:x", "comment:/* start" });
    try testing.expectEqual(State.Mode.block_comment, s1.mode);
    const s2 = try expectTokens("end */ y // tail", s1, &.{ "comment:end */", "plain:y", "comment:// tail" });
    try testing.expectEqual(State.Mode.code, s2.mode);
}

test "template strings with nested code" {
    const s1 = try expectTokens("`a ${f({ k: `b` })} c", .{}, &.{
        "string:`a ",   "punctuation:${", "function:f", "punctuation:(", "punctuation:{",
        "plain:k",      "punctuation::",  "string:`b`", "punctuation:}", "punctuation:)",
        "punctuation:}", "string: c",
    });
    try testing.expectEqual(State.Mode.template, s1.mode);
    const s2 = try expectTokens("d` + 1", s1, &.{ "string:d`", "punctuation:+", "number:1" });
    try testing.expectEqual(State.Mode.code, s2.mode);
}

test "numbers" {
    _ = try expectTokens("1e-5 + 0xff - .5 + 10n", .{}, &.{
        "number:1e-5", "punctuation:+", "number:0xff", "punctuation:-", "number:.5",
        "punctuation:+", "number:10n",
    });
}
