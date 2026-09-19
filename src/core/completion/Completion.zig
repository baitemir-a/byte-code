//! Autocompletion session: the word being typed, the ranked suggestions for
//! it (document words, JS/TS keywords, well-known globals), and which one is
//! selected. Closed most of the time.
const std = @import("std");
const Buffer = @import("../buffer/Buffer.zig");
const Highlighter = @import("../syntax/Highlighter.zig");
const js = @import("../syntax/lib/js.zig");
const clike = @import("../syntax/lib/clike.zig");
const Index = @import("Index.zig");
const builtins = @import("lib/builtins.zig");
const fuzzy = @import("lib/fuzzy.zig");

const Completion = @This();

pub const max_items = 100;

pub const ItemKind = enum { keyword, type, function, variable, member };

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

pub fn init(gpa: std.mem.Allocator) Completion {
    return .{ .gpa = gpa, .index = .init(gpa) };
}

pub fn deinit(self: *Completion) void {
    self.items.deinit(self.gpa);
    self.seen.deinit(self.gpa);
    self.index.deinit();
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
/// opens right after a `.`.
pub fn refresh(self: *Completion, buf: *const Buffer, hl: *Highlighter, explicit: bool) !void {
    if (buf.selection() != null) return self.close();

    var start = buf.cursor;
    while (start > 0 and js.isIdentChar(buf.items()[start - 1])) start -= 1;
    const word = buf.items()[start..buf.cursor];
    // Member access is a code thing; in plain text a '.' ends a sentence.
    const code = hl.language == .typescript or hl.language == .python or hl.language.clikeDialect() != null;
    const after_dot = code and buf.byteBefore(start) == '.';

    if (word.len > 0 and std.ascii.isDigit(word[0])) return self.close();
    if (word.len == 0 and !explicit and !after_dot) return self.close();
    try hl.update(self.gpa, buf);
    if (inStringOrComment(buf, hl, start)) return self.close();

    // Remember the selected label so it stays selected as the list re-sorts.
    var keep_buf: [128]u8 = undefined;
    var keep: ?[]const u8 = null;
    if (self.selectedItem()) |it| if (it.label.len <= keep_buf.len) {
        @memcpy(keep_buf[0..it.label.len], it.label);
        keep = keep_buf[0..it.label.len];
    };

    try self.index.update(self.gpa, buf, hl);
    self.items.clearRetainingCapacity();
    self.seen.clearRetainingCapacity();
    self.word_start = start;

    if (after_dot) {
        if (hl.language == .typescript) for (builtins.membersOf(objectBefore(buf, start))) |l| try self.consider(l, .member, word, 0);
        for (self.index.words.keys(), self.index.words.values()) |l, w| {
            if (w.as_member) try self.consider(l, if (w.called) .function else .member, word, 1);
        }
        if (hl.language == .typescript) for (builtins.common_members) |l| try self.consider(l, .function, word, 2);
    } else {
        for (self.index.words.keys(), self.index.words.values()) |l, w| {
            if (!w.as_name) continue;
            const kind: ItemKind = if (w.called) .function else if (w.is_type) .type else .variable;
            try self.consider(l, kind, word, 0);
        }
        if (hl.language == .typescript) {
            for (builtins.keywords) |l| try self.consider(l, .keyword, word, 1);
            for (builtins.globals) |l| try self.consider(l, if (std.ascii.isUpper(l[0])) .type else .variable, word, 2);
            for (builtins.types) |l| try self.consider(l, .type, word, 3);
        } else if (hl.language.clikeDialect()) |dialect| {
            const words = clike.wordsFor(dialect);
            for (words.keyword_list) |l| try self.consider(l, .keyword, word, 1);
            for (words.constant_list) |l| try self.consider(l, .keyword, word, 1);
            for (words.type_list) |l| try self.consider(l, .type, word, 3);
        } else if (hl.language == .python) {
            for (builtins.python_keywords) |l| try self.consider(l, .keyword, word, 1);
            for (builtins.python_functions) |l| try self.consider(l, .function, word, 2);
            for (builtins.python_types) |l| try self.consider(l, .type, word, 3);
        }
    }

    if (self.items.items.len == 0) return self.close();
    std.mem.sort(Item, self.items.items, word.len > 0, better);
    if (self.items.items.len > max_items) self.items.shrinkRetainingCapacity(max_items);

    self.selected = 0;
    if (keep) |k| for (self.items.items, 0..) |it, i| {
        if (std.mem.eql(u8, it.label, k)) self.selected = i;
    };
    self.is_open = true;
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
/// cursor) with the selected suggestion.
pub fn accept(self: *Completion, buf: *Buffer) !void {
    const item = self.selectedItem() orelse return;
    var end = buf.cursor;
    while (end < buf.items().len and js.isIdentChar(buf.items()[end])) end += 1;
    buf.moveTo(self.word_start, false);
    buf.moveTo(end, true);
    try buf.insert(item.label);
    self.close();
}

/// The identifier before the `.` preceding `pos`, e.g. `console` in `console.lo`.
fn objectBefore(buf: *const Buffer, pos: usize) []const u8 {
    const dot = pos - 1;
    var start = dot;
    while (start > 0 and js.isIdentChar(buf.items()[start - 1])) start -= 1;
    return buf.items()[start..dot];
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
}

test {
    _ = @import("tests/Completion_test.zig");
}
