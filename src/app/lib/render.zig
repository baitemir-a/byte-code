//! Drawing a frame: the editor or page, sidebar, panels and popups.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../../ui/theme/lib/theme.zig");
const Pty = @import("../../platform/Pty.zig");
const App = @import("../App.zig");
const Sidebar = @import("../../ui/sidebar/Sidebar.zig");

pub fn draw(self: *const App) void {
    rl.clearBackground(theme.background);
    const t = self.activeTab();
    const caret = self.caretVisible();
    switch (t.kind) {
        .welcome => self.welcome.draw(self.view.font, self.projects.entries.items),
        .settings => self.settings_page.draw(self.view.font, &self.settings, self.settings_path),
        .help => self.help_page.draw(self.view.font, &self.keys, self.keys_path),
        .file, .diff => {
            const editor_caret = caret and t.kind == .file and !self.find.hasFocus() and self.sidebar.input == null and !self.terminalFocused() and !self.quick_open.is_open and self.side_focus == .none;
            const diff = self.changes();
            self.view.draw(&t.buffer, &t.highlighter, self.find.highlights(&t.buffer), editor_caret, diff);
            if (self.settings.minimap) self.minimap.draw(&self.view, &t.buffer, &t.highlighter, diff);
        },
    }
    if (self.terminal) |*term| {
        const title = if (term.screen.title.items.len > 0) term.screen.title.items else std.fs.path.basename(Pty.defaultShell());
        self.terminal_panel.draw(&term.screen, self.view.font, self.terminalFocused(), caret, title);
    }
    self.tab_bar.draw(self.tabs.items, self.active, self.view.font);
    self.sidebar.draw(if (self.project) |*p| p else null, t.document.path, self.view.font, caret, &self.git);
    if (self.sidebar.width() > 0) switch (self.sidebar.view) {
        .explorer => {},
        .search => self.search_panel.draw(self.view.font, switch (self.side_focus) {
            .search => 1,
            .search_replace => 2,
            else => 0,
        }, caret, self.project != null),
        .git => self.git_panel.draw(&self.git, self.view.font, self.side_focus == .git_message, self.side_focus == .git_prompt, caret, self.project != null),
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
        Sidebar.drawGitBadgeTooltip(self.view.font, &self.git);
    }
    self.quick_open.draw(&self.file_search, self.view.font, caret, self.project != null);
    self.menu.draw(self.view.font);
    self.sidebar.drawDragLabel(self.view.font);
}
