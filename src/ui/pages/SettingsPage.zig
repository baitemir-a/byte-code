//! The Settings tab: theme, accent color, auto save, zoom, minimap and
//! word wrap.
//! Changes apply immediately and are saved to settings.json.
const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");
const SettingsPage_draw = @import("SettingsPage_draw.zig");

const Settings = core.Settings;
const SettingsPage = @This();

pub const cmd = if (builtin.os.tag == .macos) "Cmd" else "Ctrl";
pub const opt = if (builtin.os.tag == .macos) "Option" else "Alt";

pub const Action = union(enum) {
    theme: Settings.Theme,
    accent: [3]u8,
    toggle_autosave,
    /// Half-second steps, negative to shorten.
    delay: i32,
    zoom_in,
    zoom_out,
    zoom_reset,
    toggle_minimap,
    toggle_word_wrap,
    toggle_new_window,
};

pub const accent_presets = [_]struct { name: []const u8, rgb: [3]u8 }{
    .{ .name = "Blue", .rgb = Settings.default_accent },
    .{ .name = "Purple", .rgb = .{ 167, 112, 255 } },
    .{ .name = "Pink", .rgb = .{ 255, 95, 160 } },
    .{ .name = "Red", .rgb = .{ 241, 76, 76 } },
    .{ .name = "Orange", .rgb = .{ 255, 140, 40 } },
    .{ .name = "Yellow", .rgb = .{ 229, 192, 60 } },
    .{ .name = "Green", .rgb = .{ 35, 209, 139 } },
    .{ .name = "Teal", .rgb = .{ 0, 200, 190 } },
};

const row_gap: f32 = 56;
pub const swatch: f32 = 26;
const button: f32 = 28;
const content_cols = 60;

// Clickable areas, set by `layout`.
origin: rl.Vector2 = .{ .x = 0, .y = 0 },
theme_dark: rl.Rectangle = undefined,
theme_light: rl.Rectangle = undefined,
swatches: [accent_presets.len]rl.Rectangle = undefined,
autosave_toggle: rl.Rectangle = undefined,
delay_minus: rl.Rectangle = undefined,
delay_plus: rl.Rectangle = undefined,
zoom_minus: rl.Rectangle = undefined,
zoom_plus: rl.Rectangle = undefined,
zoom_reset: rl.Rectangle = undefined,
minimap_toggle: rl.Rectangle = undefined,
wrap_toggle: rl.Rectangle = undefined,
new_window_toggle: rl.Rectangle = undefined,

// Drawing, in SettingsPage_draw.zig.
pub const draw = SettingsPage_draw.draw;

pub fn layout(self: *SettingsPage, area: rl.Rectangle, font: Font) void {
    const w = content_cols * font.cell_width;
    self.origin = .{
        .x = area.x + @max(theme.padding * 2, (area.width - w) / 2),
        .y = area.y + @max(theme.padding * 2, area.height * 0.08),
    };
    const right = self.origin.x + w;
    self.theme_light = .{ .x = right - 80, .y = self.rowY(0), .width = 80, .height = button };
    self.theme_dark = .{ .x = right - 160, .y = self.rowY(0), .width = 80, .height = button };
    const y0 = self.rowY(1);
    for (&self.swatches, 0..) |*s, i| {
        const x = right - @as(f32, @floatFromInt(accent_presets.len - i)) * (swatch + 8);
        s.* = .{ .x = x, .y = y0, .width = swatch, .height = swatch };
    }
    self.autosave_toggle = .{ .x = right - 46, .y = self.rowY(2) + 3, .width = 46, .height = 22 };
    self.delay_plus = .{ .x = right - button, .y = self.rowY(3), .width = button, .height = button };
    self.delay_minus = .{ .x = right - button * 2 - 90, .y = self.rowY(3), .width = button, .height = button };
    self.zoom_reset = .{ .x = right - 64, .y = self.rowY(4), .width = 64, .height = button };
    self.zoom_plus = .{ .x = right - 64 - 12 - button, .y = self.rowY(4), .width = button, .height = button };
    self.zoom_minus = .{ .x = self.zoom_plus.x - 90 - button, .y = self.rowY(4), .width = button, .height = button };
    self.minimap_toggle = .{ .x = right - 46, .y = self.rowY(5) + 3, .width = 46, .height = 22 };
    self.wrap_toggle = .{ .x = right - 46, .y = self.rowY(6) + 3, .width = 46, .height = 22 };
    self.new_window_toggle = .{ .x = right - 46, .y = self.rowY(7) + 3, .width = 46, .height = 22 };
}

pub fn rowY(self: *const SettingsPage, row: usize) f32 {
    return self.origin.y + theme.font_size * 2.4 + 40 + @as(f32, @floatFromInt(row)) * row_gap;
}

pub fn actionAt(self: *const SettingsPage, p: rl.Vector2, settings: *const Settings) ?Action {
    if (hit(p, self.theme_dark)) return .{ .theme = .dark };
    if (hit(p, self.theme_light)) return .{ .theme = .light };
    for (self.swatches, accent_presets) |s, preset| {
        if (rl.checkCollisionPointRec(p, s)) return .{ .accent = preset.rgb };
    }
    if (hit(p, self.autosave_toggle)) return .toggle_autosave;
    if (settings.autosave) {
        if (hit(p, self.delay_minus)) return .{ .delay = -1 };
        if (hit(p, self.delay_plus)) return .{ .delay = 1 };
    }
    if (hit(p, self.zoom_minus)) return .zoom_out;
    if (hit(p, self.zoom_plus)) return .zoom_in;
    if (hit(p, self.zoom_reset)) return .zoom_reset;
    if (hit(p, self.minimap_toggle)) return .toggle_minimap;
    if (hit(p, self.wrap_toggle)) return .toggle_word_wrap;
    if (hit(p, self.new_window_toggle)) return .toggle_new_window;
    return null;
}

pub fn hit(p: rl.Vector2, r: rl.Rectangle) bool {
    return rl.checkCollisionPointRec(p, r);
}
