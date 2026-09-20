//! Drawing the Help tab: the groups of shortcuts, each with its
//! combination, and the Reset buttons that put them back.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");
const Keymap = @import("../../input/Keymap.zig");
const HelpPage = @import("HelpPage.zig");
const controls = @import("SettingsPage_draw.zig");

const drawText = controls.drawText;

pub fn draw(self: *const HelpPage, font: Font, keys: *const Keymap, path: []const u8) void {
    theme.clip(self.area);
    defer rl.endScissorMode();

    const x = self.origin.x;
    var y = self.origin.y - self.scroll;
    drawText(font, HelpPage.title, x, y, Font.heading_size, theme.foreground);
    controls.drawButton(font, self.reset_all_rect, "Reset All", changed(keys));
    y += Font.heading_size + 10;
    drawText(font, HelpPage.hint, x, y, Font.small_size, theme.popup_detail);
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
    drawText(font, "Saved to:", x, below, theme.font_size, theme.popup_detail);
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
    drawText(font, e.label, row.x + 8, ty, theme.font_size, theme.foreground);

    // The combination, in the accent color when it isn't the default one.
    const box = HelpPage.chordRect(row, font);
    const is_default = keys.isDefault(e.action);
    var buf: [48]u8 = undefined;
    const text = if (capturing)
        HelpPage.capture_label
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
    const w = @as(f32, @floatFromInt(text.len)) * font.cell_width;
    drawText(font, text, box.x + (box.width - w) / 2, ty, theme.font_size, color);

    // Hovering a changed shortcut offers to put it back; otherwise the
    // space shows the combinations that always work besides this one.
    if (hovered and !is_default) {
        controls.drawButton(font, HelpPage.resetRect(row, font), "Reset", true);
    } else if (e.also.len > 0 and !capturing) {
        const reset = HelpPage.resetRect(row, font);
        const right = reset.x + reset.width;
        const label_end = row.x + 8 + @as(f32, @floatFromInt(e.label.len)) * font.cell_width;
        const room = (right - label_end - font.cell_width * 2) / font.cell_width;
        var also_buf: [96]u8 = undefined;
        const also = writeAlso(e.also, &also_buf, if (room > 0) @intFromFloat(room) else 0);
        drawText(font, also, right - @as(f32, @floatFromInt(also.len)) * font.cell_width, ty, theme.font_size, theme.popup_detail);
    }
}

/// "or Cmd+J, Ctrl+Backtick", with as many as fit in `room` characters.
fn writeAlso(chords: []const Keymap.Chord, buf: []u8, room: usize) []const u8 {
    var w: usize = 0;
    for (chords, 0..) |c, i| {
        var one: [48]u8 = undefined;
        const text = c.write(&one);
        const sep: []const u8 = if (i == 0) "or " else ", ";
        if (w + sep.len + text.len > @min(buf.len, room)) break;
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
        .needs_modifier => drawText(
            font,
            "That key types text: hold " ++ modifier_names ++ " with it.",
            x,
            y,
            Font.small_size,
            theme.find_no_results,
        ),
        .took_from => |action| {
            var buf: [96]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "Taken from \"{s}\", which has no shortcut now.", .{Keymap.entryFor(action).label}) catch return;
            drawText(font, text, x, y, Font.small_size, theme.popup_detail);
        },
    }
}

const modifier_names = if (@import("builtin").os.tag == .macos) "Cmd, Ctrl or Option" else "Ctrl or Alt";

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
