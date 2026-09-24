//! The Git view's commands that rewrite what's committed (amending,
//! undoing the last commit, reverting), the ones that carry on or call
//! off a merge, rebase, cherry-pick or revert that stopped half-way,
//! tagging, and the history under the files.
const std = @import("std");
const core = @import("core");
const App = @import("../App.zig");
const i18n = @import("../../i18n/i18n.zig");
const GitPanel = @import("../../ui/sidebar/GitPanel.zig");

/// Rewriting a commit the remote already has means force-pushing it
/// afterwards: that is asked about first.
fn okToRewrite(self: *App, question: []const u8, ok_label: []const u8) bool {
    const pushed = self.git.has_upstream and self.git.ahead == 0;
    if (!pushed) return true;
    return self.confirm(question, i18n.tr().git.pushed_detail, ok_label);
}

/// Folds what's staged into the last commit, under the message typed in
/// the box if there is one (otherwise it keeps its own).
pub fn amendCommit(self: *App, root: []const u8) !void {
    const t = i18n.tr().git;
    if (!okToRewrite(self, t.amend_pushed_question, t.amend)) return;
    const message = std.mem.trim(u8, self.git_panel.message.text(), " \t\r\n");
    self.git.amend(self.io, root, message) catch |err| return self.gitAction(err);
    try self.git_panel.message.setText("");
    self.gitChanged();
}

/// Takes the last commit back: its changes stay staged and its message
/// goes back in the box, ready to commit again.
pub fn undoCommit(self: *App, root: []const u8) !void {
    const t = i18n.tr().git;
    if (!okToRewrite(self, t.undo_pushed_question, t.undo_commit)) return;
    const message = self.git.undoCommit(self.io, root) catch |err| return self.gitAction(err);
    defer self.gpa.free(message);
    try self.git_panel.message.setText(message);
    self.gitChanged();
}

/// Calls off what stopped half-way (a merge, rebase, cherry-pick or
/// revert), after asking: the conflicts already sorted out are lost too.
pub fn abortOperation(self: *App, root: []const u8) !void {
    const op = self.git.operation orelse return;
    const t = i18n.tr().git;
    const question = if (op == .merge) t.abort_merge_question else t.abort_question;
    const detail = if (op == .merge) t.abort_merge_detail else t.abort_detail;
    if (!self.confirm(question, detail, GitPanel.Command.abort_operation.label(&self.git))) return;
    self.gitAction(self.git.abortOperation(self.io, root, op));
    try filesMoved(self);
}

/// The commit button while something waits half-way: carries it on.
pub fn continueOperation(self: *App, root: []const u8, op: core.Git.Operation) !void {
    const message = std.mem.trim(u8, self.git_panel.message.text(), " \t\r\n");
    try stoppable(self, root, self.git.continueOperation(self.io, root, op, message));
    if (self.git.operation == null) try self.git_panel.message.setText("");
}

/// A rebase stopped at a commit whose changes aren't wanted: leaves it
/// out and goes on.
pub fn skipRebaseCommit(self: *App, root: []const u8) !void {
    try stoppable(self, root, self.git.skipRebaseCommit(self.io, root));
}

/// After a merge, rebase, cherry-pick or revert (or carrying one on).
/// Stopping at a conflict isn't an error to report: the conflicts show in
/// the Git view, to be sorted out. Anything else that went wrong is.
pub fn stoppable(self: *App, root: []const u8, result: anyerror!void) !void {
    result catch |err| {
        try self.git.refresh(self.io, root);
        const stopped = self.git.operation != null and GitPanel.count(&self.git, .conflicts) > 0;
        if (!stopped) self.gitAction(err);
    };
    self.gitChanged();
    self.showView(.git);
    try filesMoved(self);
}

/// git changed files on disk: the tree and the tabs showing them are
/// read again.
fn filesMoved(self: *App) !void {
    try self.refreshProject();
    try self.reloadUnchangedTabs();
}

/// The button on a commit in the history: a new commit takes it back,
/// after asking.
pub fn revertCommit(self: *App, root: []const u8, index: u32) !void {
    const c = self.git.history.commits.items[index];
    const t = i18n.tr().git;
    const question = try i18n.fillAlloc(self.gpa, t.revert_question, .{c.subject});
    defer self.gpa.free(question);
    if (!self.confirm(question, t.revert_detail, t.revert_commit)) return;
    const hash = try self.gpa.dupe(u8, c.hash);
    defer self.gpa.free(hash);
    try stoppable(self, root, self.git.revertCommit(self.io, root, hash));
}

/// A tag on the commit checked out: its name, then a message (which
/// can be left empty).
pub fn createTag(self: *App, root: []const u8) !void {
    const t = i18n.tr().git;
    const name = try self.askText(t.tag_title, t.tag_name, false) orelse return;
    defer self.gpa.free(name);
    const trimmed = std.mem.trim(u8, name, " \t");
    if (trimmed.len == 0) return;
    const message = try self.askText(t.tag_message_title, t.tag_message, false) orelse return;
    defer self.gpa.free(message);
    self.gitAction(self.git.createTag(self.io, root, trimmed, std.mem.trim(u8, message, " \t")));
}

/// A conflicted file is sorted out: it is staged. If markers are still
/// in it, that's probably a mistake, so it is asked about.
pub fn markResolved(self: *App, root: []const u8, index: u32) !void {
    const e = self.git.entries.items[index];
    const path = try std.fs.path.join(self.gpa, &.{ self.git.toplevel, e.path });
    defer self.gpa.free(path);
    // git takes the file from disk: what the editor shows goes there first.
    for (self.tabs.items) |*tab| {
        if (!tab.hasPath(path) or !tab.isDirty()) continue;
        tab.document.save(self.gpa, self.io, std.Io.Dir.cwd(), &tab.buffer) catch |err| {
            return self.reportError(i18n.tr().errors.save_file, path, err);
        };
    }
    const text = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(core.Document.max_file_size)) catch null;
    defer if (text) |s| self.gpa.free(s);
    if (text) |s| if (try core.Conflicts.any(self.gpa, s)) {
        const t = i18n.tr().git;
        const question = try i18n.fillAlloc(self.gpa, t.still_conflicted_question, .{std.fs.path.basename(e.path)});
        defer self.gpa.free(question);
        if (!self.confirm(question, t.still_conflicted_detail, t.mark_resolved)) return;
    };
    self.gitAction(self.git.stage(self.io, root, e.path));
}

// ------------------------------------------------------------ history

/// Reads the branch's commits again (while the history is showing).
pub fn readHistory(self: *App, root: []const u8) !void {
    const out = try core.Git.readLog(self.gpa, self.io, root);
    defer if (out) |s| self.gpa.free(s);
    try self.git.history.parseLog(out orelse "");
    // The open commit's files are read again too: an amend changes them.
    if (self.git.history.open) |i| try openCommit(self, root, i, true);
}

pub fn toggleHistory(self: *App, root: []const u8) !void {
    self.git_panel.history_open = !self.git_panel.history_open;
    if (self.git_panel.history_open) try readHistory(self, root);
}

/// A commit's row: shows the files it changed, or folds them away again.
pub fn openCommit(self: *App, root: []const u8, index: u32, keep_open: bool) !void {
    const log = &self.git.history;
    if (!keep_open and log.open == index) return log.closeFiles();
    const hash = log.commits.items[index].hash;
    const out = try core.Git.commitFiles(self.gpa, self.io, root, hash);
    defer if (out) |s| self.gpa.free(s);
    try log.parseFiles(index, out orelse "");
}

/// One of the open commit's files: what the commit changed in it.
pub fn openCommitFile(self: *App, index: u32) !void {
    const log = &self.git.history;
    const commit = log.open orelse return;
    try self.openCommitDiff(log.commits.items[commit].hash, log.files.items[index]);
}
