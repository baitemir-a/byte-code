//! The Settings tab: language, theme, accent color, auto save, zoom,
//! minimap, word wrap, whether the Git view asks before throwing changes
//! away, and what saving does to the text.
//! Changes apply immediately and are saved to settings.json.
const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../theme/lib/theme.zig");
const anim = @import("../anim.zig");
const Font = @import("../Font.zig");
const SettingsPage_draw = @import("SettingsPage_draw.zig");
const i18n = @import("../../i18n/i18n.zig");

const Settings = core.Settings;
const SettingsPage = @This();

pub const cmd = if (builtin.os.tag == .macos) "Cmd" else "Ctrl";
pub const opt = if (builtin.os.tag == .macos) "Option" else "Alt";
/// Format Document's default shortcut, for the hint.
pub const format_shortcut = "Shift+" ++ opt ++ "+F";

pub const Action = union(enum) {
    /// Opens the menu of languages under the language button.
    choose_language: rl.Rectangle,
    theme: Settings.Theme,
    accent: [3]u8,
    toggle_autosave,
    /// Half-second steps, negative to shorten.
    delay: i32,
    zoom_in,
    zoom_out,
    zoom_reset,
    toggle_minimap,
    /// Open the menus of icon modes under their buttons.
    choose_file_icons: rl.Rectangle,
    choose_folder_icons: rl.Rectangle,
    toggle_word_wrap,
    toggle_new_window,
    toggle_confirm_discard,
    toggle_pull_rebase,
    toggle_inline_blame,
    toggle_smooth,
    toggle_format_on_save,
    toggle_trim_whitespace,
    toggle_final_newline,
    /// Opens the Help tab, where the shortcuts are.
    open_help,
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
area: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
origin: rl.Vector2 = .{ .x = 0, .y = 0 },
/// Right edge of the rows, where their controls end.
right: f32 = 0,
/// How far the page is scrolled down, when it's taller than the window.
/// `scroll` is where it is drawn, `scroll_to` where it is headed.
scroll: f32 = 0,
scroll_to: f32 = 0,
max_scroll: f32 = 0,
language_button: rl.Rectangle = undefined,
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
file_icons_button: rl.Rectangle = undefined,
folder_icons_button: rl.Rectangle = undefined,
wrap_toggle: rl.Rectangle = undefined,
new_window_toggle: rl.Rectangle = undefined,
confirm_discard_toggle: rl.Rectangle = undefined,
pull_rebase_toggle: rl.Rectangle = undefined,
inline_blame_toggle: rl.Rectangle = undefined,
smooth_toggle: rl.Rectangle = undefined,
format_toggle: rl.Rectangle = undefined,
trim_toggle: rl.Rectangle = undefined,
newline_toggle: rl.Rectangle = undefined,
shortcuts_button: rl.Rectangle = undefined,

// Drawing, in SettingsPage_draw.zig.
pub const draw = SettingsPage_draw.draw;

pub fn layout(self: *SettingsPage, area: rl.Rectangle, font: Font) void {
    self.area = area;
    const w = content_cols * font.cell_width;
    const top = @max(theme.padding * 2, area.height * 0.08);
    self.max_scroll = @max(0, top + contentHeight() - area.height);
    self.scroll_to = std.math.clamp(self.scroll_to, 0, self.max_scroll);
    self.scroll = std.math.clamp(self.scroll, 0, self.max_scroll);
    self.origin = .{
        .x = area.x + @max(theme.padding * 2, (area.width - w) / 2),
        .y = area.y + top - self.scroll,
    };
    const right = self.origin.x + w;
    self.right = right;
    const t = i18n.tr().settings;
    // Wide enough for any language's name, so it doesn't jump around.
    var names_w: f32 = 0;
    for (std.enums.values(Settings.Language)) |l| names_w = @max(names_w, font.textWidth(l.nativeName()));
    const language_w = names_w + 40;
    self.language_button = .{ .x = right - language_w, .y = self.rowY(0), .width = language_w, .height = button };
    const segment_w = @max(80, @max(font.textWidth(t.dark), font.textWidth(t.light)) + 20);
    self.theme_light = .{ .x = right - segment_w, .y = self.rowY(1), .width = segment_w, .height = button };
    self.theme_dark = .{ .x = right - 2 * segment_w, .y = self.rowY(1), .width = segment_w, .height = button };
    const y0 = self.rowY(2);
    for (&self.swatches, 0..) |*s, i| {
        const x = right - @as(f32, @floatFromInt(accent_presets.len - i)) * (swatch + 8);
        s.* = .{ .x = x, .y = y0, .width = swatch, .height = swatch };
    }
    self.autosave_toggle = .{ .x = right - 46, .y = self.rowY(3) + 3, .width = 46, .height = 22 };
    self.delay_plus = .{ .x = right - button, .y = self.rowY(4), .width = button, .height = button };
    self.delay_minus = .{ .x = right - button * 2 - 90, .y = self.rowY(4), .width = button, .height = button };
    const reset_w = @max(64, font.textWidth(i18n.tr().common.reset) + 16);
    self.zoom_reset = .{ .x = right - reset_w, .y = self.rowY(5), .width = reset_w, .height = button };
    self.zoom_plus = .{ .x = right - reset_w - 12 - button, .y = self.rowY(5), .width = button, .height = button };
    self.zoom_minus = .{ .x = self.zoom_plus.x - 90 - button, .y = self.rowY(5), .width = button, .height = button };
    self.minimap_toggle = .{ .x = right - 46, .y = self.rowY(rows.minimap) + 3, .width = 46, .height = 22 };
    var icons_w: f32 = 0;
    for (std.enums.values(Settings.Icons)) |v| icons_w = @max(icons_w, font.textWidth(fileIconsLabel(v)));
    icons_w += 40;
    self.file_icons_button = .{ .x = right - icons_w, .y = self.rowY(rows.file_icons), .width = icons_w, .height = button };
    self.folder_icons_button = .{ .x = right - icons_w, .y = self.rowY(rows.folder_icons), .width = icons_w, .height = button };
    self.wrap_toggle = .{ .x = right - 46, .y = self.rowY(rows.word_wrap) + 3, .width = 46, .height = 22 };
    self.new_window_toggle = .{ .x = right - 46, .y = self.rowY(rows.new_window) + 3, .width = 46, .height = 22 };
    self.confirm_discard_toggle = .{ .x = right - 46, .y = self.rowY(rows.confirm_discard) + 3, .width = 46, .height = 22 };
    self.pull_rebase_toggle = .{ .x = right - 46, .y = self.rowY(rows.pull_rebase) + 3, .width = 46, .height = 22 };
    self.inline_blame_toggle = .{ .x = right - 46, .y = self.rowY(rows.inline_blame) + 3, .width = 46, .height = 22 };
    self.smooth_toggle = .{ .x = right - 46, .y = self.rowY(rows.smooth) + 3, .width = 46, .height = 22 };
    self.format_toggle = .{ .x = right - 46, .y = self.rowY(rows.format_on_save) + 3, .width = 46, .height = 22 };
    self.trim_toggle = .{ .x = right - 46, .y = self.rowY(rows.trim_whitespace) + 3, .width = 46, .height = 22 };
    self.newline_toggle = .{ .x = right - 46, .y = self.rowY(rows.final_newline) + 3, .width = 46, .height = 22 };
    const open_w = @max(80, font.textWidth(i18n.tr().common.open) + 16);
    self.shortcuts_button = .{ .x = right - open_w, .y = self.rowY(rows.shortcuts), .width = open_w, .height = button };
}

/// Row numbers, top to bottom.
pub const rows = struct {
    pub const language = 0;
    pub const theme = 1;
    pub const accent = 2;
    pub const autosave = 3;
    pub const delay = 4;
    pub const zoom = 5;
    pub const minimap = 6;
    pub const file_icons = 7;
    pub const folder_icons = 8;
    pub const word_wrap = 9;
    pub const new_window = 10;
    pub const confirm_discard = 11;
    pub const pull_rebase = 12;
    pub const inline_blame = 13;
    pub const smooth = 14;
    pub const format_on_save = 15;
    pub const trim_whitespace = 16;
    pub const final_newline = 17;
    pub const shortcuts = 18;
    /// "Saved to:" and the path.
    pub const path = 19;
};

pub fn rowY(self: *const SettingsPage, row: usize) f32 {
    return self.origin.y + rowOffset(row);
}

fn rowOffset(row: usize) f32 {
    return theme.font_size * 2.4 + 40 + @as(f32, @floatFromInt(row)) * row_gap;
}

/// From the title to below the "Saved to" path (see draw), plus a margin.
fn contentHeight() f32 {
    return rowOffset(rows.path) + 10 + theme.line_height * 2 + theme.padding * 2;
}

pub fn scrollBy(self: *SettingsPage, wheel_y: f32) void {
    self.scroll_to = std.math.clamp(self.scroll_to - wheel_y * row_gap, 0, self.max_scroll);
    if (!anim.enabled) self.scroll = self.scroll_to;
}

/// One frame of following the scroll.
pub fn step(self: *SettingsPage) void {
    anim.approach(&self.scroll, self.scroll_to, anim.scroll_speed);
}

pub fn actionAt(self: *const SettingsPage, p: rl.Vector2, settings: *const Settings) ?Action {
    // Controls scrolled out of view are still laid out, under the tab bar.
    if (!hit(p, self.area)) return null;
    if (hit(p, self.language_button)) return .{ .choose_language = self.language_button };
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
    if (hit(p, self.file_icons_button)) return .{ .choose_file_icons = self.file_icons_button };
    if (hit(p, self.folder_icons_button)) return .{ .choose_folder_icons = self.folder_icons_button };
    if (hit(p, self.wrap_toggle)) return .toggle_word_wrap;
    if (hit(p, self.new_window_toggle)) return .toggle_new_window;
    if (hit(p, self.confirm_discard_toggle)) return .toggle_confirm_discard;
    if (hit(p, self.pull_rebase_toggle)) return .toggle_pull_rebase;
    if (hit(p, self.inline_blame_toggle)) return .toggle_inline_blame;
    if (hit(p, self.smooth_toggle)) return .toggle_smooth;
    if (hit(p, self.format_toggle)) return .toggle_format_on_save;
    if (hit(p, self.trim_toggle)) return .toggle_trim_whitespace;
    if (hit(p, self.newline_toggle)) return .toggle_final_newline;
    if (hit(p, self.shortcuts_button)) return .open_help;
    return null;
}

/// What the icon modes are called in the menu and on the button.
pub fn fileIconsLabel(mode: Settings.Icons) []const u8 {
    const t = i18n.tr().settings;
    return switch (mode) {
        .default => t.file_icons_default,
        .icons => t.file_icons_all,
        .none => t.file_icons_none,
    };
}

pub fn hit(p: rl.Vector2, r: rl.Rectangle) bool {
    return rl.checkCollisionPointRec(p, r);
}
