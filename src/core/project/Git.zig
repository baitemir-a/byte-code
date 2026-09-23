//! Git for the sidebar's Git view: the working tree's status (via
//! `git status --porcelain`), staging, unstaging, throwing changes away
//! and committing. Runs the `git` command-line tool in the project folder.
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

/// Throws away what isn't staged in a file: git puts the staged copy back
/// in the work tree. A file git doesn't know has nothing to go back to, so
/// it is left alone.
pub fn discard(self: *Git, io: Io, root: []const u8, path: []const u8) !void {
    const spec = try topPath(self.gpa, path);
    defer self.gpa.free(spec);
    try self.expectOk(io, root, &.{ "checkout", "--quiet", "--", spec });
}

/// The same for the whole repository. What is staged stays staged.
pub fn discardAll(self: *Git, io: Io, root: []const u8) !void {
    try self.expectOk(io, root, &.{ "checkout", "--quiet", "--", ":/" });
}

pub fn stageAll(self: *Git, io: Io, root: []const u8) !void {
    try self.expectOk(io, root, &.{ "add", "--all" });
}

pub fn unstageAll(self: *Git, io: Io, root: []const u8) !void {
    try self.expectOk(io, root, &.{ "reset", "--quiet" });
}

/// The top folder of the repository `dir` is in, or null when it isn't in
/// one (or git isn't installed). Caller frees. Used for the change marks
/// in the editor, which work on any open file, not just the project's.
pub fn topLevel(gpa: Allocator, io: Io, dir: []const u8) !?[]u8 {
    const r = runGit(gpa, io, dir, &.{ "rev-parse", "--show-toplevel" }) catch return null;
    defer r.deinit(gpa);
    if (!r.ok) return null;
    const top = std.mem.trimEnd(u8, r.stdout, "\r\n");
    if (top.len == 0) return null;
    return try gpa.dupe(u8, top);
}

/// The file as git has it staged: the copy the editor's changes are
/// compared with. Null when git doesn't know the file (it is untracked,
/// so all of it is new). Caller frees.
pub fn showIndex(gpa: Allocator, io: Io, root: []const u8, rel: []const u8) !?[]u8 {
    return show(gpa, io, root, "", rel);
}

/// The file as the last commit has it, which the staged copy is compared
/// with. Caller frees.
pub fn showHead(gpa: Allocator, io: Io, root: []const u8, rel: []const u8) !?[]u8 {
    return show(gpa, io, root, "HEAD", rel);
}

fn show(gpa: Allocator, io: Io, root: []const u8, rev: []const u8, rel: []const u8) !?[]u8 {
    const spec = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ rev, rel });
    defer gpa.free(spec);
    const r = runGit(gpa, io, root, &.{ "show", spec }) catch return null;
    defer r.deinit(gpa);
    if (!r.ok) return null;
    return try gpa.dupe(u8, r.stdout);
}

/// Who last touched each line of a file, as `git blame --porcelain`
/// prints it (see Blame.zig). Null when git can't say — the file is
/// untracked, or isn't text. Caller frees.
pub fn blame(gpa: Allocator, io: Io, root: []const u8, rel: []const u8) !?[]u8 {
    const r = runGit(gpa, io, root, &.{ "blame", "--porcelain", "--", rel }) catch return null;
    defer r.deinit(gpa);
    if (!r.ok) return null;
    return try gpa.dupe(u8, r.stdout);
}

/// Where a patch lands: in what's staged, or in the file itself.
pub const ApplyTo = enum { index, work_tree };

/// Applies one change a patch describes (see `Diff.hunkPatch`), leaving
/// the rest of the file alone; `reverse` takes the change back out. git
/// reads the patch from a file, which goes in the repository's own .git
/// folder so nothing shows up in the work tree.
pub fn apply(self: *Git, io: Io, root: []const u8, patch: []const u8, to: ApplyTo, reverse: bool) !void {
    const dir = try self.gitDir(io, root);
    defer self.gpa.free(dir);
    const path = try std.fs.path.join(self.gpa, &.{ dir, "byte-code-stage.patch" });
    defer self.gpa.free(path);
    const cwd = Io.Dir.cwd();
    {
        var file = try cwd.createFileAtomic(io, path, .{ .replace = true });
        defer file.deinit(io);
        try file.file.writeStreamingAll(io, patch);
        try file.replace(io);
    }
    defer cwd.deleteFile(io, path) catch {};
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(self.gpa);
    try args.appendSlice(self.gpa, &.{ "apply", "--whitespace=nowarn" });
    if (to == .index) try args.append(self.gpa, "--cached");
    if (reverse) try args.append(self.gpa, "--reverse");
    try args.appendSlice(self.gpa, &.{ "--", path });
    try self.expectOk(io, root, args.items);
}

/// The repository's .git folder (a plain file points elsewhere in a work
/// tree or submodule, so git is asked). Caller frees.
fn gitDir(self: *Git, io: Io, root: []const u8) ![]u8 {
    const r = try runGit(self.gpa, io, root, &.{ "rev-parse", "--absolute-git-dir" });
    defer r.deinit(self.gpa);
    if (!r.ok) return error.GitFailed;
    return self.gpa.dupe(u8, std.mem.trimEnd(u8, r.stdout, "\r\n"));
}

/// Commits what's staged. On failure (e.g. a hook refused, or no name and
/// email configured) `last_error` holds git's message.
pub fn commit(self: *Git, io: Io, root: []const u8, message: []const u8) !void {
    try self.expectOk(io, root, &.{ "commit", "--quiet", "-m", message });
}

pub fn expectOk(self: *Git, io: Io, root: []const u8, args: []const []const u8) !void {
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

test {
    _ = @import("tests/Git_test.zig");
}
