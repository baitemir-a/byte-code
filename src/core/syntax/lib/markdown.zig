//! Markdown lexer for highlighting, one line at a time: headings, lists,
//! quotes, emphasis, inline code, links and fenced code blocks. Fences
//! tagged with a language the editor highlights are highlighted in it.
const std = @import("std");
const token = @import("token.zig");
const js = @import("js.zig");
const css = @import("css.zig");
const json = @import("json.zig");
const python = @import("python.zig");
const clike = @import("clike.zig");
const generic = @import("generic.zig");
const config = @import("config.zig");

const Kind = token.Kind;
const Span = token.Span;

pub const Fence = enum(u8) { none, code, js, css, json, python, clike, generic, diff };

pub const State = struct {
    fence: Fence = .none,
    /// The fence's character (` or ~) and length; a closing fence matches.
    fence_char: u8 = '`',
    fence_len: u8 = 0,
    /// Embedded lexer states inside a fenced block.
    js: js.State = .{},
    css: css.State = .{},
    json: json.State = .{},
    python: python.State = .{},
    clike: clike.State = .{},
    clike_dialect: clike.Dialect = .go,
    generic: generic.State = .{},
    generic_dialect: generic.Dialect = .c,
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
    inner: ?union(enum) {
        js: js.Lexer,
        css: css.Lexer,
        json: json.Lexer,
        python: python.Lexer,
        clike: clike.Lexer,
        generic: generic.Lexer,
        diff: config.DiffLexer,
    } = null,

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
                .python => |l| self.state.python = l.state,
                .clike => |l| self.state.clike = l.state,
                .generic => |l| self.state.generic = l.state,
                .diff => {},
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
                .python => self.inner = .{ .python = .init(l, self.state.python) },
                .clike => self.inner = .{ .clike = .init(l, self.state.clike, self.state.clike_dialect) },
                .generic => self.inner = .{ .generic = .init(l, self.state.generic, self.state.generic_dialect) },
                .diff => self.inner = .{ .diff = .init(l) },
                else => self.rest_kind = .code,
            }
            return;
        }
        if (indent >= 4) return; // indented text: keep it simple, lex inline

        // ``` or ~~~ opens a fenced block; the info string names its language.
        for ("`~") |ch| {
            const n = fenceLength(rest, ch);
            if (n >= 3) {
                self.state = fenceState(std.mem.trim(u8, rest[n..], " \t\r"));
                self.state.fence_char = ch;
                self.state.fence_len = @intCast(@min(n, 255));
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

/// The state for a fenced block whose info string is `info`: the lexer
/// for its language, if there's one.
fn fenceState(info: []const u8) State {
    var word = info[0 .. std.mem.indexOfAny(u8, info, " \t{") orelse info.len];
    var buf: [32]u8 = undefined;
    if (word.len <= buf.len) word = std.ascii.lowerString(buf[0..word.len], word);
    const simple = [_]struct { []const u8, Fence }{
        .{ "js", .js },         .{ "javascript", .js }, .{ "jsx", .js },    .{ "ts", .js },
        .{ "typescript", .js }, .{ "tsx", .js },        .{ "mjs", .js },    .{ "json", .json },
        .{ "jsonc", .json },    .{ "css", .css },       .{ "scss", .css },  .{ "sass", .css },
        .{ "less", .css },      .{ "python", .python }, .{ "py", .python }, .{ "diff", .diff },
        .{ "patch", .diff },
    };
    for (simple) |entry| {
        if (std.mem.eql(u8, word, entry[0])) return .{ .fence = entry[1] };
    }
    const c_family = [_]struct { []const u8, clike.Dialect }{
        .{ "go", .go }, .{ "golang", .go }, .{ "rust", .rust }, .{ "rs", .rust }, .{ "zig", .zig },
    };
    for (c_family) |entry| {
        if (std.mem.eql(u8, word, entry[0])) return .{ .fence = .clike, .clike_dialect = entry[1] };
    }
    const aliases = [_]struct { []const u8, generic.Dialect }{
        .{ "c++", .cpp },         .{ "cc", .cpp },            .{ "hpp", .cpp },             .{ "objective-c", .objc },
        .{ "cs", .csharp },       .{ "c#", .csharp },         .{ "kt", .kotlin },           .{ "sol", .solidity },
        .{ "glsl", .shader },     .{ "hlsl", .shader },       .{ "metal", .shader },        .{ "proto", .protobuf },
        .{ "gql", .graphql },     .{ "sh", .shell },          .{ "bash", .shell },          .{ "zsh", .shell },
        .{ "console", .shell },   .{ "shellscript", .shell }, .{ "ps1", .powershell },      .{ "pwsh", .powershell },
        .{ "bat", .batch },       .{ "cmd", .batch },         .{ "rb", .ruby },             .{ "pl", .perl },
        .{ "jl", .julia },        .{ "ex", .elixir },         .{ "exs", .elixir },          .{ "erl", .erlang },
        .{ "cr", .crystal },      .{ "gd", .gdscript },       .{ "coffee", .coffeescript }, .{ "hs", .haskell },
        .{ "ml", .ocaml },        .{ "fs", .fsharp },         .{ "f#", .fsharp },           .{ "elisp", .lisp },
        .{ "emacs-lisp", .lisp }, .{ "scheme", .lisp },       .{ "racket", .lisp },         .{ "clj", .clojure },
        .{ "make", .makefile },   .{ "docker", .dockerfile }, .{ "terraform", .hcl },       .{ "tf", .hcl },
        .{ "delphi", .pascal },   .{ "vbnet", .vb },          .{ "asm", .assembly },        .{ "nasm", .assembly },
        .{ "latex", .tex },       .{ "postgres", .sql },      .{ "mysql", .sql },           .{ "sqlite", .sql },
    };
    for (aliases) |entry| {
        if (std.mem.eql(u8, word, entry[0])) return .{ .fence = .generic, .generic_dialect = entry[1] };
    }
    if (std.meta.stringToEnum(generic.Dialect, word)) |d| return .{ .fence = .generic, .generic_dialect = d };
    return .{ .fence = .code };
}

test {
    _ = @import("../tests/markdown_test.zig");
}
