//! Markdown lexer for highlighting, one line at a time: headings, lists,
//! quotes, emphasis, inline code, links and fenced code blocks. Fences
//! tagged js/ts, json or css are highlighted in that language.
const std = @import("std");
const token = @import("token.zig");
const js = @import("js.zig");
const css = @import("css.zig");
const json = @import("json.zig");

const Kind = token.Kind;
const Span = token.Span;

pub const Fence = enum(u8) { none, code, js, css, json };

pub const State = struct {
    fence: Fence = .none,
    /// The fence's character (` or ~) and length; a closing fence matches.
    fence_char: u8 = '`',
    fence_len: u8 = 0,
    /// Embedded lexer states inside a fenced block.
    js: js.State = .{},
    css: css.State = .{},
    json: json.State = .{},
};

pub const Lexer = struct {
    line: []const u8,
    pos: usize = 0,
    state: State,
    started: bool = false,
    /// Highlight the rest of the line (after `prefix_end`) as one token.
    rest_kind: ?Kind = null,
    /// A block marker (`#`, `-`, `>`, fence) ending here, and its kind.
    prefix_end: usize = 0,
    prefix_kind: Kind = .punctuation,
    /// A link's "(url)" part, emitted after its "[text]".
    url: ?struct { start: usize, end: usize } = null,
    inner: ?union(enum) { js: js.Lexer, css: css.Lexer, json: json.Lexer } = null,

    pub fn init(line: []const u8, state: State) Lexer {
        return .{ .line = line, .state = state };
    }

    pub fn next(self: *Lexer) ?Span {
        if (!self.started) {
            self.started = true;
            self.startLine();
        }
        if (self.inner) |*in| {
            const span = switch (in.*) {
                inline else => |*l| l.next(),
            };
            if (span != null) return span;
            switch (in.*) {
                .js => |l| self.state.js = l.state,
                .css => |l| self.state.css = l.state,
                .json => |l| self.state.json = l.state,
            }
            self.inner = null;
            self.pos = self.line.len;
            return null;
        }
        if (self.pos >= self.line.len) return null;
        const start = self.pos;
        if (self.pos < self.prefix_end) {
            self.pos = self.prefix_end;
            return .{ .start = start, .end = self.pos, .kind = self.prefix_kind };
        }
        if (self.rest_kind) |k| {
            self.pos = self.line.len;
            return .{ .start = start, .end = self.pos, .kind = k };
        }
        const kind = self.inlineToken(); // advances pos: before reading it
        return .{ .start = start, .end = self.pos, .kind = kind };
    }

    /// Block-level syntax, decided by how the line starts.
    fn startLine(self: *Lexer) void {
        const l = self.line;
        var indent: usize = 0;
        while (indent < l.len and indent < 4 and l[indent] == ' ') indent += 1;
        const rest = l[indent..];

        if (self.state.fence != .none) {
            if (fenceLength(rest, self.state.fence_char) >= self.state.fence_len and
                std.mem.trim(u8, rest, " \t\r`~").len == 0)
            {
                self.state.fence = .none;
                self.rest_kind = .punctuation;
                return;
            }
            switch (self.state.fence) {
                .js => self.inner = .{ .js = .init(l, self.state.js) },
                .css => self.inner = .{ .css = .init(l, self.state.css, .scss) },
                .json => self.inner = .{ .json = .init(l, self.state.json) },
                else => self.rest_kind = .code,
            }
            return;
        }
        if (indent >= 4) return; // indented text: keep it simple, lex inline

        // ``` or ~~~ opens a fenced block; the info string names its language.
        for ("`~") |ch| {
            const n = fenceLength(rest, ch);
            if (n >= 3) {
                self.state = .{ .fence = fenceLanguage(std.mem.trim(u8, rest[n..], " \t\r")), .fence_char = ch, .fence_len = @intCast(@min(n, 255)) };
                self.prefix_end = indent + n;
                self.rest_kind = .keyword;
                return;
            }
        }
        if (rest.len == 0) return;
        switch (rest[0]) {
            '#' => {
                const hashes = std.mem.indexOfNone(u8, rest, "#") orelse rest.len;
                if (hashes <= 6 and (hashes == rest.len or rest[hashes] == ' ')) self.rest_kind = .heading;
            },
            '>' => {
                self.prefix_end = indent + 1;
                self.prefix_kind = .comment;
            },
            '-', '*', '+', '_', '=' => {
                if (isRule(rest)) {
                    self.rest_kind = .punctuation;
                } else if (rest[0] != '_' and rest[0] != '=' and rest.len > 1 and rest[1] == ' ') {
                    self.prefix_end = indent + 1; // bullet
                    self.prefix_kind = .keyword;
                }
            },
            '0'...'9' => {
                const digits = std.mem.indexOfNone(u8, rest, "0123456789") orelse rest.len;
                if (digits + 1 < rest.len and (rest[digits] == '.' or rest[digits] == ')') and rest[digits + 1] == ' ') {
                    self.prefix_end = indent + digits + 1; // "1."
                    self.prefix_kind = .keyword;
                }
            },
            else => {},
        }
    }

    fn inlineToken(self: *Lexer) Kind {
        const l = self.line;
        if (self.url) |u| if (u.start == self.pos) {
            self.pos = u.end;
            self.url = null;
            return .string;
        };
        const c = l[self.pos];
        switch (c) {
            '\\' => {
                self.pos = @min(l.len, self.pos + 2);
                return .plain;
            },
            '`' => {
                const n = fenceLength(l[self.pos..], '`');
                const marker = l[self.pos..][0..n];
                if (std.mem.indexOfPos(u8, l, self.pos + n, marker)) |end| {
                    self.pos = end + n;
                    return .code;
                }
                self.pos += n;
                return .plain;
            },
            '*', '_' => {
                // Underscores inside words (snake_case) aren't emphasis.
                const inside_word = c == '_' and self.pos > 0 and std.ascii.isAlphanumeric(l[self.pos - 1]);
                const run = fenceLength(l[self.pos..], c);
                const m = @min(run, 2);
                const marker = l[self.pos..][0..m];
                const opens = !inside_word and self.pos + m < l.len and l[self.pos + m] != ' ';
                if (opens) if (std.mem.indexOfPos(u8, l, self.pos + m + 1, marker)) |end| {
                    if (l[end - 1] != ' ') {
                        self.pos = end + m;
                        return .emphasis;
                    }
                };
                self.pos += run;
                return .plain;
            },
            '[', '!' => {
                const open = if (c == '!') self.pos + 1 else self.pos;
                if (open < l.len and l[open] == '[') if (std.mem.indexOfScalarPos(u8, l, open + 1, ']')) |close| {
                    if (close + 1 < l.len and l[close + 1] == '(') if (std.mem.indexOfScalarPos(u8, l, close + 2, ')')) |paren| {
                        self.url = .{ .start = close + 1, .end = paren + 1 };
                    };
                    self.pos = close + 1;
                    return .link;
                };
                self.pos += 1;
                return .plain;
            },
            '<' => {
                // Autolinks and inline HTML.
                if (std.mem.indexOfScalarPos(u8, l, self.pos + 1, '>')) |end| {
                    const inner = l[self.pos + 1 .. end];
                    if (inner.len > 0 and std.mem.indexOfScalar(u8, inner, ' ') == null or
                        (inner.len > 0 and std.ascii.isAlphabetic(inner[0])))
                    {
                        self.pos = end + 1;
                        return if (std.mem.indexOf(u8, inner, "://") != null or std.mem.indexOfScalar(u8, inner, '@') != null) .link else .tag;
                    }
                }
                self.pos += 1;
                return .plain;
            },
            else => {},
        }
        // Plain text up to the next character that may start something.
        const specials = "\\`*_[!<";
        self.pos += 1;
        while (self.pos < l.len) : (self.pos += 1) {
            const ch = l[self.pos];
            if (std.mem.indexOfScalar(u8, specials, ch) == null) continue;
            // snake_case: an underscore inside a word can't start emphasis.
            if (ch == '_' and std.ascii.isAlphanumeric(l[self.pos - 1])) continue;
            break;
        }
        return .plain;
    }
};

/// Number of `ch` characters `s` starts with.
fn fenceLength(s: []const u8, ch: u8) usize {
    return std.mem.indexOfNone(u8, s, &.{ch}) orelse s.len;
}

/// `---`, `***`, `___` (spaces allowed) or a setext `===` underline.
fn isRule(s: []const u8) bool {
    const t = std.mem.trimEnd(u8, s, " \t\r");
    if (t.len < 3) return false;
    var n: usize = 0;
    for (t) |b| {
        if (b == t[0]) n += 1 else if (b != ' ') return false;
    }
    return n >= 3;
}

fn fenceLanguage(info: []const u8) Fence {
    const word = info[0 .. std.mem.indexOfAny(u8, info, " \t{") orelse info.len];
    const table = [_]struct { []const u8, Fence }{
        .{ "js", .js },       .{ "javascript", .js }, .{ "jsx", .js },   .{ "ts", .js },
        .{ "typescript", .js }, .{ "tsx", .js },      .{ "mjs", .js },   .{ "json", .json },
        .{ "jsonc", .json },  .{ "css", .css },       .{ "scss", .css }, .{ "sass", .css },
        .{ "less", .css },
    };
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(word, entry[0])) return entry[1];
    }
    return .code;
}

test "blocks and inline" {
    const expect = token.expectTokens;
    _ = try expect(Lexer.init("## Title", .{}), "## Title", &.{"heading:## Title"});
    _ = try expect(Lexer.init("- a **b** `c` [d](http://e) snake_case", .{}), "- a **b** `c` [d](http://e) snake_case", &.{
        "keyword:-", "plain: a ", "emphasis:**b**", "code:`c`", "link:[d]", "string:(http://e)", "plain: snake_case",
    });
    _ = try expect(Lexer.init("> 1. *quote*", .{}), "> 1. *quote*", &.{ "comment:>", "plain: 1. ", "emphasis:*quote*" });
    _ = try expect(Lexer.init("---", .{}), "---", &.{"punctuation:---"});
}

test "fenced code is highlighted in its language" {
    const expect = token.expectTokens;
    const open = try expect(Lexer.init("```ts", .{}), "```ts", &.{ "punctuation:```", "keyword:ts" });
    try std.testing.expectEqual(Fence.js, open.state.fence);
    const body = try expect(Lexer.init("const x = 1;", open.state), "const x = 1;", &.{ "keyword:const", "plain:x", "punctuation:=", "number:1", "punctuation:;" });
    const close = try expect(Lexer.init("```", body.state), "```", &.{"punctuation:```"});
    try std.testing.expectEqual(Fence.none, close.state.fence);

    const other = try expect(Lexer.init("~~~text", .{}), "~~~text", &.{ "punctuation:~~~", "keyword:text" });
    _ = try expect(Lexer.init("# not a heading", other.state), "# not a heading", &.{"code:# not a heading"});
}
