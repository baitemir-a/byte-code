//! The sidebar's Search and Git views: showing them, their text boxes
//! and clicks, and git actions.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const dialogs = @import("../../platform/lib/dialogs.zig");
const Tab = @import("../Tab.zig");
const Sidebar = @import("../../ui/sidebar/Sidebar.zig");
const App = @import("../App.zig");
const clipboard = @import("clipboard.zig");
const i18n = @import("../../i18n/i18n.zig");

/// Shows a sidebar view (Explorer, Search, Git); Search puts the keyboard
/// in its query box.
pub fn showView(self: *App, view: Sidebar.View) void {
    self.sidebar.visible = true;
    self.sidebar.view = view;
    self.sidebar.cancelInput();
    self.completion.close();
    self.terminal_focused = false;
    self.side_focus = .none;
    switch (view) {
        .explorer => {},
        .search => {
            self.side_focus = .search;
            self.search_panel.query.buffer.selectAll();
        },
        .git => self.git_dirty = true,
    }
}

/// Runs a search once typing pauses; re-reads git status when needed.
pub fn updateSidebarViews(self: *App) !void {
    const now = rl.getTime();
    if (self.search_panel.changed_at) |t| if (now - t > 0.3) try self.runSearch(.top);
    if (self.sidebar.view == .git and self.sidebar.width() > 0) if (self.project) |*p| {
        if (self.git_dirty or now - self.git_read_at > 5) {
            try self.git.refresh(self.io, p.root().path);
            self.git_dirty = false;
            self.git_read_at = now;
        }
    };
}

/// Keys while a sidebar text box has focus. Returns false for commands
/// the editor should still get (save, find).
pub fn sideFieldKey(self: *App, cmd: core.Command) !bool {
    const field = switch (self.side_focus) {
        .none => return false,
        .search => &self.search_panel.query,
        .search_replace => &self.search_panel.replacement,
        .git_message => &self.git_panel.message,
    };
    switch (cmd) {
        .newline => switch (self.side_focus) {
            .search => try self.runSearch(.top),
            .search_replace => try self.replaceInProject(),
            else => try self.gitCommit(),
        },
        // Tab moves between the search and replace boxes.
        .indent => switch (self.side_focus) {
            .search => self.side_focus = .search_replace,
            .search_replace => self.side_focus = .search,
            else => {},
        },
        .clear_selection => self.side_focus = .none,
        .copy, .cut => try clipboard.copyOrCut(self.gpa, &field.buffer, cmd == .cut),
        .paste => if (clipboard.getClipboard()) |s| try field.paste(s),
        .toggle_match_case, .toggle_whole_word => if (self.side_focus != .git_message) {
            self.search_panel.toggle(if (cmd == .toggle_match_case) .match_case else .whole_word);
        },
        .save, .save_as, .find, .find_replace, .find_next, .find_prev => return false,
        else => _ = try field.handle(cmd),
    }
    if (self.side_focus != .git_message and self.search_panel.stale()) {
        self.search_panel.changed_at = rl.getTime();
    }
    return true;
}

/// A click in the Search or Git view.
pub fn panelClick(self: *App, point: rl.Vector2) !void {
    const project = if (self.project) |*p| p else return;
    const root = project.root().path;
    switch (self.sidebar.view) {
        .explorer => {},
        .search => {
            const panel = &self.search_panel;
            if (panel.onField(point)) {
                self.side_focus = .search;
                panel.query.buffer.moveTo(panel.query.posAtX(panel.field_rect, self.view.font, point.x), false);
                return;
            }
            if (panel.onReplaceField(point)) {
                self.side_focus = .search_replace;
                panel.replacement.buffer.moveTo(panel.replacement.posAtX(panel.replace_rect, self.view.font, point.x), false);
                return;
            }
            if (panel.onToggle(point)) |o| {
                panel.toggle(o);
                return self.runSearch(.top);
            }
            if (panel.onReplaceAll(point)) return self.replaceInProject();
            if (panel.replaceButtonAt(self.view.font, point)) |row| return switch (row) {
                .match => |m| self.replaceMatchInProject(m),
                .file => |f| self.replaceInProjectFile(f),
            };
            const row = panel.rowAt(point) orelse return;
            const file = switch (row) {
                .file => |i| i,
                .match => |m| panel.results.matches.items[m].file,
            };
            const path = try std.fs.path.join(self.gpa, &.{ root, panel.results.files.items[file].path });
            defer self.gpa.free(path);
            self.side_focus = .none;
            self.openFile(path) catch |err| return self.reportError(i18n.tr().errors.open_file, path, err);
            if (row == .match) {
                // Select the match (if the file hasn't changed under it).
                const m = panel.results.matches.items[row.match];
                const b = self.buf();
                if (m.end <= b.items().len) {
                    b.moveTo(m.start, false);
                    b.moveTo(m.end, true);
                    self.reveal_cursor = true;
                }
            }
        },
        .git => {
            const hit = self.git_panel.hitTest(&self.git, point) orelse return;
            switch (hit) {
                .message => {
                    self.side_focus = .git_message;
                    const f = &self.git_panel.message;
                    f.buffer.moveTo(f.posAtX(self.git_panel.field_rect, self.view.font, point.x), false);
                },
                .commit => try self.gitCommit(),
                .stage_all => self.gitAction(self.git.stageAll(self.io, root)),
                .unstage_all => self.gitAction(self.git.unstageAll(self.io, root)),
                .stage => |i| self.gitAction(self.git.stage(self.io, root, self.git.entries.items[i].path)),
                .unstage => |i| self.gitAction(self.git.unstage(self.io, root, self.git.entries.items[i].path)),
                // Throwing changes away can't be undone: ask first.
                .discard => |i| try discardEntry(self, root, i),
                .discard_all => try discardEverything(self, root),
                // A row opens the tab showing what changed in that file:
                // against what's staged, or, for a staged row, against
                // the last commit.
                .open => |o| {
                    const e = self.git.entries.items[o.index];
                    const path = try std.fs.path.join(self.gpa, &.{ self.git.toplevel, e.path });
                    defer self.gpa.free(path);
                    self.openDiffTab(path, if (o.staged) .head else .index) catch |err| {
                        self.reportError(i18n.tr().errors.open_file, path, err);
                    };
                },
            }
        },
    }
}

/// One row's changes go back to git's copy; a file git doesn't know yet
/// has nothing to go back to, so it goes to the trash instead.
fn discardEntry(self: *App, root: []const u8, index: u32) !void {
    const e = self.git.entries.items[index];
    const t = i18n.tr().git;
    const untracked = e.unstaged == '?';
    const name = std.fs.path.basename(e.path);
    const question = try i18n.fillAlloc(self.gpa, if (untracked) t.delete_question else t.discard_question, .{name});
    defer self.gpa.free(question);
    const detail = if (untracked) t.delete_detail else t.discard_detail;
    const label = if (untracked) i18n.tr().sidebar.delete else t.discard;
    if (!try askDiscard(self, question, detail, label)) return;
    if (untracked) {
        const path = try std.fs.path.join(self.gpa, &.{ self.git.toplevel, e.path });
        defer self.gpa.free(path);
        deleteUntracked(self, path);
        try self.refreshProject();
    } else {
        self.gitAction(self.git.discard(self.io, root, e.path));
    }
    self.gitChanged();
    try reloadDiscarded(self);
}

/// The whole list: tracked files go back to git's copy, and the files it
/// doesn't know yet go to the trash with them.
fn discardEverything(self: *App, root: []const u8) !void {
    const t = i18n.tr().git;
    var new_files = false;
    var tracked = false;
    for (self.git.entries.items) |e| {
        if (!e.isUnstaged()) continue;
        if (e.unstaged == '?') new_files = true else tracked = true;
    }
    const detail = if (new_files) t.discard_all_detail else t.discard_detail;
    if (!try askDiscard(self, t.discard_all_question, detail, t.discard)) return;
    if (tracked) self.gitAction(self.git.discardAll(self.io, root));
    if (new_files) {
        for (self.git.entries.items) |e| {
            if (e.unstaged != '?') continue;
            const path = try std.fs.path.join(self.gpa, &.{ self.git.toplevel, e.path });
            defer self.gpa.free(path);
            deleteUntracked(self, path);
        }
        try self.refreshProject();
    }
    self.gitChanged();
    try reloadDiscarded(self);
}

/// To the trash, where it can still be fished out; if the system has no
/// trash, it goes for good.
fn deleteUntracked(self: *App, path: []const u8) void {
    dialogs.moveToTrash(self.gpa, self.io, path) catch {
        std.Io.Dir.cwd().deleteFile(self.io, path) catch |err| {
            self.reportError(i18n.tr().errors.delete, path, err);
        };
    };
}

/// "Discard the changes?" — they can't be brought back afterwards. The
/// third button goes ahead and turns the question off in Settings.
fn askDiscard(self: *App, question: []const u8, detail: []const u8, ok_label: []const u8) !bool {
    if (!self.settings.confirm_discard) return true;
    const answer = dialogs.confirmRemember(self.gpa, self.io, question, detail, ok_label, i18n.tr().git.discard_always) catch return false;
    if (answer == .ok_always) {
        const old = self.settings;
        self.settings.confirm_discard = false;
        try self.settingsChanged(old);
    }
    return answer != .cancel;
}

/// Files whose changes were thrown away are on disk as git has them: the
/// tabs showing them are read again. One with unsaved changes is left
/// alone — it would lose them.
fn reloadDiscarded(self: *App) !void {
    for (self.tabs.items) |*t| {
        if (t.kind != .file or t.isDirty()) continue;
        const path = t.document.path orelse continue;
        // A file that was deleted keeps showing what the editor has.
        std.Io.Dir.cwd().access(self.io, path, .{}) catch continue;
        const copy = try self.gpa.dupe(u8, path);
        defer self.gpa.free(copy);
        const scroll = if (t == self.tab()) self.view.scroll else t.scroll;
        t.load(self.gpa, self.io, copy) catch continue; // deleted, or unreadable
        t.scroll = scroll;
        if (t == self.tab()) self.view.scroll = scroll;
    }
}

/// After a git command: report git's own message if it failed, and
/// re-read the status either way.
pub fn gitAction(self: *App, result: anyerror!void) void {
    result catch dialogs.showError(self.gpa, self.io, "Git", if (self.git.last_error.items.len > 0) self.git.last_error.items else i18n.tr().errors.git_failed);
    self.gitChanged();
}

pub fn gitCommit(self: *App) !void {
    const project = if (self.project) |*p| p else return;
    const message = std.mem.trim(u8, self.git_panel.message.text(), " \t");
    var staged = false;
    for (self.git.entries.items) |e| staged = staged or e.isStaged();
    const t = i18n.tr().errors;
    if (!staged) return dialogs.showError(self.gpa, self.io, t.nothing_to_commit, t.nothing_to_commit_detail);
    if (message.len == 0) return dialogs.showError(self.gpa, self.io, t.message_needed, t.message_needed_detail);
    self.git.commit(self.io, project.root().path, message) catch {
        return self.gitAction(error.GitFailed);
    };
    try self.git_panel.message.setText("");
    self.gitChanged();
}
