//! A file's Git changes: the marks beside the line numbers while it is
//! being edited, and the tab that shows what changed — both copies of the
//! file in one text, with buttons to undo, stage or unstage one change.
const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const core = @import("core");
const App = @import("../App.zig");
const Tab = @import("../Tab.zig");
const View = @import("../../ui/editor/View.zig");
const i18n = @import("../../i18n/i18n.zig");

const Against = core.Diff.Against;

/// git's copies are read again this often, so staging or committing from
/// somewhere else (the terminal, another editor) shows up here too.
const reread_seconds = 2;
/// Comparing waits this long after the last keystroke.
const settle_seconds = 0.2;

/// Keeps the active tab's changes up to date; called once a frame.
pub fn updateDiff(self: *App) !void {
    const t = self.tab();
    const now = rl.getTime();
    switch (t.kind) {
        .file => {
            const path = t.document.path orelse return t.diff.clear();
            if (!t.diff.isFor(path) or self.diff_dirty or now - t.diff_at > reread_seconds) {
                t.diff_at = now;
                self.diff_dirty = false;
                try readBase(self, t, path, .index);
            }
            if (t.diff.version != t.buffer.version and now - t.changed_at > settle_seconds) {
                try t.diff.compute(t.buffer.items(), t.buffer.version);
            }
        },
        // The diff tab has no buffer of its own to watch: it is rebuilt
        // from the file and from git every so often.
        // A commit's changes stay what they are.
        .diff => if (t.diff.against != .commit and (self.diff_dirty or now - t.diff_at > reread_seconds)) {
            t.diff_at = now;
            self.diff_dirty = false;
            try showChanges(self, t);
        },
        else => {},
    }
}

// ------------------------------------------------------- the diff tab

/// Opens (or brings up) the tab showing what changed in a file: against
/// what's staged, or, for the staged changes themselves, against the last
/// commit.
pub fn openDiffTab(self: *App, path: []const u8, against: Against) !void {
    for (self.tabs.items, 0..) |*t, i| {
        if (t.kind != .diff or t.diff.against != against or !t.diff.isFor(path)) continue;
        try self.activate(i);
        return showChanges(self, self.tab());
    }
    var tab: Tab = .initDiff(self.gpa);
    tab.highlighter.language = .fromPath(path);
    tab.setLabel(self.gpa, path, against) catch {};
    const at = @min(self.active + 1, self.tabs.items.len);
    try self.tabs.insert(self.gpa, at, tab);
    try self.activate(at);
    self.view.scroll = .{ .x = 0, .y = 0 };
    const t = self.tab();
    t.diff.clear();
    readBase(self, t, path, against) catch |err| {
        self.reportError(i18n.tr().errors.open_file, path, err);
        return;
    };
    try showChanges(self, t);
}

/// Opens (or brings up) the tab showing what a commit changed in one of
/// its files: the file as its parent had it against the commit's copy.
pub fn openCommitDiff(self: *App, hash: []const u8, file: core.GitLog.File) !void {
    const parent = try std.fmt.allocPrint(self.gpa, "{s}^", .{hash});
    defer self.gpa.free(parent);
    const label = hash[0..@min(7, hash.len)];
    try openRevDiff(self, parent, hash, file, label);
}

/// The same for any two revisions (branches, commits): the file as `old`
/// has it against `new`'s copy. `label` goes after the file's name.
pub fn openRevDiff(self: *App, old_rev: []const u8, new_rev: []const u8, file: core.GitLog.File, label: []const u8) !void {
    if (old_rev.len + new_rev.len > 256) return error.NameTooLong; // see Diff.setRevs
    const repo = self.git.toplevel;
    const path = try std.fs.path.join(self.gpa, &.{ repo, file.path });
    defer self.gpa.free(path);
    for (self.tabs.items, 0..) |*t, i| {
        if (t.kind == .diff and t.diff.against == .commit and t.diff.isFor(path) and
            std.mem.eql(u8, t.diff.oldRev(), old_rev) and std.mem.eql(u8, t.diff.newRev(), new_rev))
        {
            return self.activate(i);
        }
    }
    const old = try core.Git.showAt(self.gpa, self.io, repo, old_rev, file.old_path);
    defer if (old) |s| self.gpa.free(s);
    const new = try core.Git.showAt(self.gpa, self.io, repo, new_rev, file.path);
    defer if (new) |s| self.gpa.free(s);
    // A file git keeps as something other than text can't be shown.
    const before = old orelse "";
    const after = new orelse "";
    if (!std.unicode.utf8ValidateSlice(before) or !std.unicode.utf8ValidateSlice(after)) return;

    var tab: Tab = .initDiff(self.gpa);
    tab.highlighter.language = .fromPath(path);
    tab.label = try std.fmt.allocPrint(self.gpa, "{s} ({s})", .{ std.fs.path.basename(path), label });
    const at = @min(self.active + 1, self.tabs.items.len);
    try self.tabs.insert(self.gpa, at, tab);
    try self.activate(at);
    self.view.scroll = .{ .x = 0, .y = 0 };
    const t = self.tab();
    try t.diff.setFile(path, repo, file.path, .commit);
    try t.diff.setRevs(old_rev, new_rev);
    try t.diff.setBase(before, true);
    try t.diff.compute(after, t.buffer.version);
    try t.diff.buildCombined();
    try t.buffer.load(t.diff.combined.items);
    t.document.saved_version = t.buffer.version; // never dirty
}

/// Fills a diff tab: compares the two copies and puts them in its buffer,
/// removed lines and all. Leaves the buffer alone when nothing changed,
/// so the view doesn't jump while the file is being edited elsewhere.
fn showChanges(self: *App, t: *Tab) !void {
    const path = t.diff.file orelse return;
    // A fresh `path` is needed: reading the base frees the old one.
    const copy = try self.gpa.dupe(u8, path);
    defer self.gpa.free(copy);
    try readBase(self, t, copy, t.diff.against);
    if (t.diff.file == null) return;

    const text = try newSide(self, t.diff.against, copy, t.diff.repo.?, t.diff.rel.?);
    defer self.gpa.free(text);
    try t.diff.compute(text, t.buffer.version);
    try t.diff.buildCombined();
    if (std.mem.eql(u8, t.buffer.items(), t.diff.combined.items)) return;
    try t.buffer.load(t.diff.combined.items);
    t.document.saved_version = t.buffer.version; // never dirty
}

/// The newer of the two copies: the file as it is now (from the tab
/// editing it, if there is one, so unsaved changes show), or what's
/// staged when the staged changes are the ones being shown.
fn newSide(self: *App, against: Against, path: []const u8, repo: []const u8, rel: []const u8) ![]u8 {
    if (against == .head) {
        const staged = try core.Git.showIndex(self.gpa, self.io, repo, rel);
        return staged orelse try self.gpa.dupe(u8, "");
    }
    for (self.tabs.items) |*t| if (t.hasPath(path)) return self.gpa.dupe(u8, t.buffer.items());
    // A deleted file has nothing left to compare: all of it went.
    const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(core.Document.max_file_size)) catch
        return self.gpa.dupe(u8, "");
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        self.gpa.free(bytes);
        return self.gpa.dupe(u8, "");
    }
    return bytes;
}

// ------------------------------------------------------------ git's copy

/// Reads the copy of the file the changes are measured against. A file
/// outside a repository, or one git keeps as something other than text,
/// gets no marks.
fn readBase(self: *App, t: *Tab, path: []const u8, against: Against) !void {
    // Where the repository starts is asked once per file, not every time
    // its copy is read again.
    if (!t.diff.isFor(path) or t.diff.against != against) {
        const dir = std.fs.path.dirname(path) orelse ".";
        const found = try core.Git.topLevel(self.gpa, self.io, dir);
        const top = found orelse return t.diff.clear();
        defer self.gpa.free(top);
        const under = try relativePath(self.gpa, top, path);
        const rel = under orelse return t.diff.clear();
        defer self.gpa.free(rel);
        try t.diff.setFile(path, top, rel, against);
    }
    const repo = t.diff.repo orelse return;
    const rel = t.diff.rel orelse return;

    const older = if (against == .head)
        try core.Git.showHead(self.gpa, self.io, repo, rel)
    else
        try core.Git.showIndex(self.gpa, self.io, repo, rel);
    defer if (older) |s| self.gpa.free(s);
    const text = older orelse return t.diff.setBase("", false); // git doesn't have it: all new
    if (!std.unicode.utf8ValidateSlice(text)) return t.diff.clear();
    try t.diff.setBase(text, true);
}

/// Where a file sits inside its repository, '/' separated as git wants
/// it; null when it isn't under the repository's top folder after all.
fn relativePath(gpa: std.mem.Allocator, repo: []const u8, path: []const u8) !?[]u8 {
    const slashed = try gpa.dupe(u8, path);
    defer gpa.free(slashed);
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, slashed, std.fs.path.sep, '/');
    const top = std.mem.trimEnd(u8, repo, "/");
    if (slashed.len <= top.len + 1 or slashed[top.len] != '/') return null;
    // Windows spells the same folder either case; everywhere else it doesn't.
    const same = if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(slashed[0..top.len], top)
    else
        std.mem.eql(u8, slashed[0..top.len], top);
    if (!same) return null;
    return try gpa.dupe(u8, slashed[top.len + 1 ..]);
}

// ------------------------------------------------------ drawing & clicks

/// What the editor shows of the changes: marks beside the line numbers
/// while editing, both copies at once in the diff tab.
pub fn changes(self: *const App) ?View.Changes {
    const t = self.activeTab();
    return switch (t.kind) {
        .file => if (t.diff.hunks.items.len == 0) null else .{ .diff = &t.diff, .combined = false },
        .diff => if (t.diff.combined_lines.items.len == 0) null else .{ .diff = &t.diff, .combined = true },
        else => null,
    };
}

/// A click on the buttons beside a change in the diff tab. Returns
/// whether one was hit.
pub fn hunkClick(self: *App, point: rl.Vector2) !bool {
    const ch = self.changes() orelse return false;
    const button = View.hunkButtonAt(self.view, ch, point) orelse return false;
    const t = self.tab();
    if (button.hunk >= t.diff.hunks.items.len) return true;
    const repo = t.diff.repo orelse return true;
    // A file git doesn't know yet has no changes of its own to move: all
    // of it is staged at once, and there is nothing to take back out.
    if (!t.diff.tracked) {
        if (button.action == .stage) self.gitAction(self.git.stage(self.io, repo, t.diff.rel.?));
        return true;
    }
    // git works on the file as it is on disk, so what's in the editor has
    // to be there too.
    try saveOpenTab(self, t.diff.file.?);
    const patch = try t.diff.hunkPatch(self.gpa, t.diff.hunks.items[button.hunk]);
    defer self.gpa.free(patch);
    // Undoing a change puts the file back as git has it; staging and
    // unstaging move it in and out of what a commit would carry.
    self.gitAction(switch (button.action) {
        .revert => self.git.apply(self.io, repo, patch, .work_tree, true),
        .stage => self.git.apply(self.io, repo, patch, .index, false),
        .unstage => self.git.apply(self.io, repo, patch, .index, true),
    });
    if (button.action == .revert) try reloadFile(self, t.diff.file.?);
    return true;
}

/// Saves the tab editing this file, if it has unsaved changes: the patch
/// git gets describes what the editor shows.
fn saveOpenTab(self: *App, path: []const u8) !void {
    for (self.tabs.items) |*t| {
        if (!t.hasPath(path) or !t.isDirty()) continue;
        t.document.save(self.gpa, self.io, std.Io.Dir.cwd(), &t.buffer) catch |err| {
            return self.reportError(i18n.tr().errors.save_file, path, err);
        };
    }
}

/// After a change was undone on disk: the tab editing that file shows it
/// again. One with unsaved changes is left alone — it would lose them.
fn reloadFile(self: *App, path: []const u8) !void {
    for (self.tabs.items) |*t| {
        if (!t.hasPath(path) or t.isDirty()) continue;
        const scroll = if (t == self.tab()) self.view.scroll else t.scroll;
        t.load(self.gpa, self.io, path) catch |err| return self.reportError(i18n.tr().errors.open_file, path, err);
        t.scroll = scroll;
        if (t == self.tab()) self.view.scroll = scroll;
    }
}
