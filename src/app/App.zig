//! The editor application: owns the open tabs, the optional project folder,
//! the view, the completion popup and the find bar, and runs one frame of
//! input → commands → drawing.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const keymap = @import("../input/lib/keymap.zig");
const Keymap = @import("../input/Keymap.zig");
const Mouse = @import("../input/Mouse.zig");
const Tab = @import("Tab.zig");
const theme = @import("../ui/theme/lib/theme.zig");
const Font = @import("../ui/Font.zig");
const View = @import("../ui/editor/View.zig");
const CompletionPopup = @import("../ui/editor/CompletionPopup.zig");
const FindBar = @import("../ui/editor/FindBar.zig");
const Sidebar = @import("../ui/sidebar/Sidebar.zig");
const ContextMenu = @import("../ui/sidebar/ContextMenu.zig");
const Terminal = @import("Terminal.zig");
const TerminalPanel = @import("../ui/terminal/TerminalPanel.zig");
const paths = @import("../platform/lib/paths.zig");
const SettingsPage = @import("../ui/pages/SettingsPage.zig");
const Minimap = @import("../ui/editor/Minimap.zig");
const QuickOpen = @import("../ui/QuickOpen.zig");
const SearchPanel = @import("../ui/sidebar/SearchPanel.zig");
const GitPanel = @import("../ui/sidebar/GitPanel.zig");
const TabBar = @import("../ui/TabBar.zig");
const WelcomePage = @import("../ui/pages/WelcomePage.zig");
const HelpPage = @import("../ui/pages/HelpPage.zig");
const render = @import("lib/render.zig");
const settings_actions = @import("lib/settings_actions.zig");
const go_to_file = @import("lib/go_to_file.zig");
const panels = @import("lib/panels.zig");
const project_search = @import("lib/project_search.zig");
const terminal_io = @import("lib/terminal_io.zig");
const tab_actions = @import("lib/tab_actions.zig");
const files = @import("lib/files.zig");
const tree = @import("lib/tree.zig");
const mouse_input = @import("lib/mouse_input.zig");
const editing = @import("lib/editing.zig");
const clipboard = @import("lib/clipboard.zig");
const dispatch = @import("lib/dispatch.zig");
const shortcuts = @import("lib/shortcuts.zig");

pub const app_name = "byte code";

pub const TreePress = struct {
    path: []u8,
    start: rl.Vector2,
    dragging: bool = false,
    /// A collapsed folder being hovered during the drag, and since when;
    /// it opens after a moment.
    hover: ?u32 = null,
    hover_since: f64 = 0,
};

/// Mouse travel that turns a press into a drag.
pub const drag_threshold = 5;
/// Seconds of hovering a collapsed folder while dragging before it opens.
pub const drag_expand_delay = 0.6;

pub const MenuAction = enum {
    new_file,
    new_folder,
    rename,
    delete,

    pub fn label(self: MenuAction) []const u8 {
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
/// Keyboard shortcuts: what each action is bound to, where they're saved,
/// and the Help tab that lists and changes them.
keys: Keymap,
keys_path: []u8,
help_page: HelpPage = .{},
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
side_focus: enum { none, search, search_replace, git_message } = .none,
/// Scroll the editor to its cursor on the next frame (e.g. after opening
/// a search result).
reveal_cursor: bool = false,
/// Selections before each "select scope" step, so shrinking can go back.
/// Valid while the buffer and selection are as that step left them.
scope_steps: std.ArrayList(core.Buffer.Range) = .empty,
scope_version: u64 = 0,
scope_current: core.Buffer.Range = .{ .start = 0, .end = 0 },
minimap: Minimap = .{},
/// Commands gathered this frame; kept to reuse its memory.
commands: std.ArrayList(core.Command) = .empty,
/// Time of the last cursor activity, for caret blinking.
last_activity: f64 = 0,
/// The window title currently shown, to update it only on change.
title_buf: [256]u8 = undefined,
title_len: usize = 0,

// ------------------------------------------------------------ parts
// The app's work is spread over the files in this folder; their
// functions that take the app are its methods too.

// render.zig
pub const draw = render.draw;

// shortcuts.zig
pub const openHelp = shortcuts.openHelp;
pub const runHelpAction = shortcuts.runHelpAction;
pub const captureShortcut = shortcuts.captureShortcut;
pub const bindShortcut = shortcuts.bindShortcut;

// settings_actions.zig
pub const settingsChanged = settings_actions.settingsChanged;
pub const openSettings = settings_actions.openSettings;
pub const runSettingsAction = settings_actions.runSettingsAction;
pub const autosave = settings_actions.autosave;

// go_to_file.zig
pub const openQuickOpen = go_to_file.openQuickOpen;
pub const quickOpenKey = go_to_file.quickOpenKey;
pub const openQuickOpenSelection = go_to_file.openQuickOpenSelection;

// panels.zig
pub const showView = panels.showView;
pub const updateSidebarViews = panels.updateSidebarViews;
pub const sideFieldKey = panels.sideFieldKey;
pub const panelClick = panels.panelClick;
pub const gitAction = panels.gitAction;
pub const gitCommit = panels.gitCommit;

// project_search.zig
pub const runSearch = project_search.runSearch;
pub const tabForProjectFile = project_search.tabForProjectFile;
pub const replaceInProject = project_search.replaceInProject;
pub const replaceInProjectFile = project_search.replaceInProjectFile;
pub const replaceMatchInProject = project_search.replaceMatchInProject;
pub const replaceAllInFile = project_search.replaceAllInFile;

// terminal_io.zig
pub const terminalFocused = terminal_io.terminalFocused;
pub const toggleTerminal = terminal_io.toggleTerminal;
pub const handleTerminalKeys = terminal_io.handleTerminalKeys;
pub const handleTerminalMouse = terminal_io.handleTerminalMouse;

// tab_actions.zig
pub const activate = tab_actions.activate;
pub const cycleTabs = tab_actions.cycleTabs;
pub const newFile = tab_actions.newFile;
pub const closeTab = tab_actions.closeTab;

// files.zig
pub const openPath = files.openPath;
pub const openFile = files.openFile;
pub const openWithDialog = files.openWithDialog;
pub const openFolder = files.openFolder;
pub const openFolderWithDialog = files.openFolderWithDialog;
pub const openInNewWindow = files.openInNewWindow;
pub const openDroppedFiles = files.openDroppedFiles;
pub const closeFolder = files.closeFolder;
pub const refreshProjectOnFocus = files.refreshProjectOnFocus;
pub const refreshProject = files.refreshProject;
pub const retargetTabs = files.retargetTabs;
pub const confirmClose = files.confirmClose;
pub const save = files.save;
pub const resolveUnsavedChanges = files.resolveUnsavedChanges;
pub const reportError = files.reportError;

// tree.zig
pub const startCreate = tree.startCreate;
pub const defaultFolder = tree.defaultFolder;
pub const openContextMenu = tree.openContextMenu;
pub const runMenuAction = tree.runMenuAction;
pub const finishInput = tree.finishInput;
pub const finishRename = tree.finishRename;
pub const startTreePress = tree.startTreePress;
pub const endTreePress = tree.endTreePress;
pub const updateTreePress = tree.updateTreePress;
pub const moveEntry = tree.moveEntry;
pub const deleteEntry = tree.deleteEntry;
pub const finishCreate = tree.finishCreate;
pub const openFromTree = tree.openFromTree;
pub const revealCurrentFile = tree.revealCurrentFile;

// mouse_input.zig
pub const handleMouse = mouse_input.handleMouse;

// editing.zig
pub const moveByRows = editing.moveByRows;
pub const expandSelection = editing.expandSelection;
pub const shrinkSelection = editing.shrinkSelection;
pub const selectScope = editing.selectScope;
pub const scopeStepsValid = editing.scopeStepsValid;
pub const handleCompletionKey = editing.handleCompletionKey;
pub const updateCompletion = editing.updateCompletion;

// Running commands, in dispatch.zig.
pub const execute = dispatch.execute;

/// Call after the window is open (fonts need the GPU).
pub fn init(gpa: std.mem.Allocator, io: std.Io) !App {
    // Settings first: zoom decides the size the font is rendered at.
    const settings_path = try paths.settingsFile(gpa);
    errdefer gpa.free(settings_path);
    const settings = core.Settings.load(gpa, io, std.Io.Dir.cwd(), settings_path);
    const keys_path = try paths.keybindingsFile(gpa);
    errdefer gpa.free(keys_path);
    settings_actions.applyToTheme(settings);
    var app: App = .{
        .gpa = gpa,
        .io = io,
        .view = View.init(gpa, Font.load()),
        .completion = .init(gpa),
        .find = .init(gpa),
        .sidebar = .init(gpa),
        .settings = settings,
        .settings_path = settings_path,
        .keys = Keymap.load(gpa, io, std.Io.Dir.cwd(), keys_path),
        .keys_path = keys_path,
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
    self.gpa.free(self.keys_path);
    self.scope_steps.deinit(self.gpa);
    self.view.deinit();
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

pub fn tab(self: *App) *Tab {
    return &self.tabs.items[self.active];
}

pub fn activeTab(self: *const App) *const Tab {
    return &self.tabs.items[self.active];
}

pub fn buf(self: *App) *core.Buffer {
    return &self.tab().buffer;
}

pub fn isEditing(self: *const App) bool {
    return self.activeTab().kind == .file;
}

// ------------------------------------------------------------------ frame

pub fn update(self: *App) !void {
    const window = windowSize();
    try self.refreshProjectOnFocus();
    self.matchFontToDisplay();
    try self.openDroppedFiles();
    if (self.terminal) |*t| _ = try t.pump();
    try self.layout(window);

    // Keys go to the terminal when it has focus, else to the editor.
    self.commands.clearRetainingCapacity();
    const typed_in_terminal = if (self.terminalFocused()) try self.handleTerminalKeys() else blk: {
        // The Help tab takes the keyboard while it records a shortcut.
        if (self.activeTab().kind != .help) self.help_page.stopCapture();
        if (self.help_page.capturing != null) {
            self.captureShortcut();
        } else {
            try keymap.poll(self.gpa, &self.keys, &self.commands);
        }
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
pub fn windowSize() rl.Vector2 {
    return .{
        .x = @as(f32, @floatFromInt(rl.getScreenWidth())) / theme.zoom,
        .y = @as(f32, @floatFromInt(rl.getScreenHeight())) / theme.zoom,
    };
}

/// Sidebar on the left; tab bar on top of the rest; the editor below it.
pub fn layout(self: *App, window: rl.Vector2) !void {
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
    self.view.wrap = self.settings.word_wrap;
    try self.view.layout(self.buf(), text_area);
    self.quick_open.layout(editor, self.view.font);
    switch (self.activeTab().kind) {
        .welcome => self.welcome.layout(editor, self.view.font),
        .settings => self.settings_page.layout(editor, self.view.font),
        .help => self.help_page.layout(editor, self.view.font),
        .file => {},
    }
}

// ------------------------------------------------------------ display

/// Moving the window to a display with another pixel density (Retina vs
/// a regular monitor) re-renders the font for it, so text stays sharp.
pub fn matchFontToDisplay(self: *App) void {
    const scale = @max(1, rl.getWindowScaleDPI().x) * theme.zoom;
    if (@abs(scale * self.view.font.pixel - 1) < 0.01) return;
    self.view.font.unload();
    self.view.font = Font.load();
}

/// Solid right after activity, then blinking.
pub fn caretVisible(self: *const App) bool {
    const since = rl.getTime() - self.last_activity;
    return since < theme.caret_blink or @mod(since, 2 * theme.caret_blink) < theme.caret_blink;
}

/// "● name.ts — project — byte code"; the dot marks unsaved changes.
pub fn updateTitle(self: *App) !void {
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
