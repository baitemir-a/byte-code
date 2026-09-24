//! The branch's commits, newest first, for the Git view's history: who
//! made each one, when, and its first line; and, for the one opened, the
//! files it changed. Parsed from `git log` and `git diff-tree` output.
const std = @import("std");
const Allocator = std.mem.Allocator;

const GitLog = @This();

pub const Commit = struct {
    hash: []const u8,
    author: []const u8,
    /// Seconds since the epoch.
    time: i64,
    subject: []const u8,

    pub fn shortHash(c: Commit) []const u8 {
        return c.hash[0..@min(7, c.hash.len)];
    }
};

pub const File = struct {
    /// 'A', 'M', 'D', 'R'...
    status: u8,
    /// Path in the repository, '/' separated. For a rename, the new name;
    /// `old_path` is where it came from (the same path otherwise).
    path: []const u8,
    old_path: []const u8,
};

/// How many commits are read.
pub const limit = 200;

/// The arguments for `git log` that `parseLog` reads.
pub const log_args = [_][]const u8{ "log", "-n", std.fmt.comptimePrint("{d}", .{limit}), "--format=%H%x1f%an%x1f%at%x1f%s%x1e" };

gpa: Allocator,
arena: std.heap.ArenaAllocator,
commits: std.ArrayList(Commit) = .empty,
/// The commit whose files are shown, and those files.
open: ?u32 = null,
files: std.ArrayList(File) = .empty,
files_arena: std.heap.ArenaAllocator,

pub fn init(gpa: Allocator) GitLog {
    return .{ .gpa = gpa, .arena = .init(gpa), .files_arena = .init(gpa) };
}

pub fn deinit(self: *GitLog) void {
    self.commits.deinit(self.gpa);
    self.files.deinit(self.gpa);
    self.arena.deinit();
    self.files_arena.deinit();
}

pub fn clear(self: *GitLog) void {
    self.commits.clearRetainingCapacity();
    _ = self.arena.reset(.retain_capacity);
    self.closeFiles();
}

pub fn closeFiles(self: *GitLog) void {
    self.open = null;
    self.files.clearRetainingCapacity();
    _ = self.files_arena.reset(.retain_capacity);
}

/// Reads `git log` output (see `log_args`). The open commit stays open if
/// it is still in the list.
pub fn parseLog(self: *GitLog, out: []const u8) !void {
    const was_open: ?[]const u8 = if (self.open) |i| try self.gpa.dupe(u8, self.commits.items[i].hash) else null;
    defer if (was_open) |h| self.gpa.free(h);
    self.commits.clearRetainingCapacity();
    _ = self.arena.reset(.retain_capacity);
    const alloc = self.arena.allocator();
    var records = std.mem.splitScalar(u8, out, 0x1e);
    while (records.next()) |raw| {
        const record = std.mem.trim(u8, raw, "\r\n");
        if (record.len == 0) continue;
        var fields = std.mem.splitScalar(u8, record, 0x1f);
        const hash = fields.next() orelse continue;
        const author = fields.next() orelse continue;
        const time = fields.next() orelse continue;
        const subject = fields.rest();
        try self.commits.append(self.gpa, .{
            .hash = try alloc.dupe(u8, hash),
            .author = try alloc.dupe(u8, author),
            .time = std.fmt.parseInt(i64, time, 10) catch 0,
            .subject = try alloc.dupe(u8, subject),
        });
    }
    self.open = null;
    if (was_open) |h| {
        for (self.commits.items, 0..) |c, i| if (std.mem.eql(u8, c.hash, h)) {
            self.open = @intCast(i);
        };
    }
    if (self.open == null) self.closeFiles();
}

/// The arguments for `git diff-tree` that `parseFiles` reads: what a
/// commit changed against its first parent (everything, for the first
/// commit).
pub fn filesArgs(hash: []const u8) [9][]const u8 {
    return .{ "diff-tree", "-r", "--root", "-m", "--first-parent", "--no-commit-id", "--name-status", "-z", hash };
}

/// Reads `git diff-tree --name-status -z` output as commit `index`'s files.
pub fn parseFiles(self: *GitLog, index: u32, out: []const u8) !void {
    self.closeFiles();
    self.open = index;
    const alloc = self.files_arena.allocator();
    var items = std.mem.splitScalar(u8, out, 0);
    while (items.next()) |status| {
        if (status.len == 0) continue;
        const path = items.next() orelse break;
        var file: File = .{ .status = status[0], .path = try alloc.dupe(u8, path), .old_path = undefined };
        file.old_path = file.path;
        // A rename or copy names where it came from first.
        if (status[0] == 'R' or status[0] == 'C') {
            const new_path = items.next() orelse break;
            file.path = try alloc.dupe(u8, new_path);
        }
        try self.files.append(self.gpa, file);
    }
}

test {
    _ = @import("tests/GitLog_test.zig");
}
