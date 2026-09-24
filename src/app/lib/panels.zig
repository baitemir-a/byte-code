//! The sidebar's Search and Git views: showing them, their text boxes
//! and clicks, and git actions.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const dialogs = @import("../../platform/lib/dialogs.zig");
const Tab = @import("../Tab.zig");
const Sidebar = @import("../../ui/sidebar/Sidebar.zig");
const GitPanel = @import("../../ui/sidebar/GitPanel.zig");
const ContextMenu = @import("../../ui/sidebar/ContextMenu.zig");
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
    // The status is read for any view, not just Git's: the badge on its
    // tab shows what is waiting while another view is open.
    if (self.sidebar.width() > 0 or self.git_dirty) if (self.project) |*p| {
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
        .git_prompt => &self.git_panel.prompt_field,
    };
    switch (cmd) {
        .newline => switch (self.side_focus) {
            .search => try self.runSearch(.top),
            .search_replace => try self.replaceInProject(),
            .git_prompt => try finishGitPrompt(self),
            else => try self.gitCommit(),
        },
        // Tab moves between the search and replace boxes.
        .indent => switch (self.side_focus) {
            .search => self.side_focus = .search_replace,
            .search_replace => self.side_focus = .search,
            else => {},
        },
        .clear_selection => {
            self.side_focus = .none;
            self.git_panel.cancelPrompt();
        },
        .copy, .cut => try clipboard.copyOrCut(self.gpa, &field.buffer, cmd == .cut),
        .paste => if (clipboard.getClipboard()) |s| try field.paste(s),
        .toggle_match_case, .toggle_whole_word => if (self.side_focus == .search or self.side_focus == .search_replace) {
            self.search_panel.toggle(if (cmd == .toggle_match_case) .match_case else .whole_word);
        },
        .save, .save_as, .find, .find_replace, .find_next, .find_prev => return false,
        else => _ = try field.handle(cmd),
    }
    if ((self.side_focus == .search or self.side_focus == .search_replace) and self.search_panel.stale()) {
        self.search_panel.changed_at = rl.getTime();
    }
    return true;
}

/// A click on a row of the Git tab's tooltip: the view opens at the list
/// that counter stands for. Returns whether it hit one.
pub fn badgeTooltipClick(self: *App, point: rl.Vector2, pressed: bool) bool {
    if (self.sidebar.width() == 0) return false;
    const tip = Sidebar.gitBadgeTooltip(self.view.font, &self.git, point) orelse return false;
    const badge = tip.rowAt(point) orelse return rl.checkCollisionPointRec(point, tip.box);
    self.wanted_cursor = .pointing_hand;
    if (!pressed) return true;
    self.showView(.git);
    if (GitPanel.badgeSection(badge)) |section| self.git_panel.scrollToSection(&self.git, section);
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
                .commit => if (GitPanel.syncing(&self.git)) self.gitAction(self.git.sync(self.io, root)) else try self.gitCommit(),
                .toggle_commands => {
                    self.git_panel.commands_open = !self.git_panel.commands_open;
                    self.git_panel.cancelPrompt();
                },
                .command => |c| try runGitCommand(self, c, point),
                .prompt => {
                    self.side_focus = .git_prompt;
                    const f = &self.git_panel.prompt_field;
                    f.buffer.moveTo(f.posAtX(self.git_panel.promptRect(), self.view.font, point.x), false);
                },
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

/// Runs one of the list's commands. The ones that need something typed
/// or picked ask for it first; the rest go straight to git.
fn runGitCommand(self: *App, command: GitPanel.Command, at: rl.Vector2) !void {
    const project = if (self.project) |*p| p else return;
    const root = project.root().path;
    self.side_focus = .none;
    self.git_panel.cancelPrompt();
    switch (command) {
        .push => self.gitAction(self.git.push(self.io, root)),
        .pull => self.gitAction(self.git.pull(self.io, root)),
        .fetch => self.gitAction(self.git.fetch(self.io, root)),
        .commit_push => {
            try self.gitCommit();
            if (self.git.last_error.items.len == 0) self.gitAction(self.git.push(self.io, root));
        },
        .commit_sync => {
            try self.gitCommit();
            if (self.git.last_error.items.len == 0) self.gitAction(self.git.sync(self.io, root));
        },
        .stash => self.gitAction(self.git.stash(self.io, root)),
        .stash_pop => self.gitAction(self.git.stashPop(self.io, root)),
        .clone => {
            try self.git_panel.ask(.clone, "");
            self.side_focus = .git_prompt;
        },
        .create_branch => {
            try self.git_panel.ask(.create_branch, "");
            self.side_focus = .git_prompt;
        },
        // These pick a branch first, from a menu at the pointer.
        .checkout, .create_branch_from => try openBranchMenu(self, root, command == .create_branch_from, at),
    }
}

/// The branches to pick from, as a menu. Only the first few fit, which
/// are the ones worked on most recently.
fn openBranchMenu(self: *App, root: []const u8, remote: bool, at: rl.Vector2) !void {
    const list = try core.Git.branches(self.gpa, self.io, root, remote) orelse return;
    defer self.gpa.free(list);
    self.branch_list.clearRetainingCapacity();
    try self.branch_list.appendSlice(self.gpa, list);

    var labels: [ContextMenu.max_items][]const u8 = undefined;
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, self.branch_list.items, '\n');
    while (lines.next()) |line| {
        const name = std.mem.trim(u8, line, " \r");
        if (name.len == 0) continue;
        labels[n] = name;
        self.menu_actions[n] = if (remote) .{ .git_branch_from = @intCast(n) } else .{ .git_checkout = @intCast(n) };
        n += 1;
        if (n == ContextMenu.max_items) break;
    }
    if (n == 0) return;
    self.menu.open(labels[0..n], at, App.windowSize(), self.view.font);
}

/// The branch a menu row stands for.
pub fn branchName(self: *const App, index: u32) ?[]const u8 {
    var n: u32 = 0;
    var lines = std.mem.splitScalar(u8, self.branch_list.items, '\n');
    while (lines.next()) |line| {
        const name = std.mem.trim(u8, line, " \r");
        if (name.len == 0) continue;
        if (n == index) return name;
        n += 1;
    }
    return null;
}

/// Runs what the box was asked for, with what was typed in it.
pub fn finishGitPrompt(self: *App) !void {
    const project = if (self.project) |*p| p else return;
    const root = project.root().path;
    const prompt = self.git_panel.prompt orelse return;
    const text = std.mem.trim(u8, self.git_panel.prompt_field.text(), " \t");
    if (text.len == 0) return;
    const base = self.git_panel.promptBase();
    self.git_panel.cancelPrompt();
    self.side_focus = .none;
    switch (prompt) {
        .create_branch => self.gitAction(self.git.createBranch(self.io, root, text, null)),
        .create_branch_from => self.gitAction(self.git.createBranch(self.io, root, text, base)),
        // The copy lands beside the project, and opens as the new one.
        .clone => {
            const parent = std.fs.path.dirname(root) orelse root;
            self.gitAction(self.git.clone(self.io, parent, text));
            if (self.git.last_error.items.len > 0) return;
            const name = cloneFolder(text);
            const path = try std.fs.path.join(self.gpa, &.{ parent, name });
            defer self.gpa.free(path);
            self.openFolder(path) catch |err| self.reportError(i18n.tr().errors.open_folder, path, err);
        },
    }
}

/// The folder `git clone` makes: the last part of the address, without
/// its ".git".
fn cloneFolder(url: []const u8) []const u8 {
    var name = std.mem.trimEnd(u8, url, "/");
    if (std.mem.lastIndexOfAny(u8, name, "/:")) |at| name = name[at + 1 ..];
    return if (std.mem.endsWith(u8, name, ".git")) name[0 .. name.len - 4] else name;
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
