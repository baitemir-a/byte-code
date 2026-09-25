//! A small right-click menu: a list of labels at the mouse position.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");
const anim = @import("../anim.zig");

const ContextMenu = @This();

/// Enough for the language menu.
pub const max_items = 12;
/// Labels are copied in, so they can be built on the spot (a file's path
/// and line, say). A longer one keeps its end, where the telling part of
/// a path is. In bytes: text in other scripts takes 2-3 per character.
pub const max_label = 96;
const row_height = theme.line_height + 4;
const pad: f32 = 12;

is_open: bool = false,
labels: [max_items][max_label]u8 = undefined,
label_lens: [max_items]usize = undefined,
count: usize = 0,
rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
hovered: ?usize = null,

/// Opens at `at`, kept inside `bounds`.
pub fn open(self: *ContextMenu, labels: []const []const u8, at: rl.Vector2, bounds: rl.Vector2, font: Font) void {
    self.count = @min(labels.len, max_items);
    var widest: f32 = 0;
    for (labels[0..self.count], 0..) |l, i| {
        const kept = self.setLabel(i, l);
        widest = @max(widest, font.textWidth(self.labels[i][0..kept]));
    }
    const w = widest + 2 * pad;
    const h = @as(f32, @floatFromInt(self.count)) * row_height + 4;
    self.rect = .{
        .x = @min(at.x, bounds.x - w - 2),
        .y = @min(at.y, bounds.y - h - 2),
        .width = w,
        .height = h,
    };
    self.is_open = true;
}

/// Copies one label in, cutting an over-long one down to its end
/// ("...app/lib/tree.zig:50"). Returns the length kept.
fn setLabel(self: *ContextMenu, i: usize, label: []const u8) usize {
    if (label.len <= max_label) {
        @memcpy(self.labels[i][0..label.len], label);
        self.label_lens[i] = label.len;
        return label.len;
    }
    const dots = "...";
    // Starting on a whole character, not inside one.
    var from = label.len - (max_label - dots.len);
    while (from < label.len and label[from] & 0xC0 == 0x80) from += 1;
    const tail = label[from..];
    @memcpy(self.labels[i][0..dots.len], dots);
    @memcpy(self.labels[i][dots.len..][0..tail.len], tail);
    self.label_lens[i] = dots.len + tail.len;
    return dots.len + tail.len;
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
    // It unfolds from where it was opened (see ui/anim.zig).
    const t = anim.ease(anim.fade(anim.hash("context_menu", 0), self.is_open, anim.popup_speed));
    if (!self.is_open or t <= 0) return;
    const r: rl.Rectangle = .{ .x = self.rect.x, .y = self.rect.y, .width = self.rect.width, .height = self.rect.height * t };
    rl.drawRectangleRec(.{ .x = r.x + 3, .y = r.y + 4, .width = r.width, .height = r.height }, anim.alpha(theme.popup_shadow, t));
    rl.drawRectangleRec(r, anim.alpha(theme.popup_background, t));
    rl.drawRectangleLinesEx(r, 1, anim.alpha(theme.popup_border, t));
    theme.clip(r);
    defer rl.endScissorMode();
    for (self.labels[0..self.count], self.label_lens[0..self.count], 0..) |chars, len, i| {
        const label = chars[0..len];
        const top = self.rect.y + 2 + @as(f32, @floatFromInt(i)) * row_height;
        if (self.hovered == i) rl.drawRectangleRec(.{ .x = r.x + 2, .y = top, .width = r.width - 4, .height = row_height }, theme.accentDim(0.35));
        const y = top + (row_height - theme.font_size) / 2;
        _ = font.drawText(label, r.x + pad, y, theme.font_size, anim.alpha(theme.foreground, t));
    }
}
