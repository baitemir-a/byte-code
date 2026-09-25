//! The sidebar's file tree: its context menu, creating, renaming,
//! deleting and dragging entries.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const dialogs = @import("../../platform/lib/dialogs.zig");
const Sidebar = @import("../../ui/sidebar/Sidebar.zig");
const App = @import("../App.zig");
const i18n = @import("../../i18n/i18n.zig");

/// Shows the sidebar's name box for a new file or folder in `folder`.
pub fn startCreate(self: *App, kind: core.FileTree.EntryKind, folder: u32) !void {
    const project = if (self.project) |*p| p else return;
    try project.expand(self.io, folder);
    try self.sidebar.startInput(project, folder, kind);
    self.completion.close();
    self.find.focus = .editor;
}

/// Where the header buttons create things: next to the active file, or
/// at the top of the project.
pub fn defaultFolder(self: *App) u32 {
    const project = if (self.project) |*p| p else return 0;
    const path = self.tab().document.path orelse return 0;
    return if (project.find(path)) |i| project.folderOf(i) else 0;
}

/// Right-click in the sidebar: actions for the clicked file or folder, or
/// just "new" ones on empty space.
pub fn openContextMenu(self: *App, hit: ?Sidebar.Hit, at: rl.Vector2) void {
    const project = if (self.project) |*p| p else return;
    self.menu_node = if (hit) |h| switch (h) {
        .node => |index| index,
        else => null,
    } else null;
    self.menu_folder = if (self.menu_node) |n| project.folderOf(n) else 0;

    // Inside a repository, a file or folder can also be left to git to
    // ignore.
    const in_repo = if (self.menu_node) |n| repoPath(self, project.node(n).path) != null else false;
    const actions: []const App.MenuAction = if (in_repo)
        &.{ .new_file, .new_folder, .rename, .delete, .add_to_gitignore }
    else if (self.menu_node != null)
        &.{ .new_file, .new_folder, .rename, .delete }
    else
        &.{ .new_file, .new_folder };
    var labels: [5][]const u8 = undefined;
    for (actions, 0..) |a, i| {
        self.menu_actions[i] = a;
        labels[i] = a.label();
    }
    const window = App.windowSize();
    self.menu.open(labels[0..actions.len], at, window, self.view.font);
}

/// Where a path is inside the repository, '/' separated as .gitignore
/// wants it; null when it isn't in one (or is its top folder).
fn repoPath(self: *const App, path: []const u8) ?[]const u8 {
    if (self.git.state != .ok) return null;
    const top = std.mem.trimEnd(u8, self.git.toplevel, "/\\");
    if (path.len <= top.len + 1 or !std.mem.startsWith(u8, path, top)) return null;
    if (path[top.len] != '/' and path[top.len] != '\\') return null;
    return path[top.len + 1 ..];
}

pub fn runMenuAction(self: *App, action: App.MenuAction) !void {
    switch (action) {
        .new_file => try self.startCreate(.file, self.menu_folder),
        .new_folder => try self.startCreate(.folder, self.menu_folder),
        .rename => if (self.project) |*p| if (self.menu_node) |n| {
            try self.sidebar.startRename(p, n);
            self.completion.close();
            self.find.focus = .editor;
        },
        .delete => if (self.menu_node) |n| try self.deleteEntry(n),
        .add_to_gitignore => if (self.project) |*p| if (self.menu_node) |n| {
            const node = p.node(n);
            const rel = repoPath(self, node.path) orelse return;
            self.git.ignore(self.io, rel, node.is_dir) catch |err| {
                return self.reportError(i18n.tr().errors.save_file, ".gitignore", err);
            };
            self.gitChanged();
            try self.refreshProject();
        },
        // Ctrl+click's list of where a name is used.
        .go_to_ref => |i| if (i < self.refs.items.len) try self.openRef(self.refs.items[i]),
        .all_refs => self.showRefsInSearch(),
        .set_language => |l| try self.setLanguage(l),
        // The right-click menu on a tab, in split.zig.
        .split_right, .split_down, .move_to_other_pane => try self.runTabMenuAction(action),
    }
}

/// Enter in the name box: creates or renames.
pub fn finishInput(self: *App) !void {
    const input = self.sidebar.input orelse return;
    if (input.renaming) |node| try self.finishRename(node) else try self.finishCreate();
}

pub fn finishRename(self: *App, node: u32) !void {
    const project = if (self.project) |*p| p else return;
    // The tree (and the old path in it) is rebuilt by the rename: copy it.
    const old_path = try self.gpa.dupe(u8, project.node(node).path);
    defer self.gpa.free(old_path);
    const name = self.sidebar.name.text();
    const new_path = project.rename(self.io, node, name) catch |err| {
        return self.reportError(i18n.tr().errors.rename, name, err);
    };
    defer self.gpa.free(new_path);
    self.sidebar.cancelInput();

    try self.retargetTabs(old_path, new_path);
}

pub fn startTreePress(self: *App, node: u32, at: rl.Vector2) !void {
    const project = if (self.project) |*p| p else return;
    self.endTreePress();
    self.tree_press = .{ .path = try self.gpa.dupe(u8, project.node(node).path), .start = at };
}

pub fn endTreePress(self: *App) void {
    if (self.tree_press) |t| self.gpa.free(t.path);
    self.tree_press = null;
    self.sidebar.drop_target = null;
    self.sidebar.drag_label = null;
}

/// Each frame while a sidebar row is pressed: turn it into a drag, track
/// the drop target, and on release either move the entry or treat the
/// press as a click (open the file / toggle the folder).
pub fn updateTreePress(self: *App, point: rl.Vector2) !void {
    const press = if (self.tree_press) |*t| t else return;
    const project = if (self.project) |*p| p else return self.endTreePress();
    const node = project.find(press.path) orelse return self.endTreePress();
    const released = rl.isMouseButtonReleased(.left);
    if (!released and !rl.isMouseButtonDown(.left)) return self.endTreePress();

    if (!press.dragging and std.math.hypot(point.x - press.start.x, point.y - press.start.y) > App.drag_threshold) {
        press.dragging = true;
    }
    if (!press.dragging) {
        if (!released) return;
        const path = try self.gpa.dupe(u8, press.path);
        defer self.gpa.free(path);
        self.endTreePress();
        if (project.node(node).is_dir) {
            // The rows the folder brings (or takes away) slide out from
            // under it: where it is, and how many they are.
            const row = std.mem.indexOfScalar(u32, project.rows.items, node);
            const before = project.rows.items.len;
            try project.toggle(self.io, node);
            if (row) |at| {
                const delta = @as(isize, @intCast(project.rows.items.len)) - @as(isize, @intCast(before));
                self.sidebar.noteToggle(at, delta);
            }
        } else try self.openFromTree(path);
        return;
    }

    // Where it would land: the folder under the mouse, or the folder of the
    // file under it; empty space means the project folder.
    const hit = if (self.sidebar.contains(point)) self.sidebar.hitTest(project, point) else null;
    const target: ?u32 = if (hit) |h| switch (h) {
        .node => |i| project.folderOf(i),
        .empty => 0,
        else => null,
    } else null;
    const valid = if (target) |t| project.canMove(node, t) else false;
    self.sidebar.drop_target = if (valid) target else null;
    self.sidebar.drag_label = project.node(node).name;
    if (!valid) self.wanted_cursor = .not_allowed;
    self.sidebar.autoScroll(point);

    // Hovering a collapsed folder for a moment opens it.
    const hovered_folder: ?u32 = if (hit) |h| switch (h) {
        .node => |i| if (project.node(i).is_dir and !project.node(i).expanded) i else null,
        else => null,
    } else null;
    if (hovered_folder != press.hover) {
        press.hover = hovered_folder;
        press.hover_since = rl.getTime();
    } else if (hovered_folder) |f| if (rl.getTime() - press.hover_since > App.drag_expand_delay) {
        try project.expand(self.io, f);
        press.hover = null;
    };

    if (released) {
        self.endTreePress();
        if (valid) try self.moveEntry(node, target.?);
    }
}

/// Drop: moves an entry into a folder; open tabs follow it.
pub fn moveEntry(self: *App, node: u32, folder: u32) !void {
    const project = if (self.project) |*p| p else return;
    const old_path = try self.gpa.dupe(u8, project.node(node).path);
    defer self.gpa.free(old_path);
    const new_path = project.move(self.io, node, folder) catch |err| {
        return self.reportError(i18n.tr().errors.move, old_path, err);
    };
    defer self.gpa.free(new_path);
    try self.retargetTabs(old_path, new_path);
}

/// Deletes after asking: to the trash if possible, otherwise permanently
/// after asking again. Tabs of deleted files close unless they have
/// unsaved changes.
pub fn deleteEntry(self: *App, node: u32) !void {
    const project = if (self.project) |*p| p else return;
    const n = project.node(node);
    const path = try self.gpa.dupe(u8, n.path);
    defer self.gpa.free(path);
    const text = i18n.tr().dialogs;
    const question = try i18n.fillAlloc(self.gpa, text.delete_question, .{n.name});
    defer self.gpa.free(question);
    const detail = if (n.is_dir) text.delete_folder_detail else text.delete_file_detail;

    if (!self.confirm(question, detail, text.move_to_trash)) return;
    if (dialogs.moveToTrash(self.gpa, self.io, path)) {
        try self.refreshProject();
    } else |_| {
        const permanent = self.confirm(question, text.cant_trash_detail, text.delete_permanently);
        if (!permanent) return;
        project.deletePermanently(self.io, node) catch |err| return self.reportError(i18n.tr().errors.delete, path, err);
    }

    var i = self.tabs.items.len;
    while (i > 0) {
        i -= 1;
        const t = &self.tabs.items[i];
        const tab_path = t.document.path orelse continue;
        if (core.FileTree.isAtOrUnder(tab_path, path) and !t.isDirty()) _ = try self.closeTab(i);
    }
}

/// Enter in the name box for a new entry: creates the file (and opens it)
/// or folder.
pub fn finishCreate(self: *App) !void {
    const project = if (self.project) |*p| p else return;
    const input = self.sidebar.input orelse return;
    const name = self.sidebar.name.text();
    const path = project.create(self.io, input.folder, name, input.kind) catch |err| {
        const what = if (input.kind == .file) i18n.tr().errors.create_file else i18n.tr().errors.create_folder;
        return self.reportError(what, name, err);
    };
    defer self.gpa.free(path);
    self.sidebar.cancelInput();
    switch (input.kind) {
        .file => try self.openPath(path),
        .folder => if (project.find(path)) |i| if (std.mem.indexOfScalar(u32, project.rows.items, i)) |row| self.sidebar.revealRow(row),
    }
}

/// Opens a file clicked in the sidebar.
pub fn openFromTree(self: *App, path: []const u8) !void {
    // `path` lives in the tree, which may be refreshed (freed) meanwhile.
    const owned = try self.gpa.dupe(u8, path);
    defer self.gpa.free(owned);
    self.openFile(owned) catch |err| self.reportError(i18n.tr().errors.open_file, owned, err);
}

/// Expands the sidebar down to the active file and scrolls to it.
pub fn revealCurrentFile(self: *App) !void {
    const project = if (self.project) |*p| p else return;
    const path = self.tab().document.path orelse return;
    if (try project.reveal(self.io, path)) |row| self.sidebar.revealRow(row);
}
