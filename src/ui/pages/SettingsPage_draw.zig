//! Drawing the Settings tab and its controls: switches, steppers, segments
//! and buttons.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");
const core = @import("core");
const SettingsPage = @import("SettingsPage.zig");
const i18n = @import("../../i18n/i18n.zig");

const Settings = core.Settings;

pub fn draw(self: *const SettingsPage, font: Font, settings: *const Settings, settings_path: []const u8) void {
    theme.clip(self.area);
    defer rl.endScissorMode();

    const x = self.origin.x;
    const t = i18n.tr().settings;
    const rows = SettingsPage.rows;
    drawText(font, t.title, x, self.origin.y, Font.heading_size, theme.foreground);

    // Language: its name in itself; the button opens the list.
    label(font, t.language, t.language_hint, x, self.rowY(rows.language), self.language_button.x);
    drawButton(font, self.language_button, settings.language.nativeName(), true);
    const lb = self.language_button;
    font.drawIcon(.chevron_down, .{ .x = lb.x + lb.width - 14, .y = lb.y + lb.height / 2 }, .small, theme.popup_detail);

    // Theme: two buttons, the current one filled with the accent.
    label(font, t.theme, t.theme_hint, x, self.rowY(rows.theme), self.theme_dark.x);
    segment(font, self.theme_dark, t.dark, settings.theme == .dark);
    segment(font, self.theme_light, t.light, settings.theme == .light);

    // Accent color
    label(font, t.accent, t.accent_hint, x, self.rowY(rows.accent), self.swatches[0].x);
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

    // Auto save, and after how long (indented under it).
    label(font, t.autosave, t.autosave_hint, x, self.rowY(rows.autosave), self.autosave_toggle.x);
    drawToggle(self.autosave_toggle, settings.autosave);
    const enabled = settings.autosave;
    label(font, t.autosave_after, "", x + 3 * font.cell_width, self.rowY(rows.delay), self.delay_minus.x);
    var secs_buf: [16]u8 = undefined;
    const secs = std.fmt.bufPrint(&secs_buf, "{d:.2}", .{@as(f32, @floatFromInt(settings.autosave_delay_ms)) / 1000}) catch "";
    var delay_buf: [32]u8 = undefined;
    stepper(font, self.delay_minus, self.delay_plus, i18n.fill(&delay_buf, t.seconds, .{secs}), enabled);

    // Zoom
    label(font, t.zoom, SettingsPage.cmd ++ "+= / " ++ SettingsPage.cmd ++ "+- / " ++ SettingsPage.cmd ++ "+0", x, self.rowY(rows.zoom), self.zoom_minus.x);
    var zoom_buf: [8]u8 = undefined;
    const zoom_text = std.fmt.bufPrint(&zoom_buf, "{d}%", .{settings.zoom}) catch "";
    stepper(font, self.zoom_minus, self.zoom_plus, zoom_text, true);
    drawButton(font, self.zoom_reset, i18n.tr().common.reset, settings.zoom != 100);

    // Minimap
    label(font, t.minimap, t.minimap_hint, x, self.rowY(rows.minimap), self.minimap_toggle.x);
    drawToggle(self.minimap_toggle, settings.minimap);

    // Word wrap
    var wrap_buf: [128]u8 = undefined;
    label(font, t.word_wrap, i18n.fill(&wrap_buf, t.word_wrap_hint, .{SettingsPage.opt ++ "+Z"}), x, self.rowY(rows.word_wrap), self.wrap_toggle.x);
    drawToggle(self.wrap_toggle, settings.word_wrap);

    // Opening folders
    label(font, t.new_window, t.new_window_hint, x, self.rowY(rows.new_window), self.new_window_toggle.x);
    drawToggle(self.new_window_toggle, settings.open_folder_in_new_window);

    // Asking before changes are thrown away in the Git view.
    label(font, t.confirm_discard, t.confirm_discard_hint, x, self.rowY(rows.confirm_discard), self.confirm_discard_toggle.x);
    drawToggle(self.confirm_discard_toggle, settings.confirm_discard);

    // Keyboard shortcuts live in their own tab.
    label(font, t.shortcuts, t.shortcuts_hint, x, self.rowY(rows.shortcuts), self.shortcuts_button.x);
    drawButton(font, self.shortcuts_button, i18n.tr().common.open, true);

    const path_y = self.rowY(rows.path) + 10;
    drawText(font, i18n.tr().common.saved_to, x, path_y, theme.font_size, theme.popup_detail);
    drawText(font, settings_path, x, path_y + theme.line_height, theme.font_size, theme.popup_detail);
}

/// A row's title and hint on the left, cut short before its control
/// (which starts at `control_x`).
pub fn label(font: Font, title: []const u8, hint: []const u8, x: f32, y: f32, control_x: f32) void {
    const max_x = control_x - 12;
    _ = font.drawFit(title, x, y + 5, max_x, theme.foreground);
    if (hint.len > 0) _ = font.drawFitSized(hint, x, y + 5 + theme.font_size + 4, max_x, Font.small_size, theme.popup_detail);
}

/// An on/off switch: a pill with a knob, in the accent color when on.
pub fn drawToggle(r: rl.Rectangle, on: bool) void {
    rl.drawRectangleRounded(r, 1, 12, theme.copy(if (on) theme.accent else theme.popup_border));
    const knob_x = if (on) r.x + r.width - r.height / 2 else r.x + r.height / 2;
    rl.drawCircleV(.{ .x = knob_x, .y = r.y + r.height / 2 }, r.height / 2 - 3, theme.foreground);
}

/// [−]  value  [+]
pub fn stepper(font: Font, minus: rl.Rectangle, plus: rl.Rectangle, value: []const u8, enabled: bool) void {
    drawButton(font, minus, "-", enabled);
    drawButton(font, plus, "+", enabled);
    const mid = (minus.x + minus.width + plus.x) / 2;
    const w = font.textWidth(value);
    drawText(font, value, mid - w / 2, minus.y + (minus.height - theme.font_size) / 2, theme.font_size, if (enabled) theme.foreground else theme.popup_detail);
}

/// One option of a choice: filled with the accent when selected.
pub fn segment(font: Font, r: rl.Rectangle, text: []const u8, selected: bool) void {
    const hovered = SettingsPage.hit(rl.getMousePosition(), r);
    const fill = if (selected) theme.accent else if (hovered) theme.tab_hover else theme.popup_background;
    rl.drawRectangleRounded(r, 0.3, 8, theme.copy(fill));
    if (!selected) rl.drawRectangleRoundedLinesEx(r, 0.3, 8, 1, theme.popup_border);
    const w = font.textWidth(text);
    const color = if (selected) theme.background else theme.foreground;
    drawText(font, text, r.x + (r.width - w) / 2, r.y + (r.height - theme.font_size) / 2, theme.font_size, color);
}

pub fn drawButton(font: Font, r: rl.Rectangle, text: []const u8, enabled: bool) void {
    const hovered = enabled and SettingsPage.hit(rl.getMousePosition(), r);
    rl.drawRectangleRounded(r, 0.3, 8, theme.copy(if (hovered) theme.tab_hover else theme.popup_background));
    rl.drawRectangleRoundedLinesEx(r, 0.3, 8, 1, theme.popup_border);
    const w = font.textWidth(text);
    drawText(font, text, r.x + (r.width - w) / 2, r.y + (r.height - theme.font_size) / 2, theme.font_size, if (enabled) theme.foreground else theme.popup_detail);
}

pub fn drawText(font: Font, s: []const u8, x: f32, y: f32, size: f32, color: rl.Color) void {
    _ = font.drawText(s, x, y, size, color);
}
