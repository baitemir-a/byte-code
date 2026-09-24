//! What the Git view's pickers list: the repository's branches (its own
//! and the remote's), stashes and tags, another branch's commits, and the
//! files two revisions differ in. Parsed from git's output.
const std = @import("std");
const Allocator = std.mem.Allocator;
const GitLog = @import("GitLog.zig");

const GitRefs = @This();

pub const Branch = struct {
    /// "main", or "origin/main" for the remote's.
    name: []const u8,
    remote: bool,
    /// The one checked out.
    current: bool,
};

pub const Stash = struct {
    /// "stash@{0}": what git commands take.
    ref: []const u8,
    /// What was typed when it was made, or git's "WIP on main: ...".
    message: []const u8,
    /// Seconds since the epoch.
    time: i64,
};

pub const Tag = struct {
    name: []const u8,
    /// An annotated tag's message, or the commit's first line.
    subject: []const u8,
};

/// Most recently worked on first; the remote's own "HEAD" is left out.
pub const branch_args = [_][]const u8{ "for-each-ref", "--sort=-committerdate", "--format=%(refname)%1f%(HEAD)", "refs/heads", "refs/remotes" };
pub const stash_args = [_][]const u8{ "stash", "list", "--format=%gd%x1f%ct%x1f%gs" };
/// Newest first.
pub const tag_args = [_][]const u8{ "for-each-ref", "--sort=-creatordate", "--format=%(refname:short)%1f%(subject)", "refs/tags" };

gpa: Allocator,
arena: std.heap.ArenaAllocator,
branches: std.ArrayList(Branch) = .empty,
stashes: std.ArrayList(Stash) = .empty,
tags: std.ArrayList(Tag) = .empty,
commits: std.ArrayList(GitLog.Commit) = .empty,
files: std.ArrayList(GitLog.File) = .empty,

pub fn init(gpa: Allocator) GitRefs {
    return .{ .gpa = gpa, .arena = .init(gpa) };
}

pub fn deinit(self: *GitRefs) void {
    self.branches.deinit(self.gpa);
    self.stashes.deinit(self.gpa);
    self.tags.deinit(self.gpa);
    self.commits.deinit(self.gpa);
    self.files.deinit(self.gpa);
    self.arena.deinit();
}

pub fn clear(self: *GitRefs) void {
    self.branches.clearRetainingCapacity();
    self.stashes.clearRetainingCapacity();
    self.tags.clearRetainingCapacity();
    self.commits.clearRetainingCapacity();
    self.files.clearRetainingCapacity();
    _ = self.arena.reset(.retain_capacity);
}

/// Reads `git for-each-ref` output for tags (see `tag_args`).
pub fn parseTags(self: *GitRefs, out: []const u8) !void {
    self.tags.clearRetainingCapacity();
    const alloc = self.arena.allocator();
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, 0x1f);
        const name = fields.next() orelse continue;
        try self.tags.append(self.gpa, .{ .name = try alloc.dupe(u8, name), .subject = try alloc.dupe(u8, fields.rest()) });
    }
}

/// Commits in `GitLog.format`.
pub fn parseCommits(self: *GitRefs, out: []const u8) !void {
    self.commits.clearRetainingCapacity();
    try GitLog.parseCommits(self.gpa, self.arena.allocator(), out, &self.commits);
}

/// `--name-status -z` output.
pub fn parseFiles(self: *GitRefs, out: []const u8) !void {
    self.files.clearRetainingCapacity();
    try GitLog.parseNameStatus(self.gpa, self.arena.allocator(), out, &self.files);
}

/// Reads `git for-each-ref` output (see `branch_args`).
pub fn parseBranches(self: *GitRefs, out: []const u8) !void {
    self.branches.clearRetainingCapacity();
    const alloc = self.arena.allocator();
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var fields = std.mem.splitScalar(u8, line, 0x1f);
        const ref = fields.next() orelse continue;
        const head = fields.next() orelse "";
        const remote = std.mem.startsWith(u8, ref, "refs/remotes/");
        const name = if (remote) ref["refs/remotes/".len..] else if (std.mem.startsWith(u8, ref, "refs/heads/")) ref["refs/heads/".len..] else continue;
        if (remote and std.mem.endsWith(u8, name, "/HEAD")) continue;
        try self.branches.append(self.gpa, .{ .name = try alloc.dupe(u8, name), .remote = remote, .current = std.mem.eql(u8, head, "*") });
    }
}

/// Reads `git stash list` output (see `stash_args`), newest first.
pub fn parseStashes(self: *GitRefs, out: []const u8) !void {
    self.stashes.clearRetainingCapacity();
    const alloc = self.arena.allocator();
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var fields = std.mem.splitScalar(u8, line, 0x1f);
        const ref = fields.next() orelse continue;
        const time = fields.next() orelse continue;
        try self.stashes.append(self.gpa, .{
            .ref = try alloc.dupe(u8, ref),
            .time = std.fmt.parseInt(i64, time, 10) catch 0,
            .message = try alloc.dupe(u8, fields.rest()),
        });
    }
}

/// The local branch name a remote one gets when checked out:
/// "origin/feature" → "feature".
pub fn localName(remote_name: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, remote_name, '/') orelse return remote_name;
    return remote_name[slash + 1 ..];
}

test {
    _ = @import("tests/GitRefs_test.zig");
}
