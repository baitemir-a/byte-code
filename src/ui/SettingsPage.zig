//! The Settings tab: theme, accent color, auto save, zoom and minimap.
//! Changes apply immediately and are saved to settings.json.
const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("theme.zig");
const Font = @import("Font.zig");

const Settings = core.Settings;
const SettingsPage = @This();

const cmd = if (builtin.os.tag == .macos) "Cmd" else "Ctrl";

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
const swatch: f32 = 26;
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
new_window_toggle: rl.Rectangle = undefined,

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
    self.new_window_toggle = .{ .x = right - 46, .y = self.rowY(6) + 3, .width = 46, .height = 22 };
}

fn rowY(self: *const SettingsPage, row: usize) f32 {
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
    if (hit(p, self.new_window_toggle)) return .toggle_new_window;
    return null;
}

fn hit(p: rl.Vector2, r: rl.Rectangle) bool {
    return rl.checkCollisionPointRec(p, r);
}

// ------------------------------------------------------------------- draw

pub fn draw(self: *const SettingsPage, font: Font, settings: *const Settings, settings_path: []const u8) void {
    const x = self.origin.x;
    drawText(font, "Settings", x, self.origin.y, theme.font_size * 2.4, theme.foreground);

    // Theme: two buttons, the current one filled with the accent.
    label(font, "Theme", "Colors of the whole editor", x, self.rowY(0));
    segment(font, self.theme_dark, "Dark", settings.theme == .dark);
    segment(font, self.theme_light, "Light", settings.theme == .light);

    // Accent color
    label(font, "Accent color", "Highlights, active tab, links", x, self.rowY(1));
    for (self.swatches, accent_presets) |s, preset| {
        const color: rl.Color = .{ .r = preset.rgb[0], .g = preset.rgb[1], .b = preset.rgb[2], .a = 255 };
        const center: rl.Vector2 = .{ .x = s.x + s.width / 2, .y = s.y + s.height / 2 };
        rl.drawCircleV(center, swatch / 2 - 3, color);
        if (std.mem.eql(u8, &preset.rgb, &settings.accent)) {
            rl.drawCircleLinesV(center, swatch / 2, theme.foreground);
            rl.drawCircleLinesV(center, swatch / 2 - 0.5, theme.foreground);
        } else if (hit(rl.getMousePosition(), s)) {
            rl.drawCircleLinesV(center, swatch / 2, theme.popup_detail);
        }
    }

    // Auto save
    label(font, "Auto save", "Save files after you stop typing", x, self.rowY(2));
    drawToggle(self.autosave_toggle, settings.autosave);
    const enabled = settings.autosave;
    label(font, "   after", "", x, self.rowY(3));
    var delay_buf: [16]u8 = undefined;
    const secs = @as(f32, @floatFromInt(settings.autosave_delay_ms)) / 1000;
    const delay_text = std.fmt.bufPrint(&delay_buf, "{d:.2} s", .{secs}) catch "";
    stepper(font, self.delay_minus, self.delay_plus, delay_text, enabled);

    // Zoom
    label(font, "Zoom", cmd ++ "+= / " ++ cmd ++ "+- / " ++ cmd ++ "+0", x, self.rowY(4));
    var zoom_buf: [8]u8 = undefined;
    const zoom_text = std.fmt.bufPrint(&zoom_buf, "{d}%", .{settings.zoom}) catch "";
    stepper(font, self.zoom_minus, self.zoom_plus, zoom_text, true);
    drawButton(font, self.zoom_reset, "Reset", settings.zoom != 100);

    // Minimap
    label(font, "Minimap", "Overview of the file at the right edge", x, self.rowY(5));
    drawToggle(self.minimap_toggle, settings.minimap);

    // Opening folders
    label(font, "Open folders in a new window", "Otherwise they replace the current project", x, self.rowY(6));
    drawToggle(self.new_window_toggle, settings.open_folder_in_new_window);

    drawText(font, "Saved to:", x, self.rowY(7) + 10, theme.font_size, theme.popup_detail);
    drawText(font, settings_path, x, self.rowY(7) + 10 + theme.line_height, theme.font_size, theme.popup_detail);
}

fn label(font: Font, title: []const u8, hint: []const u8, x: f32, y: f32) void {
    drawText(font, title, x, y + 5, theme.font_size, theme.foreground);
    if (hint.len > 0) drawText(font, hint, x, y + 5 + theme.font_size + 4, theme.font_size * 0.8, theme.popup_detail);
}

/// An on/off switch: a pill with a knob, in the accent color when on.
fn drawToggle(r: rl.Rectangle, on: bool) void {
    rl.drawRectangleRounded(r, 1, 12, if (on) theme.accent else theme.popup_border);
    const knob_x = if (on) r.x + r.width - r.height / 2 else r.x + r.height / 2;
    rl.drawCircleV(.{ .x = knob_x, .y = r.y + r.height / 2 }, r.height / 2 - 3, theme.foreground);
}

/// [−]  value  [+]
fn stepper(font: Font, minus: rl.Rectangle, plus: rl.Rectangle, value: []const u8, enabled: bool) void {
    drawButton(font, minus, "-", enabled);
    drawButton(font, plus, "+", enabled);
    const mid = (minus.x + minus.width + plus.x) / 2;
    const w = @as(f32, @floatFromInt(value.len)) * font.cell_width;
    drawText(font, value, mid - w / 2, minus.y + (minus.height - theme.font_size) / 2, theme.font_size, if (enabled) theme.foreground else theme.popup_detail);
}

/// One option of a choice: filled with the accent when selected.
fn segment(font: Font, r: rl.Rectangle, text: []const u8, selected: bool) void {
    const hovered = hit(rl.getMousePosition(), r);
    const fill = if (selected) theme.accent else if (hovered) theme.tab_hover else theme.popup_background;
    rl.drawRectangleRounded(r, 0.3, 8, fill);
    if (!selected) rl.drawRectangleRoundedLinesEx(r, 0.3, 8, 1, theme.popup_border);
    const w = @as(f32, @floatFromInt(text.len)) * font.cell_width;
    const color = if (selected) theme.background else theme.foreground;
    drawText(font, text, r.x + (r.width - w) / 2, r.y + (r.height - theme.font_size) / 2, theme.font_size, color);
}

fn drawButton(font: Font, r: rl.Rectangle, text: []const u8, enabled: bool) void {
    const hovered = enabled and hit(rl.getMousePosition(), r);
    rl.drawRectangleRounded(r, 0.3, 8, if (hovered) theme.tab_hover else theme.popup_background);
    rl.drawRectangleRoundedLinesEx(r, 0.3, 8, 1, theme.popup_border);
    const w = @as(f32, @floatFromInt(text.len)) * font.cell_width;
    drawText(font, text, r.x + (r.width - w) / 2, r.y + (r.height - theme.font_size) / 2, theme.font_size, if (enabled) theme.foreground else theme.popup_detail);
}

fn drawText(font: Font, s: []const u8, x0: f32, y: f32, size: f32, color: rl.Color) void {
    const cw = font.cell_width * size / theme.font_size;
    var x = x0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| : (x += cw) {
        if (cp != ' ') font.drawCodepointSized(cp, x, y, size, color);
    }
}
