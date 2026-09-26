//! Mistakes in a file. Its own checks run right here: brackets that don't
//! pair up, strings left open at the end of a line, JSON that doesn't
//! parse, and imports of files or packages that aren't there. The syntax
//! errors the language's own parser finds (see `lib/checkers.zig`) come in
//! later from a background run, through `setSyntax`. Both are rebuilt when
//! the buffer changes (the caller waits for typing to pause).
const std = @import("std");
const Io = std.Io;
const Buffer = @import("../buffer/Buffer.zig");
const Highlighter = @import("../syntax/Highlighter.zig");
const Completion = @import("../completion/Completion.zig");
const imports = @import("../completion/lib/imports.zig");
const tsconfig = @import("../completion/lib/tsconfig.zig");
pub const checkers = @import("lib/checkers.zig");

const Diagnostics = @This();

pub const max_items = 200;

pub const Kind = enum {
    /// An opening bracket never closed: `a` is the bracket.
    unclosed,
    /// A closing bracket with nothing open: `a` is the bracket.
    unexpected,
    /// A closing bracket for a different opening one: expected `a`, found `b`.
    mismatched,
    /// A string with no closing quote on its line.
    unterminated_string,
    /// An import naming a file or package that can't be found: `path`.
    missing_import,
    /// JSON that doesn't parse (at the first place it goes wrong).
    invalid_json,
    /// What the language's parser said: `message`.
    syntax,
};

pub const Item = struct {
    /// Byte range in the buffer to underline.
    start: usize,
    end: usize,
    kind: Kind,
    a: u8 = 0,
    b: u8 = 0,
    /// For `missing_import`; lives in the arena until the next update.
    path: []const u8 = "",
    /// For `syntax`, in the parser's words.
    message: []const u8 = "",
};

pub const Files = Completion.Files;

gpa: std.mem.Allocator,
/// Everything to show, by position: the own checks and, once the parser
/// has looked at this same version, its errors.
items: std.ArrayList(Item) = .empty,
/// The own checks' results, and the buffer version they're for (null to
/// check again).
arena: std.heap.ArenaAllocator,
own: std.ArrayList(Item) = .empty,
version: ?u64 = null,
/// The parser's results, the version it looked at, and the version it was
/// last asked about (so a failing run isn't repeated every frame).
syntax_arena: std.heap.ArenaAllocator,
syntax: std.ArrayList(Item) = .empty,
syntax_version: ?u64 = null,
syntax_asked: ?u64 = null,

pub fn init(gpa: std.mem.Allocator) Diagnostics {
    return .{ .gpa = gpa, .arena = .init(gpa), .syntax_arena = .init(gpa) };
}

pub fn deinit(self: *Diagnostics) void {
    self.items.deinit(self.gpa);
    self.arena.deinit();
    self.syntax_arena.deinit();
}

/// Forgets everything, so the file is checked again from scratch.
pub fn invalidate(self: *Diagnostics) void {
    self.version = null;
    self.syntax_asked = null;
}

/// Whether the items are for this version of the buffer.
pub fn isCurrent(self: *const Diagnostics, buf: *const Buffer) bool {
    return self.version == buf.version;
}

/// The first problem on the line starting at `line_start`, if any.
pub fn onLine(self: *const Diagnostics, buf: *const Buffer, line_start: usize) ?Item {
    const line_end = buf.lineEnd(line_start);
    for (self.items.items) |it| {
        if (it.start >= line_start and it.start <= line_end) return it;
    }
    return null;
}

pub const Options = struct {
    /// Locates the file on disk for the import checks.
    files: ?Files = null,
    /// Whether to look at brackets and strings; off when the language's
    /// parser is known to run, since it reports those better.
    structural: bool = true,
};

/// Runs the own checks on the buffer again.
pub fn update(self: *Diagnostics, gpa: std.mem.Allocator, buf: *const Buffer, hl: *Highlighter, options: Options) !void {
    defer self.merge() catch {};
    _ = self.arena.reset(.retain_capacity);
    self.own = .empty;
    self.version = buf.version;
    const files = options.files;
    const lang = hl.language;
    if (lang == .json) return self.checkJson(buf, files);
    const brackets = options.structural and checksBrackets(lang);
    const strings = options.structural and checksStrings(lang);
    if (!brackets and !strings and files == null) return;
    try hl.update(gpa, buf);

    const alloc = self.arena.allocator();
    var ctx: ImportCheck = .{ .alloc = alloc, .files = files, .language = lang };
    var stack: std.ArrayList(Open) = .empty;

    var lines = std.mem.splitScalar(u8, buf.items(), '\n');
    var index: usize = 0;
    var line_start: usize = 0;
    while (lines.next()) |line| : ({
        index += 1;
        line_start += line.len + 1;
    }) {
        if (self.own.items.len >= max_items) break;
        var tokens = hl.tokens(index, line);
        while (tokens.next()) |span| switch (span.kind) {
            .punctuation => if (brackets) for (span.start..span.end) |i| {
                try self.bracket(alloc, &stack, line[i], line_start + i);
            },
            .string => {
                const tok = line[span.start..span.end];
                if (strings and span.end == line.len and unterminated(tok, line)) {
                    try self.add(.{ .start = line_start + span.start, .end = line_start + span.end, .kind = .unterminated_string });
                } else if (files != null and tok.len >= 2 and tok[0] == tok[tok.len - 1]) {
                    if (try ctx.missing(line, span)) |path| try self.add(.{
                        .start = line_start + span.start + 1,
                        .end = line_start + span.end - 1,
                        .kind = .missing_import,
                        .path = path,
                    });
                }
            },
            else => {},
        };
    }
    for (stack.items) |o| try self.add(.{ .start = o.pos, .end = o.pos + 1, .kind = .unclosed, .a = o.char });
}

/// Takes the parser's findings for version `version` of the buffer.
/// Columns are bytes, or characters with `in_chars`.
pub fn setSyntax(self: *Diagnostics, buf: *const Buffer, version: u64, found: []const checkers.Found, in_chars: bool) !void {
    defer self.merge() catch {};
    _ = self.syntax_arena.reset(.retain_capacity);
    self.syntax = .empty;
    self.syntax_version = version;
    if (version != buf.version) return;
    const alloc = self.syntax_arena.allocator();
    const text = buf.items();

    // Where each line starts, to turn lines and columns into offsets.
    var starts: std.ArrayList(usize) = .empty;
    try starts.append(alloc, 0);
    for (text, 0..) |c, i| if (c == '\n') try starts.append(alloc, i + 1);

    for (found[0..@min(found.len, max_items)]) |f| {
        var start = offsetOf(text, starts.items, f.line, f.col, in_chars);
        var end = if (f.end_line > 0) offsetOf(text, starts.items, f.end_line, f.end_col, in_chars) else start;
        // A spot with no length: underline the word there, or at least one
        // character — the last one on the line if it's at the line's end.
        if (end <= start) {
            end = start;
            while (end < text.len and isWordChar(text[end])) end += 1;
            if (end == start) {
                if (start < text.len and text[start] != '\n') {
                    end = start + 1;
                } else if (start > 0 and text[start - 1] != '\n') {
                    start -= 1;
                    end = start + 1;
                } else end = start + 1;
            }
        }
        try self.syntax.append(alloc, .{
            .start = start,
            .end = @max(end, start + 1),
            .kind = .syntax,
            .message = try alloc.dupe(u8, f.message),
        });
    }
}

/// A problem a language server found, as a byte range of the text.
pub const Range = struct { start: usize, end: usize, message: []const u8 };

/// Takes a language server's findings for version `version` of the
/// buffer, in place of the parser's.
pub fn setRanges(self: *Diagnostics, buf: *const Buffer, version: u64, found: []const Range) !void {
    defer self.merge() catch {};
    _ = self.syntax_arena.reset(.retain_capacity);
    self.syntax = .empty;
    self.syntax_version = version;
    self.syntax_asked = version;
    if (version != buf.version) return;
    const alloc = self.syntax_arena.allocator();
    const len = buf.items().len;
    for (found[0..@min(found.len, max_items)]) |f| {
        var start = @min(f.start, len);
        // Nothing to underline at the very end: the last character.
        if (start == len and start > 0) start -= 1;
        try self.syntax.append(alloc, .{
            .start = start,
            .end = @max(@min(f.end, len), start + 1),
            .kind = .syntax,
            .message = try alloc.dupe(u8, f.message),
        });
    }
}

/// The byte offset of 1-based `line` and `col`.
fn offsetOf(text: []const u8, starts: []const usize, line: u32, col: u32, in_chars: bool) usize {
    if (line == 0) return 0;
    if (line > starts.len) return text.len;
    const line_start = starts[line - 1];
    const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
    var pos = line_start;
    var n: u32 = 1;
    while (n < col and pos < line_end) : (n += 1) {
        pos += if (in_chars) std.unicode.utf8ByteSequenceLength(text[pos]) catch 1 else 1;
    }
    return @min(pos, line_end);
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 0x80;
}

/// Rebuilds `items` from the own checks and, when it's about this same
/// text, the parser's. The parser's word on brackets and strings wins.
fn merge(self: *Diagnostics) !void {
    self.items.clearRetainingCapacity();
    const parsed = self.syntax_version != null and self.syntax_version == self.version;
    for (self.own.items) |it| {
        const structural = switch (it.kind) {
            .unclosed, .unexpected, .mismatched, .unterminated_string => true,
            else => false,
        };
        if (parsed and structural) continue;
        try self.items.append(self.gpa, it);
    }
    if (parsed) try self.items.appendSlice(self.gpa, self.syntax.items);
    std.mem.sort(Item, self.items.items, {}, byStart);
}

fn byStart(_: void, a: Item, b: Item) bool {
    return a.start < b.start;
}

fn add(self: *Diagnostics, item: Item) !void {
    if (self.own.items.len >= max_items) return;
    try self.own.append(self.arena.allocator(), item);
}

/// JSON is parsed right here. Config files that allow comments and
/// trailing commas (tsconfig.json, .jsonc, VS Code's settings) have them
/// blanked out first.
fn checkJson(self: *Diagnostics, buf: *const Buffer, files: ?Files) !void {
    const alloc = self.arena.allocator();
    var text = buf.items();
    if (allowsComments(if (files) |f| f.path else "")) text = try tsconfig.stripJsonc(alloc, text);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;
    var scanner: std.json.Scanner = .initCompleteInput(alloc, text);
    var diag: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);
    while (true) {
        const token = scanner.next() catch {
            const at: usize = @intCast(@min(diag.getByteOffset(), text.len));
            const start = if (at == text.len and at > 0) at - 1 else at;
            return self.add(.{ .start = start, .end = start + 1, .kind = .invalid_json });
        };
        if (token == .end_of_document) return;
    }
}

fn allowsComments(path: []const u8) bool {
    const name = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, name, ".jsonc") or std.mem.endsWith(u8, name, ".json5")) return true;
    for ([_][]const u8{ "tsconfig", "jsconfig", ".eslintrc", "devcontainer", ".babelrc" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    // VS Code and friends keep their settings as JSON with comments.
    return std.mem.indexOf(u8, path, "/.vscode/") != null or std.mem.indexOf(u8, path, "/.zed/") != null;
}

const Open = struct { char: u8, pos: usize };

fn bracket(self: *Diagnostics, alloc: std.mem.Allocator, stack: *std.ArrayList(Open), c: u8, pos: usize) !void {
    switch (c) {
        '(', '[', '{' => try stack.append(alloc, .{ .char = c, .pos = pos }),
        ')', ']', '}' => {
            const want = opener(c);
            if (stack.items.len > 0 and stack.items[stack.items.len - 1].char == want) {
                _ = stack.pop();
                return;
            }
            // Closes something further out: what's in between was left open.
            var i = stack.items.len;
            while (i > 0) : (i -= 1) if (stack.items[i - 1].char == want) break;
            if (i > 0) {
                for (stack.items[i..]) |o| try self.add(.{ .start = o.pos, .end = o.pos + 1, .kind = .unclosed, .a = o.char });
                stack.shrinkRetainingCapacity(i - 1);
            } else if (stack.items.len > 0) {
                const top = stack.items[stack.items.len - 1];
                try self.add(.{ .start = pos, .end = pos + 1, .kind = .mismatched, .a = closer(top.char), .b = c });
                // Take it as the closer meant, so the opener isn't reported too.
                _ = stack.pop();
            } else {
                try self.add(.{ .start = pos, .end = pos + 1, .kind = .unexpected, .a = c });
            }
        },
        else => {},
    }
}

fn opener(c: u8) u8 {
    return switch (c) {
        ')' => '(',
        ']' => '[',
        else => '{',
    };
}

fn closer(c: u8) u8 {
    return switch (c) {
        '(' => ')',
        '[' => ']',
        else => '}',
    };
}

/// Languages whose brackets must pair up. Markup, prose and config files
/// use them freely.
fn checksBrackets(lang: Highlighter.Language) bool {
    return lang.isJs() or lang.clikeDialect() != null or lang.genericDialect() != null or switch (lang) {
        .json, .css, .scss, .python => true,
        else => false,
    };
}

/// Languages where a `"` or `'` string ends on its own line.
fn checksStrings(lang: Highlighter.Language) bool {
    return lang.isJs() or lang.genericDialect() != null or switch (lang) {
        .json, .css, .scss, .python, .go, .zig => true,
        else => false,
    };
}

/// A quoted string token running to the end of its line without closing.
fn unterminated(tok: []const u8, line: []const u8) bool {
    if (tok.len == 0 or (tok[0] != '"' and tok[0] != '\'')) return false;
    // Triple quotes and a `\` at the end go on to the next line.
    if (tok.len >= 3 and tok[1] == tok[0] and tok[2] == tok[0]) return false;
    if (line.len > 0 and line[line.len - 1] == '\\') return false;
    if (tok.len < 2 or tok[tok.len - 1] != tok[0]) return true;
    // `"abc\"`: the last quote is escaped.
    var slashes: usize = 0;
    var i = tok.len - 1;
    while (i > 1 and tok[i - 1] == '\\') : (i -= 1) slashes += 1;
    return slashes % 2 == 1;
}

/// Resolves the path in an import string, the way the language would.
const ImportCheck = struct {
    alloc: std.mem.Allocator,
    files: ?Files,
    language: Highlighter.Language,
    /// Read on the first JS import that needs it.
    config: ?tsconfig.Config = null,
    has_node_modules: ?bool = null,

    /// The import path in the string token `span`, if it names nothing.
    fn missing(self: *ImportCheck, line: []const u8, span: anytype) !?[]const u8 {
        const files = self.files orelse return null;
        const ctx = imports.context(self.language, line[0 .. span.start + 1]) orelse return null;
        var path = line[span.start + 1 .. span.end - 1];
        // `./icon.svg?raw`, `./a#b`: the suffix is for the bundler.
        if (std.mem.indexOfAny(u8, path, "?#")) |i| path = path[0..i];
        if (path.len == 0) return null;
        const here = std.fs.path.dirname(files.path) orelse "/";
        const found = switch (ctx.style) {
            .js => try self.jsFound(files, here, path),
            .zig => if (std.mem.endsWith(u8, path, ".zig") or std.mem.endsWith(u8, path, ".zon")) try self.exists(files, &.{ here, path }) else true,
            .file => switch (self.language) {
                .zig => try self.exists(files, &.{ here, path }),
                .css, .scss => if (std.mem.startsWith(u8, path, "./") or std.mem.startsWith(u8, path, "../")) try self.styleFound(files, here, path) else true,
                else => true,
            },
            .python => true,
        };
        return if (found) null else try self.alloc.dupe(u8, path);
    }

    fn jsFound(self: *ImportCheck, files: Files, here: []const u8, path: []const u8) !bool {
        if (std.mem.startsWith(u8, path, ".")) return self.moduleFound(files, &.{ here, path });
        // URLs, `node:fs`, `virtual:…` and the like aren't files.
        if (std.mem.indexOfScalar(u8, path, ':') != null or path[0] == '/') return true;
        if (self.config == null) self.config = tsconfig.load(self.alloc, files.io, here);
        const config = self.config.?;
        for (config.aliases) |a| {
            if (a.wildcard and a.prefix.len > 0 and std.mem.startsWith(u8, path, a.prefix)) {
                return self.moduleFound(files, &.{ a.target, path[a.prefix.len..] });
            }
            if (!a.wildcard and std.mem.eql(u8, path, a.prefix)) return true;
        }
        if (config.aliases.len == 0 and (std.mem.startsWith(u8, path, "@/") or std.mem.startsWith(u8, path, "~/"))) {
            const root = files.root orelse return true;
            return self.moduleFound(files, &.{ root, "src", path[2..] });
        }
        if (config.base_url) |b| if (try self.moduleFound(files, &.{ b, path })) return true;
        return self.packageFound(files, here, path);
    }

    /// A package in some node_modules up the tree (or its @types). Without
    /// any node_modules the packages aren't installed yet: nothing to say.
    fn packageFound(self: *ImportCheck, files: Files, here: []const u8, path: []const u8) !bool {
        if (isNodeBuiltin(path)) return true;
        var name_end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
        if (path[0] == '@' and name_end < path.len) name_end = std.mem.indexOfScalarPos(u8, path, name_end + 1, '/') orelse path.len;
        const name = path[0..name_end];
        var any = false;
        var up: ?[]const u8 = here;
        while (up) |d| : (up = std.fs.path.dirname(d)) {
            if (!try self.isDir(files, &.{ d, "node_modules" })) continue;
            any = true;
            if (try self.exists(files, &.{ d, "node_modules", name })) return true;
            if (path[0] != '@' and try self.exists(files, &.{ d, "node_modules", "@types", name })) return true;
        }
        return !any;
    }

    /// A JS module: the file itself, with a script extension added (or a
    /// `.js` written for a `.ts`), or a folder with an index or package.json.
    fn moduleFound(self: *ImportCheck, files: Files, parts: []const []const u8) !bool {
        const base = try std.fs.path.resolve(self.alloc, parts);
        if (try self.isFile(files, &.{base})) return true;
        const exts = [_][]const u8{ ".ts", ".tsx", ".d.ts", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts", ".json", ".vue", ".svelte" };
        for (exts) |ext| if (try self.isFile(files, &.{try std.mem.concat(self.alloc, u8, &.{ base, ext })})) return true;
        inline for (.{ ".js", ".jsx", ".mjs", ".cjs" }, .{ ".ts", ".tsx", ".mts", ".cts" }) |js_ext, ts_ext| {
            if (std.mem.endsWith(u8, base, js_ext)) {
                const stem = base[0 .. base.len - js_ext.len];
                if (try self.isFile(files, &.{try std.mem.concat(self.alloc, u8, &.{ stem, ts_ext })})) return true;
            }
        }
        if (try self.isDir(files, &.{base})) {
            if (try self.isFile(files, &.{ base, "package.json" })) return true;
            for (exts[0..6]) |ext| if (try self.isFile(files, &.{ base, try std.mem.concat(self.alloc, u8, &.{ "index", ext }) })) return true;
        }
        return false;
    }

    /// A stylesheet: as written, or Sass's `_partial` and extension forms.
    fn styleFound(self: *ImportCheck, files: Files, here: []const u8, path: []const u8) !bool {
        const full = try std.fs.path.resolve(self.alloc, &.{ here, path });
        if (try self.isFile(files, &.{full})) return true;
        const dir = std.fs.path.dirname(full) orelse "/";
        const name = std.fs.path.basename(full);
        for ([_][]const u8{ "", "_" }) |pre| for ([_][]const u8{ ".scss", ".sass", ".css", ".less" }) |ext| {
            if (try self.isFile(files, &.{ dir, try std.mem.concat(self.alloc, u8, &.{ pre, name, ext }) })) return true;
        };
        for ([_][]const u8{ "_index.scss", "index.scss", "_index.sass" }) |index| {
            if (try self.isFile(files, &.{ full, index })) return true;
        }
        return false;
    }

    fn exists(self: *ImportCheck, files: Files, parts: []const []const u8) !bool {
        return (try self.stat(files, parts)) != null;
    }

    fn isFile(self: *ImportCheck, files: Files, parts: []const []const u8) !bool {
        const kind = (try self.stat(files, parts)) orelse return false;
        return kind != .directory;
    }

    fn isDir(self: *ImportCheck, files: Files, parts: []const []const u8) !bool {
        return (try self.stat(files, parts)) == .directory;
    }

    fn stat(self: *ImportCheck, files: Files, parts: []const []const u8) !?Io.File.Kind {
        const path = try std.fs.path.join(self.alloc, parts);
        const st = Io.Dir.cwd().statFile(files.io, path, .{}) catch return null;
        return st.kind;
    }
};

fn isNodeBuiltin(path: []const u8) bool {
    const name = path[0 .. std.mem.indexOfScalar(u8, path, '/') orelse path.len];
    const builtins = [_][]const u8{
        "assert",         "async_hooks", "buffer",    "child_process", "cluster",        "console", "constants",
        "crypto",         "dgram",       "dns",       "domain",        "events",         "fs",      "http",
        "http2",          "https",       "inspector", "module",        "net",            "os",      "path",
        "perf_hooks",     "process",     "punycode",  "querystring",   "readline",       "repl",    "stream",
        "string_decoder", "sys",         "timers",    "tls",           "trace_events",   "tty",     "url",
        "util",           "v8",          "vm",        "wasi",          "worker_threads", "zlib",    "bun",
    };
    for (builtins) |b| if (std.mem.eql(u8, name, b)) return true;
    return false;
}

test {
    _ = @import("tests/Diagnostics_test.zig");
}
