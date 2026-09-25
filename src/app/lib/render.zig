//! Drawing a frame: the editor or page, sidebar, panels and popups.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../../ui/theme/lib/theme.zig");
const Pty = @import("../../platform/Pty.zig");
const App = @import("../App.zig");
const Tab = @import("../Tab.zig");
const Sidebar = @import("../../ui/sidebar/Sidebar.zig");
const View = @import("../../ui/editor/View.zig");
const Minimap = @import("../../ui/editor/Minimap.zig");
const View_conflicts = @import("../../ui/editor/View_conflicts.zig");
const View_blame = @import("../../ui/editor/View_blame.zig");
const git_diff = @import("git_diff.zig");
const split_panes = @import("split.zig");
const i18n = @import("../../i18n/i18n.zig");

pub fn draw(self: *const App) void {
    // Under a dialog, nothing lights up where the pointer is.
    if (self.modal != null) rl.setMouseOffset(-1_000_000, -1_000_000);
    drawFrame(self);
    rl.setMouseOffset(0, 0);
    self.drawModal();
}

fn drawFrame(self: *const App) void {
    rl.clearBackground(theme.background);
    const t = self.activeTab();
    const caret = self.caretVisible();
    // The pane without the keyboard first, then the one with it over the
    // line between them.
    if (self.split != null) drawPane(self, false, caret);
    drawPane(self, true, caret);
    split_panes.drawDivider(self);
    if (self.terminal) |*term| {
        const title = if (term.screen.title.items.len > 0) term.screen.title.items else std.fs.path.basename(Pty.defaultShell());
        self.terminal_panel.draw(&term.screen, self.view.font, self.terminalFocused(), caret, title);
    }
    self.tab_bar.draw(self.paneTabs(self.pane), self.active - self.paneStart(self.pane), self.view.font, true);
    if (self.split != null) {
        const p: u1 = if (self.pane == 0) 1 else 0;
        self.other_bar.draw(self.paneTabs(p), self.other_active - self.paneStart(p), self.other_view.font, false);
    }
    self.sidebar.draw(if (self.project) |*p| p else null, t.document.path, self.view.font, caret, &self.git, self.terminal_panel.visible);
    if (self.sidebar.width() > 0) switch (self.sidebar.view) {
        .explorer => {},
        .search => self.search_panel.draw(self.view.font, switch (self.side_focus) {
            .search => 1,
            .search_replace => 2,
            else => 0,
        }, caret, self.project != null),
        .git => self.git_panel.draw(&self.git, self.view.font, self.side_focus == .git_message, self.side_focus == .git_prompt, caret, self.project != null, nowSeconds(self.io)),
    };
    if (t.kind == .file or t.kind == .diff) {
        if (t.kind == .file) self.popup.draw(&self.completion, &self.view);
        self.find.draw(&self.view, &t.buffer, caret);
    }
    // The bar along the bottom, and the date its blame hangs off.
    var age_buf: [64]u8 = undefined;
    var exact_buf: [32]u8 = undefined;
    var position_buf: [64]u8 = undefined;
    self.status.draw(self.view.font, self.blameAt(&age_buf, &exact_buf), self.cursorPosition(&position_buf));

    if (self.sidebar.width() > 0) {
        switch (self.sidebar.view) {
            .search => self.search_panel.drawTooltip(self.view.font),
            .git => self.git_panel.drawBadgeTooltip(&self.git, self.view.font),
            .explorer => {},
        }
        self.sidebar.drawGitBadgeTooltip(self.view.font, &self.git);
    }
    self.quick_open.draw(&self.file_search, self.view.font, caret, self.project != null);
    self.picker.draw(self.view.font, caret, i18n.tr().quick_open.no_matches);
    self.menu.draw(self.view.font);
    self.sidebar.drawDragLabel(self.view.font);
    drawTabDrag(self);
}

/// One pane: the page its tab shows, or its text with the change marks
/// and the minimap. Only the pane with the keyboard gets the caret, the
/// blame, a merge's conflict buttons and the search highlighting.
fn drawPane(self: *const App, focused: bool, caret: bool) void {
    const pane: u1 = if (focused) self.pane else (if (self.pane == 0) 1 else 0);
    const t: *const Tab = if (focused) self.activeTab() else self.otherTab();
    const view: *const View = if (focused) &self.view else &self.other_view;
    const map: *const Minimap = if (focused) &self.minimap else &self.other_minimap;
    const area = self.pane_rects[pane];
    const split = self.split != null;
    if (split) rl.drawRectangleRec(area, theme.background);
    if (split) theme.clip(area);
    switch (t.kind) {
        .welcome => self.welcome.draw(view.font, self.projects.entries.items),
        .settings => self.settings_page.draw(view.font, &self.settings, self.settings_path),
        .help => self.help_page.draw(view.font, &self.keys, self.keys_path),
        .file, .diff => {
            const editor_caret = focused and caret and t.kind == .file and !self.find.hasFocus() and self.sidebar.input == null and !self.terminalFocused() and !self.quick_open.is_open and !self.picker.is_open and self.side_focus == .none;
            const diff = git_diff.changesOf(t);
            // A merge's conflicts: bands under the text, buttons over it.
            const conflicts = if (focused) self.conflicts() else &.{};
            View_conflicts.drawBands(view.*, conflicts);
            view.draw(&t.buffer, &t.highlighter, if (focused) self.find.highlights(&t.buffer) else null, editor_caret, diff);
            View_conflicts.drawButtons(view.*, &t.buffer, conflicts);
            var blame_buf: [256]u8 = undefined;
            if (focused) if (self.inlineBlame(&blame_buf)) |text| View_blame.draw(view.*, &t.buffer, text);
            // The minimap clips to itself, so it comes after the pane's.
            if (split) rl.endScissorMode();
            if (self.settings.minimap) map.draw(view, &t.buffer, &t.highlighter, diff);
            return;
        },
    }
    if (split) rl.endScissorMode();
}

/// A tab being dragged to the other pane: its name by the pointer, and
/// the room the drop would give it.
fn drawTabDrag(self: *const App) void {
    const press = self.tab_press orelse return;
    if (!press.dragging or press.index >= self.tabs.items.len) return;
    const name = self.tabs.items[press.index].name();
    if (split_panes.dropAt(self, press.index, rl.getMousePosition())) |drop| {
        const r = split_panes.dropRect(self, drop);
        rl.drawRectangleRec(r, theme.accentDim(0.2));
        rl.drawRectangleLinesEx(r, 2, theme.accent);
    }
    const m = rl.getMousePosition();
    const font = self.view.font;
    const cols: f32 = @floatFromInt(@min(name.len, 40));
    const box: rl.Rectangle = .{ .x = m.x + 14, .y = m.y + 10, .width = cols * font.cell_width + 16, .height = theme.line_height + 4 };
    rl.drawRectangleRec(.{ .x = box.x + 2, .y = box.y + 3, .width = box.width, .height = box.height }, theme.popup_shadow);
    rl.drawRectangleRec(box, theme.popup_background);
    rl.drawRectangleLinesEx(box, 1, theme.popup_border);
    _ = font.drawFit(name, box.x + 8, box.y + (box.height - theme.font_size) / 2, box.x + box.width - 8 + 0.5, theme.foreground);
}

/// The wall clock, in seconds since the epoch.
fn nowSeconds(io: std.Io) i64 {
    const ts = std.Io.Timestamp.now(io, .real);
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
}
