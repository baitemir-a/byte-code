//! Multiple cursors: adding them, column selections, running an edit at
//! each, and keeping them apart.
const std = @import("std");
const text = @import("../../editing/lib/text.zig");
const motion = @import("../../editing/lib/motion.zig");
const find = @import("../../search/lib/find.zig");
const Buffer = @import("../Buffer.zig");

const Allocator = std.mem.Allocator;

pub fn hasExtraCursors(self: *const Buffer) bool {
    return self.extra.items.len > 0;
}

/// Adds a cursor at `pos`, which becomes the main one. At an existing
/// cursor, removes that cursor instead (unless it's the only one).
pub fn toggleCursor(self: *Buffer, pos: usize) !void {
    const p = @min(pos, self.bytes.items.len);
    for (self.extra.items, 0..) |c, i| {
        if (c.cursor == p) {
            _ = self.extra.orderedRemove(i);
            return;
        }
    }
    if (p == self.cursor and self.extra.items.len > 0) {
        const c = self.extra.pop().?;
        self.cursor = c.cursor;
        self.anchor = c.anchor;
        self.goal_col = c.goal_col;
        return;
    }
    if (p == self.cursor) return;
    var old = mainCursor(
        self,
    );
    old.primary = false;
    try self.extra.append(self.gpa, old);
    self.moveHead(p, false);
    try normalizeCursors(
        self,
    );
}

/// A cursor on every line from `from` to `to` (line, on-screen column), at
/// `to`'s column, selecting back to `from`'s column: a column ("box")
/// selection. Lines in between too short to reach the box are skipped.
/// The cursor on `to`'s line is the main one.
pub fn selectColumns(self: *Buffer, from_line: usize, from_col: usize, to_line: usize, to_col: usize) !void {
    self.extra.clearRetainingCapacity();
    const b = self.bytes.items;
    const lo = @min(from_line, to_line);
    const hi = @min(@max(from_line, to_line), self.lineCount() - 1);
    const min_col = @min(from_col, to_col);
    var start = self.posAt(lo, 0);
    var main: Buffer.Cursor = .{ .cursor = self.cursor };
    for (lo..hi + 1) |line| {
        const end = self.lineEnd(start);
        defer start = @min(end + 1, b.len);
        const text_line = b[start..end];
        const ends = line == from_line or line == to_line;
        if (!ends and text.visualColumn(text_line) < min_col) continue;
        const head = start + text.offsetAtColumn(text_line, to_col);
        const tail = start + text.offsetAtColumn(text_line, from_col);
        const c: Buffer.Cursor = .{ .cursor = head, .anchor = if (tail != head) tail else null, .goal_col = to_col };
        if (line == @min(to_line, hi)) main = c else try self.extra.append(self.gpa, c);
    }
    self.cursor = main.cursor;
    self.anchor = main.anchor;
    self.goal_col = main.goal_col;
    self.history.seal();
}

pub const Occurrence = enum {
    /// Nothing was selected: the word at the cursor was.
    word,
    /// Another place with the selected text got a cursor of its own.
    added,
    /// There was nothing (more) to select.
    none,
};

/// Cmd+D. With nothing selected, selects the word at the cursor. With a
/// selection, the next place with the same text (after the main cursor,
/// going round to the top) gets a cursor that selects it and becomes the
/// main one. `whole_word`: only where it isn't part of a longer word, as
/// when the selection started from a word.
pub fn selectNextOccurrence(self: *Buffer, whole_word: bool) !Occurrence {
    const b = self.bytes.items;
    const sel = self.selection() orelse {
        const r = motion.wordRange(b, self.cursor);
        if (r.start == r.end or !text.isWordChar(b[r.start])) return .none;
        self.extra.clearRetainingCapacity();
        self.cursor = r.end;
        self.anchor = r.start;
        self.goal_col = null;
        self.history.seal();
        return .word;
    };
    const needle = try self.gpa.dupe(u8, b[sel.start..sel.end]);
    defer self.gpa.free(needle);
    const all = try allCursors(self, self.gpa);
    defer self.gpa.free(all);
    const opts: find.Options = .{ .match_case = true, .whole_word = whole_word };
    var from = sel.end;
    var wrapped = false;
    while (true) {
        const at = find.next(b, from, needle, opts) orelse {
            if (wrapped) return .none;
            wrapped = true;
            from = 0;
            continue;
        };
        if (wrapped and at >= sel.start) return .none;
        const taken = for (all) |c| {
            const r = c.range();
            if (at < r.end and at + needle.len > r.start) break true;
        } else false;
        if (!taken) {
            var old = mainCursor(self);
            old.primary = false;
            try self.extra.append(self.gpa, old);
            self.cursor = at + needle.len;
            self.anchor = at;
            self.goal_col = null;
            self.history.seal();
            try normalizeCursors(self);
            return .added;
        }
        from = at + 1;
    }
}

/// Every cursor, the main one included, in document order (caller frees).
pub fn allCursors(self: *const Buffer, gpa: Allocator) ![]Buffer.Cursor {
    const out = try gpa.alloc(Buffer.Cursor, self.extra.items.len + 1);
    @memcpy(out[0..self.extra.items.len], self.extra.items);
    out[self.extra.items.len] = mainCursor(
        self,
    );
    std.mem.sort(Buffer.Cursor, out, {}, before);
    return out;
}

pub fn mainCursor(self: *const Buffer) Buffer.Cursor {
    return .{ .cursor = self.cursor, .anchor = self.anchor, .goal_col = self.goal_col, .primary = true };
}

pub fn before(_: void, a: Buffer.Cursor, b: Buffer.Cursor) bool {
    return a.range().start < b.range().start;
}

/// Runs `op.apply(buffer)` once per cursor, as if each were the only one,
/// in document order (or reverse). With several cursors the edits undo as
/// one step. `op` is any value with `fn apply(@TypeOf(op), *Buffer) !void`.
pub fn eachCursor(self: *Buffer, op: anytype, reverse: bool) !void {
    if (self.extra.items.len == 0) return op.apply(self);

    try self.extra.append(self.gpa, mainCursor(
        self,
    ));
    std.mem.sort(Buffer.Cursor, self.extra.items, {}, before);
    self.history.beginGroup();
    defer {
        self.history.endGroup();
        self.active = null;
        normalizeCursors(
            self,
        ) catch {};
    }
    const n = self.extra.items.len;
    for (0..n) |k| {
        const i = if (reverse) n - 1 - k else k;
        const c = self.extra.items[i];
        self.cursor = c.cursor;
        self.anchor = c.anchor;
        self.goal_col = c.goal_col;
        self.active = i;
        defer self.extra.items[i] = .{ .cursor = self.cursor, .anchor = self.anchor, .goal_col = self.goal_col, .primary = c.primary };
        try op.apply(self);
    }
}

/// Sorts the cursors, merges ones that meet or overlap, and takes the main
/// cursor out of `extra` again.
pub fn normalizeCursors(self: *Buffer) !void {
    if (self.extra.items.len == 0) return;
    if (self.active == null and !hasPrimary(self.extra.items)) try self.extra.append(self.gpa, mainCursor(
        self,
    ));
    const cs = self.extra.items;
    std.mem.sort(Buffer.Cursor, cs, {}, before);
    var n: usize = 0;
    for (cs) |c| {
        if (n > 0) {
            const prev = &cs[n - 1];
            const a = prev.range();
            const b = c.range();
            if (b.start < a.end or b.start == a.start or (b.start == a.end and b.start == b.end)) {
                const forward = prev.anchor == null or prev.cursor >= prev.anchor.?;
                const end = @max(a.end, b.end);
                prev.* = .{
                    .cursor = if (forward) end else a.start,
                    .anchor = if (end == a.start) null else if (forward) a.start else end,
                    .goal_col = prev.goal_col,
                    .primary = prev.primary or c.primary,
                };
                continue;
            }
        }
        cs[n] = c;
        n += 1;
    }
    self.extra.shrinkRetainingCapacity(n);
    for (self.extra.items, 0..) |c, i| if (c.primary) {
        _ = self.extra.orderedRemove(i);
        self.cursor = c.cursor;
        self.anchor = c.anchor;
        self.goal_col = c.goal_col;
        break;
    };
}

pub fn hasPrimary(cs: []const Buffer.Cursor) bool {
    for (cs) |c| if (c.primary) return true;
    return false;
}
