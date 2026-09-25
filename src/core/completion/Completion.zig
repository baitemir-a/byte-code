//! Autocompletion session: the word being typed, the ranked suggestions for
//! it (document words, JS/TS keywords, well-known globals, or files and
//! packages inside an import path), and which one is selected. Closed most
//! of the time.
const std = @import("std");
const Io = std.Io;
const Buffer = @import("../buffer/Buffer.zig");
const Highlighter = @import("../syntax/Highlighter.zig");
const js = @import("../syntax/lib/js.zig");
const clike = @import("../syntax/lib/clike.zig");
const generic = @import("../syntax/lib/generic.zig");
const Index = @import("Index.zig");
const builtins = @import("lib/builtins.zig");
const fuzzy = @import("lib/fuzzy.zig");
const imports = @import("lib/imports.zig");
const tsconfig = @import("lib/tsconfig.zig");
const token = @import("../syntax/lib/token.zig");

const Completion = @This();

pub const max_items = 100;

pub const ItemKind = enum { keyword, type, function, variable, member, file, folder, module };

/// Where the edited file lives, for suggesting paths in its imports.
pub const Files = struct {
    io: Io,
    /// The file's absolute path.
    path: []const u8,
    /// The project folder, for `/`-rooted paths and Python's absolute imports.
    root: ?[]const u8 = null,
};

pub const Item = struct {
    /// Points into static tables or the index; valid until the next refresh.
    label: []const u8,
    kind: ItemKind,
    score: i32,
    /// Matched character positions, for highlighting (see `fuzzy.Match`).
    matches: u64,
    /// Source priority for equal scores: lower comes first.
    rank: u8,
    /// Order added; keeps built-in lists in their curated order.
    seq: u32,
};

gpa: std.mem.Allocator,
index: Index,
items: std.ArrayList(Item) = .empty,
/// Labels already added during a refresh, to drop duplicates.
seen: std.StringHashMapUnmanaged(void) = .empty,
is_open: bool = false,
selected: usize = 0,
/// Byte offset where the word being completed starts.
word_start: usize = 0,
/// Suggesting a path inside an import string rather than a word.
path_mode: bool = false,
/// Set by `accept` when it inserted a folder: its contents come next.
reopen: bool = false,
/// File names read for path suggestions; reset by each refresh.
names: std.heap.ArenaAllocator,

pub fn init(gpa: std.mem.Allocator) Completion {
    return .{ .gpa = gpa, .index = .init(gpa), .names = .init(gpa) };
}

pub fn deinit(self: *Completion) void {
    self.items.deinit(self.gpa);
    self.seen.deinit(self.gpa);
    self.index.deinit();
    self.names.deinit();
}

pub fn close(self: *Completion) void {
    self.is_open = false;
    self.items.clearRetainingCapacity();
}

pub fn selectedItem(self: *const Completion) ?Item {
    if (!self.is_open or self.items.items.len == 0) return null;
    return self.items.items[self.selected];
}

/// Moves the selection, wrapping around at either end.
pub fn moveSelection(self: *Completion, delta: isize) void {
    const n: isize = @intCast(self.items.items.len);
    if (n == 0) return;
    self.selected = @intCast(@mod(@as(isize, @intCast(self.selected)) + delta, n));
}

/// Recomputes suggestions for the word at the cursor. With `explicit`
/// (Ctrl+Space) it also opens on an empty word; otherwise an empty word only
/// opens right after a `.`. Inside an import path it suggests the files,
/// folders and packages it can name, found through `files`.
pub fn refresh(self: *Completion, buf: *const Buffer, hl: *Highlighter, explicit: bool, files: ?Files) !void {
    if (buf.selection() != null) return self.close();
    if (files) |f| if (try self.refreshImport(buf, hl, f)) return;

    var start = buf.cursor;
    while (start > 0 and js.isIdentChar(buf.items()[start - 1])) start -= 1;
    const word = buf.items()[start..buf.cursor];
    // Member access is a code thing; in plain text a '.' ends a sentence.
    const code = hl.language.isJs() or hl.language == .python or hl.language.clikeDialect() != null or hl.language.genericDialect() != null;
    const after_dot = code and buf.byteBefore(start) == '.';

    if (word.len > 0 and std.ascii.isDigit(word[0])) return self.close();
    if (word.len == 0 and !explicit and !after_dot) return self.close();
    try hl.update(self.gpa, buf);
    if (inStringOrComment(buf, hl, start)) return self.close();

    var keep_buf: [128]u8 = undefined;
    const keep = self.keepSelected(&keep_buf);

    try self.index.update(self.gpa, buf, hl);
    self.items.clearRetainingCapacity();
    self.seen.clearRetainingCapacity();
    self.word_start = start;
    self.path_mode = false;

    if (after_dot) {
        if (hl.language.isJs()) for (builtins.membersOf(objectBefore(buf, start))) |l| try self.consider(l, .member, word, 0);
        for (self.index.words.keys(), self.index.words.values()) |l, w| {
            if (w.as_member) try self.consider(l, if (w.called) .function else .member, word, 1);
        }
        if (hl.language.isJs()) for (builtins.common_members) |l| try self.consider(l, .function, word, 2);
    } else {
        for (self.index.words.keys(), self.index.words.values()) |l, w| {
            if (!w.as_name) continue;
            const kind: ItemKind = if (w.called) .function else if (w.is_type) .type else .variable;
            try self.consider(l, kind, word, 0);
        }
        if (hl.language.isJs()) {
            for (builtins.keywords) |l| try self.consider(l, .keyword, word, 1);
            for (builtins.globals) |l| try self.consider(l, if (std.ascii.isUpper(l[0])) .type else .variable, word, 2);
            for (builtins.types) |l| try self.consider(l, .type, word, 3);
        } else if (hl.language.clikeDialect()) |dialect| {
            const words = clike.wordsFor(dialect);
            for (words.keyword_list) |l| try self.consider(l, .keyword, word, 1);
            for (words.constant_list) |l| try self.consider(l, .keyword, word, 1);
            for (words.type_list) |l| try self.consider(l, .type, word, 3);
        } else if (hl.language.genericDialect()) |dialect| {
            const spec = &generic.language(dialect).spec;
            for (spec.keywords) |l| try self.consider(l, .keyword, word, 1);
            for (spec.constants) |l| try self.consider(l, .keyword, word, 1);
            for (spec.builtins) |l| try self.consider(l, .function, word, 2);
            for (spec.types) |l| try self.consider(l, .type, word, 3);
        } else if (hl.language == .python) {
            for (builtins.python_keywords) |l| try self.consider(l, .keyword, word, 1);
            for (builtins.python_functions) |l| try self.consider(l, .function, word, 2);
            for (builtins.python_types) |l| try self.consider(l, .type, word, 3);
        }
    }

    self.finish(word.len > 0, keep);
}

/// Copies the selected label so it stays selected as the list re-sorts.
fn keepSelected(self: *const Completion, keep_buf: *[128]u8) ?[]const u8 {
    const it = self.selectedItem() orelse return null;
    if (it.label.len > keep_buf.len) return null;
    @memcpy(keep_buf[0..it.label.len], it.label);
    return keep_buf[0..it.label.len];
}

/// Sorts and trims the gathered items and opens the list, if any.
fn finish(self: *Completion, has_query: bool, keep: ?[]const u8) void {
    if (self.items.items.len == 0) return self.close();
    std.mem.sort(Item, self.items.items, has_query, better);
    if (self.items.items.len > max_items) self.items.shrinkRetainingCapacity(max_items);

    self.selected = 0;
    if (keep) |k| for (self.items.items, 0..) |it, i| {
        if (std.mem.eql(u8, it.label, k)) self.selected = i;
    };
    self.is_open = true;
}

/// Suggestions for an import path at the cursor. Returns false when the
/// cursor isn't in one, leaving the word completion to run.
fn refreshImport(self: *Completion, buf: *const Buffer, hl: *Highlighter, files: Files) !bool {
    const line_start = buf.lineStart(buf.cursor);
    const ctx = imports.context(hl.language, buf.items()[line_start..buf.cursor]) orelse return false;
    try hl.update(self.gpa, buf);
    switch (kindAt(buf, hl, line_start + ctx.anchor)) {
        .comment => return false,
        .string, .regex => if (ctx.style == .python) return false,
        else => {},
    }

    var keep_buf: [128]u8 = undefined;
    const keep = self.keepSelected(&keep_buf);
    self.items.clearRetainingCapacity();
    self.seen.clearRetainingCapacity();
    _ = self.names.reset(.retain_capacity);
    const alloc = self.names.allocator();

    const dir = ctx.dirPart();
    const seg = ctx.segment();
    self.word_start = line_start + ctx.start + dir.len;
    self.path_mode = ctx.style != .python;
    const here = std.fs.path.dirname(files.path) orelse "/";

    switch (ctx.style) {
        .python => {
            // `from ..pkg.` climbs one folder per dot after the first.
            const dots = dir.len - std.mem.trimStart(u8, dir, ".").len;
            const rel = try alloc.dupe(u8, dir[dots..]);
            std.mem.replaceScalar(u8, rel, '.', '/');
            if (dots > 0) {
                var base = here;
                for (1..dots) |_| base = std.fs.path.dirname(base) orelse base;
                try self.listFolder(files, &.{ base, rel }, .python, seg, 0);
            } else {
                try self.listFolder(files, &.{ here, rel }, .python, seg, 0);
                if (files.root) |r| try self.listFolder(files, &.{ r, rel }, .python, seg, 1);
            }
        },
        else => |style| {
            if (std.mem.startsWith(u8, dir, "/")) {
                // Web paths start at the project folder, the rest at the disk's root.
                const base = if (style == .file) files.root orelse "/" else "/";
                try self.listFolder(files, &.{ base, dir }, style, seg, 0);
            } else if (style == .js and !std.mem.startsWith(u8, ctx.typed, ".")) {
                // An alias (`@/shared/ui`), else a package: look in every
                // node_modules up the tree.
                if (!try self.listAliased(files, here, dir, seg)) {
                    var up: ?[]const u8 = here;
                    while (up) |d| : (up = std.fs.path.dirname(d)) {
                        try self.listFolder(files, &.{ d, "node_modules", dir }, .js, seg, 1);
                    }
                }
            } else {
                try self.listFolder(files, &.{ here, dir }, style, seg, 0);
            }
            if (onlyDots(dir) and (style != .js or dir.len > 0 or seg.len == 0 or seg[0] == '.')) {
                if (dir.len == 0 and style == .js) try self.consider("./", .folder, seg, 0);
                try self.consider("../", .folder, seg, 0);
            }
            if (style == .zig and dir.len == 0) {
                for ([_][]const u8{ "std", "builtin", "root" }) |l| try self.consider(l, .module, seg, 1);
            }
        },
    }

    self.finish(seg.len > 0, keep);
    return true;
}

/// Handles the aliases of the tsconfig.json / jsconfig.json over the file:
/// lists the folder an aliased path is in, or offers the aliases themselves
/// while the path has no folder yet. Returns true if `dir` was an alias.
/// Without configured aliases, `@/` and `~/` stand for the project's src/.
fn listAliased(self: *Completion, files: Files, here: []const u8, dir: []const u8, seg: []const u8) !bool {
    const alloc = self.names.allocator();
    const config = tsconfig.load(alloc, files.io, here);
    var aliases = config.aliases;
    if (aliases.len == 0) if (files.root) |r| {
        const src = try std.fs.path.join(alloc, &.{ r, "src" });
        const is_dir = if (Io.Dir.cwd().statFile(files.io, src, .{})) |st| st.kind == .directory else |_| false;
        if (is_dir) aliases = try alloc.dupe(tsconfig.Alias, &.{
            .{ .prefix = "@/", .wildcard = true, .target = src },
            .{ .prefix = "~/", .wildcard = true, .target = src },
        });
    };

    var aliased = false;
    for (aliases) |a| {
        if (a.wildcard and a.prefix.len > 0 and std.mem.startsWith(u8, dir, a.prefix)) {
            try self.listFolder(files, &.{ a.target, dir[a.prefix.len..] }, .js, seg, 0);
            aliased = true;
        } else if (dir.len == 0 and a.prefix.len > 0) {
            // `@/` leads into a folder; an exact alias names a module.
            const folder = a.wildcard and a.prefix[a.prefix.len - 1] == '/';
            if (folder or !a.wildcard) try self.consider(a.prefix, if (folder) .folder else .module, seg, 0);
        }
    }
    // With a baseUrl, bare paths also start there.
    if (!aliased) if (config.base_url) |b| try self.listFolder(files, &.{ b, dir }, .js, seg, 2);
    return aliased;
}

/// Offers the entries of the folder at the joined `parts`: sub-folders first,
/// then files, each group by name.
fn listFolder(self: *Completion, files: Files, parts: []const []const u8, style: imports.Style, seg: []const u8, rank: u8) !void {
    const alloc = self.names.allocator();
    const path = try std.fs.path.resolve(alloc, parts);
    const Entry = struct {
        label: []const u8,
        kind: ItemKind,

        fn lessThan(_: void, a: @This(), b: @This()) bool {
            const a_dir = a.kind != .file and a.kind != .module;
            const b_dir = b.kind != .file and b.kind != .module;
            if (a_dir != b_dir) return a_dir;
            return std.ascii.lessThanIgnoreCase(a.label, b.label);
        }
    };
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(self.gpa);

    var dir = Io.Dir.cwd().openDir(files.io, path, .{ .iterate = true }) catch return;
    defer dir.close(files.io);
    // Folders in node_modules (or in its `@scope/`) are packages.
    const base = std.fs.path.basename(path);
    const in_packages = std.mem.eql(u8, base, "node_modules") or (std.mem.startsWith(u8, base, "@") and
        std.mem.eql(u8, std.fs.path.basename(std.fs.path.dirname(path) orelse ""), "node_modules"));
    var it = dir.iterate();
    while (it.next(files.io) catch null) |e| {
        if (entries.items.len >= 2000) break;
        if (e.name.len == 0 or e.name[0] == '.') continue;
        const is_dir = switch (e.kind) {
            .directory => true,
            // Follow symlinks (pnpm's node_modules is made of them).
            .sym_link => if (dir.statFile(files.io, e.name, .{})) |st| st.kind == .directory else |_| false,
            else => false,
        };
        if (is_dir) {
            if (!imports.folderShown(style, e.name)) continue;
            const entry: Entry = if (style == .python)
                .{ .label = try alloc.dupe(u8, e.name), .kind = .folder }
            else if (in_packages and e.name[0] != '@')
                .{ .label = try alloc.dupe(u8, e.name), .kind = .module }
            else
                .{ .label = try std.mem.concat(alloc, u8, &.{ e.name, "/" }), .kind = .folder };
            try entries.append(self.gpa, entry);
        } else {
            // Leave out the file being edited.
            if (std.mem.eql(u8, path, std.fs.path.dirname(files.path) orelse "") and
                std.mem.eql(u8, e.name, std.fs.path.basename(files.path))) continue;
            const label = imports.fileLabel(style, e.name) orelse continue;
            try entries.append(self.gpa, .{ .label = try alloc.dupe(u8, label), .kind = if (style == .python) .module else .file });
        }
    }
    std.mem.sort(Entry, entries.items, {}, Entry.lessThan);
    for (entries.items) |e| try self.consider(e.label, e.kind, seg, rank);
}

/// Whether a path is only `./` and `../` steps (or empty).
fn onlyDots(dir: []const u8) bool {
    var parts = std.mem.tokenizeScalar(u8, dir, '/');
    while (parts.next()) |p| if (!std.mem.eql(u8, p, ".") and !std.mem.eql(u8, p, "..")) return false;
    return true;
}

fn consider(self: *Completion, label: []const u8, kind: ItemKind, word: []const u8, rank: u8) !void {
    // The word exactly as typed is no suggestion.
    if (std.mem.eql(u8, label, word)) return;
    const m = fuzzy.match(label, word) orelse return;
    const gop = try self.seen.getOrPut(self.gpa, label);
    if (gop.found_existing) return;
    try self.items.append(self.gpa, .{
        .label = label,
        .kind = kind,
        .score = m.score,
        .matches = m.positions,
        .rank = rank,
        .seq = @intCast(self.items.items.len),
    });
}

/// Best match first; among equals the preferred source, then (once
/// something is typed) the shorter label.
fn better(has_query: bool, a: Item, b: Item) bool {
    if (a.score != b.score) return a.score > b.score;
    if (a.rank != b.rank) return a.rank < b.rank;
    if (has_query and a.label.len != b.label.len) return a.label.len < b.label.len;
    return a.seq < b.seq;
}

/// Replaces the word at the cursor (including any rest of it after the
/// cursor) with the selected suggestion. After a folder, `reopen` is set so
/// the caller can list what's inside it.
pub fn accept(self: *Completion, buf: *Buffer) !void {
    const item = self.selectedItem() orelse return;
    const text = buf.items();
    var end = buf.cursor;
    if (self.path_mode) {
        while (end < text.len and std.mem.indexOfScalar(u8, "\"'`/ \t\n)>", text[end]) == null) end += 1;
        // Don't double the slash of a path that goes on.
        if (item.kind == .folder and end < text.len and text[end] == '/') end += 1;
    } else {
        while (end < text.len and js.isIdentChar(text[end])) end += 1;
    }
    buf.moveTo(self.word_start, false);
    buf.moveTo(end, true);
    try buf.insert(item.label);
    self.close();
    self.reopen = item.kind == .folder;
}

/// The identifier before the `.` preceding `pos`, e.g. `console` in `console.lo`.
fn objectBefore(buf: *const Buffer, pos: usize) []const u8 {
    const dot = pos - 1;
    var start = dot;
    while (start > 0 and js.isIdentChar(buf.items()[start - 1])) start -= 1;
    return buf.items()[start..dot];
}

/// The kind of the token at `pos`.
fn kindAt(buf: *const Buffer, hl: *const Highlighter, pos: usize) token.Kind {
    const line_start = buf.lineStart(pos);
    const line = buf.items()[line_start..buf.lineEnd(pos)];
    const col = pos - line_start;
    var tokens = hl.tokens(buf.lineIndex(pos), line);
    while (tokens.next()) |span| {
        if (span.start <= col and col < span.end) return span.kind;
    }
    return .plain;
}

/// Whether a word starting at `pos` would be inside a string or comment.
fn inStringOrComment(buf: *const Buffer, hl: *const Highlighter, pos: usize) bool {
    const line_start = buf.lineStart(pos);
    const line = buf.items()[line_start..buf.lineEnd(pos)];
    const col = pos - line_start;
    var tokens = hl.tokens(buf.lineIndex(pos), line);
    while (tokens.next()) |span| {
        // The token containing `pos`, or ending right at it at the line end
        // (an unterminated string or comment still open there).
        const at_end = col == span.end and span.end == line.len;
        if (span.start > col or (col >= span.end and !at_end)) continue;
        return switch (span.kind) {
            .comment => true,
            .string, .regex => !at_end or !closed(line[span.start..span.end]),
            else => false,
        };
    }
    return false;
}

/// Whether a string/regex token ends with its closing delimiter.
fn closed(tok: []const u8) bool {
    return tok.len >= 2 and tok[tok.len - 1] == tok[0];
}

test {
    _ = Index;
    _ = fuzzy;
    _ = imports;
    _ = tsconfig;
}

test {
    _ = @import("tests/Completion_test.zig");
}
