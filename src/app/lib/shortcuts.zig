//! The Help tab: opening it, recording a new key combination for a
//! shortcut and keeping keybindings.json up to date.
const std = @import("std");
const Keymap = @import("../../input/Keymap.zig");
const keymap = @import("../../input/lib/keymap.zig");
const HelpPage = @import("../../ui/pages/HelpPage.zig");
const App = @import("../App.zig");

pub fn openHelp(self: *App) !void {
    for (self.tabs.items, 0..) |t, i| {
        if (t.kind == .help) return self.activate(i);
    }
    try self.tabs.insert(self.gpa, self.active + 1, .initHelp(self.gpa));
    try self.activate(self.active + 1);
}

pub fn runHelpAction(self: *App, action: HelpPage.Action) !void {
    switch (action) {
        .capture => |a| self.help_page.startCapture(a),
        .reset => |a| {
            self.keys.reset(a);
            self.help_page.message = .none;
            saveKeys(self);
        },
        .reset_all => {
            self.keys.resetAll();
            self.help_page.stopCapture();
            self.help_page.message = .none;
            saveKeys(self);
        },
        .cancel => self.help_page.stopCapture(),
    }
}

/// While the Help tab waits for a combination, keys bind a shortcut
/// instead of running one.
pub fn captureShortcut(self: *App) void {
    const action = self.help_page.capturing orelse return;
    switch (HelpPage.readChord()) {
        .none => {},
        .cancel => self.help_page.stopCapture(),
        .clear => self.bindShortcut(action, null),
        // A bare letter or digit would type instead of running the command.
        .chord => |c| if (c.typesText()) {
            self.help_page.message = .needs_modifier;
        } else self.bindShortcut(action, c),
    }
    keymap.discardTyped();
}

/// Gives `action` a combination (or none), taking it from whatever had it.
pub fn bindShortcut(self: *App, action: Keymap.Action, chord: ?Keymap.Chord) void {
    self.help_page.message = if (chord) |c|
        if (self.keys.conflict(c, action)) |other| .{ .took_from = other } else .none
    else
        .none;
    self.keys.set(action, chord);
    self.help_page.stopCapture();
    saveKeys(self);
}

fn saveKeys(self: *App) void {
    self.keys.save(self.gpa, self.io, std.Io.Dir.cwd(), self.keys_path) catch |err| {
        self.reportError("Couldn't save keyboard shortcuts", self.keys_path, err);
    };
}
