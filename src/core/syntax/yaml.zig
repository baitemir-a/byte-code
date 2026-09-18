//! YAML lexer for highlighting, one line at a time. Its `yarn` mode handles
//! yarn.lock, whose entries use `key value` without a colon.
const std = @import("std");
const token = @import("token.zig");

const Kind = token.Kind;
const Span = token.Span;

pub const State = struct {
    /// Inside a block scalar (`key: |` or `key: >`): lines indented more
    /// than this belong to it. -1 when not in one.
    block_indent: i32 = -1,
};

pub const Lexer = struct {
    line: []const u8,
    pos: usize = 0,
    state: State,
    yarn: bool,
    started: bool = false,
    /// The whole line is block scalar text.
    in_block: bool = false,
    /// Leading spaces of the line.
    indent: usize = 0,
    /// A key may start here: first thing on the line, or after a `- `.
    key_position: bool = true,
    /// Nesting of flow collections (`[...]`, `{...}`) on this line.
    flow_depth: u8 = 0,

    pub fn init(line: []const u8, state: State, yarn: bool) Lexer {
        return .{ .line = line, .state = state, .yarn = yarn };
    }

    pub fn next(self: *Lexer) ?Span {
        if (!self.started) {
            self.started = true;
            self.startLine();
        }
        if (self.pos >= self.line.len) return null;
        const start = self.pos;
        const kind = if (self.in_block) blk: {
            self.pos = self.line.len;
            break :blk Kind.string;
        } else self.code();
        return .{ .start = start, .end = self.pos, .kind = kind };
    }

    fn startLine(self: *Lexer) void {
        const l = self.line;
        while (self.indent < l.len and l[self.indent] == ' ') self.indent += 1;
        if (self.state.block_indent < 0) return;
        const blank = std.mem.trim(u8, l, " \t\r").len == 0;
        if (blank or @as(i32, @intCast(self.indent)) > self.state.block_indent) {
            self.in_block = true;
        } else {
            self.state.block_indent = -1;
        }
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
        if (c == '#' and (self.pos == 0 or l[self.pos - 1] == ' ' or l[self.pos - 1] == '\t')) {
            self.pos = l.len;
            return .comment;
        }
        // Document markers.
        if (self.pos == 0 and (std.mem.startsWith(u8, l, "---") or std.mem.startsWith(u8, l, "..."))) {
            self.pos = 3;
            return .punctuation;
        }
        if (self.key_position) {
            // List item: "- " keeps the key position for "- key: value".
            if (c == '-' and (self.peek(1) == null or self.peek(1) == ' ')) {
                self.pos += 1;
                return .punctuation;
            }
            self.key_position = false;
            if (self.keyEnd()) |end| {
                self.pos = end;
                return .property;
            }
        }
        switch (c) {
            ':' => {
                self.pos += 1;
                return .punctuation;
            },
            '"', '\'' => return self.string(c),
            '&', '*' => if (self.peek(1)) |n| if (std.ascii.isAlphanumeric(n)) {
                self.pos += 1;
                while (self.peek(0)) |w| : (self.pos += 1) if (w == ' ' or w == ',' or w == ']' or w == '}') break;
                return .constant; // &anchor, *alias
            },
            '!' => {
                while (self.peek(0)) |w| : (self.pos += 1) if (w == ' ') break;
                return .keyword; // !!str, !Ref
            },
            '|', '>' => if (self.blockScalarHeader()) {
                self.state.block_indent = @intCast(self.indent);
                self.pos = l.len - std.mem.trimStart(u8, l[self.pos..], "|>-+0123456789").len;
                return .punctuation;
            },
            '[', '{' => {
                self.flow_depth +|= 1;
                self.pos += 1;
                return .punctuation;
            },
            ']', '}', ',' => {
                if (c != ',') self.flow_depth -|= 1;
                self.pos += 1;
                return .punctuation;
            },
            else => {},
        }
        return self.scalar();
    }

    /// End of a mapping key starting at `pos`: text up to a `:` followed by
    /// a space or the line end (not inside quotes). In yarn mode a line
    /// without such a colon starts with its key anyway (`version "1.0"`).
    fn keyEnd(self: *const Lexer) ?usize {
        const l = self.line;
        var i = self.pos;
        var quote: u8 = 0;
        while (i < l.len) : (i += 1) {
            const c = l[i];
            if (quote != 0) {
                if (c == quote) quote = 0;
                continue;
            }
            switch (c) {
                '"', '\'' => quote = c,
                '#' => if (i > 0 and l[i - 1] == ' ') break,
                ':' => if (i + 1 == l.len or l[i + 1] == ' ' or l[i + 1] == '\r') return if (i > self.pos) i else null,
                else => {},
            }
        }
        if (!self.yarn) return null;
        // yarn: the first word or quoted string.
        if (l[self.pos] == '"') return if (std.mem.indexOfScalarPos(u8, l, self.pos + 1, '"')) |q| q + 1 else l.len;
        return std.mem.indexOfScalarPos(u8, l, self.pos, ' ') orelse l.len;
    }

    /// `|`, `>`, `|-`, `>+2`... followed by nothing but a comment.
    fn blockScalarHeader(self: *const Lexer) bool {
        const rest = std.mem.trimStart(u8, self.line[self.pos + 1 ..], "-+0123456789");
        const after = std.mem.trim(u8, rest, " \t\r");
        return after.len == 0 or after[0] == '#';
    }

    fn string(self: *Lexer, q: u8) Kind {
        const l = self.line;
        self.pos += 1;
        while (self.pos < l.len) {
            const s = l[self.pos];
            self.pos = if (s == '\\' and q == '"') @min(l.len, self.pos + 2) else self.pos + 1;
            if (s == q) break;
        }
        return .string;
    }

    /// A plain value up to a comment, the line end, or (in flow) a separator.
    fn scalar(self: *Lexer) Kind {
        const l = self.line;
        const start = self.pos;
        while (self.pos < l.len) : (self.pos += 1) {
            const c = l[self.pos];
            if (c == '#' and l[self.pos - 1] == ' ') break;
            if (self.flow_depth > 0 and (c == ',' or c == ']' or c == '}')) break;
        }
        // Don't swallow the spaces before a comment.
        while (self.pos > start + 1 and l[self.pos - 1] == ' ') self.pos -= 1;
        const word = std.mem.trimEnd(u8, l[start..self.pos], "\r");
        const constants = [_][]const u8{ "true", "false", "null", "yes", "no", "on", "off", "~", "True", "False", "Null", "TRUE", "FALSE", "NULL" };
        for (constants) |k| {
            if (std.mem.eql(u8, word, k)) return .constant;
        }
        if (isNumber(word)) return .number;
        return .string;
    }
};

fn isNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    const body = if (s[0] == '-' or s[0] == '+') s[1..] else s;
    if (body.len == 0 or !std.ascii.isDigit(body[0])) return false;
    for (body) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_')) return false;
    }
    return true;
}

test "mappings, lists, scalars" {
    const expect = token.expectTokens;
    _ = try expect(Lexer.init("name: web # svc", .{}, false), "name: web # svc", &.{ "property:name", "punctuation::", "string:web", "comment:# svc" });
    _ = try expect(Lexer.init("  - port: 8080", .{}, false), "  - port: 8080", &.{ "punctuation:-", "property:port", "punctuation::", "number:8080" });
    _ = try expect(Lexer.init("- \"x\"", .{}, false), "- \"x\"", &.{ "punctuation:-", "string:\"x\"" });
    _ = try expect(Lexer.init("url: http://a.io", .{}, false), "url: http://a.io", &.{ "property:url", "punctuation::", "string:http://a.io" });
    _ = try expect(Lexer.init("tags: [a, true, 3]", .{}, false), "tags: [a, true, 3]", &.{
        "property:tags", "punctuation::", "punctuation:[", "string:a", "punctuation:,", "constant:true", "punctuation:,", "number:3", "punctuation:]",
    });
    _ = try expect(Lexer.init("base: &b !!map", .{}, false), "base: &b !!map", &.{ "property:base", "punctuation::", "constant:&b", "keyword:!!map" });
}

test "block scalars span lines" {
    const expect = token.expectTokens;
    const a = try expect(Lexer.init("run: |", .{}, false), "run: |", &.{ "property:run", "punctuation::", "punctuation:|" });
    const b = try expect(Lexer.init("  echo: hi", a.state, false), "  echo: hi", &.{"string:  echo: hi"});
    const c = try expect(Lexer.init("next: 1", b.state, false), "next: 1", &.{ "property:next", "punctuation::", "number:1" });
    try std.testing.expectEqual(@as(i32, -1), c.state.block_indent);
}

test "yarn.lock" {
    const expect = token.expectTokens;
    _ = try expect(Lexer.init("\"@babel/core@^7.0.0\", \"@babel/core@^7.1\":", .{}, true), "\"@babel/core@^7.0.0\", \"@babel/core@^7.1\":", &.{
        "property:\"@babel/core@^7.0.0\", \"@babel/core@^7.1\"", "punctuation::",
    });
    _ = try expect(Lexer.init("  version \"7.2.0\"", .{}, true), "  version \"7.2.0\"", &.{ "property:version", "string:\"7.2.0\"" });
    _ = try expect(Lexer.init("    \"@babel/types\" \"^7.0.0\"", .{}, true), "    \"@babel/types\" \"^7.0.0\"", &.{ "property:\"@babel/types\"", "string:\"^7.0.0\"" });
    _ = try expect(Lexer.init("  integrity sha512-abc==", .{}, true), "  integrity sha512-abc==", &.{ "property:integrity", "string:sha512-abc==" });
}
