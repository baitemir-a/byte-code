//! Go Back / Go Forward: the places the cursor jumped from. Every frame
//! the cursor's place is compared with the last one; another file, or a
//! move of many lines that no typing explains (Cmd+click, a search
//! result, Cmd+Down, a click far away), counts as a jump and the place
//! left is remembered.
const std = @import("std");
const App = @import("../App.zig");
const palette = @import("palette.zig");
const i18n = @import("../../i18n/i18n.zig");

const Navigation = @This();

/// A move of at least this many lines counts as a jump.
const jump_lines = 10;
/// Places kept each way.
const max_points = 50;

pub const Point = struct {
    /// Owned.
    path: []u8,
    pos: usize,
};

back: std.ArrayList(Point) = .empty,
forward: std.ArrayList(Point) = .empty,
/// Where the cursor was last frame, its line and the text's version.
here: ?Point = null,
here_line: usize = 0,
here_version: u64 = 0,
/// The cursor was moved on purpose this frame (going back, putting it
/// back after a preview): the next frame only takes note of its place.
quiet: bool = false,

pub fn deinit(self: *Navigation, gpa: std.mem.Allocator) void {
    for (self.back.items) |p| gpa.free(p.path);
    for (self.forward.items) |p| gpa.free(p.path);
    self.back.deinit(gpa);
    self.forward.deinit(gpa);
    if (self.here) |h| gpa.free(h.path);
}

/// Called once a frame, after input.
pub fn track(self: *Navigation, app: *App) !void {
    const t = app.tab();
    if (t.kind != .file) return;
    const path = t.document.path orelse return;
    const pos = t.buffer.cursor;
    const line = if (app.view.rowsCurrent(&t.buffer) and app.view.rows.items.len > 0)
        app.view.rows.items[app.view.rowOf(pos)].line
    else
        t.buffer.lineIndex(pos);
    defer {
        self.here_line = line;
        self.here_version = t.buffer.version;
        self.quiet = false;
    }
    const h = if (self.here) |*h| h else {
        self.here = .{ .path = try app.gpa.dupe(u8, path), .pos = pos };
        return;
    };
    const same = std.mem.eql(u8, h.path, path);
    const moved = if (line > self.here_line) line - self.here_line else self.here_line - line;
    const jump = !same or (t.buffer.version == self.here_version and moved >= jump_lines);
    // While a list previews places, those don't count.
    if (jump and !self.quiet and !app.picker.is_open) {
        try push(app.gpa, &self.back, .{ .path = try app.gpa.dupe(u8, h.path), .pos = h.pos });
        clear(app.gpa, &self.forward);
    }
    if (!same) {
        const copy = try app.gpa.dupe(u8, path);
        app.gpa.free(h.path);
        h.path = copy;
    }
    h.pos = pos;
}

/// A jump made by a command that previewed it first: `from` is where the
/// cursor was in the current file before.
pub fn jumped(self: *Navigation, app: *App, from: usize) void {
    self.quiet = true;
    const path = app.tab().document.path orelse return;
    const copy = app.gpa.dupe(u8, path) catch return;
    push(app.gpa, &self.back, .{ .path = copy, .pos = from }) catch app.gpa.free(copy);
    clear(app.gpa, &self.forward);
}

pub fn goBack(self: *Navigation, app: *App) !void {
    try self.go(app, &self.back, &self.forward);
}

pub fn goForward(self: *Navigation, app: *App) !void {
    try self.go(app, &self.forward, &self.back);
}

/// Pops a place off `from`, leaving the current one on `to`, and goes
/// there.
fn go(self: *Navigation, app: *App, from: *std.ArrayList(Point), to: *std.ArrayList(Point)) !void {
    const target = from.pop() orelse return;
    defer app.gpa.free(target.path);
    if (self.here) |h| {
        // Where the cursor is now, not where it was last frame.
        var now = h;
        if (app.tab().kind == .file) now.pos = app.tab().buffer.cursor;
        try push(app.gpa, to, now);
        self.here = null;
    }
    self.quiet = true;
    app.openFile(target.path) catch |err| return app.reportError(i18n.tr().errors.open_file, target.path, err);
    const b = app.buf();
    b.moveTo(@min(target.pos, b.items().len), false);
    palette.center(app, b.lineIndex(b.cursor));
}

fn push(gpa: std.mem.Allocator, list: *std.ArrayList(Point), p: Point) !void {
    if (list.items.len >= max_points) gpa.free(list.orderedRemove(0).path);
    try list.append(gpa, p);
}

fn clear(gpa: std.mem.Allocator, list: *std.ArrayList(Point)) void {
    for (list.items) |p| gpa.free(p.path);
    list.clearRetainingCapacity();
}
