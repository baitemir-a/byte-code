//! The folders opened as projects: the recent ones and the favorites,
//! listed on the welcome page. Kept in projects.json next to settings.json,
//! most recently opened first.
//!
//! A favorite is an ordinary entry with a flag, so it keeps its place in
//! the history and is never dropped to make room for newer folders.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Projects = @This();

/// How many folders that aren't favorites are remembered.
pub const max_recent = 10;
/// A ceiling on the whole list, favorites included.
pub const max_entries = 50;

pub const Entry = struct {
    /// Absolute path of the folder; owned by the list.
    path: []const u8,
    favorite: bool = false,
};

gpa: Allocator,
entries: std.ArrayList(Entry) = .empty,

/// The file's shape; the list is one field so it can grow later.
const File = struct { projects: []const Entry = &.{} };

pub fn init(gpa: Allocator) Projects {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Projects) void {
    for (self.entries.items) |e| self.gpa.free(e.path);
    self.entries.deinit(self.gpa);
}

/// Reads the list from `path`. A missing or unreadable file gives an
/// empty one, as on a first run.
pub fn load(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) Projects {
    var list: Projects = .init(gpa);
    const bytes = dir.readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch return list;
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(File, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return list;
    defer parsed.deinit();
    for (parsed.value.projects) |e| {
        if (list.entries.items.len >= max_entries) break;
        if (e.path.len == 0 or list.indexOf(e.path) != null) continue;
        const owned = gpa.dupe(u8, e.path) catch break;
        list.entries.append(gpa, .{ .path = owned, .favorite = e.favorite }) catch {
            gpa.free(owned);
            break;
        };
    }
    return list;
}

pub fn save(self: *const Projects, io: Io, dir: Io.Dir, path: []const u8) !void {
    const json = try std.json.Stringify.valueAlloc(self.gpa, File{ .projects = self.entries.items }, .{ .whitespace = .indent_2 });
    defer self.gpa.free(json);
    if (std.fs.path.dirname(path)) |d| try dir.createDirPath(io, d);
    var file = try dir.createFileAtomic(io, path, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, json);
    try file.replace(io);
}

pub fn indexOf(self: *const Projects, path: []const u8) ?usize {
    const wanted = trimTrailingSep(path);
    for (self.entries.items, 0..) |e, i| {
        if (std.mem.eql(u8, e.path, wanted)) return i;
    }
    return null;
}

/// A folder was opened: it goes to the front of the list, keeping the
/// favorite mark it already had.
pub fn record(self: *Projects, path: []const u8) !void {
    const wanted = trimTrailingSep(path);
    if (wanted.len == 0) return;
    if (self.indexOf(wanted)) |i| {
        const e = self.entries.orderedRemove(i);
        try self.entries.insert(self.gpa, 0, e);
    } else {
        const owned = try self.gpa.dupe(u8, wanted);
        errdefer self.gpa.free(owned);
        try self.entries.insert(self.gpa, 0, .{ .path = owned });
    }
    self.trim();
}

/// Marks or unmarks a favorite. An unmarked one stays in the history,
/// where it may now be old enough to fall off the end.
pub fn toggleFavorite(self: *Projects, index: usize) void {
    if (index >= self.entries.items.len) return;
    const e = &self.entries.items[index];
    e.favorite = !e.favorite;
    self.trim();
}

pub fn remove(self: *Projects, index: usize) void {
    if (index >= self.entries.items.len) return;
    self.gpa.free(self.entries.orderedRemove(index).path);
}

/// Drops the folders past the end of the history. Favorites don't count
/// towards it and are only dropped if the list somehow grows past
/// `max_entries`.
fn trim(self: *Projects) void {
    var recent: usize = 0;
    var i: usize = 0;
    while (i < self.entries.items.len) {
        const favorite = self.entries.items[i].favorite;
        if (!favorite) recent += 1;
        if ((!favorite and recent > max_recent) or i >= max_entries) {
            self.remove(i);
            continue;
        }
        i += 1;
    }
}

/// Paths compare without a trailing separator: "/code/app" and
/// "/code/app/" are the same folder.
fn trimTrailingSep(path: []const u8) []const u8 {
    var p = path;
    while (p.len > 1 and (p[p.len - 1] == '/' or p[p.len - 1] == '\\')) p = p[0 .. p.len - 1];
    return p;
}

test {
    _ = @import("tests/Projects_test.zig");
}
