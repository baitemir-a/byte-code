//! The welcome tab: how to get started, each row clickable. The keyboard
//! shortcuts live in the Help tab (Keymap and HelpPage).
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");

const WelcomePage = @This();

const Action = struct { label: []const u8, command: core.Command };

const actions = [_]Action{
    .{ .label = "Open File...", .command = .open },
    .{ .label = "Open Folder...", .command = .open_folder },
    .{ .label = "New File", .command = .new_file },
    .{ .label = "Settings...", .command = .open_settings },
    .{ .label = "Keyboard Shortcuts...", .command = .open_help },
};

const title = "byte code";
const subtitle = "A lightweight code editor";
const drop_hint = "You can also drop files or folders onto this window.";
const content_cols = 56;

/// Clickable rows, in window coordinates; set by `layout`.
action_rects: [actions.len]rl.Rectangle = undefined,
hovered: ?usize = null,
/// Top-left of the content block.
origin: rl.Vector2 = .{ .x = 0, .y = 0 },

pub fn layout(self: *WelcomePage, area: rl.Rectangle, font: Font) void {
    const w = content_cols * font.cell_width;
    self.origin = .{
        .x = area.x + @max(theme.padding * 2, (area.width - w) / 2),
        .y = area.y + @max(theme.padding * 2, area.height * 0.15),
    };
    for (&self.action_rects, 0..) |*r, i| {
        r.* = .{ .x = self.origin.x - 8, .y = self.actionsTop() + rowY(i), .width = w + 16, .height = theme.line_height + 4 };
    }
    const mouse = rl.getMousePosition();
    self.hovered = for (self.action_rects, 0..) |r, i| {
        if (rl.checkCollisionPointRec(mouse, r)) break i;
    } else null;
}

/// The command for a clicked "Start" row.
pub fn actionAt(self: *const WelcomePage, p: rl.Vector2) ?core.Command {
    for (self.action_rects, actions) |r, a| {
        if (rl.checkCollisionPointRec(p, r)) return a.command;
    }
    return null;
}

fn rowY(i: usize) f32 {
    return @as(f32, @floatFromInt(i)) * (theme.line_height + 6);
}

fn actionsTop(self: *const WelcomePage) f32 {
    return self.origin.y + theme.font_size * 2.4 + theme.line_height * 3;
}

pub fn draw(self: *const WelcomePage, font: Font) void {
    const x = self.origin.x;
    var y = self.origin.y;

    drawText(font, title, x, y, Font.heading_size, theme.foreground);
    y += theme.font_size * 2.4 + 8;
    drawText(font, subtitle, x, y, theme.font_size, theme.popup_detail);

    y = self.actionsTop() - theme.line_height - 4;
    drawText(font, "Start", x, y, theme.font_size, theme.welcome_heading);
    for (actions, self.action_rects, 0..) |a, r, i| {
        if (self.hovered == i) rl.drawRectangleRec(r, theme.tab_hover);
        const ty = r.y + (r.height - theme.font_size) / 2;
        drawText(font, a.label, x, ty, theme.font_size, theme.accent);
    }
    y = self.actionsTop() + rowY(actions.len) + theme.line_height / 2;
    drawText(font, drop_hint, x, y, theme.font_size, theme.popup_detail);
}

fn drawText(font: Font, s: []const u8, x0: f32, y: f32, size: f32, color: rl.Color) void {
    const cw = font.cell_width * size / theme.font_size;
    var x = x0;
    for (s) |c| {
        if (c != ' ') font.drawCodepointSized(c, x, y, size, color);
        x += cw;
    }
}
