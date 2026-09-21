//! JavaScript / TypeScript lexer for highlighting. It works one line at a
//! time; `State` carries what spans lines (block comments, template
//! strings, JSX elements).
//!
//! With `State.jsx` set (.jsx and .tsx files) a `<` where a value belongs
//! opens an element: its tag and attributes are highlighted as markup,
//! the text between tags is left plain, and each `{ ... }` goes back to
//! being code — which may hold elements of its own.
const std = @import("std");
const token = @import("token.zig");

const Kind = token.Kind;
const Span = token.Span;

/// Lexer state at a line boundary.
pub const State = struct {
    mode: Mode = .code,
    /// Brace depth inside each open `${ ... }` or JSX `{ ... }`,
    /// innermost last.
    braces: [max_nesting]u8 = undefined,
    /// What each of them goes back to when its brace closes, and the JSX
    /// elements that were open around it.
    returns: [max_nesting]Mode = undefined,
    depths: [max_nesting]u8 = undefined,
    nesting: u8 = 0,
    /// JSX elements open at this point, in the innermost expression.
    jsx_depth: u8 = 0,
    /// The tag being lexed closes an element (`</div>`).
    closing: bool = false,
    /// This file may hold JSX: `<` can open an element.
    jsx: bool = false,

    pub const Mode = enum(u8) { code, block_comment, template, jsx_tag, jsx_text };
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
            .jsx_tag => self.tagBody(),
            .jsx_text => self.jsxText(),
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
            '/' => if (self.valuePosition() and self.regex()) return .regex,
            '<' => if (self.state.jsx and self.elementStart()) return self.openTag(),
            '{' => if (self.state.nesting > 0) {
                self.state.braces[self.state.nesting - 1] += 1;
            },
            '}' => if (self.state.nesting > 0) {
                const depth = &self.state.braces[self.state.nesting - 1];
                if (depth.* == 0) {
                    // Closes a `${` or a JSX `{`: back where it opened.
                    self.state.nesting -= 1;
                    self.state.mode = self.state.returns[self.state.nesting];
                    self.state.jsx_depth = self.state.depths[self.state.nesting];
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
            self.pos += 1; // the `{` is consumed by the expression
            return self.openExpression(.template);
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

    /// Whether a value can begin here: what tells a regex from division,
    /// and a JSX element from a comparison.
    fn valuePosition(self: *const Lexer) bool {
        const p = self.prev orelse return true;
        return switch (p.kind) {
            .keyword => true, // return /x/, return <div/> ...
            .punctuation => p.last != ')' and p.last != ']' and p.last != '}',
            else => false,
        };
    }

    // ------------------------------------------------------------- JSX

    /// A `<` in code: an element rather than a comparison or a shift,
    /// when a value belongs here and a tag name (or a `<>` fragment)
    /// follows immediately.
    fn elementStart(self: *const Lexer) bool {
        if (!self.valuePosition()) return false;
        const c = self.peek(1) orelse return false;
        return isIdentStart(c) or c == '>';
    }

    /// Consumes `<name` or a whole `<>`, the opening of an element.
    fn openTag(self: *Lexer) Kind {
        self.pos += 1;
        if (self.peek(0) == '>') { // `<>`: a fragment, with no attributes
            self.pos += 1;
            self.endTag(.opened);
            return .tag;
        }
        while (self.peek(0)) |c| : (self.pos += 1) if (!isTagChar(c)) break;
        self.state.closing = false;
        self.state.mode = .jsx_tag;
        return .tag;
    }

    /// Consumes `</name` (or `</`, closing a fragment).
    fn closeTag(self: *Lexer) Kind {
        self.pos += 2;
        while (self.peek(0)) |c| : (self.pos += 1) if (!isTagChar(c)) break;
        self.state.closing = true;
        self.state.mode = .jsx_tag;
        return .tag;
    }

    /// Inside a tag: its attributes, up to the `>` or `/>` ending it.
    fn tagBody(self: *Lexer) Kind {
        const c = self.line[self.pos];
        if (c == ' ' or c == '\t') {
            while (self.peek(0)) |w| : (self.pos += 1) if (w != ' ' and w != '\t') break;
            return .plain;
        }
        if (c == '/' and self.peek(1) == '>') {
            self.pos += 2;
            self.endTag(.none); // self-closing: nothing was left open
            return .tag;
        }
        if (c == '>') {
            self.pos += 1;
            self.endTag(if (self.state.closing) .closed else .opened);
            return .tag;
        }
        if (c == '"' or c == '\'') return self.string(c);
        if (c == '{') return self.openExpression(.jsx_tag);
        if (isIdentStart(c)) {
            while (self.peek(0)) |a| : (self.pos += 1) if (!isTagChar(a)) break;
            return .attribute;
        }
        self.pos += 1;
        return .punctuation;
    }

    /// A tag ended: an opening one puts what follows inside the element,
    /// a closing one takes it back out — to the element around it, or to
    /// code once none is left open.
    fn endTag(self: *Lexer, change: enum { opened, closed, none }) void {
        switch (change) {
            .opened => self.state.jsx_depth +|= 1,
            .closed => self.state.jsx_depth -|= 1,
            .none => {},
        }
        self.state.closing = false;
        self.state.mode = if (self.state.jsx_depth > 0) .jsx_text else .code;
    }

    /// Between tags: text, up to the next tag or `{ ... }`.
    fn jsxText(self: *Lexer) Kind {
        const c = self.line[self.pos];
        if (c == '{') return self.openExpression(.jsx_text);
        if (c == '<') {
            if (self.peek(1) == '/') return self.closeTag();
            if (self.peek(1)) |n| if (isIdentStart(n) or n == '>') return self.openTag();
        }
        self.pos += 1; // whatever it is, it's text: take at least this byte
        while (self.pos < self.line.len) : (self.pos += 1) {
            const t = self.line[self.pos];
            if (t == '<' or t == '{') break;
        }
        return .plain;
    }

    /// A `{ ... }` holding code — a template's `${`, a JSX attribute or
    /// JSX text. Its contents are lexed as code (elements of their own
    /// included) until the matching brace goes back to `from`.
    fn openExpression(self: *Lexer, from: State.Mode) Kind {
        self.pos += 1;
        if (self.state.nesting >= State.max_nesting) return .punctuation; // too deep to follow
        self.state.braces[self.state.nesting] = 0;
        self.state.returns[self.state.nesting] = from;
        self.state.depths[self.state.nesting] = self.state.jsx_depth;
        self.state.nesting += 1;
        self.state.jsx_depth = 0;
        self.state.mode = .code;
        self.prev = null; // a fresh expression: `/` and `<` start values
        return .punctuation;
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

/// Tag and attribute names take a few characters identifiers don't:
/// `<Menu.Item>`, `<my-element>`, `data-id`, `xlink:href`.
fn isTagChar(c: u8) bool {
    return isIdentChar(c) or c == '-' or c == '.' or c == ':';
}

// -------------------------------------------------------------- word lists

fn wordSet(comptime words: []const []const u8) std.StaticStringMap(void) {
    comptime var kvs: [words.len]struct { []const u8 } = undefined;
    inline for (words, 0..) |w, i| kvs[i] = .{w};
    return .initComptime(kvs);
}

pub const keyword_list = [_][]const u8{
    "break",      "case",     "catch",     "class",  "const",  "continue",   "debugger",
    "default",    "delete",   "do",        "else",   "export", "extends",    "finally",
    "for",        "function", "if",        "import", "in",     "instanceof", "let",
    "new",        "return",   "switch",    "throw",  "try",    "typeof",     "var",
    "void",       "while",    "with",      "yield",  "await",  "enum",       "interface",
    "implements", "private",  "protected", "public", "static",
};
const keywords = wordSet(&keyword_list);

/// TypeScript / modern JS keywords that are also valid identifiers.
pub const contextual_keyword_list = [_][]const u8{
    "async",     "of",      "get",      "set",      "from",   "as",      "type",
    "namespace", "declare", "abstract", "readonly", "keyof",  "infer",   "is",
    "satisfies", "module",  "override", "accessor", "unique", "asserts",
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

test {
    _ = @import("../tests/js_test.zig");
}
