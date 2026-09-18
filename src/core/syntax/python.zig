//! Python lexer for highlighting, one line at a time. Triple-quoted strings
//! carry over to following lines.
const std = @import("std");
const token = @import("token.zig");

const Kind = token.Kind;
const Span = token.Span;

pub const State = struct {
    /// Quote character of an open triple-quoted string, or 0.
    triple: u8 = 0,
};

pub const Lexer = struct {
    line: []const u8,
    pos: usize = 0,
    state: State,
    /// Right after `def` / `class`: the next name is being defined.
    defining: enum { none, function, class } = .none,
    /// Nothing but whitespace so far on this line (decorators start lines).
    line_start: bool = true,

    pub fn init(line: []const u8, state: State) Lexer {
        return .{ .line = line, .state = state };
    }

    pub fn next(self: *Lexer) ?Span {
        if (self.pos >= self.line.len) return null;
        const start = self.pos;
        const kind = if (self.state.triple != 0) self.tripleRest() else self.code();
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
        const at_line_start = self.line_start;
        self.line_start = false;

        if (c == '#') {
            self.pos = l.len;
            return .comment;
        }
        if (self.stringQuote()) |quote_at| return self.string(quote_at);
        if (c == '@' and at_line_start) {
            // @decorator, @module.decorator
            self.pos += 1;
            while (self.peek(0)) |w| : (self.pos += 1) if (!(isIdentChar(w) or w == '.')) break;
            return .function;
        }
        if (std.ascii.isDigit(c) or (c == '.' and self.peek(1) != null and std.ascii.isDigit(self.peek(1).?))) {
            self.pos += 1;
            while (self.peek(0)) |d| : (self.pos += 1) {
                if (!(std.ascii.isAlphanumeric(d) or d == '_' or d == '.')) break;
            }
            return .number;
        }
        if (isIdentStart(c)) return self.identifier();
        self.pos += 1;
        return .punctuation;
    }

    /// Where the quote is, if a string (with optional r/b/f/u prefix) starts here.
    fn stringQuote(self: *const Lexer) ?usize {
        var i = self.pos;
        while (i < self.line.len and i - self.pos < 2 and std.mem.indexOfScalar(u8, "rRbBfFuU", self.line[i]) != null) i += 1;
        if (i < self.line.len and (self.line[i] == '"' or self.line[i] == '\'')) return i;
        return null;
    }

    fn string(self: *Lexer, quote_at: usize) Kind {
        const l = self.line;
        const q = l[quote_at];
        if (std.mem.startsWith(u8, l[quote_at..], &.{ q, q, q })) {
            self.pos = quote_at + 3;
            self.state.triple = q;
            return self.tripleRest();
        }
        self.pos = quote_at + 1;
        while (self.pos < l.len) {
            const s = l[self.pos];
            self.pos = if (s == '\\') @min(l.len, self.pos + 2) else self.pos + 1;
            if (s == q) break;
        }
        return .string;
    }

    /// The rest of a triple-quoted string on this line.
    fn tripleRest(self: *Lexer) Kind {
        const l = self.line;
        const q = self.state.triple;
        while (self.pos < l.len) {
            if (l[self.pos] == '\\') {
                self.pos = @min(l.len, self.pos + 2);
                continue;
            }
            if (std.mem.startsWith(u8, l[self.pos..], &.{ q, q, q })) {
                self.pos += 3;
                self.state.triple = 0;
                break;
            }
            self.pos += 1;
        }
        return .string;
    }

    fn identifier(self: *Lexer) Kind {
        const start = self.pos;
        while (self.peek(0)) |w| : (self.pos += 1) if (!isIdentChar(w)) break;
        const word = self.line[start..self.pos];
        const is_member = start > 0 and self.line[start - 1] == '.';

        const defining = self.defining;
        self.defining = .none;
        switch (defining) {
            .function => return .function,
            .class => return .type,
            .none => {},
        }
        if (!is_member) {
            if (constants.has(word)) return .constant;
            if (keywords.has(word)) {
                if (std.mem.eql(u8, word, "def")) self.defining = .function;
                if (std.mem.eql(u8, word, "class")) self.defining = .class;
                return .keyword;
            }
            if (builtin_types.has(word)) return .type;
        }
        const rest = std.mem.trimStart(u8, self.line[self.pos..], " \t");
        if (rest.len > 0 and rest[0] == '(') return .function;
        if (std.ascii.isUpper(word[0])) return .type;
        return .plain;
    }
};

pub fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

pub fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

fn wordSet(comptime words: []const []const u8) std.StaticStringMap(void) {
    comptime var kvs: [words.len]struct { []const u8 } = undefined;
    inline for (words, 0..) |w, i| kvs[i] = .{w};
    return .initComptime(kvs);
}

pub const keyword_list = [_][]const u8{
    "and",   "as",     "assert", "async",    "await",  "break", "class",  "continue",
    "def",   "del",    "elif",   "else",     "except", "finally", "for",  "from",
    "global", "if",    "import", "in",       "is",     "lambda", "nonlocal", "not",
    "or",    "pass",   "raise",  "return",   "try",    "while", "with",   "yield",
    "match", "case",
};
const keywords = wordSet(&keyword_list);

pub const constant_list = [_][]const u8{ "True", "False", "None", "self", "cls", "__name__", "__file__" };
const constants = wordSet(&constant_list);

pub const builtin_type_list = [_][]const u8{
    "int",   "float", "str",   "bytes",  "bool",      "list",      "dict",        "set",
    "tuple", "object", "type", "frozenset", "complex", "bytearray", "Exception", "ValueError",
    "TypeError", "KeyError", "IndexError", "RuntimeError", "OSError", "StopIteration",
};
const builtin_types = wordSet(&builtin_type_list);

pub const builtin_function_list = [_][]const u8{
    "print", "len",      "range",   "enumerate", "zip",   "map",   "filter",  "sorted",
    "open",  "isinstance", "getattr", "setattr", "hasattr", "super", "abs",   "min",
    "max",   "sum",      "any",     "all",       "repr",  "input", "iter",    "next",
    "round", "vars",     "dir",     "id",        "hash",  "format", "reversed", "__init__",
};

test "definitions, strings, decorators" {
    const expect = token.expectTokens;
    _ = try expect(Lexer.init("@app.route(\"/\")", .{}), "@app.route(\"/\")", &.{ "function:@app.route", "punctuation:(", "string:\"/\"", "punctuation:)" });
    _ = try expect(Lexer.init("def run(self, n: int = 0x1F) -> None:  # go", .{}), "def run(self, n: int = 0x1F) -> None:  # go", &.{
        "keyword:def", "function:run", "punctuation:(", "constant:self", "punctuation:,", "plain:n", "punctuation::", "type:int",
        "punctuation:=", "number:0x1F", "punctuation:)", "punctuation:-", "punctuation:>", "constant:None", "punctuation::", "comment:# go",
    });
    _ = try expect(Lexer.init("class User(Base): x = f'{a}' + rb'\\d'", .{}), "class User(Base): x = f'{a}' + rb'\\d'", &.{
        "keyword:class", "type:User", "punctuation:(", "type:Base", "punctuation:)", "punctuation::", "plain:x", "punctuation:=",
        "string:f'{a}'", "punctuation:+", "string:rb'\\d'",
    });
}

test "triple-quoted strings span lines" {
    const expect = token.expectTokens;
    const lx = try expect(Lexer.init("doc = \"\"\"Hello", .{}), "doc = \"\"\"Hello", &.{ "plain:doc", "punctuation:=", "string:\"\"\"Hello" });
    try std.testing.expectEqual(@as(u8, '"'), lx.state.triple);
    const end = try expect(Lexer.init("world\"\"\" if x else y", lx.state), "world\"\"\" if x else y", &.{ "string:world\"\"\"", "keyword:if", "plain:x", "keyword:else", "plain:y" });
    try std.testing.expectEqual(@as(u8, 0), end.state.triple);
}
