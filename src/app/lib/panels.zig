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
                .open => |i| {
                    const e = self.git.entries.items[i];
                    const path = try std.fs.path.join(self.gpa, &.{ self.git.toplevel, e.path });
                    defer self.gpa.free(path);
                    if (e.unstaged != 'D' and e.staged != 'D') self.openFile(path) catch |err| self.reportError(i18n.tr().errors.open_file, path, err);
                },
            }
        },
    }
}

/// After a git command: report git's own message if it failed, and
/// re-read the status either way.
pub fn gitAction(self: *App, result: anyerror!void) void {
    result catch dialogs.showError(self.gpa, self.io, "Git", if (self.git.last_error.items.len > 0) self.git.last_error.items else i18n.tr().errors.git_failed);
    self.git_dirty = true;
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
    self.git_dirty = true;
}
