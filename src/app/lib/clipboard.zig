//! Copy, cut and paste, with one or several cursors.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");

/// Copies (and with `cut`, deletes) the selection, or the whole current
/// line when nothing is selected.
pub fn copyOrCut(gpa: std.mem.Allocator, b: *core.Buffer, cut: bool) !void {
    if (b.hasExtraCursors()) return copyOrCutEach(gpa, b, cut);
    const r = b.selection() orelse b.currentLineRange();
    try setClipboard(gpa, b.items()[r.start..r.end]);
    if (cut) try b.deleteRange(r);
}

/// With several cursors: copies each one's selection (or line), one per
/// line, and with `cut` deletes them.
pub fn copyOrCutEach(gpa: std.mem.Allocator, b: *core.Buffer, cut: bool) !void {
    const cursors = try b.allCursors(gpa);
    defer gpa.free(cursors);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (cursors, 0..) |c, i| {
        if (i > 0) try out.append(gpa, '\n');
        var r = c.range();
        if (r.start == r.end) r = .{ .start = b.lineStart(c.cursor), .end = b.lineEnd(c.cursor) };
        try out.appendSlice(gpa, b.items()[r.start..r.end]);
    }
    try setClipboard(gpa, out.items);
    if (!cut) return;
    const Cut = struct {
        pub fn apply(_: @This(), target: *core.Buffer) !void {
            try target.deleteRange(target.selection() orelse target.currentLineRange());
        }
    };
    try b.eachCursor(Cut{}, false);
}

/// Pastes at every cursor. When the text has as many lines as there are
/// cursors (e.g. copied from them), each cursor gets its own line.
pub fn pasteAtCursors(gpa: std.mem.Allocator, b: *core.Buffer, s: []const u8) !void {
    if (!b.hasExtraCursors()) return b.insert(s);
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, s, "\n"), '\n');
    while (lines.next()) |line| try parts.append(gpa, line);
    const split = parts.items.len == b.extra.items.len + 1;
    const Paste = struct {
        parts: []const []const u8,
        whole: []const u8,
        split: bool,
        next: *usize,
        pub fn apply(op: @This(), target: *core.Buffer) !void {
            defer op.next.* += 1;
            try target.insert(if (op.split) op.parts[op.next.*] else op.whole);
        }
    };
    var next: usize = 0;
    try b.eachCursor(Paste{ .parts = parts.items, .whole = s, .split = split, .next = &next }, false);
}

pub fn setClipboard(gpa: std.mem.Allocator, s: []const u8) !void {
    const z = try gpa.dupeZ(u8, s);
    defer gpa.free(z);
    rl.setClipboardText(z);
}

pub fn getClipboard() ?[]const u8 {
    // GLFW returns null when the clipboard holds no text.
    const ptr = rl.cdef.GetClipboardText() orelse return null;
    return std.mem.span(ptr);
}
