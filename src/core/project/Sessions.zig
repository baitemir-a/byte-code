//! What was open in each project folder, to put it back when the folder
//! is opened again: the tabs' files, where the cursor and the scroll were
//! in each, which blocks were folded, and which tab was showing. Stored
//! as JSON (sessions.json next to settings.json); the most recent folders
//! first, the oldest dropped past `max_sessions`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Sessions = @This();

pub const max_sessions = 50;

pub const TabState = struct {
    path: []const u8,
    /// The cursor, zero-based.
    line: u32 = 0,
    col: u32 = 0,
    /// The first row showing (fractional).
    top: f32 = 0,
    /// The folded blocks' first lines.
    folds: []const u32 = &.{},
};

pub const Session = struct {
    root: []const u8,
    tabs: []const TabState = &.{},
    /// Index into `tabs` of the one showing.
    active: u32 = 0,
};

const File = struct { sessions: []const Session = &.{} };

gpa: Allocator,
/// Owns every string and slice in `list`.
arena: std.heap.ArenaAllocator,
list: std.ArrayList(Session) = .empty,

pub fn init(gpa: Allocator) Sessions {
    return .{ .gpa = gpa, .arena = .init(gpa) };
}

pub fn deinit(self: *Sessions) void {
    self.list.deinit(self.gpa);
    self.arena.deinit();
}

/// Reads the sessions; a missing or broken file gives none.
pub fn load(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) Sessions {
    var self = init(gpa);
    const bytes = dir.readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch return self;
    defer gpa.free(bytes);
    const file = std.json.parseFromSliceLeaky(File, self.arena.allocator(), bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return self;
    for (file.sessions[0..@min(file.sessions.len, max_sessions)]) |s| self.list.append(gpa, s) catch break;
    return self;
}

pub fn save(self: *const Sessions, io: Io, dir: Io.Dir, path: []const u8) !void {
    const json = try std.json.Stringify.valueAlloc(self.gpa, File{ .sessions = self.list.items }, .{ .whitespace = .indent_1 });
    defer self.gpa.free(json);
    if (std.fs.path.dirname(path)) |d| try dir.createDirPath(io, d);
    var file = try dir.createFileAtomic(io, path, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, json);
    try file.replace(io);
}

/// The session of the folder at `root`, if one was kept.
pub fn get(self: *const Sessions, root: []const u8) ?Session {
    for (self.list.items) |s| if (std.mem.eql(u8, s.root, root)) return s;
    return null;
}

/// Keeps `session` (copied) as its folder's, first in the list.
pub fn put(self: *Sessions, session: Session) !void {
    const a = self.arena.allocator();
    const tabs = try a.alloc(TabState, session.tabs.len);
    for (session.tabs, tabs) |t, *o| o.* = .{
        .path = try a.dupe(u8, t.path),
        .line = t.line,
        .col = t.col,
        .top = t.top,
        .folds = try a.dupe(u32, t.folds),
    };
    const copy: Session = .{ .root = try a.dupe(u8, session.root), .tabs = tabs, .active = session.active };
    for (self.list.items, 0..) |s, i| if (std.mem.eql(u8, s.root, session.root)) {
        _ = self.list.orderedRemove(i);
        break;
    };
    try self.list.insert(self.gpa, 0, copy);
    if (self.list.items.len > max_sessions) self.list.shrinkRetainingCapacity(max_sessions);
}

test {
    _ = @import("tests/Sessions_test.zig");
}
