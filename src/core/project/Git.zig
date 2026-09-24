//! Git for the sidebar's Git view: the working tree's status (via
//! `git status --porcelain`), staging, unstaging, throwing changes away,
//! committing, and the commands the view's list offers (push, pull,
//! branches, stashing). Runs the `git` command-line tool in the project
//! folder.
//!
//! Everything here blocks until git is done. The ones that reach the
//! network can take a while: the editor runs them on a thread of their
//! own, with a `Progress` that shows how far git got and can stop it.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const GitLog = @import("GitLog.zig");
const GitRefs = @import("GitRefs.zig");

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

    /// A merge left both sides in the file: it is neither staged nor
    /// simply changed until someone sorts it out.
    pub fn isConflict(e: Entry) bool {
        if (e.staged == 'U' or e.unstaged == 'U') return true;
        return (e.staged == 'A' and e.unstaged == 'A') or (e.staged == 'D' and e.unstaged == 'D');
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
/// can be above the project folder), and its .git folder.
toplevel: []const u8 = "",
git_dir: []const u8 = "",
/// Commits this branch has that its upstream doesn't, and the other way
/// round: what a push would send, and what a pull would bring.
ahead: u32 = 0,
behind: u32 = 0,
/// Whether the branch has a remote one it pushes to and pulls from.
has_upstream: bool = false,
/// A merge is waiting to be committed (or called off).
merging: bool = false,
entries: std.ArrayList(Entry) = .empty,
/// The branch's commits, read while the Git view shows them.
history: GitLog,
/// Git's error output from the last failed command.
last_error: std.ArrayList(u8) = .empty,
/// Where a long command (push, pull...) says how far it got, and how it
/// is stopped. Commands run without one when null.
progress: ?*Progress = null,
/// The environment the commands run with, when not the editor's own: the
/// one that sends git's password questions to the editor (see AskPass).
environ: ?*const std.process.Environ.Map = null,

pub fn init(gpa: Allocator) Git {
    return .{ .gpa = gpa, .arena = .init(gpa), .history = .init(gpa) };
}

pub fn deinit(self: *Git) void {
    self.last_error.deinit(self.gpa);
    self.history.deinit();
    self.entries.deinit(self.gpa);
    self.arena.deinit();
}

/// Re-reads `git status` for the repository at `root`.
pub fn refresh(self: *Git, io: Io, root: []const u8) !void {
    const top = runGit(self.gpa, io, root, &.{ "rev-parse", "--show-toplevel", "--absolute-git-dir" }) catch |err| {
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
    const merge_head = try runGit(self.gpa, io, root, &.{ "rev-parse", "-q", "--verify", "MERGE_HEAD" });
    defer merge_head.deinit(self.gpa);
    self.merging = merge_head.ok;
    var lines = std.mem.splitScalar(u8, top.stdout, '\n');
    self.toplevel = try self.arena.allocator().dupe(u8, std.mem.trimEnd(u8, lines.next() orelse "", "\r"));
    self.git_dir = try self.arena.allocator().dupe(u8, std.mem.trimEnd(u8, lines.next() orelse "", "\r"));
    self.state = .ok;
}

/// The files in .git that change when anything git would report changes:
/// a commit, a checkout, staging, a fetch, a merge, a stash.
const watched = [_][]const u8{ "HEAD", "index", "logs/HEAD", "FETCH_HEAD", "MERGE_HEAD", "ORIG_HEAD", "refs/stash", "packed-refs" };

/// A number that changes whenever one of those files does (its time or
/// size), so git's own state is read again only then. 0 outside a
/// repository.
pub fn watchStamp(self: *const Git, io: Io) u64 {
    if (self.git_dir.len == 0) return 0;
    var dir = Io.Dir.cwd().openDir(io, self.git_dir, .{}) catch return 0;
    defer dir.close(io);
    var h = std.hash.Wyhash.init(0);
    for (watched) |name| {
        const st = dir.statFile(io, name, .{}) catch {
            h.update("-");
            continue;
        };
        h.update(std.mem.asBytes(&st.mtime.nanoseconds));
        h.update(std.mem.asBytes(&st.size));
    }
    return h.final();
}

fn clear(self: *Git) void {
    self.entries.clearRetainingCapacity();
    _ = self.arena.reset(.retain_capacity);
    self.branch = "";
    self.toplevel = "";
    self.git_dir = "";
    self.ahead = 0;
    self.behind = 0;
    self.has_upstream = false;
    self.merging = false;
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
            self.has_upstream = std.mem.indexOf(u8, b, "...") != null;
            // "[ahead 2, behind 1]" at the end of the line.
            if (std.mem.indexOf(u8, b, "ahead ")) |at| self.ahead = count(b[at + "ahead ".len ..]);
            if (std.mem.indexOf(u8, b, "behind ")) |at| self.behind = count(b[at + "behind ".len ..]);
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

/// The number a string starts with, 0 if it doesn't start with one.
fn count(s: []const u8) u32 {
    var end: usize = 0;
    while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
    return std.fmt.parseInt(u32, s[0..end], 10) catch 0;
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

/// The file as commit `rev` has it (e.g. "abc123" or "abc123^"). Null
/// when it isn't there: added by that commit, or deleted before it.
pub fn showAt(gpa: Allocator, io: Io, root: []const u8, rev: []const u8, rel: []const u8) !?[]u8 {
    return show(gpa, io, root, rev, rel);
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

// -------------------------------------------------------- the commands

/// Sends this branch's commits. A branch without an upstream gets one,
/// which is what git itself suggests in that case.
pub fn push(self: *Git, io: Io, root: []const u8) !void {
    self.expectOk(io, root, &.{ "push", "--progress" }) catch |err| {
        if (err == error.GitCancelled or std.mem.indexOf(u8, self.last_error.items, "--set-upstream") == null) return err;
        try self.expectOk(io, root, &.{ "push", "--progress", "--set-upstream", "origin", "HEAD" });
    };
}

pub fn pull(self: *Git, io: Io, root: []const u8) !void {
    try self.expectOk(io, root, &.{ "pull", "--progress", "--no-edit" });
}

/// What the remote has, without touching the work tree: it is what the
/// "to pull" counter is worked out from.
pub fn fetch(self: *Git, io: Io, root: []const u8) !void {
    try self.expectOk(io, root, &.{ "fetch", "--progress", "--prune" });
}

/// Both ways round: take what the remote has, then send what it doesn't.
pub fn sync(self: *Git, io: Io, root: []const u8) !void {
    try self.pull(io, root);
    try self.push(io, root);
}

/// Copies a repository into `parent`, as a folder named after it.
pub fn clone(self: *Git, io: Io, parent: []const u8, url: []const u8) !void {
    try self.expectOk(io, parent, &.{ "clone", "--progress", "--", url });
}

pub fn checkout(self: *Git, io: Io, root: []const u8, branch: []const u8) !void {
    try self.expectOk(io, root, &.{ "checkout", branch });
}

/// Starts a branch and moves onto it, from `base` when there is one.
pub fn createBranch(self: *Git, io: Io, root: []const u8, name: []const u8, base: ?[]const u8) !void {
    if (base) |from| {
        try self.expectOk(io, root, &.{ "checkout", "-b", name, from });
    } else {
        try self.expectOk(io, root, &.{ "checkout", "-b", name });
    }
}

/// A remote's branch, checked out as a local one that follows it.
pub fn checkoutRemote(self: *Git, io: Io, root: []const u8, remote_branch: []const u8) !void {
    try self.expectOk(io, root, &.{ "checkout", "--track", remote_branch });
}

/// Deletes a branch. Without `force` git refuses one whose commits
/// aren't merged anywhere (they would be lost).
pub fn deleteBranch(self: *Git, io: Io, root: []const u8, name: []const u8, force: bool) !void {
    try self.expectOk(io, root, &.{ "branch", if (force) "-D" else "-d", "--", name });
}

pub fn renameBranch(self: *Git, io: Io, root: []const u8, old: []const u8, new: []const u8) !void {
    try self.expectOk(io, root, &.{ "branch", "-m", old, new });
}

/// Merges a branch into the one checked out. A conflict leaves the merge
/// half-done (`merging`), to be sorted out or called off.
pub fn merge(self: *Git, io: Io, root: []const u8, branch: []const u8) !void {
    try self.expectOk(io, root, &.{ "merge", "--no-edit", branch });
}

/// Puts the changes aside, under `message` when there is one; `pop`
/// brings the last lot back.
pub fn stash(self: *Git, io: Io, root: []const u8, message: []const u8) !void {
    if (message.len == 0) return self.expectOk(io, root, &.{ "stash", "push" });
    try self.expectOk(io, root, &.{ "stash", "push", "-m", message });
}

pub fn stashPop(self: *Git, io: Io, root: []const u8) !void {
    try self.expectOk(io, root, &.{ "stash", "pop" });
}

/// One stash (`ref` is e.g. "stash@{2}"): brought back and dropped,
/// brought back and kept, or just dropped.
pub fn stashPopAt(self: *Git, io: Io, root: []const u8, ref: []const u8) !void {
    try self.expectOk(io, root, &.{ "stash", "pop", ref });
}

pub fn stashApply(self: *Git, io: Io, root: []const u8, ref: []const u8) !void {
    try self.expectOk(io, root, &.{ "stash", "apply", ref });
}

pub fn stashDrop(self: *Git, io: Io, root: []const u8, ref: []const u8) !void {
    try self.expectOk(io, root, &.{ "stash", "drop", ref });
}

/// The branches and the stashes, as `GitRefs` reads them. Caller frees.
pub fn readBranches(gpa: Allocator, io: Io, root: []const u8) !?[]u8 {
    const r = runGit(gpa, io, root, &GitRefs.branch_args) catch return null;
    defer r.deinit(gpa);
    if (!r.ok) return null;
    return try gpa.dupe(u8, r.stdout);
}

pub fn readStashes(gpa: Allocator, io: Io, root: []const u8) !?[]u8 {
    const r = runGit(gpa, io, root, &GitRefs.stash_args) catch return null;
    defer r.deinit(gpa);
    if (!r.ok) return null;
    return try gpa.dupe(u8, r.stdout);
}

/// The branches, most recently worked on first, one per line. `remote`
/// takes in the ones only the remote has (as "origin/name"), for picking
/// what to start a branch from. Caller frees.
pub fn branches(gpa: Allocator, io: Io, root: []const u8, remote: bool) !?[]u8 {
    const args: []const []const u8 = if (remote)
        &.{ "branch", "--all", "--format=%(refname:short)", "--sort=-committerdate" }
    else
        &.{ "branch", "--format=%(refname:short)", "--sort=-committerdate" };
    const r = runGit(gpa, io, root, args) catch return null;
    defer r.deinit(gpa);
    if (!r.ok) return null;
    return try gpa.dupe(u8, r.stdout);
}

/// The branch's latest commits, as `GitLog.parseLog` reads them. Null
/// when there are none yet. Caller frees.
pub fn readLog(gpa: Allocator, io: Io, root: []const u8) !?[]u8 {
    const r = runGit(gpa, io, root, &GitLog.log_args) catch return null;
    defer r.deinit(gpa);
    if (!r.ok) return null;
    return try gpa.dupe(u8, r.stdout);
}

/// The files a commit changed, as `GitLog.parseFiles` reads them.
/// Caller frees.
pub fn commitFiles(gpa: Allocator, io: Io, root: []const u8, hash: []const u8) !?[]u8 {
    const r = runGit(gpa, io, root, &GitLog.filesArgs(hash)) catch return null;
    defer r.deinit(gpa);
    if (!r.ok) return null;
    return try gpa.dupe(u8, r.stdout);
}

/// Folds what's staged into the last commit. With no message, the
/// commit keeps the one it has.
pub fn amend(self: *Git, io: Io, root: []const u8, message: []const u8) !void {
    if (message.len == 0) return self.expectOk(io, root, &.{ "commit", "--quiet", "--amend", "--no-edit" });
    try self.expectOk(io, root, &.{ "commit", "--quiet", "--amend", "-m", message });
}

/// Takes the last commit back: its changes stay, staged, and its message
/// is returned (caller frees) so it can be used again.
pub fn undoCommit(self: *Git, io: Io, root: []const u8) ![]u8 {
    const msg = try runGit(self.gpa, io, root, &.{ "log", "-1", "--format=%B" });
    defer msg.deinit(self.gpa);
    if (!msg.ok) {
        try self.setError(msg);
        return error.GitFailed;
    }
    const parent = try runGit(self.gpa, io, root, &.{ "rev-parse", "-q", "--verify", "HEAD~1" });
    defer parent.deinit(self.gpa);
    // The first commit has nothing to go back to: the branch is emptied.
    if (parent.ok) {
        try self.expectOk(io, root, &.{ "reset", "--quiet", "--soft", "HEAD~1" });
    } else {
        try self.expectOk(io, root, &.{ "update-ref", "-d", "HEAD" });
    }
    return self.gpa.dupe(u8, std.mem.trim(u8, msg.stdout, " \r\n"));
}

/// Calls the merge off: everything goes back to how it was before it.
pub fn abortMerge(self: *Git, io: Io, root: []const u8) !void {
    try self.expectOk(io, root, &.{ "merge", "--abort" });
}

/// Finishes a merge whose conflicts are sorted out, with git's own
/// message unless another is given.
pub fn commitMerge(self: *Git, io: Io, root: []const u8, message: []const u8) !void {
    if (message.len == 0) return self.expectOk(io, root, &.{ "commit", "--quiet", "--no-edit" });
    try self.expectOk(io, root, &.{ "commit", "--quiet", "-m", message });
}

/// Commits what's staged. On failure (e.g. a hook refused, or no name and
/// email configured) `last_error` holds git's message.
pub fn commit(self: *Git, io: Io, root: []const u8, message: []const u8) !void {
    try self.expectOk(io, root, &.{ "commit", "--quiet", "-m", message });
}

pub fn expectOk(self: *Git, io: Io, root: []const u8, args: []const []const u8) !void {
    const r = if (self.progress) |p|
        try runStreaming(self.gpa, io, root, args, self.environ, p)
    else
        try runGitIn(self.gpa, io, root, args, self.environ);
    defer r.deinit(self.gpa);
    if (r.ok) return;
    try self.setError(r);
    return error.GitFailed;
}

fn setError(self: *Git, r: Result) !void {
    self.last_error.clearRetainingCapacity();
    const out = if (r.stderr.len > 0) r.stderr else r.stdout;
    // What git printed over and over (the progress it overwrites with a
    // carriage return) leaves only its last version.
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |raw| {
        const shown = raw[if (std.mem.lastIndexOfScalar(u8, std.mem.trimEnd(u8, raw, "\r"), '\r')) |at| at + 1 else 0..];
        const line = std.mem.trim(u8, shown, " \r");
        if (line.len == 0) continue;
        if (self.last_error.items.len > 0) try self.last_error.append(self.gpa, '\n');
        try self.last_error.appendSlice(self.gpa, line);
    }
}

/// How far a long command got, and the way to stop it. Shared between
/// the thread running git and the one drawing the window.
pub const Progress = struct {
    mutex: Io.Mutex = .init,
    /// The last line git printed about what it is doing.
    line: [200]u8 = undefined,
    line_len: usize = 0,
    /// The git process running, while it runs.
    pid: ?std.process.Child.Id = null,
    cancelled: std.atomic.Value(bool) = .init(false),

    /// The last line, copied into `out` (it changes as git goes on).
    pub fn current(self: *Progress, io: Io, out: []u8) []const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const n = @min(out.len, self.line_len);
        @memcpy(out[0..n], self.line[0..n]);
        return out[0..n];
    }

    /// Stops git: the command fails with `error.GitCancelled`.
    pub fn cancel(self: *Progress, io: Io) void {
        self.cancelled.store(true, .release);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.pid) |pid| terminate(pid);
    }

    fn set(self: *Progress, io: Io, text: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.line_len = @min(text.len, self.line.len);
        @memcpy(self.line[0..self.line_len], text[0..self.line_len]);
    }

    fn setPid(self: *Progress, io: Io, pid: ?std.process.Child.Id) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.pid = pid;
    }
};

/// Ends git, and what it started (ssh, the https helper): on POSIX it
/// runs in a process group of its own, which goes as a whole.
fn terminate(pid: std.process.Child.Id) void {
    switch (@import("builtin").os.tag) {
        .windows => _ = TerminateProcess(pid, 1),
        else => std.posix.kill(-pid, std.posix.SIG.TERM) catch {},
    }
}

extern "kernel32" fn TerminateProcess(process: std.os.windows.HANDLE, exit_code: c_uint) callconv(.winapi) std.os.windows.BOOL;

/// The last thing git said about how far it got: the text after the last
/// line break or carriage return that has something after it.
fn lastLine(out: []const u8) []const u8 {
    var end = out.len;
    while (end > 0 and (out[end - 1] == '\n' or out[end - 1] == '\r' or out[end - 1] == ' ')) end -= 1;
    const start = if (std.mem.lastIndexOfAny(u8, out[0..end], "\r\n")) |at| at + 1 else 0;
    return out[start..end];
}

/// Runs git reading what it prints to stderr as it goes, for `progress`.
fn runStreaming(gpa: Allocator, io: Io, root: []const u8, args: []const []const u8, environ: ?*const std.process.Environ.Map, progress: *Progress) !Result {
    if (progress.cancelled.load(.acquire)) return error.GitCancelled;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "git", "-C", root });
    try argv.appendSlice(gpa, args);
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = environ,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
        .pgid = if (@import("builtin").os.tag == .windows) null else 0,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.GitNotFound,
        else => |e| return e,
    };
    defer child.kill(io);
    progress.setPid(io, child.id);

    var err_out: std.ArrayList(u8) = .empty;
    errdefer err_out.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = child.stderr.?.readStreaming(io, &.{&buf}) catch break;
        if (n == 0) break;
        // Enough to say what went wrong; the rest is more progress.
        if (err_out.items.len < 256 * 1024) try err_out.appendSlice(gpa, buf[0..n]);
        progress.set(io, lastLine(err_out.items));
    }
    // Done with the pid before git is waited for (after which the number
    // may go to another process).
    progress.setPid(io, null);
    const term = try child.wait(io);
    if (progress.cancelled.load(.acquire)) return error.GitCancelled;
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{ .ok = ok, .stdout = try gpa.alloc(u8, 0), .stderr = try err_out.toOwnedSlice(gpa) };
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
    return runGitIn(gpa, io, root, args, null);
}

fn runGitIn(gpa: Allocator, io: Io, root: []const u8, args: []const []const u8, environ: ?*const std.process.Environ.Map) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "git", "-C", root });
    try argv.appendSlice(gpa, args);
    const r = std.process.run(gpa, io, .{ .argv = argv.items, .environ_map = environ }) catch |err| switch (err) {
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
