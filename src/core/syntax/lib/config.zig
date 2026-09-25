//! Lexers for small line-based formats:
//! - dotenv (`.env`, `.env.local`): `KEY=value`, `export`, `$VAR` references;
//! - ignore files (`.gitignore`, `.dockerignore`, ...): glob patterns;
//! - diffs and patches: added and removed lines, hunk headers.
const std = @import("std");
const token = @import("token.zig");

const Kind = token.Kind;
const Span = token.Span;

pub const DotenvState = struct {
    /// Quote of a value that continues onto the next line, or 0.
    quote: u8 = 0,
};

pub const DotenvLexer = struct {
    line: []const u8,
    pos: usize = 0,
    state: DotenvState,
    /// Before the `=`: we're in the key.
    in_key: bool,

    pub fn init(line: []const u8, state: DotenvState) DotenvLexer {
        return .{ .line = line, .state = state, .in_key = state.quote == 0 };
    }

    pub fn next(self: *DotenvLexer) ?Span {
        if (self.pos >= self.line.len) return null;
        const start = self.pos;
        const kind = self.lex();
        return .{ .start = start, .end = self.pos, .kind = kind };
    }

    fn lex(self: *DotenvLexer) Kind {
        const l = self.line;
        if (self.state.quote != 0) return self.quoted(self.state.quote);
        const c = l[self.pos];
        if (c == ' ' or c == '\t' or c == '\r') {
            while (self.pos < l.len and (l[self.pos] == ' ' or l[self.pos] == '\t' or l[self.pos] == '\r')) self.pos += 1;
            return .plain;
        }
        if (c == '#' and (self.in_key or l[self.pos - 1] == ' ')) {
            self.pos = l.len;
            return .comment;
        }
        if (self.in_key) {
            if (c == '=') {
                self.pos += 1;
                self.in_key = false;
                return .punctuation;
            }
            const start = self.pos;
            self.pos = @max(start + 1, std.mem.indexOfAnyPos(u8, l, start, "= \t") orelse l.len);
            const is_export = std.mem.eql(u8, l[start..self.pos], "export") and self.pos < l.len and l[self.pos] == ' ';
            return if (is_export) .keyword else .property;
        }
        switch (c) {
            '"', '\'', '`' => {
                self.pos += 1;
                return self.quoted(c);
            },
            '$' => return self.reference(),
            else => {},
        }
        // Unquoted value up to a reference or a ` #` comment (without the
        // spaces before it).
        const start = self.pos;
        while (self.pos < l.len) : (self.pos += 1) {
            if (l[self.pos] == '$') break;
            if (l[self.pos] == '#' and l[self.pos - 1] == ' ') break;
        }
        if (self.pos < l.len and l[self.pos] == '#') {
            while (self.pos > start + 1 and l[self.pos - 1] == ' ') self.pos -= 1;
        }
        return .string;
    }

    /// `$NAME` or `${NAME}`.
    fn reference(self: *DotenvLexer) Kind {
        const l = self.line;
        self.pos += 1;
        if (self.pos < l.len and l[self.pos] == '{') {
            self.pos = if (std.mem.indexOfScalarPos(u8, l, self.pos, '}')) |e| e + 1 else l.len;
        } else {
            while (self.pos < l.len and (std.ascii.isAlphanumeric(l[self.pos]) or l[self.pos] == '_')) self.pos += 1;
        }
        return .constant;
    }

    fn quoted(self: *DotenvLexer, q: u8) Kind {
        const l = self.line;
        while (self.pos < l.len) {
            const s = l[self.pos];
            self.pos = if (s == '\\' and q != '\'') @min(l.len, self.pos + 2) else self.pos + 1;
            if (s == q) {
                self.state.quote = 0;
                return .string;
            }
        }
        self.state.quote = q; // continues on the next line
        return .string;
    }
};

pub const IgnoreLexer = struct {
    line: []const u8,
    pos: usize = 0,

    pub fn init(line: []const u8) IgnoreLexer {
        return .{ .line = line };
    }

    pub fn next(self: *IgnoreLexer) ?Span {
        const l = self.line;
        if (self.pos >= l.len) return null;
        const start = self.pos;
        const c = l[self.pos];
        const kind: Kind = blk: {
            if (self.pos == 0 and c == '#') {
                self.pos = l.len;
                break :blk .comment;
            }
            switch (c) {
                '!' => if (self.pos == 0) {
                    self.pos += 1;
                    break :blk .keyword; // negation: re-include
                },
                '*', '?' => {
                    while (self.pos < l.len and (l[self.pos] == '*' or l[self.pos] == '?')) self.pos += 1;
                    break :blk .keyword;
                },
                '[' => {
                    self.pos = if (std.mem.indexOfScalarPos(u8, l, self.pos, ']')) |e| e + 1 else l.len;
                    break :blk .keyword; // [abc] character class
                },
                '/' => {
                    self.pos += 1;
                    break :blk .punctuation;
                },
                '\\' => {
                    self.pos = @min(l.len, self.pos + 2);
                    break :blk .plain;
                },
                else => {},
            }
            while (self.pos < l.len and std.mem.indexOfScalar(u8, "*?[/\\", l[self.pos]) == null) self.pos += 1;
            break :blk .plain;
        };
        return .{ .start = start, .end = self.pos, .kind = kind };
    }
};

/// A whole line at a time: added lines as strings, removed ones as regexes
/// (green and red in the themes), `@@` hunk headers as constants, and file
/// headers (`diff`, `---`, `+++`, `index`) as keywords.
pub const DiffLexer = struct {
    line: []const u8,
    done: bool = false,

    pub fn init(line: []const u8) DiffLexer {
        return .{ .line = line };
    }

    pub fn next(self: *DiffLexer) ?Span {
        const l = self.line;
        if (self.done or l.len == 0) return null;
        self.done = true;
        const heads = [_][]const u8{ "diff ", "--- ", "+++ ", "index ", "new file", "deleted file", "similarity", "rename ", "old mode", "new mode" };
        const kind: Kind = for (heads) |h| {
            if (std.mem.startsWith(u8, l, h)) break .keyword;
        } else switch (l[0]) {
            '+', '>' => .string,
            '-', '<' => .regex,
            '@' => .constant,
            '\\' => .comment, // \ No newline at end of file
            else => .plain,
        };
        return .{ .start = 0, .end = l.len, .kind = kind };
    }
};

test {
    _ = @import("../tests/config_test.zig");
}
