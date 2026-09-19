//! JSON lexer for highlighting, one line at a time. Also accepts comments
//! (JSONC, as in tsconfig.json). Object keys are told apart from values.
const std = @import("std");
const token = @import("token.zig");

const Kind = token.Kind;
const Span = token.Span;

pub const State = struct {
    in_comment: bool = false,
};

pub const Lexer = struct {
    line: []const u8,
    pos: usize = 0,
    state: State,

    pub fn init(line: []const u8, state: State) Lexer {
        return .{ .line = line, .state = state };
    }

    pub fn next(self: *Lexer) ?Span {
        if (self.pos >= self.line.len) return null;
        const start = self.pos;
        const kind = if (self.state.in_comment) self.blockComment() else self.value();
        return .{ .start = start, .end = self.pos, .kind = kind };
    }

    fn peek(self: *const Lexer, offset: usize) ?u8 {
        const i = self.pos + offset;
        return if (i < self.line.len) self.line[i] else null;
    }

    fn value(self: *Lexer) Kind {
        const l = self.line;
        const c = l[self.pos];
        switch (c) {
            ' ', '\t', '\r' => {
                while (self.peek(0)) |w| : (self.pos += 1) if (w != ' ' and w != '\t' and w != '\r') break;
                return .plain;
            },
            '/' => if (self.peek(1) == '/') {
                self.pos = l.len;
                return .comment;
            } else if (self.peek(1) == '*') {
                self.pos += 2;
                self.state.in_comment = true;
                return self.blockComment();
            },
            '"' => {
                self.pos += 1;
                while (self.pos < l.len) {
                    const s = l[self.pos];
                    self.pos = if (s == '\\') @min(l.len, self.pos + 2) else self.pos + 1;
                    if (s == '"') break;
                }
                // A string followed by ':' is a key.
                const rest = std.mem.trimStart(u8, l[self.pos..], " \t");
                return if (rest.len > 0 and rest[0] == ':') .property else .string;
            },
            '-', '0'...'9' => {
                self.pos += 1;
                while (self.peek(0)) |d| : (self.pos += 1) {
                    if (!(std.ascii.isDigit(d) or d == '.' or d == 'e' or d == 'E' or d == '+' or d == '-')) break;
                }
                return .number;
            },
            'a'...'z', 'A'...'Z' => {
                const word_start = self.pos;
                while (self.peek(0)) |w| : (self.pos += 1) if (!std.ascii.isAlphanumeric(w)) break;
                const word = l[word_start..self.pos];
                const is_constant = std.mem.eql(u8, word, "true") or std.mem.eql(u8, word, "false") or std.mem.eql(u8, word, "null");
                return if (is_constant) .constant else .plain;
            },
            else => {},
        }
        self.pos += 1;
        return .punctuation;
    }

    fn blockComment(self: *Lexer) Kind {
        if (std.mem.indexOfPos(u8, self.line, self.pos, "*/")) |end| {
            self.pos = end + 2;
            self.state.in_comment = false;
        } else self.pos = self.line.len;
        return .comment;
    }
};

test {
    _ = @import("../tests/json_test.zig");
}
