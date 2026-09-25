//! The integrated terminal: showing it, and its keyboard and mouse input.
const std = @import("std");
const rl = @import("raylib");
const keymap = @import("../../input/lib/keymap.zig");
const Mouse = @import("../../input/Mouse.zig");
const Terminal = @import("../Terminal.zig");
const terminal_keys = @import("../../input/lib/terminal_keys.zig");
const Pty = @import("../../platform/Pty.zig");
const App = @import("../App.zig");
const clipboard = @import("clipboard.zig");

pub fn terminalFocused(self: *const App) bool {
    return self.terminal_focused and self.terminal_panel.visible and self.terminal != null;
}

/// Ctrl+`: opens the terminal (starting a shell the first time), focuses
/// it if it's open but not focused, or hides it.
pub fn toggleTerminal(self: *App) !void {
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

/// The sidebar's terminal button: opens the panel, or closes it if it is
/// already open. The click that pressed the button lands outside the panel
/// and takes its focus first, so `toggleTerminal`'s focus test can't tell
/// "open it" from "close it" here.
pub fn toggleTerminalPanel(self: *App) !void {
    if (self.terminal_panel.visible) {
        self.terminal_panel.visible = false;
        self.terminal_focused = false;
        return;
    }
    try self.toggleTerminal();
}

/// This frame's keys, while the terminal has focus. Returns true if
/// anything was typed.
pub fn handleTerminalKeys(self: *App) !bool {
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
            try clipboard.setClipboard(self.gpa, text);
        },
        .paste => if (clipboard.getClipboard()) |s| {
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
            try keymap.poll(self.gpa, &self.keys, &self.commands);
            var kept: usize = 0;
            for (self.commands.items) |cmd| switch (cmd) {
                .open, .open_folder, .new_file, .close_tab, .next_tab, .prev_tab, .toggle_sidebar, .toggle_terminal, .save, .save_as, .open_settings, .open_help, .zoom_in, .zoom_out, .zoom_reset, .quick_open, .show_explorer, .show_search, .show_git => {
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
pub fn handleTerminalMouse(self: *App, point: rl.Vector2, pressed: bool) bool {
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
        panel.dragScroll(&term.screen, point);
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
