//! The editor application: owns the open tabs, the optional project folder,
//! the view, the completion popup and the find bar, and runs one frame of
//! input → commands → drawing.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const keymap = @import("input/keymap.zig");
const Mouse = @import("input/Mouse.zig");
const dialogs = @import("platform/dialogs.zig");
const Tab = @import("Tab.zig");
const theme = @import("ui/theme.zig");
const Font = @import("ui/Font.zig");
const View = @import("ui/View.zig");
const CompletionPopup = @import("ui/CompletionPopup.zig");
const FindBar = @import("ui/FindBar.zig");
const Sidebar = @import("ui/Sidebar.zig");
const ContextMenu = @import("ui/ContextMenu.zig");
const Terminal = @import("Terminal.zig");
const TerminalPanel = @import("ui/TerminalPanel.zig");
const terminal_keys = @import("input/terminal_keys.zig");
const Pty = @import("platform/Pty.zig");
const paths = @import("platform/paths.zig");
const SettingsPage = @import("ui/SettingsPage.zig");
const Minimap = @import("ui/Minimap.zig");
const QuickOpen = @import("ui/QuickOpen.zig");
const SearchPanel = @import("ui/SearchPanel.zig");
const GitPanel = @import("ui/GitPanel.zig");
const TabBar = @import("ui/TabBar.zig");
const WelcomePage = @import("ui/WelcomePage.zig");

pub const app_name = "byte code";

const TreePress = struct {
    path: []u8,
    start: rl.Vector2,
    dragging: bool = false,
    /// A collapsed folder being hovered during the drag, and since when;
    /// it opens after a moment.
    hover: ?u32 = null,
    hover_since: f64 = 0,
};

/// Mouse travel that turns a press into a drag.
const drag_threshold = 5;
/// Seconds of hovering a collapsed folder while dragging before it opens.
const drag_expand_delay = 0.6;

const MenuAction = enum {
    new_file,
    new_folder,
    rename,
    delete,

    fn label(self: MenuAction) []const u8 {
        return switch (self) {
            .new_file => "New File...",
            .new_folder => "New Folder...",
            .rename => "Rename...",
            .delete => "Delete",
        };
    }
};

const App = @This();

gpa: std.mem.Allocator,
io: std.Io,
/// Never empty: closing the last tab brings back the welcome tab.
tabs: std.ArrayList(Tab) = .empty,
active: usize = 0,
/// The folder opened as a project, shown in the sidebar.
project: ?core.FileTree = null,
sidebar: Sidebar,
/// Right-click menu in the sidebar: its actions, and what they act on
/// (the clicked node, and the folder new entries go in).
menu: ContextMenu = .{},
menu_actions: [4]MenuAction = undefined,
menu_node: ?u32 = null,
menu_folder: u32 = 0,
/// A mouse press on a sidebar row. It becomes a drag (to move the entry)
/// once the mouse moves a few pixels; otherwise it's a click on release.
/// Holds the entry's path, not its index, so a tree refresh can't make it
/// point at another file.
tree_press: ?TreePress = null,
tab_bar: TabBar = .{},
welcome: WelcomePage = .{},
/// Window focus last frame: regaining it re-reads the project folder.
was_focused: bool = true,
view: View,
completion: core.Completion,
popup: CompletionPopup = .{},
find: FindBar,
mouse: Mouse = .{},
/// The integrated terminal, started the first time it's opened.
terminal: ?Terminal = null,
terminal_panel: TerminalPanel = .{},
/// Keyboard input goes to the terminal rather than the editor.
terminal_focused: bool = false,
/// Bytes typed into the terminal this frame; kept to reuse its memory.
terminal_input: std.ArrayList(u8) = .empty,
/// The mouse cursor's shape: what parts of the UI ask for this frame
/// (resize arrows over an edge, "not allowed" while dragging), and what's
/// currently set. Applied once per frame, so they can't fight over it.
wanted_cursor: rl.MouseCursor = .default,
cursor_shape: rl.MouseCursor = .default,
settings: core.Settings,
/// Where settings are saved (see platform/paths.zig).
settings_path: []u8,
settings_page: SettingsPage = .{},
/// Cmd+P, and the project's files it searches.
quick_open: QuickOpen,
file_search: core.FileSearch,
/// The sidebar's Search and Git views.
search_panel: SearchPanel,
git_panel: GitPanel,
git: core.Git,
/// Git status needs re-reading (after saves, focus, git actions); also
/// re-read every few seconds while the Git view shows.
git_dirty: bool = true,
git_read_at: f64 = 0,
/// Which sidebar text box has the keyboard, if any.
side_focus: enum { none, search, git_message } = .none,
/// Scroll the editor to its cursor on the next frame (e.g. after opening
/// a search result).
reveal_cursor: bool = false,
minimap: Minimap = .{},
/// Commands gathered this frame; kept to reuse its memory.
commands: std.ArrayList(core.Command) = .empty,
/// Time of the last cursor activity, for caret blinking.
last_activity: f64 = 0,
/// The window title currently shown, to update it only on change.
title_buf: [256]u8 = undefined,
title_len: usize = 0,

/// Call after the window is open (fonts need the GPU).
pub fn init(gpa: std.mem.Allocator, io: std.Io) !App {
    // Settings first: zoom decides the size the font is rendered at.
    const settings_path = try paths.settingsFile(gpa);
    errdefer gpa.free(settings_path);
    const settings = core.Settings.load(gpa, io, std.Io.Dir.cwd(), settings_path);
    applyToTheme(settings);
    var app: App = .{
        .gpa = gpa,
        .io = io,
        .view = View.init(Font.load()),
        .completion = .init(gpa),
        .find = .init(gpa),
        .sidebar = .init(gpa),
        .settings = settings,
        .settings_path = settings_path,
        .quick_open = .init(gpa),
        .file_search = .init(gpa),
        .search_panel = .init(gpa),
        .git_panel = .init(gpa),
        .git = .init(gpa),
    };
    app.sidebar.preferred_width = @floatFromInt(settings.sidebar_width);
    return app;
}

pub fn deinit(self: *App) void {
    self.gpa.free(self.settings_path);
    self.quick_open.deinit();
    self.file_search.deinit();
    self.search_panel.deinit();
    self.git_panel.deinit();
    self.git.deinit();
    for (self.tabs.items) |*t| t.deinit(self.gpa);
    self.tabs.deinit(self.gpa);
    self.commands.deinit(self.gpa);
    self.tab_bar.deinit(self.gpa);
    if (self.project) |*p| p.deinit();
    if (self.tree_press) |t| self.gpa.free(t.path);
    if (self.terminal) |*t| t.deinit();
    self.terminal_input.deinit(self.gpa);
    self.sidebar.deinit();
    self.find.deinit();
    self.completion.deinit();
    self.view.font.unload();
}

/// Opens the file or folder given on the command line, if any. Without a
/// file to show, the welcome tab opens.
pub fn start(self: *App, path: ?[]const u8) !void {
    if (path) |p| try self.openPath(p);
    if (self.tabs.items.len == 0) try self.tabs.append(self.gpa, .initWelcome(self.gpa));
}

fn tab(self: *App) *Tab {
    return &self.tabs.items[self.active];
}

fn activeTab(self: *const App) *const Tab {
    return &self.tabs.items[self.active];
}

fn buf(self: *App) *core.Buffer {
    return &self.tab().buffer;
}

fn isEditing(self: *const App) bool {
    return self.activeTab().kind == .file;
}

// ------------------------------------------------------------------ frame

pub fn update(self: *App) !void {
    const window = windowSize();
    try self.refreshProjectOnFocus();
    try self.openDroppedFiles();
    if (self.terminal) |*t| _ = try t.pump();
    try self.layout(window);

    // Keys go to the terminal when it has focus, else to the editor.
    self.commands.clearRetainingCapacity();
    const typed_in_terminal = if (self.terminalFocused()) try self.handleTerminalKeys() else blk: {
        try keymap.poll(self.gpa, &self.commands);
        break :blk false;
    };
    for (self.commands.items) |cmd| try self.execute(cmd);
    const typed = self.commands.items.len > 0 and !self.terminalFocused();
    // Edits may have changed the line count (gutter width) or the tabs.
    if (typed or self.commands.items.len > 0) try self.layout(window);

    self.wanted_cursor = .default;
    const clicked = try self.handleMouse();
    if (self.wanted_cursor != self.cursor_shape) {
        rl.setMouseCursor(self.wanted_cursor);
        self.cursor_shape = self.wanted_cursor;
    }
    // Always: the mouse can open or close tabs even on frames it reports as
    // no click (a sidebar file opens on release), and drawing needs a layout
    // that matches the tabs.
    try self.layout(window);
    if (typed or clicked or typed_in_terminal) self.last_activity = rl.getTime();

    if (self.isEditing()) {
        if (typed or self.reveal_cursor) self.view.revealCursor(self.buf());
        self.reveal_cursor = false;
        self.view.clampScroll(self.buf());
        try self.tab().highlighter.update(self.gpa, self.buf());
        try self.find.update(self.buf());
        self.popup.layout(&self.completion, &self.view, self.buf());
        self.find.layout(&self.view);
    }
    self.autosave();
    try self.updateSidebarViews();
    try self.updateTitle();
}

/// The window's size in UI units (zoom makes each unit more pixels).
fn windowSize() rl.Vector2 {
    return .{
        .x = @as(f32, @floatFromInt(rl.getScreenWidth())) / theme.zoom,
        .y = @as(f32, @floatFromInt(rl.getScreenHeight())) / theme.zoom,
    };
}

pub fn draw(self: *const App) void {
    rl.clearBackground(theme.background);
    const t = self.activeTab();
    const caret = self.caretVisible();
    switch (t.kind) {
        .welcome => self.welcome.draw(self.view.font),
        .settings => self.settings_page.draw(self.view.font, &self.settings, self.settings_path),
        .file => {
            const editor_caret = caret and !self.find.hasFocus() and self.sidebar.input == null and !self.terminalFocused() and !self.quick_open.is_open and self.side_focus == .none;
            self.view.draw(&t.buffer, &t.highlighter, self.find.highlights(&t.buffer), editor_caret);
            if (self.settings.minimap) self.minimap.draw(&self.view, &t.buffer, &t.highlighter);
        },
    }
    if (self.terminal) |*term| {
        const title = if (term.screen.title.items.len > 0) term.screen.title.items else std.fs.path.basename(Pty.defaultShell());
        self.terminal_panel.draw(&term.screen, self.view.font, self.terminalFocused(), caret, title);
    }
    self.tab_bar.draw(self.tabs.items, self.active, self.view.font);
    self.sidebar.draw(if (self.project) |*p| p else null, t.document.path, self.view.font, caret);
    if (self.sidebar.width() > 0) switch (self.sidebar.view) {
        .explorer => {},
        .search => self.search_panel.draw(self.view.font, self.side_focus == .search, caret, self.project != null),
        .git => self.git_panel.draw(&self.git, self.view.font, self.side_focus == .git_message, caret, self.project != null),
    };
    if (t.kind == .file) {
        self.popup.draw(&self.completion, &self.view);
        self.find.draw(&self.view, &t.buffer, caret);
    }
    self.quick_open.draw(&self.file_search, self.view.font, caret, self.project != null);
    self.menu.draw(self.view.font);
    self.sidebar.drawDragLabel(self.view.font);
}

/// Sidebar on the left; tab bar on top of the rest; the editor below it.
fn layout(self: *App, window: rl.Vector2) !void {
    self.sidebar.layout(if (self.project) |*p| p else null, window, self.view.font);
    switch (self.sidebar.view) {
        .explorer => {},
        .search => self.search_panel.layout(self.sidebar.contentRect(), self.view.font),
        .git => self.git_panel.layout(self.sidebar.contentRect(), self.view.font, &self.git),
    }
    self.menu.update();
    const left = self.sidebar.width();
    const bar: rl.Rectangle = .{ .x = left, .y = 0, .width = window.x - left, .height = TabBar.height };
    try self.tab_bar.layout(self.gpa, self.tabs.items, self.active, bar, self.view.font);
    // The terminal panel takes the bottom of the editor column.
    const column: rl.Rectangle = .{ .x = left, .y = bar.height, .width = bar.width, .height = window.y - bar.height };
    self.terminal_panel.layout(column, self.view.font);
    if (self.terminal) |*t| try t.resize(self.terminal_panel.cols, self.terminal_panel.rows);
    var editor = column;
    editor.height -= self.terminal_panel.takenHeight(column);
    // The minimap takes the editor's right edge.
    var text_area = editor;
    if (self.settings.minimap and self.isEditing()) {
        self.minimap.layout(editor);
        text_area.width -= Minimap.width;
    }
    self.view.layout(self.buf(), text_area);
    self.quick_open.layout(editor, self.view.font);
    switch (self.activeTab().kind) {
        .welcome => self.welcome.layout(editor, self.view.font),
        .settings => self.settings_page.layout(editor, self.view.font),
        .file => {},
    }
}

// --------------------------------------------------------------- settings

/// Accent and zoom live in the theme, where drawing code reads them.
fn applyToTheme(s: core.Settings) void {
    theme.setMode(s.theme);
    theme.accent = .{ .r = s.accent[0], .g = s.accent[1], .b = s.accent[2], .a = 255 };
    theme.zoom = @as(f32, @floatFromInt(s.zoom)) / 100;
    rl.setMouseScale(1 / theme.zoom, 1 / theme.zoom);
}

/// After changing `self.settings`: applies them and saves settings.json.
fn settingsChanged(self: *App, old: core.Settings) !void {
    self.settings.clamp();
    applyToTheme(self.settings);
    if (self.settings.zoom != old.zoom) {
        // Re-render the font for the new size, so text stays sharp.
        self.view.font.unload();
        self.view.font = Font.load();
    }
    self.settings.save(self.gpa, self.io, std.Io.Dir.cwd(), self.settings_path) catch |err| {
        self.reportError("Couldn't save settings", self.settings_path, err);
    };
}

// ------------------------------------------------ go to file, close folder

/// Cmd+P: lists the project's files (read fresh each time) to pick from.
fn openQuickOpen(self: *App) !void {
    self.file_search.files.clearRetainingCapacity();
    if (self.project) |*p| self.file_search.scan(self.io, p.root().path) catch |err| {
        self.reportError("Couldn't list the project's files", p.root().path, err);
    };
    try self.quick_open.open(&self.file_search);
    self.completion.close();
    self.find.focus = .editor;
    self.sidebar.cancelInput();
    self.terminal_focused = false;
}

/// Keys while "go to file" is open: type to filter, arrows to choose,
/// Enter to open, Esc to close.
fn quickOpenKey(self: *App, cmd: core.Command) !void {
    const q = &self.quick_open;
    switch (cmd) {
        .newline => try self.openQuickOpenSelection(),
        .clear_selection => q.close(),
        .move => |m| switch (m.motion) {
            .line_up => q.moveSelection(-1),
            .line_down => q.moveSelection(1),
            .page_up => q.moveSelection(-QuickOpen.max_rows),
            .page_down => q.moveSelection(QuickOpen.max_rows),
            else => _ = try q.query.handle(cmd),
        },
        .copy, .cut => try copyOrCut(self.gpa, &q.query.buffer, cmd == .cut),
        .paste => if (getClipboard()) |s| {
            try q.query.paste(s);
            try q.refresh(&self.file_search);
        },
        else => if (try q.query.handle(cmd)) try q.refresh(&self.file_search),
    }
}

fn openQuickOpenSelection(self: *App) !void {
    const project = if (self.project) |*p| p else return self.quick_open.close();
    const file = self.quick_open.selectedFile() orelse return;
    const path = try std.fs.path.join(self.gpa, &.{ project.root().path, self.file_search.files.items[file] });
    defer self.gpa.free(path);
    self.quick_open.close();
    self.openFile(path) catch |err| self.reportError("Couldn't open file", path, err);
}

// --------------------------------------------------- search and git views

/// Shows a sidebar view (Explorer, Search, Git); Search puts the keyboard
/// in its query box.
fn showView(self: *App, view: Sidebar.View) void {
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
fn updateSidebarViews(self: *App) !void {
    const now = rl.getTime();
    if (self.search_panel.changed_at) |t| if (now - t > 0.3) try self.runSearch();
    if (self.sidebar.view == .git and self.sidebar.width() > 0) if (self.project) |*p| {
        if (self.git_dirty or now - self.git_read_at > 5) {
            try self.git.refresh(self.io, p.root().path);
            self.git_dirty = false;
            self.git_read_at = now;
        }
    };
}

fn runSearch(self: *App) !void {
    const panel = &self.search_panel;
    panel.changed_at = null;
    panel.searched_for.clearRetainingCapacity();
    try panel.searched_for.appendSlice(self.gpa, panel.query.text());
    panel.scroll = 0;
    const project = if (self.project) |*p| p else return panel.results.clear();
    self.file_search.scan(self.io, project.root().path) catch |err| {
        return self.reportError("Couldn't list the project's files", project.root().path, err);
    };
    try panel.results.run(self.io, project.root().path, self.file_search.files.items, panel.query.text());
}

/// Keys while a sidebar text box has focus. Returns false for commands
/// the editor should still get (save, find).
fn sideFieldKey(self: *App, cmd: core.Command) !bool {
    const field = switch (self.side_focus) {
        .none => return false,
        .search => &self.search_panel.query,
        .git_message => &self.git_panel.message,
    };
    switch (cmd) {
        .newline => if (self.side_focus == .search) try self.runSearch() else try self.gitCommit(),
        .clear_selection => self.side_focus = .none,
        .copy, .cut => try copyOrCut(self.gpa, &field.buffer, cmd == .cut),
        .paste => if (getClipboard()) |s| try field.paste(s),
        .save, .save_as, .find, .find_replace, .find_next, .find_prev => return false,
        else => _ = try field.handle(cmd),
    }
    if (self.side_focus == .search and !std.mem.eql(u8, field.text(), self.search_panel.searched_for.items)) {
        self.search_panel.changed_at = rl.getTime();
    }
    return true;
}

/// A click in the Search or Git view.
fn panelClick(self: *App, point: rl.Vector2) !void {
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
            const row = panel.rowAt(point) orelse return;
            const file = switch (row) {
                .file => |i| i,
                .match => |m| panel.results.matches.items[m].file,
            };
            const path = try std.fs.path.join(self.gpa, &.{ root, panel.results.files.items[file].path });
            defer self.gpa.free(path);
            self.side_focus = .none;
            self.openFile(path) catch |err| return self.reportError("Couldn't open file", path, err);
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
                    if (e.unstaged != 'D' and e.staged != 'D') self.openFile(path) catch |err| self.reportError("Couldn't open file", path, err);
                },
            }
        },
    }
}

/// After a git command: report git's own message if it failed, and
/// re-read the status either way.
fn gitAction(self: *App, result: anyerror!void) void {
    result catch dialogs.showError(self.gpa, self.io, "Git", if (self.git.last_error.items.len > 0) self.git.last_error.items else "The git command failed.");
    self.git_dirty = true;
}

fn gitCommit(self: *App) !void {
    const project = if (self.project) |*p| p else return;
    const message = std.mem.trim(u8, self.git_panel.message.text(), " \t");
    var staged = false;
    for (self.git.entries.items) |e| staged = staged or e.isStaged();
    if (!staged) return dialogs.showError(self.gpa, self.io, "Nothing to commit", "Stage changes first with the + next to them.");
    if (message.len == 0) return dialogs.showError(self.gpa, self.io, "Commit message needed", "Type a message describing the change.");
    self.git.commit(self.io, project.root().path, message) catch {
        return self.gitAction(error.GitFailed);
    };
    try self.git_panel.message.setText("");
    self.git_dirty = true;
}

/// Cmd+K: closes the project folder and its sidebar. Open tabs stay open.
fn closeFolder(self: *App) void {
    if (self.project == null) return;
    self.endTreePress();
    self.menu.close();
    self.sidebar.reset();
    self.quick_open.close();
    self.project.?.deinit();
    self.project = null;
}

fn openSettings(self: *App) !void {
    for (self.tabs.items, 0..) |t, i| {
        if (t.kind == .settings) return self.activate(i);
    }
    try self.tabs.insert(self.gpa, self.active + 1, .initSettings(self.gpa));
    try self.activate(self.active + 1);
}

fn runSettingsAction(self: *App, action: SettingsPage.Action) !void {
    const old = self.settings;
    switch (action) {
        .theme => |t| self.settings.theme = t,
        .accent => |c| self.settings.accent = c,
        .toggle_autosave => self.settings.autosave = !self.settings.autosave,
        .delay => |steps| self.settings.adjustDelay(steps),
        .zoom_in => self.settings.zoomIn(),
        .zoom_out => self.settings.zoomOut(),
        .zoom_reset => self.settings.zoom = 100,
        .toggle_minimap => self.settings.minimap = !self.settings.minimap,
        .toggle_new_window => self.settings.open_folder_in_new_window = !self.settings.open_folder_in_new_window,
    }
    try self.settingsChanged(old);
}

/// Saves files with unsaved changes once typing has paused for the
/// configured delay. Untitled files are left alone (they need a name). A
/// failed save is reported once per file, then retried after new edits.
fn autosave(self: *App) void {
    const now = rl.getTime();
    for (self.tabs.items) |*t| {
        if (t.kind != .file) continue;
        if (t.buffer.version != t.seen_version) {
            t.seen_version = t.buffer.version;
            t.changed_at = now;
        }
        if (!self.settings.autosave or t.document.path == null or !t.isDirty()) continue;
        const delay = @as(f64, @floatFromInt(self.settings.autosave_delay_ms)) / 1000;
        if (now - t.changed_at < delay) continue;
        t.changed_at = now; // don't retry a failing save every frame
        t.document.save(self.gpa, self.io, std.Io.Dir.cwd(), &t.buffer) catch |err| {
            if (!t.autosave_error_shown) {
                t.autosave_error_shown = true;
                self.reportError("Auto save failed", t.document.path.?, err);
            }
            continue;
        };
        t.autosave_error_shown = false;
    }
}

// --------------------------------------------------------------- terminal

fn terminalFocused(self: *const App) bool {
    return self.terminal_focused and self.terminal_panel.visible and self.terminal != null;
}

/// Ctrl+`: opens the terminal (starting a shell the first time), focuses
/// it if it's open but not focused, or hides it.
fn toggleTerminal(self: *App) !void {
    if (self.terminalFocused()) {
        self.terminal_panel.visible = false;
        self.terminal_focused = false;
        return;
    }
    self.terminal_panel.visible = true;
    self.terminal_focused = true;
    self.completion.close();
    if (self.terminal == null) {
        // Start in the project folder, else next to the current file.
        const cwd = if (self.project) |*p| p.root().path else self.tab().document.dirname() orelse Pty.homeDir();
        self.terminal = try Terminal.init(self.gpa, cwd, @intCast(self.terminal_panel.cols), @intCast(self.terminal_panel.rows));
    }
}

/// This frame's keys, while the terminal has focus. Returns true if
/// anything was typed.
fn handleTerminalKeys(self: *App) !bool {
    const term = &self.terminal.?;
    const panel = &self.terminal_panel;
    self.terminal_input.clearRetainingCapacity();
    const action = try terminal_keys.poll(self.gpa, &self.terminal_input, term.screen.app_cursor_keys);
    switch (action) {
        .none => {},
        .toggle => try self.toggleTerminal(),
        .copy => if (panel.orderedSelection()) |s| {
            const text = try term.screen.text(self.gpa, s[0], s[1]);
            defer self.gpa.free(text);
            try setClipboard(self.gpa, text);
        },
        .paste => if (getClipboard()) |s| {
            try term.paste(s);
            panel.scroll_back = 0;
        },
        .clear => {
            try term.screen.feed("\x1b[H\x1b[2J\x1b[3J");
            term.send("\x0c"); // Ctrl+L: the shell redraws its prompt
        },
        // Cmd shortcuts still work (Cmd+S, Cmd+O, Cmd+W...), but only ones
        // that make sense while the terminal has focus.
        .shortcut => {
            try keymap.poll(self.gpa, &self.commands);
            var kept: usize = 0;
            for (self.commands.items) |cmd| switch (cmd) {
                .open, .open_folder, .new_file, .close_tab, .next_tab, .prev_tab, .toggle_sidebar, .toggle_terminal, .save, .save_as, .open_settings, .zoom_in, .zoom_out, .zoom_reset, .quick_open, .show_explorer, .show_search, .show_git => {
                    self.commands.items[kept] = cmd;
                    kept += 1;
                },
                else => {},
            };
            self.commands.shrinkRetainingCapacity(kept);
        },
    }
    const typed = self.terminal_input.items;
    if (typed.len == 0) return action != .none;
    // After the shell exits, Enter starts a new one.
    if (term.exited()) {
        if (std.mem.indexOfScalar(u8, typed, '\r') != null) try term.restart();
    } else term.send(typed);
    panel.scroll_back = 0; // typing jumps back to the prompt
    panel.selection = null;
    return true;
}

/// Mouse on the terminal panel: resize by dragging its top edge, select
/// text, scroll history, close. Returns true if it took the mouse.
fn handleTerminalMouse(self: *App, point: rl.Vector2, pressed: bool) bool {
    const panel = &self.terminal_panel;
    const term = if (self.terminal) |*t| t else return false;
    if (!panel.visible) return false;

    if (panel.onDivider(point) or panel.resizing) self.wanted_cursor = .resize_ns;

    const released = !rl.isMouseButtonDown(.left);
    if (panel.resizing) {
        panel.height = panel.rect.y + panel.rect.height - point.y;
        if (released) panel.resizing = false;
        return true;
    }
    if (panel.selecting) {
        panel.selection.?.head = panel.cellAt(&term.screen, point, self.view.font);
        if (released) panel.selecting = false;
        return true;
    }
    if (!panel.contains(point) and !panel.onDivider(point)) {
        if (pressed) self.terminal_focused = false; // clicked elsewhere
        return false;
    }
    panel.scrollBy(&term.screen, rl.getMouseWheelMove());
    if (!pressed) return true;
    if (panel.onDivider(point)) {
        panel.resizing = true;
    } else if (panel.onClose(point)) {
        panel.visible = false;
        self.terminal_focused = false;
    } else {
        self.terminal_focused = true;
        self.completion.close();
        const at = panel.cellAt(&term.screen, point, self.view.font);
        panel.selection = .{ .anchor = at, .head = at };
        panel.selecting = rl.checkCollisionPointRec(point, panel.content);
    }
    return true;
}

/// Solid right after activity, then blinking.
fn caretVisible(self: *const App) bool {
    const since = rl.getTime() - self.last_activity;
    return since < theme.caret_blink or @mod(since, 2 * theme.caret_blink) < theme.caret_blink;
}

/// "● name.ts — project — byte code"; the dot marks unsaved changes.
fn updateTitle(self: *App) !void {
    const project = if (self.project) |*p| p.root().name else "";
    var buf_z: [256]u8 = undefined;
    const title = std.fmt.bufPrintZ(&buf_z, "{s}{s}{s}{s} — " ++ app_name, .{
        if (self.tab().isDirty()) "● " else "",
        self.tab().name(),
        if (project.len > 0) " — " else "",
        project,
    }) catch return; // absurdly long names: keep the old title
    if (std.mem.eql(u8, title, self.title_buf[0..self.title_len])) return;
    @memcpy(self.title_buf[0..title.len], title);
    self.title_len = title.len;
    rl.setWindowTitle(title);
}

// ------------------------------------------------------------------- tabs

fn activate(self: *App, index: usize) !void {
    if (index == self.active) return;
    self.tab().scroll = self.view.scroll;
    self.active = index;
    self.view.scroll = self.tab().scroll;
    self.completion.close();
    self.mouse.dragging = false;
    try self.revealCurrentFile();
}

fn cycleTabs(self: *App, delta: isize) !void {
    const n: isize = @intCast(self.tabs.items.len);
    try self.activate(@intCast(@mod(@as(isize, @intCast(self.active)) + delta, n)));
}

fn newFile(self: *App) !void {
    try self.tabs.insert(self.gpa, self.active + 1, .initFile(self.gpa));
    try self.activate(self.active + 1);
}

/// Closes a tab, asking about unsaved changes first. Returns false if
/// cancelled.
fn closeTab(self: *App, index: usize) !bool {
    if (self.tabs.items[index].isDirty()) {
        try self.activate(index); // show what we're asking about
        if (!try self.resolveUnsavedChanges()) return false;
    }
    var closed = self.tabs.orderedRemove(index);
    closed.deinit(self.gpa);
    if (self.tabs.items.len == 0) try self.tabs.append(self.gpa, .initWelcome(self.gpa));

    // Stay on the same tab, or its right neighbour if it was the one closed.
    if (index < self.active) self.active -= 1;
    if (index == self.active) {
        self.active = @min(index, self.tabs.items.len - 1);
        self.view.scroll = self.tab().scroll;
        self.completion.close();
    }
    try self.revealCurrentFile();
    return true;
}

// ------------------------------------------------------------------ files

/// Opens a file (in a tab) or a folder (as the project), reporting failures
/// in a dialog.
pub fn openPath(self: *App, path: []const u8) !void {
    if (isDirectory(self.io, path)) return self.openFolder(path);
    self.openFile(path) catch |err| self.reportError("Couldn't open file", path, err);
}

fn isDirectory(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// Switches to the file's tab if it's open, otherwise opens it in a new tab
/// (reusing an empty untitled one).
fn openFile(self: *App, given_path: []const u8) !void {
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

fn openWithDialog(self: *App) !void {
    const start_dir = self.tab().document.dirname() orelse if (self.project) |*p| p.root().path else null;
    const path = try dialogs.openFile(self.gpa, self.io, start_dir) orelse return;
    defer self.gpa.free(path);
    try self.openPath(path);
}

/// Opens a folder as the project. Open tabs stay open.
fn openFolder(self: *App, path: []const u8) !void {
    const tree = core.FileTree.open(self.gpa, self.io, path) catch |err| {
        return self.reportError("Couldn't open folder", path, err);
    };
    if (self.project) |*p| p.deinit();
    self.project = tree;
    self.sidebar.reset();
    if (self.tabs.items.len > 0) try self.revealCurrentFile();
}

fn openFolderWithDialog(self: *App) !void {
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
fn openInNewWindow(self: *App, path: []const u8) !void {
    const exe = try std.process.executablePathAlloc(self.io, self.gpa);
    defer self.gpa.free(exe);
    _ = std.process.spawn(self.io, .{
        .argv = &.{ exe, path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        // Its own process group on macOS/Linux (Windows has no such thing).
        .pgid = if (@import("builtin").os.tag == .windows) null else 0,
    }) catch |err| return self.reportError("Couldn't open a new window", path, err);
}

/// Files and folders dropped onto the window.
fn openDroppedFiles(self: *App) !void {
    if (!rl.isFileDropped()) return;
    const dropped = rl.loadDroppedFiles();
    defer rl.unloadDroppedFiles(dropped);
    for (dropped.paths[0..dropped.count]) |p| try self.openPath(std.mem.span(p));
}

/// Shows the sidebar's name box for a new file or folder in `folder`.
fn startCreate(self: *App, kind: core.FileTree.EntryKind, folder: u32) !void {
    const project = if (self.project) |*p| p else return;
    try project.expand(self.io, folder);
    try self.sidebar.startInput(project, folder, kind);
    self.completion.close();
    self.find.focus = .editor;
}

/// Where the header buttons create things: next to the active file, or
/// at the top of the project.
fn defaultFolder(self: *App) u32 {
    const project = if (self.project) |*p| p else return 0;
    const path = self.tab().document.path orelse return 0;
    return if (project.find(path)) |i| project.folderOf(i) else 0;
}

/// Right-click in the sidebar: actions for the clicked file or folder, or
/// just "new" ones on empty space.
fn openContextMenu(self: *App, hit: ?Sidebar.Hit, at: rl.Vector2) void {
    const project = if (self.project) |*p| p else return;
    self.menu_node = if (hit) |h| switch (h) {
        .node => |index| index,
        else => null,
    } else null;
    self.menu_folder = if (self.menu_node) |n| project.folderOf(n) else 0;

    const actions: []const MenuAction = if (self.menu_node != null)
        &.{ .new_file, .new_folder, .rename, .delete }
    else
        &.{ .new_file, .new_folder };
    var labels: [4][]const u8 = undefined;
    for (actions, 0..) |a, i| {
        self.menu_actions[i] = a;
        labels[i] = a.label();
    }
    const window = windowSize();
    self.menu.open(labels[0..actions.len], at, window, self.view.font);
}

fn runMenuAction(self: *App, action: MenuAction) !void {
    switch (action) {
        .new_file => try self.startCreate(.file, self.menu_folder),
        .new_folder => try self.startCreate(.folder, self.menu_folder),
        .rename => if (self.project) |*p| if (self.menu_node) |n| {
            try self.sidebar.startRename(p, n);
            self.completion.close();
            self.find.focus = .editor;
        },
        .delete => if (self.menu_node) |n| try self.deleteEntry(n),
    }
}

/// Enter in the name box: creates or renames.
fn finishInput(self: *App) !void {
    const input = self.sidebar.input orelse return;
    if (input.renaming) |node| try self.finishRename(node) else try self.finishCreate();
}

fn finishRename(self: *App, node: u32) !void {
    const project = if (self.project) |*p| p else return;
    // The tree (and the old path in it) is rebuilt by the rename: copy it.
    const old_path = try self.gpa.dupe(u8, project.node(node).path);
    defer self.gpa.free(old_path);
    const name = self.sidebar.name.text();
    const new_path = project.rename(self.io, node, name) catch |err| {
        return self.reportError("Couldn't rename", name, err);
    };
    defer self.gpa.free(new_path);
    self.sidebar.cancelInput();

    try self.retargetTabs(old_path, new_path);
}

/// After a rename or move: tabs showing the entry, or files inside a moved
/// folder, follow it to its new path.
fn retargetTabs(self: *App, old_path: []const u8, new_path: []const u8) !void {
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

// ------------------------------------------------------ sidebar dragging

fn startTreePress(self: *App, node: u32, at: rl.Vector2) !void {
    const project = if (self.project) |*p| p else return;
    self.endTreePress();
    self.tree_press = .{ .path = try self.gpa.dupe(u8, project.node(node).path), .start = at };
}

fn endTreePress(self: *App) void {
    if (self.tree_press) |t| self.gpa.free(t.path);
    self.tree_press = null;
    self.sidebar.drop_target = null;
    self.sidebar.drag_label = null;
}

/// Each frame while a sidebar row is pressed: turn it into a drag, track
/// the drop target, and on release either move the entry or treat the
/// press as a click (open the file / toggle the folder).
fn updateTreePress(self: *App, point: rl.Vector2) !void {
    const press = if (self.tree_press) |*t| t else return;
    const project = if (self.project) |*p| p else return self.endTreePress();
    const node = project.find(press.path) orelse return self.endTreePress();
    const released = rl.isMouseButtonReleased(.left);
    if (!released and !rl.isMouseButtonDown(.left)) return self.endTreePress();

    if (!press.dragging and std.math.hypot(point.x - press.start.x, point.y - press.start.y) > drag_threshold) {
        press.dragging = true;
    }
    if (!press.dragging) {
        if (!released) return;
        const path = try self.gpa.dupe(u8, press.path);
        defer self.gpa.free(path);
        self.endTreePress();
        if (project.node(node).is_dir) try project.toggle(self.io, node) else try self.openFromTree(path);
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
    } else if (hovered_folder) |f| if (rl.getTime() - press.hover_since > drag_expand_delay) {
        try project.expand(self.io, f);
        press.hover = null;
    };

    if (released) {
        self.endTreePress();
        if (valid) try self.moveEntry(node, target.?);
    }
}

/// Drop: moves an entry into a folder; open tabs follow it.
fn moveEntry(self: *App, node: u32, folder: u32) !void {
    const project = if (self.project) |*p| p else return;
    const old_path = try self.gpa.dupe(u8, project.node(node).path);
    defer self.gpa.free(old_path);
    const new_path = project.move(self.io, node, folder) catch |err| {
        return self.reportError("Couldn't move", old_path, err);
    };
    defer self.gpa.free(new_path);
    try self.retargetTabs(old_path, new_path);
}

/// Deletes after asking: to the trash if possible, otherwise permanently
/// after asking again. Tabs of deleted files close unless they have
/// unsaved changes.
fn deleteEntry(self: *App, node: u32) !void {
    const project = if (self.project) |*p| p else return;
    const n = project.node(node);
    const path = try self.gpa.dupe(u8, n.path);
    defer self.gpa.free(path);
    const question = try std.fmt.allocPrint(self.gpa, "Delete \"{s}\"?", .{n.name});
    defer self.gpa.free(question);
    const detail = if (n.is_dir) "The folder and everything in it will be moved to the Trash." else "It will be moved to the Trash.";

    if (!(dialogs.confirm(self.gpa, self.io, question, detail, "Move to Trash") catch false)) return;
    if (dialogs.moveToTrash(self.gpa, self.io, path)) {
        try self.refreshProject();
    } else |_| {
        const permanent = dialogs.confirm(self.gpa, self.io, question, "It can't be moved to the Trash. Delete it permanently? This can't be undone.", "Delete Permanently") catch false;
        if (!permanent) return;
        project.deletePermanently(self.io, node) catch |err| return self.reportError("Couldn't delete", path, err);
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
fn finishCreate(self: *App) !void {
    const project = if (self.project) |*p| p else return;
    const input = self.sidebar.input orelse return;
    const name = self.sidebar.name.text();
    const path = project.create(self.io, input.folder, name, input.kind) catch |err| {
        const what = if (input.kind == .file) "Couldn't create file" else "Couldn't create folder";
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
fn openFromTree(self: *App, path: []const u8) !void {
    // `path` lives in the tree, which may be refreshed (freed) meanwhile.
    const owned = try self.gpa.dupe(u8, path);
    defer self.gpa.free(owned);
    self.openFile(owned) catch |err| self.reportError("Couldn't open file", owned, err);
}

/// Expands the sidebar down to the active file and scrolls to it.
fn revealCurrentFile(self: *App) !void {
    const project = if (self.project) |*p| p else return;
    const path = self.tab().document.path orelse return;
    if (try project.reveal(self.io, path)) |row| self.sidebar.revealRow(row);
}

/// Picks up files created, renamed or deleted outside the editor.
fn refreshProjectOnFocus(self: *App) !void {
    const focused = rl.isWindowFocused();
    defer self.was_focused = focused;
    if (focused and !self.was_focused) {
        try self.refreshProject();
        self.git_dirty = true; // files may have changed elsewhere
    }
}

/// Re-reads the project folder. Tree positions change, so whatever the menu
/// and the name box point at is found again by path — never acted on by a
/// stale index — or dropped if it's gone.
fn refreshProject(self: *App) !void {
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
fn save(self: *App, choose_path: bool) !bool {
    self.git_dirty = true;
    const t = self.tab();
    if (t.kind != .file) return false;
    if (choose_path or t.document.path == null) {
        const path = try dialogs.saveFile(self.gpa, self.io, t.document.name(), t.document.dirname()) orelse return false;
        defer self.gpa.free(path);
        try t.document.setPath(self.gpa, path);
        t.highlighter.language = .fromPath(path);
    }
    t.document.save(self.gpa, self.io, std.Io.Dir.cwd(), &t.buffer) catch |err| {
        self.reportError("Couldn't save file", t.document.path.?, err);
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
fn resolveUnsavedChanges(self: *App) !bool {
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

fn reportError(self: *App, title: []const u8, path: []const u8, err: anyerror) void {
    const reason = switch (err) {
        error.NotUtf8 => "It isn't a UTF-8 text file.",
        error.FileTooBig => "It is larger than 64 MB.",
        error.AccessDenied, error.PermissionDenied => "Permission denied.",
        error.IsDir => "It is a directory.",
        error.FileNotFound => "The folder doesn't exist.",
        error.NoSpaceLeft => "The disk is full.",
        error.PathAlreadyExists => "A file or folder with that name already exists.",
        error.InvalidName => "Enter a name inside this folder (no \"..\" or leading \"/\").",
        else => @errorName(err),
    };
    const message = std.fmt.allocPrint(self.gpa, "{s}\n\n{s}", .{ path, reason }) catch return;
    defer self.gpa.free(message);
    dialogs.showError(self.gpa, self.io, title, message);
}

// ---------------------------------------------------------------- input

/// Clicks go to whatever is on top: the suggestion popup, the find bar, the
/// tab bar, the sidebar, then the welcome page or the text (which also takes
/// keyboard focus back from the find bar).
fn handleMouse(self: *App) !bool {
    const point = rl.getMousePosition();
    const pressed = rl.isMouseButtonPressed(.left);
    const right_pressed = rl.isMouseButtonPressed(.right);
    const editing = self.isEditing();

    // "Go to file" is on top: a click picks a file, a click elsewhere closes it.
    if (self.quick_open.is_open) {
        if (!pressed) return false;
        if (self.quick_open.itemAt(point)) |i| {
            self.quick_open.selected = i;
            try self.openQuickOpenSelection();
        } else if (!self.quick_open.contains(point)) self.quick_open.close();
        return true;
    }

    // The sidebar's right edge: drag to resize.
    if (self.sidebar.resizing) {
        self.wanted_cursor = .resize_ew;
        if (rl.isMouseButtonDown(.left)) {
            self.sidebar.preferred_width = @max(Sidebar.min_width, point.x);
        } else {
            // Released: remember the width that was actually used.
            self.sidebar.resizing = false;
            const old = self.settings;
            self.settings.sidebar_width = @intFromFloat(self.sidebar.width());
            self.sidebar.preferred_width = self.sidebar.width();
            try self.settingsChanged(old);
        }
        return true;
    }
    if (!self.menu.is_open and self.sidebar.onEdge(point)) {
        self.wanted_cursor = .resize_ew;
        if (pressed) {
            self.sidebar.resizing = true;
            return true;
        }
    }

    // The terminal panel (unless a menu is open on top of it).
    if (!self.menu.is_open and self.handleTerminalMouse(point, pressed)) return true;

    // The context menu is on top of everything; any click closes it.
    if (self.menu.is_open and (pressed or right_pressed)) {
        const chosen = if (pressed) self.menu.itemAt(point) else null;
        self.menu.close();
        if (chosen) |i| try self.runMenuAction(self.menu_actions[i]);
        return true;
    }

    const on_popup = editing and pressed and self.popup.contains(point);
    if (on_popup) if (self.popup.itemAt(&self.completion, point)) |i| {
        self.completion.selected = i;
        try self.completion.accept(self.buf());
    };

    const on_find = editing and pressed and !on_popup and self.find.contains(point);
    if (on_find) self.find.click(point, &self.view);

    // Tabs: click to switch, × or middle click to close.
    const over_tabs = self.tab_bar.contains(point);
    const middle = rl.isMouseButtonPressed(.middle);
    const on_tabs = over_tabs and (pressed or middle);
    if (on_tabs) if (self.tab_bar.hit(point)) |h| {
        if (h.close or middle) _ = try self.closeTab(h.index) else try self.activate(h.index);
    };

    // The sidebar: the wheel scrolls it; clicks toggle folders, open files
    // or press the header buttons; right-click offers New File / Folder.
    // The sidebar's scrollbar comes before its rows.
    if (!self.menu.is_open and self.sidebar.handleScrollbar(point, pressed)) return true;
    const over_sidebar = self.sidebar.contains(point);
    const on_sidebar = (pressed or right_pressed) and over_sidebar;
    if (over_sidebar) switch (self.sidebar.view) {
        .explorer => self.sidebar.scrollBy(rl.getMouseWheelMove()),
        .search => self.search_panel.scrollBy(rl.getMouseWheelMove()),
        .git => self.git_panel.scrollBy(rl.getMouseWheelMove()),
    };
    // Clicking outside the sidebar takes the keyboard from its text boxes.
    if (pressed and !over_sidebar) self.side_focus = .none;
    var keep_name_box = false;
    if (on_sidebar) if (self.project) |*p| {
        const hit = self.sidebar.hitTest(p, point);
        if (right_pressed) {
            if (self.sidebar.view == .explorer) self.openContextMenu(hit, point);
        } else if (hit) |h| switch (h) {
            .view_tab => |v| self.showView(v),
            .settings_button => try self.openSettings(),
            .open_folder_button => self.openFolderWithDialog() catch |err| self.reportError("Couldn't open folder", "", err),
            .panel => try self.panelClick(point),
            // Acted on at release: the press may turn into a drag.
            .node => |index| try self.startTreePress(index, point),
            .input => {
                self.sidebar.clickInput(p, point, self.view.font);
                keep_name_box = true;
            },
            .collapse_button => try p.collapseAll(),
            .new_button => |kind| {
                try self.startCreate(kind, self.defaultFolder());
                keep_name_box = true;
            },
            .empty => {},
        };
    };
    // Clicking anywhere but the name box gives up on the new entry.
    if ((pressed or right_pressed) and !keep_name_box) self.sidebar.cancelInput();
    try self.updateTreePress(point);
    const dragging = self.tree_press != null and self.tree_press.?.dragging;

    // A drag in the sidebar owns the mouse (and re-lays-out every frame).
    const captured = on_popup or on_find or on_tabs or on_sidebar or dragging;
    if (!self.isEditing()) {
        if (pressed and !captured) switch (self.activeTab().kind) {
            // The welcome page's "Start" links, the settings' controls.
            .welcome => if (self.welcome.actionAt(point)) |cmd| try self.execute(cmd),
            .settings => if (self.settings_page.actionAt(point, &self.settings)) |a| try self.runSettingsAction(a),
            .file => {},
        };
        return captured or pressed;
    }

    // The minimap: click or drag to scroll.
    if (self.settings.minimap and !captured and self.minimap.handleMouse(&self.view, self.buf(), point, pressed)) return true;

    const moved = self.mouse.update(&self.view, self.buf(), captured, !over_sidebar and !over_tabs);
    if (moved) {
        self.completion.close();
        self.find.focus = .editor;
    }
    return moved or captured;
}

fn execute(self: *App, cmd: core.Command) !void {
    // Commands that work anywhere, including the welcome tab.
    switch (cmd) {
        .open => return self.openWithDialog() catch |err| self.reportError("Couldn't open file", "", err),
        .open_folder => return self.openFolderWithDialog() catch |err| self.reportError("Couldn't open folder", "", err),
        .new_file => return self.newFile(),
        .close_tab => {
            _ = try self.closeTab(self.active);
            return;
        },
        .next_tab => return self.cycleTabs(1),
        .prev_tab => return self.cycleTabs(-1),
        .toggle_sidebar => {
            self.sidebar.visible = !self.sidebar.visible;
            return;
        },
        .toggle_terminal => return self.toggleTerminal(),
        .open_settings => return self.openSettings(),
        .quick_open => return self.openQuickOpen(),
        .show_explorer => return self.showView(.explorer),
        .show_search => return self.showView(.search),
        .show_git => return self.showView(.git),
        .close_folder => return self.closeFolder(),
        .zoom_in, .zoom_out, .zoom_reset => return self.runSettingsAction(switch (cmd) {
            .zoom_in => .zoom_in,
            .zoom_out => .zoom_out,
            else => .zoom_reset,
        }),
        else => {},
    }

    if (self.quick_open.is_open) return self.quickOpenKey(cmd);
    if (try self.sideFieldKey(cmd)) return;

    // Esc cancels a drag in the sidebar.
    if (cmd == .clear_selection) if (self.tree_press) |t| if (t.dragging) return self.endTreePress();

    // While naming a new file or folder, keys edit the name box.
    if (self.sidebar.input != null) {
        const field = &self.sidebar.name;
        switch (cmd) {
            .newline => try self.finishInput(),
            .clear_selection => self.sidebar.cancelInput(),
            .copy, .cut => try copyOrCut(self.gpa, &field.buffer, cmd == .cut),
            .paste => if (getClipboard()) |s| try field.paste(s),
            else => _ = try field.handle(cmd),
        }
        return;
    }
    if (!self.isEditing()) return;

    const b = self.buf();
    // Find shortcuts work wherever the focus is.
    switch (cmd) {
        .find, .find_replace => {
            self.completion.close();
            return self.find.show(b, cmd == .find_replace);
        },
        .find_next => return if (self.find.query.text().len > 0) self.find.next(b) else self.find.show(b, false),
        .find_prev => return if (self.find.query.text().len > 0) self.find.prev(b) else self.find.show(b, false),
        else => {},
    }

    if (self.find.focusedField()) |field| {
        switch (cmd) {
            .copy, .cut => try copyOrCut(self.gpa, &field.buffer, cmd == .cut),
            .paste => if (getClipboard()) |s| try self.find.paste(s, b),
            else => if (try self.find.handle(cmd, b, keymap.Mods.current())) return,
        }
        if (cmd == .copy or cmd == .cut or cmd == .paste) return;
    }

    if (self.completion.is_open and try self.handleCompletionKey(cmd)) return;
    // Esc in the editor with nothing selected closes the find bar.
    if (cmd == .clear_selection and self.find.is_open and b.selection() == null) self.find.close();

    switch (cmd) {
        .copy, .cut => try copyOrCut(self.gpa, b, cmd == .cut),
        .paste => if (getClipboard()) |s| try b.insert(s),
        .save, .save_as => _ = self.save(cmd == .save_as) catch |err| self.reportError("Couldn't save file", "", err),
        .complete => {},
        else => try core.command.run(b, cmd, self.view.pageLines()),
    }
    try self.updateCompletion(cmd);
}

/// While suggestions are showing, arrows pick one, Enter/Tab accept it and
/// Esc closes the list. Returns true if the command was consumed.
fn handleCompletionKey(self: *App, cmd: core.Command) !bool {
    const c = &self.completion;
    switch (cmd) {
        .move => |m| {
            if (m.extend) return false;
            const page: isize = CompletionPopup.max_rows;
            switch (m.motion) {
                .line_up => c.moveSelection(-1),
                .line_down => c.moveSelection(1),
                .page_up => c.moveSelection(-page),
                .page_down => c.moveSelection(page),
                else => return false,
            }
        },
        .newline, .indent => try c.accept(self.buf()),
        .clear_selection => c.close(),
        else => return false,
    }
    return true;
}

/// Opens suggestions while typing a word or after `.`, keeps them in sync
/// while editing that word, and closes them on anything else.
fn updateCompletion(self: *App, cmd: core.Command) !void {
    const c = &self.completion;
    const t = self.tab();
    switch (cmd) {
        .type_char => |cp| {
            const word_char = cp >= 0x80 or core.syntax.js.isIdentChar(@intCast(cp));
            if (word_char or cp == '.') try c.refresh(&t.buffer, &t.highlighter, false) else c.close();
        },
        .backspace, .delete => if (c.is_open) try c.refresh(&t.buffer, &t.highlighter, false),
        .complete => try c.refresh(&t.buffer, &t.highlighter, true),
        else => c.close(),
    }
}

/// Copies (and with `cut`, deletes) the selection, or the whole current
/// line when nothing is selected.
fn copyOrCut(gpa: std.mem.Allocator, b: *core.Buffer, cut: bool) !void {
    const r = b.selection() orelse b.currentLineRange();
    try setClipboard(gpa, b.items()[r.start..r.end]);
    if (cut) try b.deleteRange(r);
}

fn setClipboard(gpa: std.mem.Allocator, s: []const u8) !void {
    const z = try gpa.dupeZ(u8, s);
    defer gpa.free(z);
    rl.setClipboardText(z);
}

fn getClipboard() ?[]const u8 {
    // GLFW returns null when the clipboard holds no text.
    const ptr = rl.cdef.GetClipboardText() orelse return null;
    return std.mem.span(ptr);
}
