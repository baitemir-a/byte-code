//! Git for the sidebar's Git view: the working tree's status (via
//! `git status --porcelain`), staging, unstaging and committing. Runs the
//! `git` command-line tool in the project folder.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Git = @This();

pub const Entry = struct {
    /// Path relative to the repository root, '/' separated.
    path: []const u8,
    /// Status letters from `git status --porcelain`: in the index (staged)
    /// and in the working tree. '?' for untracked files.
    staged: u8,
    unstaged: u8,

    pub fn isStaged(e: Entry) bool {
        return e.staged != ' ' and e.staged != '?';
    }

    pub fn isUnstaged(e: Entry) bool {
        return e.unstaged != ' ';
    }
};

pub const State = enum {
    /// Not refreshed yet.
    unknown,
    ok,
    not_a_repository,
    /// The `git` tool isn't installed.
    no_git,
};

gpa: Allocator,
arena: std.heap.ArenaAllocator,
state: State = .unknown,
branch: []const u8 = "",
/// The repository's top folder (paths in `entries` are relative to it; it
/// can be above the project folder).
toplevel: []const u8 = "",
entries: std.ArrayList(Entry) = .empty,
/// Git's error output from the last failed command.
last_error: std.ArrayList(u8) = .empty,

pub fn init(gpa: Allocator) Git {
    return .{ .gpa = gpa, .arena = .init(gpa) };
}

pub fn deinit(self: *Git) void {
    self.last_error.deinit(self.gpa);
    self.entries.deinit(self.gpa);
    self.arena.deinit();
}

/// Re-reads `git status` for the repository at `root`.
pub fn refresh(self: *Git, io: Io, root: []const u8) !void {
    const top = runGit(self.gpa, io, root, &.{ "rev-parse", "--show-toplevel" }) catch |err| {
        self.clear();
        self.state = if (err == error.GitNotFound) .no_git else .not_a_repository;
        return;
    };
    defer top.deinit(self.gpa);
    if (!top.ok) {
        self.clear();
        self.state = .not_a_repository;
        return;
    }
    const r = runGit(self.gpa, io, root, &.{ "status", "--porcelain=v1", "--branch", "-z", "--untracked-files=all" }) catch |err| {
        self.clear();
        self.state = if (err == error.GitNotFound) .no_git else .not_a_repository;
        return;
    };
    defer r.deinit(self.gpa);
    if (!r.ok) {
        self.clear();
        self.state = .not_a_repository;
        return;
    }
    try self.parse(r.stdout);
    self.toplevel = try self.arena.allocator().dupe(u8, std.mem.trimEnd(u8, top.stdout, "\r\n"));
    self.state = .ok;
}

fn clear(self: *Git) void {
    self.entries.clearRetainingCapacity();
    _ = self.arena.reset(.retain_capacity);
    self.branch = "";
    self.toplevel = "";
}

/// Parses `git status --porcelain=v1 --branch -z` output.
pub fn parse(self: *Git, out: []const u8) !void {
    self.clear();
    const alloc = self.arena.allocator();
    var items = std.mem.splitScalar(u8, out, 0);
    while (items.next()) |item| {
        if (item.len == 0) continue;
        if (std.mem.startsWith(u8, item, "## ")) {
            // "## main...origin/main [ahead 1]" or "## No commits yet on main"
            var b = item[3..];
            if (std.mem.startsWith(u8, b, "No commits yet on ")) b = b["No commits yet on ".len..];
            const end = std.mem.indexOf(u8, b, "...") orelse std.mem.indexOfScalar(u8, b, ' ') orelse b.len;
            self.branch = try alloc.dupe(u8, b[0..end]);
            continue;
        }
        if (item.len < 4) continue;
        try self.entries.append(self.gpa, .{
            .staged = item[0],
            .unstaged = item[1],
            .path = try alloc.dupe(u8, item[3..]),
        });
        // A rename or copy is followed by the old path: skip it.
        if (item[0] == 'R' or item[0] == 'C') _ = items.next();
    }
    std.mem.sort(Entry, self.entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
}

/// Stages an entry's path (relative to the repository's top folder).
pub fn stage(self: *Git, io: Io, root: []const u8, path: []const u8) !void {
    const spec = try topPath(self.gpa, path);
    defer self.gpa.free(spec);
    try self.expectOk(io, root, &.{ "add", "--all", "--", spec });
}

pub fn unstage(self: *Git, io: Io, root: []const u8, path: []const u8) !void {
    const spec = try topPath(self.gpa, path);
    defer self.gpa.free(spec);
    try self.expectOk(io, root, &.{ "reset", "--quiet", "--", spec });
}

/// A pathspec relative to the repository's top, whatever folder git runs in.
fn topPath(gpa: Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, ":(top){s}", .{path});
}

pub fn stageAll(self: *Git, io: Io, root: []const u8) !void {
    try self.expectOk(io, root, &.{ "add", "--all" });
}

pub fn unstageAll(self: *Git, io: Io, root: []const u8) !void {
    try self.expectOk(io, root, &.{ "reset", "--quiet" });
}

/// Commits what's staged. On failure (e.g. a hook refused, or no name and
/// email configured) `last_error` holds git's message.
pub fn commit(self: *Git, io: Io, root: []const u8, message: []const u8) !void {
    try self.expectOk(io, root, &.{ "commit", "--quiet", "-m", message });
}

fn expectOk(self: *Git, io: Io, root: []const u8, args: []const []const u8) !void {
    const r = try runGit(self.gpa, io, root, args);
    defer r.deinit(self.gpa);
    if (r.ok) return;
    self.last_error.clearRetainingCapacity();
    try self.last_error.appendSlice(self.gpa, std.mem.trim(u8, if (r.stderr.len > 0) r.stderr else r.stdout, " \n"));
    return error.GitFailed;
}

const Result = struct {
    ok: bool,
    stdout: []u8,
    stderr: []u8,

    fn deinit(r: Result, gpa: Allocator) void {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
};

fn runGit(gpa: Allocator, io: Io, root: []const u8, args: []const []const u8) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "git", "-C", root });
    try argv.appendSlice(gpa, args);
    const r = std.process.run(gpa, io, .{ .argv = argv.items }) catch |err| switch (err) {
        error.FileNotFound => return error.GitNotFound,
        else => |e| return e,
    };
    const ok = switch (r.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{ .ok = ok, .stdout = r.stdout, .stderr = r.stderr };
}

test "parses porcelain status" {
    var g = Git.init(std.testing.allocator);
    defer g.deinit();
    try g.parse("## main...origin/main [ahead 1]\x00 M src/app.ts\x00A  new.ts\x00R  moved.ts\x00old.ts\x00?? notes.md\x00MM both.zig\x00");
    try std.testing.expectEqualStrings("main", g.branch);
    try std.testing.expectEqual(@as(usize, 5), g.entries.items.len);
    const e = g.entries.items; // sorted by path
    try std.testing.expectEqualStrings("both.zig", e[0].path);
    try std.testing.expect(e[0].isStaged() and e[0].isUnstaged());
    try std.testing.expectEqualStrings("moved.ts", e[1].path);
    try std.testing.expect(e[1].isStaged() and !e[1].isUnstaged());
    try std.testing.expectEqualStrings("notes.md", e[3].path);
    try std.testing.expect(!e[3].isStaged() and e[3].isUnstaged());

    try g.parse("## No commits yet on dev\x00");
    try std.testing.expectEqualStrings("dev", g.branch);
}

test "real repository: status, stage, commit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var g = Git.init(gpa);
    defer g.deinit();
    try g.refresh(io, root);
    if (g.state == .no_git) return error.SkipZigTest;
    try std.testing.expectEqual(State.not_a_repository, g.state);

    // Set up a repository with a local identity (so commit works anywhere).
    for ([_][]const []const u8{
        &.{"init"},
        &.{ "config", "user.email", "test@example.com" },
        &.{ "config", "user.name", "Test" },
    }) |args| try g.expectOk(io, root, args);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hi" });

    try g.refresh(io, root);
    try std.testing.expectEqual(State.ok, g.state);
    try std.testing.expectEqual(@as(usize, 1), g.entries.items.len);
    try std.testing.expectEqual(@as(u8, '?'), g.entries.items[0].unstaged);

    try g.stage(io, root, "a.txt");
    try g.refresh(io, root);
    try std.testing.expect(g.entries.items[0].isStaged());

    try g.commit(io, root, "first");
    try g.refresh(io, root);
    try std.testing.expectEqual(@as(usize, 0), g.entries.items.len);

    // Nothing staged: git refuses, and says why.
    try std.testing.expectError(error.GitFailed, g.commit(io, root, "empty"));
    try std.testing.expect(g.last_error.items.len > 0);
}
