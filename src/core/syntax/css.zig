//! CSS lexer for highlighting, one line at a time. The SCSS dialect (also
//! used for Sass and Less) adds `//` comments, `$variables` and `&`.
//!
//! Selectors and declarations are told apart per line: `name:` is a
//! property when no `{` follows it before the next `;`, so nested rules like
//! `a:hover {` stay selectors.
const std = @import("std");
const token = @import("token.zig");

const Kind = token.Kind;
const Span = token.Span;

pub const State = struct {
    in_comment: bool = false,
};

pub const Dialect = enum { css, scss };

pub const Lexer = struct {
    line: []const u8,
    pos: usize = 0,
    state: State,
    dialect: Dialect,
    /// Between a property's `:` and the next `;`, `{` or `}`.
    in_value: bool = false,
    /// The next `:` ends a property name and starts its value.
    property_colon: bool = false,
    /// The word after an at-rule like `@include` names a mixin or function.
    after_at_rule: bool = false,

    pub fn init(line: []const u8, state: State, dialect: Dialect) Lexer {
        return .{ .line = line, .state = state, .dialect = dialect };
    }

    pub fn next(self: *Lexer) ?Span {
        if (self.pos >= self.line.len) return null;
        const start = self.pos;
        const kind = if (self.state.in_comment) self.blockComment() else self.code();
        return .{ .start = start, .end = self.pos, .kind = kind };
    }

    fn peek(self: *const Lexer, offset: usize) ?u8 {
        const i = self.pos + offset;
        return if (i < self.line.len) self.line[i] else null;
    }

    fn code(self: *Lexer) Kind {
        const c = self.line[self.pos];
        if (c == ' ' or c == '\t' or c == '\r') {
            while (self.peek(0)) |w| : (self.pos += 1) if (w != ' ' and w != '\t' and w != '\r') break;
            return .plain;
        }
        if (c == '/' and self.peek(1) == '*') {
            self.pos += 2;
            self.state.in_comment = true;
            return self.blockComment();
        }
        if (c == '/' and self.peek(1) == '/' and self.dialect == .scss and self.lineCommentHere()) {
            self.pos = self.line.len;
            return .comment;
        }

        const after_at = self.after_at_rule;
        self.after_at_rule = false;
        switch (c) {
            '"', '\'' => return self.string(c),
            '@' => {
                self.pos += 1;
                self.word();
                self.after_at_rule = true;
                return .keyword;
            },
            '$' => if (self.peek(1)) |n| if (isIdentStart(n)) {
                self.pos += 1;
                self.word();
                return self.nameKind(.constant);
            },
            '!' => if (self.peek(1)) |n| if (std.ascii.isAlphabetic(n)) {
                self.pos += 1;
                self.word();
                return .keyword; // !important, !default
            },
            '#' => if (self.in_value) {
                self.pos += 1;
                self.word();
                return .number; // #fff
            } else if (self.peek(1)) |n| if (isIdentStart(n)) {
                self.pos += 1;
                self.word();
                return .function; // #id selector
            },
            '.' => if (self.peek(1)) |n| {
                if (std.ascii.isDigit(n)) return self.number();
                if (!self.in_value and isIdentStart(n)) {
                    self.pos += 1;
                    self.word();
                    return .function; // .class selector
                }
            },
            '0'...'9' => return self.number(),
            '-' => if (self.peek(1)) |n| if (std.ascii.isDigit(n) or n == '.') return self.number(),
            ':' => {
                self.pos += 1;
                if (self.property_colon) {
                    self.property_colon = false;
                    self.in_value = true;
                    return .punctuation;
                }
                if (!self.in_value) {
                    if (self.peek(0) == ':') self.pos += 1; // ::before
                    if (self.peek(0)) |n| if (isIdentStart(n)) {
                        self.word();
                        return .function; // :hover
                    };
                }
                return .punctuation;
            },
            ';', '{', '}' => {
                self.pos += 1;
                self.in_value = false;
                self.property_colon = false;
                return .punctuation;
            },
            '&' => {
                self.pos += 1;
                return .keyword;
            },
            else => {},
        }
        if (isIdentStart(c)) {
            self.word();
            if (self.peek(0) == '(') return .function;
            if (self.in_value) return .constant;
            if (after_at) return .function;
            return self.nameKind(.tag);
        }
        self.pos += 1;
        return .punctuation;
    }

    /// A name right before a declaration's `:` is a property (and that colon
    /// starts its value); otherwise it gets `otherwise`.
    fn nameKind(self: *Lexer, otherwise: Kind) Kind {
        const l = self.line;
        var colon = self.pos;
        while (colon < l.len and (l[colon] == ' ' or l[colon] == '\t')) colon += 1;
        if (colon >= l.len or l[colon] != ':') return otherwise;
        const rest = l[colon + 1 ..];
        if (rest.len > 0 and rest[0] == ':') return otherwise; // a::before
        const semicolon = std.mem.indexOfScalar(u8, rest, ';');
        if (std.mem.indexOfScalar(u8, rest[0 .. semicolon orelse rest.len], '{') != null) return otherwise;
        // Indented Sass has no braces: `a:hover` (no space, no `;`) is a selector.
        if (otherwise == .tag and semicolon == null and rest.len > 0 and std.ascii.isAlphabetic(rest[0])) return otherwise;
        self.property_colon = true;
        return if (otherwise == .constant) .constant else .property;
    }

    /// `//` starts a comment only where a token could start, not inside
    /// values like `url(http://...)`.
    fn lineCommentHere(self: *const Lexer) bool {
        if (self.pos == 0) return true;
        const p = self.line[self.pos - 1];
        return p == ' ' or p == '\t' or p == ';' or p == '{' or p == '}';
    }

    fn word(self: *Lexer) void {
        while (self.peek(0)) |w| : (self.pos += 1) if (!isIdentChar(w)) break;
    }

    fn number(self: *Lexer) Kind {
        self.pos += 1;
        while (self.peek(0)) |d| : (self.pos += 1) if (!(std.ascii.isDigit(d) or d == '.')) break;
        // Units: px, em, %, ...
        while (self.peek(0)) |u| : (self.pos += 1) if (!(std.ascii.isAlphabetic(u) or u == '%')) break;
        return .number;
    }

    fn string(self: *Lexer, quote: u8) Kind {
        const l = self.line;
        self.pos += 1;
        while (self.pos < l.len) {
            const s = l[self.pos];
            self.pos = if (s == '\\') @min(l.len, self.pos + 2) else self.pos + 1;
            if (s == quote) break;
        }
        return .string;
    }

    fn blockComment(self: *Lexer) Kind {
        if (std.mem.indexOfPos(u8, self.line, self.pos, "*/")) |end| {
            self.pos = end + 2;
            self.state.in_comment = false;
        } else self.pos = self.line.len;
        return .comment;
    }
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '-' or c >= 0x80;
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

test "rules and declarations" {
    const expect = token.expectTokens;
    _ = try expect(Lexer.init("a.btn:hover, #main > p {", .{}, .css), "a.btn:hover, #main > p {", &.{
        "tag:a", "function:.btn", "function::hover", "punctuation:,", "function:#main", "punctuation:>", "tag:p", "punctuation:{",
    });
    _ = try expect(Lexer.init("  margin: 0 auto -1.5em; color: #fff !important;", .{}, .css), "  margin: 0 auto -1.5em; color: #fff !important;", &.{
        "property:margin", "punctuation::", "number:0",   "constant:auto", "number:-1.5em", "punctuation:;",
        "property:color",  "punctuation::", "number:#fff", "keyword:!important", "punctuation:;",
    });
    _ = try expect(Lexer.init("background: url(http://x.io/a.png) rgb(0, 0, 0);", .{}, .scss), "background: url(http://x.io/a.png) rgb(0, 0, 0);", &.{
        "property:background", "punctuation::", "function:url", "punctuation:(", "constant:http", "punctuation::",
        "punctuation:/",       "punctuation:/", "constant:x",   "punctuation:.", "constant:io",   "punctuation:/",
        "constant:a",          "punctuation:.", "constant:png", "punctuation:)", "function:rgb",  "punctuation:(",
        "number:0",            "punctuation:,", "number:0",     "punctuation:,", "number:0",      "punctuation:)",
        "punctuation:;",
    });
}

test "scss" {
    const expect = token.expectTokens;
    _ = try expect(Lexer.init("$gap: 4px; // spacing", .{}, .scss), "$gap: 4px; // spacing", &.{
        "constant:$gap", "punctuation::", "number:4px", "punctuation:;", "comment:// spacing",
    });
    _ = try expect(Lexer.init("  &:hover { @include shadow(2); }", .{}, .scss), "  &:hover { @include shadow(2); }", &.{
        "keyword:&", "function::hover", "punctuation:{", "keyword:@include", "function:shadow", "punctuation:(", "number:2", "punctuation:)", "punctuation:;", "punctuation:}",
    });
    const lx = try expect(Lexer.init("a { /* multi", .{}, .css), "a { /* multi", &.{ "tag:a", "punctuation:{", "comment:/* multi" });
    try std.testing.expect(lx.state.in_comment);
}
