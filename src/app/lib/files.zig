//! Opening and saving files and folders, closing the folder, and
//! keeping the project in sync with the disk.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const dialogs = @import("../../platform/lib/dialogs.zig");
const Tab = @import("../Tab.zig");
const paths = @import("../../platform/lib/paths.zig");
const App = @import("../App.zig");
const i18n = @import("../../i18n/i18n.zig");

/// Opens a file (in a tab) or a folder (as the project), reporting failures
/// in a dialog.
pub fn openPath(self: *App, path: []const u8) !void {
    if (isDirectory(self.io, path)) return self.openFolder(path);
    self.openFile(path) catch |err| self.reportError(i18n.tr().errors.open_file, path, err);
}

pub fn isDirectory(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// Switches to the file's tab if it's open, otherwise opens it in a new tab
/// (reusing an empty untitled one).
pub fn openFile(self: *App, given_path: []const u8) !void {
    // Absolute paths, so tabs and the project tree can match them. A file
    // that doesn't exist yet keeps the path as given.
    const abs = std.Io.Dir.cwd().realPathFileAlloc(self.io, given_path, self.gpa) catch null;
    defer if (abs) |a| self.gpa.free(a);
    const path: []const u8 = if (abs) |a| a else given_path;

    for (self.tabs.items, 0..) |*t, i| {
        if (t.hasPath(path)) return self.activate(i);
    }
    if (self.tabs.items.len > 0 and self.tab().isPristine()) {
        try self.tab().load(self.gpa, self.io, path);
        return self.revealCurrentFile();
    }
    var new = Tab.initFile(self.gpa);
    errdefer new.deinit(self.gpa);
    try new.load(self.gpa, self.io, path);
    const at = if (self.tabs.items.len == 0) 0 else self.active + 1;
    try self.tabs.insert(self.gpa, at, new);
    if (self.tabs.items.len == 1) {
        self.active = 0;
        self.view.scroll = .{ .x = 0, .y = 0 };
        try self.revealCurrentFile();
    } else try self.activate(at);
}

pub fn openWithDialog(self: *App) !void {
    const start_dir = self.tab().document.dirname() orelse if (self.project) |*p| p.root().path else null;
    const path = try dialogs.openFile(self.gpa, self.io, start_dir) orelse return;
    defer self.gpa.free(path);
    try self.openPath(path);
}

/// Opens a folder as the project. Open tabs stay open.
pub fn openFolder(self: *App, path: []const u8) !void {
    const tree = core.FileTree.open(self.gpa, self.io, path) catch |err| {
        return self.reportError(i18n.tr().errors.open_folder, path, err);
    };
    if (self.project) |*p| p.deinit();
    self.project = tree;
    self.rememberProject(self.project.?.root().path);
    self.sidebar.reset();
    if (self.tabs.items.len > 0) try self.revealCurrentFile();
}

/// Remembers a folder that was just opened, for the welcome page's
/// recent list.
pub fn rememberProject(self: *App, path: []const u8) void {
    self.projects.record(path) catch return;
    saveProjects(self);
}

/// A row on the welcome page: opens that folder (in a new window when
/// that's the setting and a project is already here).
pub fn openProject(self: *App, index: usize) !void {
    if (index >= self.projects.entries.items.len) return;
    // The list shifts as the folder is recorded, so take a copy first.
    const path = try self.gpa.dupe(u8, self.projects.entries.items[index].path);
    defer self.gpa.free(path);
    if (self.project != null and self.settings.open_folder_in_new_window) {
        return self.openInNewWindow(path);
    }
    try self.openFolder(path);
}

/// A click on the welcome tab: a "Start" row, a folder, or the star that
/// keeps one as a favorite.
pub fn welcomeClick(self: *App, point: rl.Vector2) !void {
    switch (self.welcome.hitTest(point) orelse return) {
        .command => |cmd| try self.execute(cmd),
        .open => |i| try self.openProject(i),
        .favorite => |i| self.toggleFavoriteProject(i),
    }
}

/// The star on a welcome page row: keeps that folder listed as a
/// favorite, or gives up on it.
pub fn toggleFavoriteProject(self: *App, index: usize) void {
    self.projects.toggleFavorite(index);
    saveProjects(self);
}

fn saveProjects(self: *App) void {
    self.projects.save(self.io, std.Io.Dir.cwd(), self.projects_path) catch |err| {
        self.reportError(i18n.tr().errors.save_projects, self.projects_path, err);
    };
}

pub fn openFolderWithDialog(self: *App) !void {
    const start_dir = if (self.project) |*p| p.root().path else self.tab().document.dirname();
    const path = try dialogs.openFolder(self.gpa, self.io, start_dir) orelse return;
    defer self.gpa.free(path);
    // With a project already here, the setting decides: a new window, or
    // replace this one.
    if (self.project != null and self.settings.open_folder_in_new_window) {
        return self.openInNewWindow(path);
    }
    try self.openFolder(path);
}

/// Starts another copy of the editor for `path`. It runs on its own: in
/// its own process group, not tied to this window's terminal.
pub fn openInNewWindow(self: *App, path: []const u8) !void {
    const exe = try std.process.executablePathAlloc(self.io, self.gpa);
    defer self.gpa.free(exe);
    _ = std.process.spawn(self.io, .{
        .argv = &.{ exe, path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        // Its own process group on macOS/Linux (Windows has no such thing).
        .pgid = if (@import("builtin").os.tag == .windows) null else 0,
    }) catch |err| return self.reportError(i18n.tr().errors.new_window, path, err);
}

/// Files and folders dropped onto the window.
pub fn openDroppedFiles(self: *App) !void {
    if (!rl.isFileDropped()) return;
    const dropped = rl.loadDroppedFiles();
    defer rl.unloadDroppedFiles(dropped);
    for (dropped.paths[0..dropped.count]) |p| try self.openPath(std.mem.span(p));
}

/// Cmd+K: closes the project folder and its sidebar. Open tabs stay open.
pub fn closeFolder(self: *App) void {
    if (self.project == null) return;
    self.endTreePress();
    self.menu.close();
    self.sidebar.reset();
    self.quick_open.close();
    self.project.?.deinit();
    self.project = null;
}

/// Picks up files created, renamed or deleted outside the editor.
pub fn refreshProjectOnFocus(self: *App) !void {
    const focused = rl.isWindowFocused();
    defer self.was_focused = focused;
    if (focused and !self.was_focused) {
        try self.refreshProject();
        self.gitChanged(); // things may have changed elsewhere
    }
}

/// Re-reads the project folder. Tree positions change, so whatever the menu
/// and the name box point at is found again by path — never acted on by a
/// stale index — or dropped if it's gone.
pub fn refreshProject(self: *App) !void {
    const project = if (self.project) |*p| p else return;
    const Saved = struct { folder: ?[]u8 = null, node: ?[]u8 = null, menu_node: ?[]u8 = null, menu_folder: ?[]u8 = null };
    var saved: Saved = .{};
    defer inline for (std.meta.fields(Saved)) |f| if (@field(saved, f.name)) |s| self.gpa.free(s);
    if (self.sidebar.input) |in| {
        saved.folder = try self.gpa.dupe(u8, project.node(in.folder).path);
        if (in.renaming) |n| saved.node = try self.gpa.dupe(u8, project.node(n).path);
    }
    if (self.menu.is_open) {
        if (self.menu_node) |n| saved.menu_node = try self.gpa.dupe(u8, project.node(n).path);
        saved.menu_folder = try self.gpa.dupe(u8, project.node(self.menu_folder).path);
    }

    try project.refresh(self.io);

    if (self.sidebar.input) |*in| {
        const folder = project.find(saved.folder.?);
        const node = if (saved.node) |p| project.find(p) else null;
        if (folder == null or (saved.node != null and node == null)) {
            self.sidebar.cancelInput();
        } else {
            in.folder = folder.?;
            in.renaming = node;
        }
    }
    if (self.menu.is_open) {
        const folder = project.find(saved.menu_folder.?);
        const node = if (saved.menu_node) |p| project.find(p) else null;
        if (folder == null or (saved.menu_node != null and node == null)) {
            self.menu.close();
        } else {
            self.menu_folder = folder.?;
            self.menu_node = node;
        }
    }
}

/// After a rename or move: tabs showing the entry, or files inside a moved
/// folder, follow it to its new path.
pub fn retargetTabs(self: *App, old_path: []const u8, new_path: []const u8) !void {
    for (self.tabs.items) |*t| {
        const path = t.document.path orelse continue;
        if (!core.FileTree.isAtOrUnder(path, old_path)) continue;
        const moved = try std.mem.concat(self.gpa, u8, &.{ new_path, path[old_path.len..] });
        defer self.gpa.free(moved);
        try t.document.setPath(self.gpa, moved);
        t.highlighter.language = .detect(moved, t.buffer.items());
    }
    try self.revealCurrentFile();
}

/// Called when the window is asked to close: asks about each tab with
/// unsaved changes. Returns false to keep running.
pub fn confirmClose(self: *App) !bool {
    for (0..self.tabs.items.len) |i| {
        if (!self.tabs.items[i].isDirty()) continue;
        try self.activate(i);
        if (!try self.resolveUnsavedChanges()) return false;
    }
    return true;
}

/// Saves the active tab, asking for a path first if it has none (or always,
/// with `choose_path`). Returns false if cancelled or failed.
pub fn save(self: *App, choose_path: bool) !bool {
    self.gitChanged();
    const t = self.tab();
    if (t.kind != .file) return false;
    if (choose_path or t.document.path == null) {
        const path = try dialogs.saveFile(self.gpa, self.io, t.document.name(), t.document.dirname()) orelse return false;
        defer self.gpa.free(path);
        try t.document.setPath(self.gpa, path);
        t.highlighter.language = .fromPath(path);
    }
    t.document.save(self.gpa, self.io, std.Io.Dir.cwd(), &t.buffer) catch |err| {
        self.reportError(i18n.tr().errors.save_file, t.document.path.?, err);
        return false;
    };
    // Saving under a new name may have added a file to the project.
    if (choose_path) {
        try self.refreshProject();
        try self.revealCurrentFile();
    }
    return true;
}

/// If the active tab has unsaved changes, asks whether to save them.
/// Returns true when it's fine to throw them away.
pub fn resolveUnsavedChanges(self: *App) !bool {
    if (!self.tab().isDirty()) return true;
    const choice = dialogs.askSaveChanges(self.gpa, self.io, self.tab().name()) catch |err| switch (err) {
        // No way to ask: keep the work rather than lose it silently.
        error.DialogUnavailable => return false,
        else => |e| return e,
    };
    return switch (choice) {
        .save => try self.save(false),
        .discard => true,
        .cancel => false,
    };
}

pub fn reportError(self: *App, title: []const u8, path: []const u8, err: anyerror) void {
    const t = i18n.tr().reasons;
    const reason = switch (err) {
        error.NotUtf8 => t.not_utf8,
        error.FileTooBig => t.too_big,
        error.AccessDenied, error.PermissionDenied => t.permission_denied,
        error.IsDir => t.is_dir,
        error.FileNotFound => t.not_found,
        error.NoSpaceLeft => t.disk_full,
        error.PathAlreadyExists => t.already_exists,
        error.InvalidName => t.invalid_name,
        else => @errorName(err),
    };
    const message = std.fmt.allocPrint(self.gpa, "{s}\n\n{s}", .{ path, reason }) catch return;
    defer self.gpa.free(message);
    dialogs.showError(self.gpa, self.io, title, message);
}
