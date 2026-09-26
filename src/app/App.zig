//! The editor application: owns the open tabs, the optional project folder,
//! the view, the completion popup and the find bar, and runs one frame of
//! input → commands → drawing.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const i18n = @import("../i18n/i18n.zig");
const keymap = @import("../input/lib/keymap.zig");
const Keymap = @import("../input/Keymap.zig");
const Mouse = @import("../input/Mouse.zig");
const Tab = @import("Tab.zig");
const theme = @import("../ui/theme/lib/theme.zig");
const anim = @import("../ui/anim.zig");
const Font = @import("../ui/Font.zig");
const file_icon = @import("../ui/widgets/lib/file_icon.zig");
const folder_icon = @import("../ui/widgets/lib/folder_icon.zig");
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
const StatusBar = @import("../ui/StatusBar.zig");
const WelcomePage = @import("../ui/pages/WelcomePage.zig");
const HelpPage = @import("../ui/pages/HelpPage.zig");
const render = @import("lib/render.zig");
const modals = @import("lib/modals.zig");
const Modal = @import("../ui/Modal.zig");
const settings_actions = @import("lib/settings_actions.zig");
const go_to_file = @import("lib/go_to_file.zig");
const panels = @import("lib/panels.zig");
const project_search = @import("lib/project_search.zig");
const terminal_io = @import("lib/terminal_io.zig");
const tab_actions = @import("lib/tab_actions.zig");
const files = @import("lib/files.zig");
const tree = @import("lib/tree.zig");
const mouse_input = @import("lib/mouse_input.zig");
const git_diff = @import("lib/git_diff.zig");
const git_blame = @import("lib/git_blame.zig");
const problems = @import("lib/problems.zig");
const git_jobs = @import("lib/git_job.zig");
const git_conflicts = @import("lib/git_conflicts.zig");
const git_pickers = @import("lib/git_pickers.zig");
const Picker = @import("../ui/Picker.zig");
const symbol_nav = @import("lib/symbol_nav.zig");
const editing = @import("lib/editing.zig");
const clipboard = @import("lib/clipboard.zig");
const dispatch = @import("lib/dispatch.zig");
const split_panes = @import("lib/split.zig");
const shortcuts = @import("lib/shortcuts.zig");
const palette = @import("lib/palette.zig");
const folding = @import("lib/folding.zig");
const Navigation = @import("lib/navigation.zig");

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

/// Which rows an icon menu is for.
pub const IconsFor = enum { file, folder };

pub const MenuAction = union(enum) {
    new_file,
    new_folder,
    rename,
    delete,
    /// Stop git listing a file or folder.
    add_to_gitignore,
    /// Ctrl+click: go to one of the places in `refs`.
    go_to_ref: u32,
    /// Ctrl+click: put every one of them in the Search view.
    all_refs,
    /// The language and icon menus in Settings.
    set_language: core.Settings.Language,
    set_icons: struct { of: IconsFor, mode: core.Settings.Icons },
    /// The right-click menu on a tab: the editor in two panes.
    split_right,
    split_down,
    move_to_other_pane,

    /// The menu row for the actions whose wording never changes; the
    /// ctrl+click ones are labelled with the place they lead to.
    pub fn label(self: MenuAction) []const u8 {
        const t = i18n.tr().sidebar;
        return switch (self) {
            .new_file => t.new_file,
            .new_folder => t.new_folder,
            .rename => t.rename,
            .delete => t.delete,
            .add_to_gitignore => t.add_to_gitignore,
            .go_to_ref, .all_refs => "",
            .set_language => |l| l.nativeName(),
            .set_icons => |i| SettingsPage.fileIconsLabel(i.mode),
            .split_right => i18n.tr().tabs.split_right,
            .split_down => i18n.tr().tabs.split_down,
            .move_to_other_pane => i18n.tr().tabs.move_to_other,
        };
    }
};

/// A place a name is used, for the ctrl+click menu. `file` indexes the
/// Search view's results, or is null for a place in the current file.
pub const Ref = struct {
    file: ?u32,
    line: u32,
    start: usize,
    end: usize,
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
menu_actions: [ContextMenu.max_items]MenuAction = undefined,
menu_node: ?u32 = null,
menu_folder: u32 = 0,
/// The tab the right-click menu was opened on, for its split actions.
menu_tab: ?usize = null,
/// Ctrl+click: the name looked up and where it is used, listed by the
/// menu and left alone until the next lookup.
refs: std.ArrayList(Ref) = .empty,
ref_name: std.ArrayList(u8) = .empty,
/// A mouse press on a sidebar row. It becomes a drag (to move the entry)
/// once the mouse moves a few pixels; otherwise it's a click on release.
/// Holds the entry's path, not its index, so a tree refresh can't make it
/// point at another file.
tree_press: ?TreePress = null,
tab_bar: TabBar = .{},
/// The editor in two panes (see lib/split.zig): which way the second one
/// goes and where its tabs start, how the room is shared between them, and
/// which of them has the keyboard. The pane that has it uses `view`,
/// `tab_bar`, `minimap` and `active`; the other one's are kept here and
/// swapped in when it is clicked.
split: ?split_panes.Dir = null,
split_at: usize = 0,
split_ratio: f32 = 0.5,
pane: u1 = 0,
other_active: usize = 0,
other_view: View,
other_bar: TabBar = .{},
other_minimap: Minimap = .{},
/// Where each pane draws, its own tab bar included; set by `layout`.
pane_rects: [2]rl.Rectangle = .{ std.mem.zeroes(rl.Rectangle), std.mem.zeroes(rl.Rectangle) },
/// The divider between the panes is being dragged.
split_resizing: bool = false,
/// A tab held down, which dragging moves to the other pane.
tab_press: ?split_panes.TabPress = null,
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
/// The folders opened before and the favorites among them, listed on the
/// welcome page (projects.json next to settings.json).
projects: core.Projects,
projects_path: []u8,
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
/// What .git looked like when the status was last read, and when it was
/// last looked at: git run elsewhere (the terminal) shows up at once.
git_stamp: u64 = 0,
git_watch_at: f64 = 0,
/// A push, pull or fetch running in the background, if any.
git_job: ?*git_jobs.Job = null,
/// The language parser checking a file's syntax in the background, if any;
/// where programs are looked for (worked out by the first run); and which
/// parsers were found to run, or not to be installed.
syntax_job: ?*problems.Job = null,
tool_path: ?[]u8 = null,
ts_server: core.Diagnostics.checkers.Server,
tools_working: std.EnumSet(core.Diagnostics.checkers.Tool) = .initEmpty(),
tools_missing: std.EnumSet(core.Diagnostics.checkers.Tool) = .initEmpty(),
/// The editor's environment, which git commands that may ask for a
/// password are run with (plus what sends the question here).
environ: ?*const std.process.Environ.Map = null,
/// The same for git's copy of the file being edited, which the change
/// marks in the gutter are compared with, and for who last touched each
/// of its lines (the bar at the bottom).
diff_dirty: bool = true,
blame_dirty: bool = true,
/// The dialog being shown, while `runModal` waits for its answer.
modal: ?*const Modal = null,
/// The bar along the bottom of the window.
status: StatusBar = .{},
/// Which sidebar text box has the keyboard, if any.
side_focus: enum { none, search, search_replace, git_message, git_prompt } = .none,
/// The list picked from at the top of the editor (branches, stashes),
/// what it is for, and the branches and stashes it shows.
picker: Picker,
picker_mode: git_pickers.Mode = .checkout,
/// The branch a two-step list was started from (cherry-pick, compare).
picker_rev: std.ArrayList(u8) = .empty,
git_refs: core.GitRefs,
/// Scroll the editor to its cursor on the next frame (e.g. after opening
/// a search result).
reveal_cursor: bool = false,
/// Selections before each "select scope" step, so shrinking can go back.
/// Valid while the buffer and selection are as that step left them.
scope_steps: std.ArrayList(core.Buffer.Range) = .empty,
scope_version: u64 = 0,
scope_current: core.Buffer.Range = .{ .start = 0, .end = 0 },
minimap: Minimap = .{},
/// The command palette's rows, as actions; the names the file declares,
/// for Go to Symbol; and where the cursor was when a list that moves it
/// while choosing opened (Esc goes back there).
palette_actions: std.ArrayList(Keymap.Action) = .empty,
symbols: std.ArrayList(core.symbols.Symbol) = .empty,
jump_origin: ?palette.Origin = null,
/// Go Back / Go Forward.
nav: Navigation = .{},
/// Cmd+D: whether the occurrences it adds must be whole words (it
/// started from a word), valid while the text and the main selection
/// are as it left them.
occurrence_whole: bool = false,
occurrence_version: u64 = 0,
occurrence_sel: core.Buffer.Range = .{ .start = 0, .end = 0 },
/// The bracket at the cursor and its partner, outlined; and the text,
/// cursor and tab they were found for.
bracket_pair: ?core.brackets.Pair = null,
bracket_key: [3]u64 = .{ 0, 0, 0 },
/// A command picked in the command palette, run after this frame's
/// input.
pending_command: ?core.Command = null,
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

// modals.zig
pub const runModal = modals.runModal;
pub const drawModal = modals.drawModal;
pub const confirm = modals.confirm;
pub const confirmRemember = modals.confirmRemember;
pub const askSaveChanges = modals.askSaveChanges;
pub const showError = modals.showError;
pub const askText = modals.askText;

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
pub const setLanguage = settings_actions.setLanguage;
pub const setIcons = settings_actions.setIcons;

// go_to_file.zig
pub const openQuickOpen = go_to_file.openQuickOpen;
pub const quickOpenKey = go_to_file.quickOpenKey;
pub const openQuickOpenSelection = go_to_file.openQuickOpenSelection;

// git_diff.zig
pub const updateDiff = git_diff.updateDiff;
pub const changes = git_diff.changes;
pub const hunkClick = git_diff.hunkClick;
pub const openDiffTab = git_diff.openDiffTab;
pub const openCommitDiff = git_diff.openCommitDiff;
pub const openRevDiff = git_diff.openRevDiff;

// git_blame.zig
pub const updateBlame = git_blame.updateBlame;
// problems.zig
pub const updateProblems = problems.updateProblems;
pub const problemAtCursor = problems.problemAtCursor;
pub const blameAt = git_blame.blameAt;
pub const inlineBlame = git_blame.inlineBlame;
pub const cursorPosition = git_blame.cursorPosition;

// git_conflicts.zig
pub const updateConflicts = git_conflicts.updateConflicts;
pub const conflicts = git_conflicts.conflicts;
pub const conflictMouse = git_conflicts.conflictMouse;

// git_pickers.zig
pub const openBranchPicker = git_pickers.openBranchPicker;
pub const openStashPicker = git_pickers.openStashPicker;
pub const pickerKey = git_pickers.pickerKey;
pub const pickerMouse = git_pickers.pickerMouse;

// git_job.zig
pub const startGitJob = git_jobs.startGitJob;
pub const startClone = git_jobs.startClone;
pub const cancelGitJob = git_jobs.cancelGitJob;
pub const pollGitJob = git_jobs.pollGitJob;
pub const gitBusy = git_jobs.gitBusy;

// panels.zig
pub const showView = panels.showView;
pub const updateSidebarViews = panels.updateSidebarViews;
pub const sideFieldKey = panels.sideFieldKey;
pub const panelClick = panels.panelClick;
pub const badgeTooltipClick = panels.badgeTooltipClick;
pub const gitAction = panels.gitAction;
pub const gitCommit = panels.gitCommit;
pub const finishGitPrompt = panels.finishGitPrompt;
pub const openClone = panels.openClone;
pub const reloadUnchangedTabs = panels.reloadUnchangedTabs;

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
pub const toggleTerminalPanel = terminal_io.toggleTerminalPanel;
pub const handleTerminalKeys = terminal_io.handleTerminalKeys;
pub const handleTerminalMouse = terminal_io.handleTerminalMouse;

// tab_actions.zig
pub const insertTab = tab_actions.insertTab;
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
pub const rememberProject = files.rememberProject;
pub const openProject = files.openProject;
pub const welcomeClick = files.welcomeClick;
pub const toggleFavoriteProject = files.toggleFavoriteProject;
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

// split.zig
pub const paneOf = split_panes.paneOf;
pub const paneStart = split_panes.paneStart;
pub const paneEnd = split_panes.paneEnd;
pub const paneTabs = split_panes.paneTabs;
pub const paneCount = split_panes.paneCount;
pub const paneAt = split_panes.paneAt;
pub const focusPane = split_panes.focusPane;
pub const splitTab = split_panes.splitTab;
pub const moveTab = split_panes.moveTab;
pub const collapseSplit = split_panes.collapse;
pub const openTabMenu = split_panes.openTabMenu;
pub const runTabMenuAction = split_panes.runTabMenuAction;
pub const startTabPress = split_panes.startTabPress;
pub const updateTabPress = split_panes.updateTabPress;
pub const dividerRect = split_panes.dividerRect;
pub const resizeSplit = split_panes.resizeSplit;
pub const otherTab = split_panes.otherTab;

// symbol_nav.zig
pub const symbolClick = symbol_nav.symbolClick;
pub const openRef = symbol_nav.openRef;
pub const showRefsInSearch = symbol_nav.showRefsInSearch;

// palette.zig
pub const openCommandPalette = palette.openCommandPalette;
pub const openGoToLine = palette.openGoToLine;
pub const openSymbols = palette.openSymbols;

// folding.zig
pub const foldAtCursor = folding.foldAtCursor;
pub const unfoldAtCursor = folding.unfoldAtCursor;
pub const foldAll = folding.foldAll;
pub const unfoldAll = folding.unfoldAll;
pub const foldClick = folding.foldClick;

// editing.zig
pub const moveByRows = editing.moveByRows;
pub const expandSelection = editing.expandSelection;
pub const shrinkSelection = editing.shrinkSelection;
pub const selectScope = editing.selectScope;
pub const scopeStepsValid = editing.scopeStepsValid;
pub const handleCompletionKey = editing.handleCompletionKey;
pub const acceptCompletion = editing.acceptCompletion;
pub const updateCompletion = editing.updateCompletion;
pub const toggleComment = editing.toggleComment;
pub const selectNextOccurrence = editing.selectNextOccurrence;
pub const jumpToBracket = editing.jumpToBracket;

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
    const projects_path = try paths.projectsFile(gpa);
    errdefer gpa.free(projects_path);
    settings_actions.applyToTheme(settings);
    var app: App = .{
        .gpa = gpa,
        .io = io,
        .view = View.init(gpa, Font.load()),
        .other_view = undefined,
        .ts_server = .init(gpa),
        .completion = .init(gpa),
        .find = .init(gpa),
        .sidebar = .init(gpa),
        .settings = settings,
        .settings_path = settings_path,
        .keys = Keymap.load(gpa, io, std.Io.Dir.cwd(), keys_path),
        .keys_path = keys_path,
        .projects = .load(gpa, io, std.Io.Dir.cwd(), projects_path),
        .projects_path = projects_path,
        .quick_open = .init(gpa),
        .file_search = .init(gpa),
        .search_panel = .init(gpa),
        .git_panel = .init(gpa),
        .git = .init(gpa),
        .picker = .init(gpa),
        .git_refs = .init(gpa),
    };
    // The second pane's view shares the font that was just loaded.
    app.other_view = View.init(gpa, app.view.font);
    app.sidebar.preferred_width = @floatFromInt(settings.sidebar_width);
    return app;
}

pub fn deinit(self: *App) void {
    git_jobs.finishGitJob(self);
    problems.finishJob(self);
    if (self.tool_path) |p| self.gpa.free(p);
    self.gpa.free(self.settings_path);
    self.gpa.free(self.keys_path);
    self.gpa.free(self.projects_path);
    self.projects.deinit();
    self.scope_steps.deinit(self.gpa);
    self.palette_actions.deinit(self.gpa);
    self.symbols.deinit(self.gpa);
    self.nav.deinit(self.gpa);
    self.picker.deinit();
    self.picker_rev.deinit(self.gpa);
    self.git_refs.deinit();
    self.refs.deinit(self.gpa);
    self.ref_name.deinit(self.gpa);
    self.view.deinit();
    self.other_view.deinit();
    self.quick_open.deinit();
    self.file_search.deinit();
    self.search_panel.deinit();
    self.git_panel.deinit();
    self.git.deinit();
    for (self.tabs.items) |*t| t.deinit(self.gpa);
    self.tabs.deinit(self.gpa);
    self.commands.deinit(self.gpa);
    self.tab_bar.deinit(self.gpa);
    self.other_bar.deinit(self.gpa);
    if (self.project) |*p| p.deinit();
    if (self.tree_press) |t| self.gpa.free(t.path);
    if (self.terminal) |*t| t.deinit();
    self.terminal_input.deinit(self.gpa);
    self.sidebar.deinit();
    self.find.deinit();
    self.completion.deinit();
    self.view.font.unload();
    file_icon.unload();
    folder_icon.unload();
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

/// Whether the active tab shows text (a file, or a file's changes).
/// Something changed what git would say: the status, the change marks
/// and the blame are all read again.
pub fn gitChanged(self: *App) void {
    self.git_dirty = true;
    self.diff_dirty = true;
    self.blame_dirty = true;
}

pub fn isEditing(self: *const App) bool {
    const kind = self.activeTab().kind;
    return kind == .file or kind == .diff;
}

/// The tab showing a file's changes is a view of two copies at once:
/// moving around and copying work, changing the text doesn't.
pub fn readOnly(self: *const App) bool {
    return self.activeTab().kind == .diff;
}

// ------------------------------------------------------------------ frame

pub fn update(self: *App) !void {
    const window = windowSize();
    stepAnimations(self);
    try self.refreshProjectOnFocus();
    self.matchFontToDisplay();
    matchMouseToLayout();
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
    if (self.pending_command) |cmd| {
        self.pending_command = null;
        try self.execute(cmd);
    }
    if (self.wanted_cursor != self.cursor_shape) {
        rl.setMouseCursor(self.wanted_cursor);
        self.cursor_shape = self.wanted_cursor;
    }
    // Always: the mouse can open or close tabs even on frames it reports as
    // no click (a sidebar file opens on release), and drawing needs a layout
    // that matches the tabs.
    try self.layout(window);
    // A cursor that got into a folded block opens it.
    if (try folding.unfoldCursors(self)) try self.layout(window);
    if (typed or clicked or typed_in_terminal) self.last_activity = rl.getTime();
    try self.nav.track(self);

    if (self.isEditing()) {
        if (typed or self.reveal_cursor) self.view.revealCursor(self.buf());
        self.reveal_cursor = false;
        self.view.clampScroll(self.buf());
        try self.tab().highlighter.update(self.gpa, self.buf());
        editing.updateBracketPair(self);
        try self.find.update(self.buf());
        self.popup.layout(&self.completion, &self.view, self.buf());
        self.find.layout(&self.view);
    }
    // The pane without the keyboard: its text stays coloured and its
    // scroll inside the file, even while it is only being looked at.
    if (self.split != null) {
        const t = self.otherTab();
        if (t.kind == .file or t.kind == .diff) {
            self.other_view.clampScroll(&t.buffer);
            try t.highlighter.update(self.gpa, &t.buffer);
        }
    }
    self.autosave();
    try self.updateSidebarViews();
    try self.updateDiff();
    try self.updateBlame();
    try self.updateProblems();
    try self.updateConflicts();

    try self.updateTitle();
}

/// Lays the frame out again for the current window size, for redrawing
/// while the window is being resized (when `update` can't run).
pub fn relayout(self: *App) !void {
    matchMouseToLayout();
    try self.layout(windowSize());
    if (self.isEditing()) {
        self.view.clampScroll(self.buf());
        self.popup.layout(&self.completion, &self.view, self.buf());
        self.find.layout(&self.view);
    }
}

/// What the bar at the bottom says about git: the branch and how far it
/// is from its remote. Null outside a repository.
pub fn branchStatus(self: *const App) ?StatusBar.Branch {
    if (self.project == null or self.git.state != .ok or self.git.branch.len == 0) return null;
    return .{
        .name = self.git.branch,
        .ahead = self.git.ahead,
        .behind = self.git.behind,
        .has_upstream = self.git.has_upstream,
        .busy = self.gitBusy(),
    };
}

/// One frame of every animation, before anything is laid out from what
/// they move: scrolls following their targets, panels sliding in and out,
/// and the fades small things keep in ui/anim.zig. With the setting off
/// each of these lands on its target at once.
fn stepAnimations(self: *App) void {
    anim.newFrame();
    self.sidebar.step(self.sidebar.visible and self.project != null);
    self.search_panel.step();
    self.git_panel.step();
    self.help_page.step();
    self.settings_page.step();
    self.welcome.step();
    self.terminal_panel.step();
    self.view.step();
    self.other_view.step();
}

/// The window's size in UI units (zoom makes each unit more pixels).
pub fn windowSize() rl.Vector2 {
    return .{
        .x = @as(f32, @floatFromInt(rl.getScreenWidth())) / theme.zoom,
        .y = @as(f32, @floatFromInt(rl.getScreenHeight())) / theme.zoom,
    };
}

/// Sidebar on the left; the editor column beside it, in one pane or two,
/// each with its tab bar on top; the terminal panel along their bottom.
pub fn layout(self: *App, full_window: rl.Vector2) !void {
    // The bar at the bottom takes its height off everything else.
    self.status.layout(full_window, self.view.font, self.branchStatus());
    const window: rl.Vector2 = .{ .x = full_window.x, .y = @max(0, full_window.y - StatusBar.height) };
    self.sidebar.layout(if (self.project) |*p| p else null, window, self.view.font);
    self.sidebar.updateGitBadgeTooltip(self.view.font, &self.git);
    switch (self.sidebar.view) {
        .explorer => {},
        .search => self.search_panel.layout(self.sidebar.contentRect(), self.view.font),
        .git => self.git_panel.layout(self.sidebar.contentRect(), self.view.font, &self.git),
    }
    self.menu.update();
    const left = self.sidebar.width();
    const full: rl.Rectangle = .{ .x = left, .y = 0, .width = window.x - left, .height = window.y };
    // The terminal panel takes the bottom of the column, under both panes.
    const column: rl.Rectangle = .{ .x = left, .y = TabBar.height, .width = full.width, .height = window.y - TabBar.height };
    self.terminal_panel.layout(column, self.view.font);
    if (self.terminal) |*t| try t.resize(self.terminal_panel.cols, self.terminal_panel.rows);
    var panes = full;
    panes.height -= self.terminal_panel.takenHeight(column);
    self.pane_rects = split_panes.paneRects(self, panes);

    const editor = try layoutPane(self, self.pane, &self.view, &self.tab_bar, &self.minimap, self.active);
    if (self.split != null) {
        const p: u1 = if (self.pane == 0) 1 else 0;
        _ = try layoutPane(self, p, &self.other_view, &self.other_bar, &self.other_minimap, self.other_active);
    }
    // The lists that drop down over the editor belong to the pane with
    // the keyboard.
    self.quick_open.layout(editor, self.view.font);
    self.picker.layout(editor, self.view.font);
}

/// One pane: its tab bar along the top, then the text (with the minimap
/// at its right edge) or the page its tab shows. Returns the area below
/// the tab bar.
fn layoutPane(self: *App, pane: u1, view: *View, bar: *TabBar, map: *Minimap, active: usize) !rl.Rectangle {
    const area = self.pane_rects[pane];
    const bar_rect: rl.Rectangle = .{ .x = area.x, .y = area.y, .width = area.width, .height = TabBar.height };
    try bar.layout(self.gpa, self.paneTabs(pane), active - self.paneStart(pane), bar_rect, view.font);
    const editor: rl.Rectangle = .{
        .x = area.x,
        .y = area.y + TabBar.height,
        .width = area.width,
        .height = @max(0, area.height - TabBar.height),
    };
    const t = &self.tabs.items[active];
    var text_area = editor;
    if (self.settings.minimap and (t.kind == .file or t.kind == .diff)) {
        map.layout(editor);
        text_area.width -= Minimap.width;
    }
    view.wrap = self.settings.word_wrap;
    if (t.kind == .file) try folding.updateHidden(self.gpa, t) else t.hidden.clearRetainingCapacity();
    try view.layout(&t.buffer, text_area, t.hidden.items);
    switch (t.kind) {
        .welcome => self.welcome.layout(editor, view.font, self.projects.entries.items),
        .settings => self.settings_page.layout(editor, view.font),
        .help => self.help_page.layout(editor, view.font),
        .file, .diff => {},
    }
    return editor;
}

// ------------------------------------------------------------ display

/// Moving the window to a display with another pixel density (Retina vs
/// a regular monitor) re-renders the font for it, so text stays sharp.
pub fn matchFontToDisplay(self: *App) void {
    const scale = @max(1, rl.getWindowScaleDPI().x) * theme.zoom;
    if (@abs(scale * self.view.font.pixel - 1) < 0.01) return;
    self.view.font.unload();
    self.view.font = Font.load();
    self.other_view.font = self.view.font;
}

/// Mouse positions in UI units. The pointer comes in the window system's
/// coordinates: logical points on macOS and Wayland (so dividing by the
/// DPI there halves them on Retina), physical pixels on Windows and X11.
/// raylib recomputes its own mouse scale on every resize (e.g. a Linux
/// window manager toggling fullscreen), so this redoes it every frame.
pub fn matchMouseToLayout() void {
    var w: c_int = 0;
    var h: c_int = 0;
    if (glfwGetCurrentContext()) |window| glfwGetWindowSize(window, &w, &h);
    // Logical screen size per pointer unit (1 when both are points).
    const sx = if (w > 0) @as(f32, @floatFromInt(rl.getScreenWidth())) / @as(f32, @floatFromInt(w)) else 1;
    const sy = if (h > 0) @as(f32, @floatFromInt(rl.getScreenHeight())) / @as(f32, @floatFromInt(h)) else 1;
    rl.setMouseScale(sx / theme.zoom, sy / theme.zoom);
}

// raylib's GLFW, which it builds in.
extern "c" fn glfwGetCurrentContext() ?*anyopaque;
extern "c" fn glfwGetWindowSize(window: *anyopaque, width: *c_int, height: *c_int) void;

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
