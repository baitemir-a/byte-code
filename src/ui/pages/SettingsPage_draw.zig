//! Drawing the Settings tab and its controls: switches, steppers, segments
//! and buttons.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");
const core = @import("core");
const SettingsPage = @import("SettingsPage.zig");

const Settings = core.Settings;

pub fn draw(self: *const SettingsPage, font: Font, settings: *const Settings, settings_path: []const u8) void {
    const x = self.origin.x;
    drawText(font, "Settings", x, self.origin.y, Font.heading_size, theme.foreground);

    // Theme: two buttons, the current one filled with the accent.
    label(font, "Theme", "Colors of the whole editor", x, self.rowY(0));
    segment(font, self.theme_dark, "Dark", settings.theme == .dark);
    segment(font, self.theme_light, "Light", settings.theme == .light);

    // Accent color
    label(font, "Accent color", "Highlights, active tab, links", x, self.rowY(1));
    for (self.swatches, SettingsPage.accent_presets) |s, preset| {
        const color: rl.Color = .{ .r = preset.rgb[0], .g = preset.rgb[1], .b = preset.rgb[2], .a = 255 };
        const center: rl.Vector2 = .{ .x = s.x + s.width / 2, .y = s.y + s.height / 2 };
        rl.drawCircleV(center, SettingsPage.swatch / 2 - 3, color);
        if (std.mem.eql(u8, &preset.rgb, &settings.accent)) {
            rl.drawCircleLinesV(center, SettingsPage.swatch / 2, theme.foreground);
            rl.drawCircleLinesV(center, SettingsPage.swatch / 2 - 0.5, theme.foreground);
        } else if (SettingsPage.hit(rl.getMousePosition(), s)) {
            rl.drawCircleLinesV(center, SettingsPage.swatch / 2, theme.popup_detail);
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
    label(font, "Zoom", SettingsPage.cmd ++ "+= / " ++ SettingsPage.cmd ++ "+- / " ++ SettingsPage.cmd ++ "+0", x, self.rowY(4));
    var zoom_buf: [8]u8 = undefined;
    const zoom_text = std.fmt.bufPrint(&zoom_buf, "{d}%", .{settings.zoom}) catch "";
    stepper(font, self.zoom_minus, self.zoom_plus, zoom_text, true);
    drawButton(font, self.zoom_reset, "Reset", settings.zoom != 100);

    // Minimap
    label(font, "Minimap", "Overview of the file at the right edge", x, self.rowY(5));
    drawToggle(self.minimap_toggle, settings.minimap);

    // Word wrap
    label(font, "Word wrap", "Break long lines to fit the width (" ++ SettingsPage.opt ++ "+Z)", x, self.rowY(6));
    drawToggle(self.wrap_toggle, settings.word_wrap);

    // Opening folders
    label(font, "Open folders in a new window", "Otherwise they replace the current project", x, self.rowY(7));
    drawToggle(self.new_window_toggle, settings.open_folder_in_new_window);

    drawText(font, "Saved to:", x, self.rowY(8) + 10, theme.font_size, theme.popup_detail);
    drawText(font, settings_path, x, self.rowY(8) + 10 + theme.line_height, theme.font_size, theme.popup_detail);
}

pub fn label(font: Font, title: []const u8, hint: []const u8, x: f32, y: f32) void {
    drawText(font, title, x, y + 5, theme.font_size, theme.foreground);
    if (hint.len > 0) drawText(font, hint, x, y + 5 + theme.font_size + 4, Font.small_size, theme.popup_detail);
}

/// An on/off switch: a pill with a knob, in the accent color when on.
pub fn drawToggle(r: rl.Rectangle, on: bool) void {
    rl.drawRectangleRounded(r, 1, 12, if (on) theme.accent else theme.popup_border);
    const knob_x = if (on) r.x + r.width - r.height / 2 else r.x + r.height / 2;
    rl.drawCircleV(.{ .x = knob_x, .y = r.y + r.height / 2 }, r.height / 2 - 3, theme.foreground);
}

/// [−]  value  [+]
pub fn stepper(font: Font, minus: rl.Rectangle, plus: rl.Rectangle, value: []const u8, enabled: bool) void {
    drawButton(font, minus, "-", enabled);
    drawButton(font, plus, "+", enabled);
    const mid = (minus.x + minus.width + plus.x) / 2;
    const w = @as(f32, @floatFromInt(value.len)) * font.cell_width;
    drawText(font, value, mid - w / 2, minus.y + (minus.height - theme.font_size) / 2, theme.font_size, if (enabled) theme.foreground else theme.popup_detail);
}

/// One option of a choice: filled with the accent when selected.
pub fn segment(font: Font, r: rl.Rectangle, text: []const u8, selected: bool) void {
    const hovered = SettingsPage.hit(rl.getMousePosition(), r);
    const fill = if (selected) theme.accent else if (hovered) theme.tab_hover else theme.popup_background;
    rl.drawRectangleRounded(r, 0.3, 8, fill);
    if (!selected) rl.drawRectangleRoundedLinesEx(r, 0.3, 8, 1, theme.popup_border);
    const w = @as(f32, @floatFromInt(text.len)) * font.cell_width;
    const color = if (selected) theme.background else theme.foreground;
    drawText(font, text, r.x + (r.width - w) / 2, r.y + (r.height - theme.font_size) / 2, theme.font_size, color);
}

pub fn drawButton(font: Font, r: rl.Rectangle, text: []const u8, enabled: bool) void {
    const hovered = enabled and SettingsPage.hit(rl.getMousePosition(), r);
    rl.drawRectangleRounded(r, 0.3, 8, if (hovered) theme.tab_hover else theme.popup_background);
    rl.drawRectangleRoundedLinesEx(r, 0.3, 8, 1, theme.popup_border);
    const w = @as(f32, @floatFromInt(text.len)) * font.cell_width;
    drawText(font, text, r.x + (r.width - w) / 2, r.y + (r.height - theme.font_size) / 2, theme.font_size, if (enabled) theme.foreground else theme.popup_detail);
}

pub fn drawText(font: Font, s: []const u8, x0: f32, y: f32, size: f32, color: rl.Color) void {
    const cw = font.cell_width * size / theme.font_size;
    var x = x0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| : (x += cw) {
        if (cp != ' ') font.drawCodepointSized(cp, x, y, size, color);
    }
}
