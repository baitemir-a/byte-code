//! Undo/redo stacks. Consecutive typing or deleting is merged into one step.
const std = @import("std");
const Allocator = std.mem.Allocator;

const History = @This();

pub const Kind = enum { typing, deleting, other };

/// One reversible change: bytes `removed` at `pos` were replaced by `inserted`.
pub const Edit = struct {
    pos: usize,
    removed: []u8,
    inserted: []u8,
    kind: Kind,
    cursor_before: usize,
    anchor_before: ?usize,
    cursor_after: usize,
    /// Closed to merging, e.g. after the user moved the cursor.
    sealed: bool = false,
    /// Undone and redone together with the edit before it (one keystroke
    /// with several cursors).
    joined: bool = false,

    fn deinit(e: Edit, gpa: Allocator) void {
        gpa.free(e.removed);
        gpa.free(e.inserted);
    }

    fn hadSelection(e: Edit) bool {
        return e.anchor_before != null and e.anchor_before.? != e.cursor_before;
    }
};

/// Same as `Edit` but with borrowed slices; `record` copies them.
pub const Change = struct {
    pos: usize,
    removed: []const u8,
    inserted: []const u8,
    kind: Kind,
    cursor_before: usize,
    anchor_before: ?usize,
    cursor_after: usize,
};

undo_stack: std.ArrayList(Edit) = .empty,
redo_stack: std.ArrayList(Edit) = .empty,
/// Between `beginGroup` and `endGroup`, changes form one undo step.
grouping: bool = false,
group_started: bool = false,

pub fn deinit(self: *History, gpa: Allocator) void {
    clear(gpa, &self.undo_stack);
    clear(gpa, &self.redo_stack);
    self.undo_stack.deinit(gpa);
    self.redo_stack.deinit(gpa);
}

fn clear(gpa: Allocator, stack: *std.ArrayList(Edit)) void {
    for (stack.items) |e| e.deinit(gpa);
    stack.clearRetainingCapacity();
}

/// Records a change that is about to be applied. Must be called before the
/// text is modified, since `c.removed` usually points into it.
pub fn record(self: *History, gpa: Allocator, c: Change) !void {
    clear(gpa, &self.redo_stack);
    var joined = false;
    if (self.grouping) {
        joined = self.group_started;
        self.group_started = true;
    } else if (try self.mergeIntoLast(gpa, c)) return;

    const removed = try gpa.dupe(u8, c.removed);
    errdefer gpa.free(removed);
    const inserted = try gpa.dupe(u8, c.inserted);
    errdefer gpa.free(inserted);
    try self.undo_stack.append(gpa, .{
        .pos = c.pos,
        .removed = removed,
        .inserted = inserted,
        .kind = c.kind,
        .cursor_before = c.cursor_before,
        .anchor_before = c.anchor_before,
        .cursor_after = c.cursor_after,
        .joined = joined,
    });
}

/// Starts collecting changes into one undo step.
pub fn beginGroup(self: *History) void {
    self.seal();
    self.grouping = true;
    self.group_started = false;
}

pub fn endGroup(self: *History) void {
    self.grouping = false;
    self.seal();
}

/// Whether the next edit to redo belongs to the one just redone.
pub fn redoContinues(self: *const History) bool {
    const e = self.redo_stack.getLastOrNull() orelse return false;
    return e.joined;
}

/// Ends the current undo group so the next change starts a new step.
pub fn seal(self: *History) void {
    if (self.undo_stack.items.len > 0) self.undo_stack.items[self.undo_stack.items.len - 1].sealed = true;
}

/// Moves the newest edit to the redo stack and returns it (still owned here).
pub fn popUndo(self: *History, gpa: Allocator) !?Edit {
    try self.redo_stack.ensureUnusedCapacity(gpa, 1);
    const e = self.undo_stack.pop() orelse return null;
    self.redo_stack.appendAssumeCapacity(e);
    return e;
}

/// Moves the newest undone edit back to the undo stack and returns it.
pub fn popRedo(self: *History, gpa: Allocator) !?Edit {
    try self.undo_stack.ensureUnusedCapacity(gpa, 1);
    var e = self.redo_stack.pop() orelse return null;
    e.sealed = true;
    self.undo_stack.appendAssumeCapacity(e);
    return e;
}

fn mergeIntoLast(self: *History, gpa: Allocator, c: Change) !bool {
    if (c.kind == .other or self.undo_stack.items.len == 0) return false;
    if (c.anchor_before != null and c.anchor_before.? != c.cursor_before) return false;
    const last = &self.undo_stack.items[self.undo_stack.items.len - 1];
    if (last.sealed or last.kind != c.kind or last.hadSelection()) return false;

    switch (c.kind) {
        .typing => {
            if (c.removed.len != 0 or last.removed.len != 0) return false;
            if (c.pos != last.pos + last.inserted.len) return false;
            // Whitespace starts a new step, so undo goes word by word.
            if (std.mem.indexOfAny(u8, c.inserted, " \t\n") != null) return false;
            last.inserted = try append(gpa, last.inserted, c.inserted);
        },
        .deleting => {
            if (c.inserted.len != 0 or last.inserted.len != 0) return false;
            if (c.pos + c.removed.len == last.pos) { // backspace
                last.removed = try prepend(gpa, last.removed, c.removed);
                last.pos = c.pos;
            } else if (c.pos == last.pos) { // forward delete
                last.removed = try append(gpa, last.removed, c.removed);
            } else return false;
        },
        .other => unreachable,
    }
    last.cursor_after = c.cursor_after;
    return true;
}

/// Returns `owned ++ extra`, freeing `owned`.
fn append(gpa: Allocator, owned: []u8, extra: []const u8) ![]u8 {
    const out = try gpa.realloc(owned, owned.len + extra.len);
    @memcpy(out[out.len - extra.len ..], extra);
    return out;
}

/// Returns `extra ++ owned`, freeing `owned`.
fn prepend(gpa: Allocator, owned: []u8, extra: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, owned.len + extra.len);
    @memcpy(out[0..extra.len], extra);
    @memcpy(out[extra.len..], owned);
    gpa.free(owned);
    return out;
}
