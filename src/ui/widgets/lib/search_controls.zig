//! Small controls shared by the find bar and the Search view: option
//! toggles ("Aa" match case, "ab" whole word), buttons and tooltips.
const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const theme = @import("../../theme/lib/theme.zig");
const Font = @import("../../Font.zig");
const i18n = @import("../../../i18n/i18n.zig");

pub const Option = enum {
    match_case,
    whole_word,

    pub fn label(self: Option) []const u8 {
        return switch (self) {
            .match_case => "Aa",
            .whole_word => "ab",
        };
    }

    /// Its name and shortcut, into `buf`.
    pub fn tooltip(self: Option, buf: []u8) []const u8 {
        const mac = builtin.os.tag == .macos;
        const t = i18n.tr().find;
        return switch (self) {
            .match_case => i18n.fill(buf, t.match_case_tooltip, .{if (mac) "Cmd+Option+C" else "Alt+C"}),
            .whole_word => i18n.fill(buf, t.whole_word_tooltip, .{if (mac) "Cmd+Option+W" else "Alt+W"}),
        };
    }
};

/// Width of an option toggle.
pub fn toggleWidth(font: Font) f32 {
    return 2 * font.cell_width + 10;
}

/// Width of a button showing `label`.
pub fn buttonWidth(font: Font, label: []const u8) f32 {
    return font.textWidth(label) + 16;
}

/// An option toggle: filled with the accent while on.
pub fn drawToggle(font: Font, r: rl.Rectangle, option: Option, on: bool) void {
    const hov = rl.checkCollisionPointRec(rl.getMousePosition(), r);
    if (on) {
        rl.drawRectangleRounded(r, 0.25, 8, theme.accentDim(0.35));
        rl.drawRectangleRoundedLinesEx(r, 0.25, 8, 1, theme.accent);
    } else if (hov) {
        rl.drawRectangleRounded(r, 0.25, 8, theme.sidebar_hover);
    }
    const text = option.label();
    const w = @as(f32, @floatFromInt(text.len)) * font.cell_width;
    const x = r.x + (r.width - w) / 2;
    const y = r.y + (r.height - theme.font_size) / 2;
    const color = if (on) theme.foreground else theme.popup_detail;
    _ = font.drawFit(text, x, y, r.x + r.width, color);
    // "ab" underlined, like the usual whole-word icon.
    if (option == .whole_word) rl.drawRectangleRec(.{ .x = x, .y = y + theme.font_size + 1, .width = w, .height = 1 }, theme.copy(color));
}

/// A button: `primary` ones are filled with the accent. Disabled ones are
/// drawn outlined and dimmed.
pub fn drawButton(font: Font, r: rl.Rectangle, label: []const u8, enabled: bool, primary: bool) void {
    const hov = enabled and rl.checkCollisionPointRec(rl.getMousePosition(), r);
    const fill = if (!enabled)
        theme.popup_background
    else if (primary)
        (if (hov) theme.accentDim(0.8) else theme.accent)
    else if (hov)
        theme.sidebar_hover
    else
        theme.popup_background;
    rl.drawRectangleRounded(r, 0.25, 8, theme.copy(fill));
    if (!enabled or !primary) rl.drawRectangleRoundedLinesEx(r, 0.25, 8, 1, theme.popup_border);
    const color = if (!enabled) theme.popup_detail else if (primary) theme.background else theme.foreground;
    const w = font.textWidth(label);
    _ = font.drawFit(label, r.x + @max(4, (r.width - w) / 2), r.y + (r.height - theme.font_size) / 2, r.x + r.width, color);
}

/// A one-line tooltip under `anchor`, kept inside the window.
pub fn drawTooltip(font: Font, anchor: rl.Rectangle, text: []const u8) void {
    const window_width = @as(f32, @floatFromInt(rl.getScreenWidth())) / theme.zoom;
    const w = font.textWidth(text) + 12;
    const h = theme.line_height;
    const x = std.math.clamp(anchor.x + anchor.width / 2 - w / 2, 4, @max(4, window_width - w - 4));
    const r: rl.Rectangle = .{ .x = x, .y = anchor.y + anchor.height + 6, .width = w, .height = h };
    rl.drawRectangleRec(.{ .x = r.x + 2, .y = r.y + 3, .width = r.width, .height = r.height }, theme.popup_shadow);
    rl.drawRectangleRec(r, theme.popup_background);
    rl.drawRectangleLinesEx(r, 1, theme.popup_border);
    _ = font.drawFit(text, r.x + 6, r.y + (h - theme.font_size) / 2, r.x + r.width, theme.foreground);
}
