//! Tests for Git.zig.
const std = @import("std");
const Git = @import("../Git.zig");
const GitLog = @import("../GitLog.zig");
const GitRefs = @import("../GitRefs.zig");

test "parses porcelain status" {
    var g = Git.init(std.testing.allocator);
    defer g.deinit();
    try g.parse("## main...origin/main [ahead 1]\x00 M src/app.ts\x00A  new.ts\x00R  moved.ts\x00old.ts\x00?? notes.md\x00MM both.zig\x00");
    try std.testing.expectEqualStrings("main", g.branch);
    try std.testing.expectEqual(@as(u32, 1), g.ahead);
    try std.testing.expectEqual(@as(u32, 0), g.behind);
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
    try std.testing.expectEqual(@as(u32, 0), g.ahead);

    // What a push would send and a pull would bring, and a merge left
    // half-done in two files.
    try g.parse("## main...origin/main [ahead 2, behind 3]\x00UU both.zig\x00AA added.zig\x00 M plain.zig\x00");
    try std.testing.expectEqual(@as(u32, 2), g.ahead);
    try std.testing.expectEqual(@as(u32, 3), g.behind);
    var conflicts: usize = 0;
    for (g.entries.items) |entry| conflicts += @intFromBool(entry.isConflict());
    try std.testing.expectEqual(@as(usize, 2), conflicts);
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
    // The temporary folder may sit inside another repository (this
    // project's own): then git finds that one, higher up.
    if (g.state == .ok) try std.testing.expect(!std.mem.eql(u8, g.toplevel, root));

    // Set up a repository with a local identity (so commit works anywhere).
    for ([_][]const []const u8{
        &.{"init"},
        &.{ "config", "user.email", "test@example.com" },
        &.{ "config", "user.name", "Test" },
    }) |args| try g.expectOk(io, root, args);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hi" });

    try g.refresh(io, root);
    try std.testing.expectEqual(Git.State.ok, g.state);
    try std.testing.expectEqualStrings(root, g.toplevel); // our new repository
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

test "real repository: throwing changes away keeps what is staged" {
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
    for ([_][]const []const u8{
        &.{"init"},
        &.{ "config", "user.email", "test@example.com" },
        &.{ "config", "user.name", "Test" },
    }) |args| try g.expectOk(io, root, args);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "two\n" });
    try g.expectOk(io, root, &.{ "add", "." });
    try g.expectOk(io, root, &.{ "commit", "--quiet", "-m", "first" });

    // b.txt has a staged change on top of which the work tree changed
    // again; a.txt changed in the work tree only.
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "staged\n" });
    try g.expectOk(io, root, &.{ "add", "b.txt" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "and then some\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one changed\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "new.txt", .data = "untracked\n" });

    // One file at a time: a.txt goes back to the commit.
    try g.discard(io, root, "a.txt");
    const a = try tmp.dir.readFileAlloc(io, "a.txt", gpa, .limited(64));
    defer gpa.free(a);
    try std.testing.expectEqualStrings("one\n", a);

    // All of them: b.txt goes back to what is staged, which stays staged,
    // and the file git doesn't know is left where it is.
    try g.discardAll(io, root);
    const b = try tmp.dir.readFileAlloc(io, "b.txt", gpa, .limited(64));
    defer gpa.free(b);
    try std.testing.expectEqualStrings("staged\n", b);
    const untracked = try tmp.dir.readFileAlloc(io, "new.txt", gpa, .limited(64));
    defer gpa.free(untracked);
    try std.testing.expectEqualStrings("untracked\n", untracked);

    try g.refresh(io, root);
    try std.testing.expectEqual(@as(usize, 2), g.entries.items.len); // b.txt staged, new.txt untracked
    for (g.entries.items) |e| {
        if (std.mem.eql(u8, e.path, "b.txt")) try std.testing.expect(e.isStaged() and !e.isUnstaged());
    }
}

test "real repository: branches, stashing, and a remote to push to" {
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

    // A bare repository stands in for the remote; cloning it makes the
    // working copy beside it, named after it without the ".git".
    try tmp.dir.createDirPath(io, "origin.git");
    const remote = try tmp.dir.realPathFileAlloc(io, "origin.git", gpa);
    defer gpa.free(remote);
    try g.expectOk(io, remote, &.{ "init", "--bare", "--quiet" });
    try g.clone(io, root, remote);
    const work = try std.fs.path.join(gpa, &.{ root, "origin" });
    defer gpa.free(work);
    for ([_][]const []const u8{
        &.{ "config", "user.email", "test@example.com" },
        &.{ "config", "user.name", "Test" },
    }) |args| try g.expectOk(io, work, args);

    var dir = try std.Io.Dir.cwd().openDir(io, work, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\n" });
    try g.expectOk(io, work, &.{ "add", "a.txt" });
    try g.commit(io, work, "first");

    // Nothing is set up to push to yet: push says so and sets it up.
    try g.push(io, work);
    try g.fetch(io, work);
    try g.refresh(io, work);
    try std.testing.expectEqual(@as(u32, 0), g.ahead);

    // A branch of its own, and back again (to whatever git named the
    // first one: "master" or "main", depending on its settings).
    const first = try gpa.dupe(u8, g.branch);
    defer gpa.free(first);
    try g.createBranch(io, work, "feature", null);
    try g.refresh(io, work);
    try std.testing.expectEqualStrings("feature", g.branch);
    const list = (try Git.readBranches(gpa, io, work)).?;
    defer gpa.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "refs/heads/feature") != null);
    try g.checkout(io, work, first);
    try g.refresh(io, work);
    try std.testing.expectEqualStrings(first, g.branch);

    // Changes put aside and brought back.
    try dir.writeFile(io, .{ .sub_path = "a.txt", .data = "changed\n" });
    try g.stash(io, work, "");
    try g.refresh(io, work);
    try std.testing.expectEqual(@as(usize, 0), g.entries.items.len);
    try g.stashPop(io, work);
    try g.refresh(io, work);
    try std.testing.expectEqual(@as(usize, 1), g.entries.items.len);
}

test "real repository: history, amending, undoing, and a merge" {
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
    for ([_][]const []const u8{
        &.{"init"},
        &.{ "config", "user.email", "test@example.com" },
        &.{ "config", "user.name", "Test" },
    }) |args| try g.expectOk(io, root, args);

    // Undoing the very first commit empties the branch.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\n" });
    try g.stage(io, root, "a.txt");
    try g.commit(io, root, "first");
    const first_message = try g.undoCommit(io, root);
    defer gpa.free(first_message);
    try std.testing.expectEqualStrings("first", first_message);
    try std.testing.expectEqual(@as(?[]u8, null), try Git.readLog(gpa, io, root));
    try g.commit(io, root, "first");

    // Amending: a new message, then more changes under the same one.
    try g.amend(io, root, "the first");
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "two\n" });
    try g.stage(io, root, "b.txt");
    try g.amend(io, root, "");

    var log = GitLog.init(gpa);
    defer log.deinit();
    const out = (try Git.readLog(gpa, io, root)).?;
    defer gpa.free(out);
    try log.parseLog(out);
    try std.testing.expectEqual(@as(usize, 1), log.commits.items.len);
    try std.testing.expectEqualStrings("the first", log.commits.items[0].subject);
    const files = (try Git.commitFiles(gpa, io, root, log.commits.items[0].hash)).?;
    defer gpa.free(files);
    try log.parseFiles(0, files);
    try std.testing.expectEqual(@as(usize, 2), log.files.items.len);
    const old = (try Git.showAt(gpa, io, root, log.commits.items[0].hash, "b.txt")).?;
    defer gpa.free(old);
    try std.testing.expectEqualStrings("two\n", old);

    // Undoing a later commit keeps its changes, staged.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one more\n" });
    try g.stage(io, root, "a.txt");
    try g.commit(io, root, "second");
    const message = try g.undoCommit(io, root);
    defer gpa.free(message);
    try std.testing.expectEqualStrings("second", message);
    try g.refresh(io, root);
    try std.testing.expectEqual(@as(usize, 1), g.entries.items.len);
    try std.testing.expect(g.entries.items[0].isStaged());
    try g.commit(io, root, "second");

    // Both branches change the same line: the merge stops half-done, and
    // can be called off.
    const main = try gpa.dupe(u8, g.branch);
    defer gpa.free(main);
    try g.createBranch(io, root, "other", "HEAD~1");
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "theirs\n" });
    try g.stage(io, root, "a.txt");
    try g.commit(io, root, "theirs");
    try g.checkout(io, root, main);
    try std.testing.expectError(error.GitFailed, g.expectOk(io, root, &.{ "merge", "other" }));
    try g.refresh(io, root);
    try std.testing.expectEqual(@as(?Git.Operation, .merge), g.operation);
    try std.testing.expect(g.entries.items[0].isConflict());
    try g.abortOperation(io, root, .merge);
    try g.refresh(io, root);
    try std.testing.expectEqual(@as(?Git.Operation, null), g.operation);
    try std.testing.expectEqual(@as(usize, 0), g.entries.items.len);
}

test "real repository: managing branches and stashes, with progress" {
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
    for ([_][]const []const u8{
        &.{"init"},
        &.{ "config", "user.email", "test@example.com" },
        &.{ "config", "user.name", "Test" },
    }) |args| try g.expectOk(io, root, args);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\n" });
    try g.stage(io, root, "a.txt");
    try g.commit(io, root, "first");
    try g.refresh(io, root);
    const main = try gpa.dupe(u8, g.branch);
    defer gpa.free(main);
    try std.testing.expect(g.git_dir.len > 0);

    // What .git looks like (taken after git status, which may touch the
    // index itself) stays put until something changes it, like a commit.
    const stamp = g.watchStamp(io);
    try std.testing.expect(stamp != 0);
    try std.testing.expectEqual(stamp, g.watchStamp(io));

    // A branch with a commit of its own, renamed, merged, and deleted.
    try g.createBranch(io, root, "topic", null);
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "two\n" });
    try g.stage(io, root, "b.txt");
    try g.commit(io, root, "second");
    try g.renameBranch(io, root, "topic", "feature");
    try std.testing.expect(g.watchStamp(io) != stamp);
    try g.checkout(io, root, main);
    // Not merged yet: git won't delete it without being told to.
    try std.testing.expectError(error.GitFailed, g.deleteBranch(io, root, "feature", false));
    try g.merge(io, root, "feature");
    try g.deleteBranch(io, root, "feature", false);

    var refs = GitRefs.init(gpa);
    defer refs.deinit();
    const branches = (try Git.readBranches(gpa, io, root)).?;
    defer gpa.free(branches);
    try refs.parseBranches(branches);
    try std.testing.expectEqual(@as(usize, 1), refs.branches.items.len);
    try std.testing.expect(refs.branches.items[0].current);

    // Two stashes, one with a message; the older one comes back first.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "first stash\n" });
    try g.stash(io, root, "");
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "second stash\n" });
    try g.stash(io, root, "the second");
    const stashes = (try Git.readStashes(gpa, io, root)).?;
    defer gpa.free(stashes);
    try refs.parseStashes(stashes);
    try std.testing.expectEqual(@as(usize, 2), refs.stashes.items.len);
    try std.testing.expect(std.mem.endsWith(u8, refs.stashes.items[0].message, "the second"));
    try g.stashApply(io, root, "stash@{1}");
    const a = try tmp.dir.readFileAlloc(io, "a.txt", gpa, .limited(64));
    defer gpa.free(a);
    try std.testing.expectEqualStrings("first stash\n", a);
    try g.stashDrop(io, root, "stash@{1}");
    try g.discardAll(io, root);
    try g.stashPopAt(io, root, "stash@{0}");
    const stashes_left = (try Git.readStashes(gpa, io, root)).?;
    defer gpa.free(stashes_left);
    try std.testing.expectEqualStrings("", stashes_left);

    // A clone with a progress: git's stderr is read as it comes, and
    // what goes wrong is still reported.
    var progress: Git.Progress = .{};
    var g2 = Git.init(gpa);
    defer g2.deinit();
    g2.progress = &progress;
    try tmp.dir.createDirPath(io, "copies");
    const copies = try tmp.dir.realPathFileAlloc(io, "copies", gpa);
    defer gpa.free(copies);
    try g2.clone(io, copies, root);
    try std.testing.expectError(error.GitFailed, g2.clone(io, copies, root)); // already there
    try std.testing.expect(std.mem.indexOf(u8, g2.last_error.items, "already exists") != null);

    // Called off before it starts: nothing runs.
    progress.cancel(io);
    try std.testing.expectError(error.GitCancelled, g2.fetch(io, copies));
}

test "real repository: a command that hangs can be stopped" {
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // no `sleep` to stand in for a remote
    try g.expectOk(io, root, &.{"init"});

    // A "remote" that never answers: git waits on it until stopped.
    var progress: Git.Progress = .{};
    g.progress = &progress;
    const Stopper = struct {
        fn run(p: *Git.Progress, stop_io: std.Io) void {
            stop_io.sleep(.fromMilliseconds(300), .awake) catch {};
            p.cancel(stop_io);
        }
    };
    const stopper = try std.Thread.spawn(.{}, Stopper.run, .{ &progress, io });
    defer stopper.join();
    const started = std.Io.Timestamp.now(io, .awake);
    const result = g.expectOk(io, root, &.{ "-c", "protocol.ext.allow=always", "fetch", "ext::sleep 30" });
    try std.testing.expectError(error.GitCancelled, result);
    const took = started.durationTo(std.Io.Timestamp.now(io, .awake));
    try std.testing.expect(took.toMilliseconds() < 5000);
}

test "real repository: rebasing, cherry-picking, reverting, tags, comparing" {
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
    for ([_][]const []const u8{
        &.{"init"},
        &.{ "config", "user.email", "test@example.com" },
        &.{ "config", "user.name", "Test" },
    }) |args| try g.expectOk(io, root, args);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\n" });
    try g.stage(io, root, "a.txt");
    try g.commit(io, root, "first");
    try g.refresh(io, root);
    const main = try gpa.dupe(u8, g.branch);
    defer gpa.free(main);

    // Another branch with two commits; one of them is copied over.
    try g.createBranch(io, root, "topic", null);
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "b\n" });
    try g.stage(io, root, "b.txt");
    try g.commit(io, root, "add b");
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "topic\n" });
    try g.stage(io, root, "a.txt");
    try g.commit(io, root, "change a on topic");
    try g.checkout(io, root, main);

    var refs = GitRefs.init(gpa);
    defer refs.deinit();
    const not_here = (try Git.readCommitsNotHere(gpa, io, root, "topic")).?;
    defer gpa.free(not_here);
    try refs.parseCommits(not_here);
    try std.testing.expectEqual(@as(usize, 2), refs.commits.items.len);
    try std.testing.expectEqualStrings("add b", refs.commits.items[1].subject);
    try g.cherryPick(io, root, refs.commits.items[1].hash);
    const b = try tmp.dir.readFileAlloc(io, "b.txt", gpa, .limited(64));
    defer gpa.free(b);
    try std.testing.expectEqualStrings("b\n", b);

    // What the two branches differ in, file by file.
    const changed = (try Git.readChangedFiles(gpa, io, root, "HEAD", "topic")).?;
    defer gpa.free(changed);
    try refs.parseFiles(changed);
    try std.testing.expectEqual(@as(usize, 1), refs.files.items.len);
    try std.testing.expectEqualStrings("a.txt", refs.files.items[0].path);

    // Reverting the copy takes b.txt away again, in a commit of its own.
    try g.revertCommit(io, root, "HEAD");
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "b.txt", .{}));

    // A change to a.txt here too: rebasing topic onto it stops at the
    // conflict, which is sorted out and carried on (without an editor).
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "main\n" });
    try g.stage(io, root, "a.txt");
    try g.commit(io, root, "change a on main");
    try g.checkout(io, root, "topic");
    try std.testing.expectError(error.GitFailed, g.rebase(io, root, main));
    try g.refresh(io, root);
    try std.testing.expectEqual(@as(?Git.Operation, .rebase), g.operation);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "both\n" });
    try g.stage(io, root, "a.txt");
    try g.continueOperation(io, root, .rebase, "");
    try g.refresh(io, root);
    try std.testing.expectEqual(@as(?Git.Operation, null), g.operation);

    // Tags: a plain one and one with a message, listed newest first, and
    // shown on their commit in the history.
    try g.createTag(io, root, "v1", "");
    try g.createTag(io, root, "v2", "The second");
    const tags = (try Git.readTags(gpa, io, root)).?;
    defer gpa.free(tags);
    try refs.parseTags(tags);
    try std.testing.expectEqual(@as(usize, 2), refs.tags.items.len);
    const log_out = (try Git.readLog(gpa, io, root)).?;
    defer gpa.free(log_out);
    var log = GitLog.init(gpa);
    defer log.deinit();
    try log.parseLog(log_out);
    try std.testing.expect(std.mem.indexOf(u8, log.commits.items[0].tags, "v1") != null);
    try g.deleteTag(io, root, "v1");
}
