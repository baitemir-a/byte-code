//! Settings: applying them, the Settings tab, auto save.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../../ui/theme/lib/theme.zig");
const Font = @import("../../ui/Font.zig");
const SettingsPage = @import("../../ui/pages/SettingsPage.zig");
const App = @import("../App.zig");

/// Accent and zoom live in the theme, where drawing code reads them.
/// Mouse scale is App.matchFontToDisplay's job: it also depends on the
/// display's DPI, which isn't known here, and needs redoing every frame
/// anyway since raylib recomputes its own on window resize.
pub fn applyToTheme(s: core.Settings) void {
    theme.setMode(s.theme);
    theme.accent = .{ .r = s.accent[0], .g = s.accent[1], .b = s.accent[2], .a = 255 };
    theme.zoom = @as(f32, @floatFromInt(s.zoom)) / 100;
}

/// After changing `self.settings`: applies them and saves settings.json.
pub fn settingsChanged(self: *App, old: core.Settings) !void {
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

pub fn openSettings(self: *App) !void {
    for (self.tabs.items, 0..) |t, i| {
        if (t.kind == .settings) return self.activate(i);
    }
    try self.tabs.insert(self.gpa, self.active + 1, .initSettings(self.gpa));
    try self.activate(self.active + 1);
}

pub fn runSettingsAction(self: *App, action: SettingsPage.Action) !void {
    // Not a setting: it opens a tab.
    if (action == .open_help) return self.openHelp();
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
        .toggle_word_wrap => self.settings.word_wrap = !self.settings.word_wrap,
        .toggle_new_window => self.settings.open_folder_in_new_window = !self.settings.open_folder_in_new_window,
        .open_help => unreachable,
    }
    try self.settingsChanged(old);
}

/// Saves files with unsaved changes once typing has paused for the
/// configured delay. Untitled files are left alone (they need a name). A
/// failed save is reported once per file, then retried after new edits.
pub fn autosave(self: *App) void {
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
