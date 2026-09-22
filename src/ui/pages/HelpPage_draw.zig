//! Drawing the Help tab: the groups of shortcuts, each with its
//! combination, and the Reset buttons that put them back.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");
const Keymap = @import("../../input/Keymap.zig");
const HelpPage = @import("HelpPage.zig");
const i18n = @import("../../i18n/i18n.zig");
const controls = @import("SettingsPage_draw.zig");

const drawText = controls.drawText;

pub fn draw(self: *const HelpPage, font: Font, keys: *const Keymap, path: []const u8) void {
    theme.clip(self.area);
    defer rl.endScissorMode();

    const x = self.origin.x;
    var y = self.origin.y - self.scroll;
    const t = i18n.tr();
    drawText(font, t.help.title, x, y, Font.heading_size, theme.foreground);
    controls.drawButton(font, self.reset_all_rect, t.help.reset_all, changed(keys));
    y += Font.heading_size + 10;
    drawText(font, t.help.hint, x, y, Font.small_size, theme.popup_detail);
    y += theme.line_height;
    drawMessage(self, font, x, y);

    var group: ?Keymap.Group = null;
    var last_row: rl.Rectangle = .{ .x = x, .y = y, .width = 0, .height = 0 };
    for (Keymap.entries, self.rows, 0..) |e, row, i| {
        if (group == null or group.? != e.group) {
            group = e.group;
            drawText(font, e.group.title(), x, row.y - theme.line_height - 6, theme.font_size, theme.welcome_heading);
        }
        last_row = row;
        if (row.y + row.height < self.area.y or row.y > self.area.y + self.area.height) continue;
        drawRow(self, font, keys, e, row, self.hovered == i);
    }

    // Where the changes are kept, like the Settings tab shows.
    const below = last_row.y + last_row.height + theme.line_height;
    drawText(font, t.common.saved_to, x, below, theme.font_size, theme.popup_detail);
    drawText(font, path, x, below + theme.line_height, theme.font_size, theme.popup_detail);

    drawScrollbar(self);
}

fn drawRow(self: *const HelpPage, font: Font, keys: *const Keymap, e: Keymap.Entry, row: rl.Rectangle, hovered: bool) void {
    const capturing = self.capturing == e.action;
    if (capturing) {
        rl.drawRectangleRec(row, theme.accentDim(0.3));
    } else if (hovered) {
        rl.drawRectangleRec(row, theme.tab_hover);
    }

    const ty = row.y + (row.height - theme.font_size) / 2;
    // The combination, in the accent color when it isn't the default one.
    const box = HelpPage.chordRect(row, font);
    const label = Keymap.label(e.action);
    const label_end = font.drawFit(label, row.x + 8, ty, HelpPage.resetRect(row, font).x - 8, theme.foreground);

    const is_default = keys.isDefault(e.action);
    var buf: [48]u8 = undefined;
    const text = if (capturing)
        i18n.tr().help.press_keys
    else if (keys.chordFor(e.action)) |c|
        c.write(&buf)
    else
        HelpPage.unbound_label;
    const color = if (capturing)
        theme.foreground
    else if (keys.chordFor(e.action) == null)
        theme.popup_detail
    else if (is_default)
        theme.foreground
    else
        theme.accent;
    rl.drawRectangleRounded(box, 0.3, 8, theme.copy(if (capturing or hovered) theme.popup_background else theme.background));
    rl.drawRectangleRoundedLinesEx(box, 0.3, 8, 1, theme.copy(if (capturing) theme.accent else theme.popup_border));
    _ = font.drawFit(text, box.x + @max(4, (box.width - font.textWidth(text)) / 2), ty, box.x + box.width - 4, color);

    // Hovering a changed shortcut offers to put it back; otherwise the
    // space shows the combinations that always work besides this one.
    if (hovered and !is_default) {
        controls.drawButton(font, HelpPage.resetRect(row, font), i18n.tr().common.reset, true);
    } else if (e.also.len > 0 and !capturing) {
        const reset = HelpPage.resetRect(row, font);
        const right = reset.x + reset.width;
        const room = right - label_end - font.cell_width * 2;
        var also_buf: [96]u8 = undefined;
        const also = writeAlso(font, e.also, &also_buf, @max(0, room));
        drawText(font, also, right - font.textWidth(also), ty, theme.font_size, theme.popup_detail);
    }
}

/// "or Cmd+J, Ctrl+Backtick", with as many as fit in `room` wide.
fn writeAlso(font: Font, chords: []const Keymap.Chord, buf: []u8, room: f32) []const u8 {
    var w: usize = 0;
    var width: f32 = 0;
    var or_buf: [32]u8 = undefined;
    const first_sep = std.fmt.bufPrint(&or_buf, "{s} ", .{i18n.tr().help.@"or"}) catch "";
    for (chords, 0..) |c, i| {
        var one: [48]u8 = undefined;
        const text = c.write(&one);
        const sep: []const u8 = if (i == 0) first_sep else ", ";
        const add = font.textWidth(sep) + font.textWidth(text);
        if (w + sep.len + text.len > buf.len or width + add > room) break;
        width += add;
        @memcpy(buf[w..][0..sep.len], sep);
        w += sep.len;
        @memcpy(buf[w..][0..text.len], text);
        w += text.len;
    }
    return buf[0..w];
}

fn drawMessage(self: *const HelpPage, font: Font, x: f32, y: f32) void {
    switch (self.message) {
        .none => {},
        .needs_modifier => {
            const t = i18n.tr().help;
            var buf: [192]u8 = undefined;
            const mods = if (@import("builtin").os.tag == .macos) t.modifiers_mac else t.modifiers_other;
            drawText(font, i18n.fill(&buf, t.needs_modifier, .{mods}), x, y, Font.small_size, theme.find_no_results);
        },
        .took_from => |action| {
            var buf: [192]u8 = undefined;
            const text = i18n.fill(&buf, i18n.tr().help.taken_from, .{Keymap.label(action)});
            drawText(font, text, x, y, Font.small_size, theme.popup_detail);
        },
    }
}

/// A thin bar on the right edge showing how far down the list we are.
fn drawScrollbar(self: *const HelpPage) void {
    if (self.max_scroll <= 0) return;
    const h = self.area.height;
    const visible = h / (h + self.max_scroll);
    const thumb_h = @max(40, h * visible);
    const t = self.scroll / self.max_scroll;
    rl.drawRectangleRounded(.{
        .x = self.area.x + self.area.width - 8,
        .y = self.area.y + t * (h - thumb_h),
        .width = 4,
        .height = thumb_h,
    }, 1, 6, theme.scrollbar_thumb);
}

fn changed(keys: *const Keymap) bool {
    for (Keymap.entries) |e| {
        if (!keys.isDefault(e.action)) return true;
    }
    return false;
}
