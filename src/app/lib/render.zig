//! Drawing a frame: the editor or page, sidebar, panels and popups.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../../ui/theme/lib/theme.zig");
const Pty = @import("../../platform/Pty.zig");
const App = @import("../App.zig");

pub fn draw(self: *const App) void {
    rl.clearBackground(theme.background);
    const t = self.activeTab();
    const caret = self.caretVisible();
    switch (t.kind) {
        .welcome => self.welcome.draw(self.view.font),
        .settings => self.settings_page.draw(self.view.font, &self.settings, self.settings_path),
        .help => self.help_page.draw(self.view.font, &self.keys, self.keys_path),
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
        .search => self.search_panel.draw(self.view.font, switch (self.side_focus) {
            .search => 1,
            .search_replace => 2,
            else => 0,
        }, caret, self.project != null),
        .git => self.git_panel.draw(&self.git, self.view.font, self.side_focus == .git_message, caret, self.project != null),
    };
    if (t.kind == .file) {
        self.popup.draw(&self.completion, &self.view);
        self.find.draw(&self.view, &t.buffer, caret);
    }
    if (self.sidebar.width() > 0 and self.sidebar.view == .search) self.search_panel.drawTooltip(self.view.font);
    self.quick_open.draw(&self.file_search, self.view.font, caret, self.project != null);
    self.menu.draw(self.view.font);
    self.sidebar.drawDragLabel(self.view.font);
}
