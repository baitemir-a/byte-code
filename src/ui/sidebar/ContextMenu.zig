//! A small right-click menu: a list of labels at the mouse position.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");

const ContextMenu = @This();

pub const max_items = 8;
const row_height = theme.line_height + 4;
const pad: f32 = 12;

is_open: bool = false,
labels: [max_items][]const u8 = undefined,
count: usize = 0,
rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
hovered: ?usize = null,

/// Opens at `at`, kept inside `bounds`.
pub fn open(self: *ContextMenu, labels: []const []const u8, at: rl.Vector2, bounds: rl.Vector2, font: Font) void {
    self.count = @min(labels.len, max_items);
    @memcpy(self.labels[0..self.count], labels[0..self.count]);
    var longest: usize = 0;
    for (labels) |l| longest = @max(longest, l.len);
    const w = @as(f32, @floatFromInt(longest)) * font.cell_width + 2 * pad;
    const h = @as(f32, @floatFromInt(self.count)) * row_height + 4;
    self.rect = .{
        .x = @min(at.x, bounds.x - w - 2),
        .y = @min(at.y, bounds.y - h - 2),
        .width = w,
        .height = h,
    };
    self.is_open = true;
}

pub fn close(self: *ContextMenu) void {
    self.is_open = false;
}

pub fn contains(self: *const ContextMenu, p: rl.Vector2) bool {
    return self.is_open and rl.checkCollisionPointRec(p, self.rect);
}

/// Index of the item under a point.
pub fn itemAt(self: *const ContextMenu, p: rl.Vector2) ?usize {
    if (!self.contains(p)) return null;
    const i: usize = @intFromFloat(@max(0, (p.y - self.rect.y - 2) / row_height));
    return if (i < self.count) i else null;
}

pub fn update(self: *ContextMenu) void {
    self.hovered = self.itemAt(rl.getMousePosition());
}

pub fn draw(self: *const ContextMenu, font: Font) void {
    if (!self.is_open) return;
    const r = self.rect;
    rl.drawRectangleRec(.{ .x = r.x + 3, .y = r.y + 4, .width = r.width, .height = r.height }, theme.popup_shadow);
    rl.drawRectangleRec(r, theme.popup_background);
    rl.drawRectangleLinesEx(r, 1, theme.popup_border);
    for (self.labels[0..self.count], 0..) |label, i| {
        const top = r.y + 2 + @as(f32, @floatFromInt(i)) * row_height;
        if (self.hovered == i) rl.drawRectangleRec(.{ .x = r.x + 2, .y = top, .width = r.width - 4, .height = row_height }, theme.accentDim(0.35));
        var x = r.x + pad;
        const y = top + (row_height - theme.font_size) / 2;
        for (label) |c| {
            if (c != ' ') font.drawCodepoint(c, x, y, theme.foreground);
            x += font.cell_width;
        }
    }
}
