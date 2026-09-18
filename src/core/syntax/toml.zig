//! TOML lexer for highlighting, one line at a time; also good enough for
//! INI-style files (.ini, .cfg, .editorconfig, .npmrc). Also used for
//! Cargo.lock, poetry.lock and uv.lock.
const std = @import("std");
const token = @import("token.zig");

const Kind = token.Kind;
const Span = token.Span;

pub const State = struct {
    /// Quote of an open multi-line string (""" or '''), or 0.
    triple: u8 = 0,
    /// Nesting of an array that continues onto the next line.
    array_depth: u8 = 0,
};

pub const Lexer = struct {
    line: []const u8,
    pos: usize = 0,
    state: State,
    /// A key comes next (line start, or inside an inline table after `{`/`,`).
    expect_key: bool,
    /// Nesting of `{ ... }` inline tables on this line.
    table_depth: u8 = 0,

    pub fn init(line: []const u8, state: State) Lexer {
        return .{ .line = line, .state = state, .expect_key = state.array_depth == 0 and state.triple == 0 };
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
        const first_on_line = std.mem.trim(u8, l[0..self.pos], " \t").len == 0;
        // `#` comments; INI files also use `;` at the start of a line.
        if (c == '#' or (c == ';' and first_on_line)) {
            self.pos = l.len;
            return .comment;
        }
        if (self.expect_key) {
            // [table] / [[array of tables]] headers.
            if (c == '[' and first_on_line and self.state.array_depth == 0) {
                self.pos = if (std.mem.lastIndexOfScalar(u8, l, ']')) |e| e + 1 else l.len;
                return .tag;
            }
            switch (c) {
                '"', '\'' => {
                    _ = self.string(c);
                    return .property;
                },
                '=', ':' => {
                    self.pos += 1;
                    self.expect_key = false;
                    return .punctuation;
                },
                else => if (isKeyChar(c)) {
                    while (self.peek(0)) |w| : (self.pos += 1) if (!isKeyChar(w)) break;
                    return .property;
                },
            }
            self.pos += 1;
            return .punctuation;
        }
        switch (c) {
            '"', '\'' => return self.string(c),
            '[' => self.state.array_depth +|= 1,
            ']' => self.state.array_depth -|= 1,
            '{' => {
                self.table_depth +|= 1;
                self.expect_key = true;
            },
            '}' => self.table_depth -|= 1,
            ',' => if (self.table_depth > 0) {
                self.expect_key = true;
            },
            else => if (std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.' or c == '_') {
                // Numbers, dates (1979-05-27T07:32:00Z), booleans and bare INI values.
                const start = self.pos;
                while (self.peek(0)) |w| : (self.pos += 1) {
                    if (!(std.ascii.isAlphanumeric(w) or w == '+' or w == '-' or w == '.' or w == '_' or w == ':')) break;
                }
                const word = l[start..self.pos];
                if (eqlAny(word, &.{ "true", "false", "inf", "nan", "+inf", "-inf" })) return .constant;
                if (std.ascii.isDigit(word[0]) or ((word[0] == '+' or word[0] == '-') and word.len > 1 and std.ascii.isDigit(word[1]))) return .number;
                return .plain;
            },
        }
        self.pos += 1;
        return .punctuation;
    }

    fn string(self: *Lexer, q: u8) Kind {
        const l = self.line;
        if (std.mem.startsWith(u8, l[self.pos..], &.{ q, q, q })) {
            self.pos += 3;
            self.state.triple = q;
            return self.tripleRest();
        }
        self.pos += 1;
        while (self.pos < l.len) {
            const s = l[self.pos];
            // Literal ('...') strings have no escapes.
            self.pos = if (s == '\\' and q == '"') @min(l.len, self.pos + 2) else self.pos + 1;
            if (s == q) break;
        }
        return .string;
    }

    fn tripleRest(self: *Lexer) Kind {
        const l = self.line;
        const q = self.state.triple;
        while (self.pos < l.len) {
            if (l[self.pos] == '\\' and q == '"') {
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
};

fn isKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c >= 0x80;
}

fn eqlAny(word: []const u8, options: []const []const u8) bool {
    for (options) |o| {
        if (std.mem.eql(u8, word, o)) return true;
    }
    return false;
}

test "tables, keys, values" {
    const expect = token.expectTokens;
    _ = try expect(Lexer.init("[[package]]", .{}), "[[package]]", &.{"tag:[[package]]"});
    _ = try expect(Lexer.init("name = \"serde\" # lib", .{}), "name = \"serde\" # lib", &.{ "property:name", "punctuation:=", "string:\"serde\"", "comment:# lib" });
    _ = try expect(Lexer.init("opt = { version = 1.2, default-features = false }", .{}), "opt = { version = 1.2, default-features = false }", &.{
        "property:opt", "punctuation:=", "punctuation:{", "property:version", "punctuation:=", "number:1.2", "punctuation:,",
        "property:default-features", "punctuation:=", "constant:false", "punctuation:}",
    });
    _ = try expect(Lexer.init("; ini comment", .{}), "; ini comment", &.{"comment:; ini comment"});
}

test "multi-line arrays and strings" {
    const expect = token.expectTokens;
    const lx = try expect(Lexer.init("deps = [", .{}), "deps = [", &.{ "property:deps", "punctuation:=", "punctuation:[" });
    const lx2 = try expect(Lexer.init("  \"a\", 2024-01-02,", lx.state), "  \"a\", 2024-01-02,", &.{ "string:\"a\"", "punctuation:,", "number:2024-01-02", "punctuation:," });
    const lx3 = try expect(Lexer.init("]", lx2.state), "]", &.{"punctuation:]"});
    try std.testing.expectEqual(@as(u8, 0), lx3.state.array_depth);
    const s = try expect(Lexer.init("text = '''raw", .{}), "text = '''raw", &.{ "property:text", "punctuation:=", "string:'''raw" });
    try std.testing.expectEqual(@as(u8, '\''), s.state.triple);
}
