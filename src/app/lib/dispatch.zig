//! Running a command: global shortcuts first, then whatever has the keyboard
//! (Go to File, a sidebar box, the find bar, the editor).
const core = @import("core");
const keymap = @import("../../input/lib/keymap.zig");
const clipboard = @import("clipboard.zig");
const App = @import("../App.zig");
const i18n = @import("../../i18n/i18n.zig");

pub fn execute(self: *App, cmd: core.Command) !void {
    // Commands that work anywhere, including the welcome tab.
    switch (cmd) {
        .open => return self.openWithDialog() catch |err| self.reportError(i18n.tr().errors.open_file, "", err),
        .open_folder => return self.openFolderWithDialog() catch |err| self.reportError(i18n.tr().errors.open_folder, "", err),
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
        .open_help => return self.openHelp(),
        .toggle_word_wrap => {
            try self.runSettingsAction(.toggle_word_wrap);
            self.reveal_cursor = true;
            return;
        },
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
            .copy, .cut => try clipboard.copyOrCut(self.gpa, &field.buffer, cmd == .cut),
            .paste => if (clipboard.getClipboard()) |s| try field.paste(s),
            else => _ = try field.handle(cmd),
        }
        return;
    }
    if (!self.isEditing()) return;
    // A file's changes are shown, not edited.
    if (self.readOnly() and core.command.changesText(cmd)) return;

    const b = self.buf();
    // Find shortcuts work wherever the focus is.
    switch (cmd) {
        .find, .find_replace => {
            self.completion.close();
            return self.find.show(b, cmd == .find_replace);
        },
        .find_next => return if (self.find.query.text().len > 0) self.find.next(b) else self.find.show(b, false),
        .toggle_match_case => return self.find.toggle(.match_case, b),
        .toggle_whole_word => return self.find.toggle(.whole_word, b),
        .find_prev => return if (self.find.query.text().len > 0) self.find.prev(b) else self.find.show(b, false),
        else => {},
    }

    if (self.find.focusedField()) |field| {
        switch (cmd) {
            .copy, .cut => try clipboard.copyOrCut(self.gpa, &field.buffer, cmd == .cut),
            .paste => if (clipboard.getClipboard()) |s| try self.find.paste(s, b),
            else => if (try self.find.handle(cmd, b, keymap.Mods.current())) return,
        }
        if (cmd == .copy or cmd == .cut or cmd == .paste) return;
    }

    if (self.completion.is_open and try self.handleCompletionKey(cmd)) return;
    // Esc in the editor with nothing selected closes the find bar.
    if (cmd == .clear_selection and self.find.is_open and b.selection() == null) self.find.close();

    switch (cmd) {
        .copy, .cut => try clipboard.copyOrCut(self.gpa, b, cmd == .cut),
        .paste => if (clipboard.getClipboard()) |s| try clipboard.pasteAtCursors(self.gpa, b, s),
        .save, .save_as => _ = self.save(cmd == .save_as) catch |err| self.reportError(i18n.tr().errors.save_file, "", err),
        .complete => {},
        .expand_selection => try self.expandSelection(b),
        .shrink_selection => self.shrinkSelection(b),
        .move => |m| if (!self.moveByRows(b, m)) try core.command.runAtCursors(b, cmd, self.view.pageLines()),
        else => try core.command.runAtCursors(b, cmd, self.view.pageLines()),
    }
    try self.updateCompletion(cmd);
}
