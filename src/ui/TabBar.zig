//! The row of tabs above the text. Click a tab to switch to it, its × (or a
//! middle click) to close it. A dot marks unsaved changes.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("theme.zig");
const Font = @import("Font.zig");
const Tab = @import("../Tab.zig");
const file_icon = @import("file_icon.zig");

/// Room for the file-type dot in front of a file tab's name.
const icon_space: f32 = file_icon.radius * 2 + 8;

fn iconSpace(t: *const Tab) f32 {
    return if (t.kind == .file) icon_space else 0;
}

const TabBar = @This();

pub const height: f32 = theme.line_height + 12;
const pad: f32 = 12;
const close_size: f32 = 16;
const max_name_cols = 28;

pub const Hit = struct { index: usize, close: bool };

/// The bar's area; set by `layout`.
rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
/// One rectangle per tab, in window coordinates (scrolled).
tab_rects: std.ArrayList(rl.Rectangle) = .empty,
/// Pixels scrolled right when the tabs don't all fit.
scroll: f32 = 0,
hovered: ?usize = null,

pub fn deinit(self: *TabBar, gpa: std.mem.Allocator) void {
    self.tab_rects.deinit(gpa);
}

pub fn layout(self: *TabBar, gpa: std.mem.Allocator, tabs: []const Tab, active: usize, area: rl.Rectangle, font: Font) !void {
    self.rect = area;
    self.tab_rects.clearRetainingCapacity();

    var x: f32 = 0;
    for (tabs) |*t| {
        const cols: f32 = @floatFromInt(@min(max_name_cols, t.name().len));
        const w = pad + iconSpace(t) + cols * font.cell_width + 8 + close_size + pad / 2;
        try self.tab_rects.append(gpa, .{ .x = x, .y = area.y, .width = w, .height = height });
        x += w;
    }

    // Scroll just enough to keep the active tab in view.
    const a = self.tab_rects.items[active];
    if (a.x < self.scroll) self.scroll = a.x;
    if (a.x + a.width > self.scroll + area.width) self.scroll = a.x + a.width - area.width;
    self.scroll = std.math.clamp(self.scroll, 0, @max(0, x - area.width));
    for (self.tab_rects.items) |*r| r.x += area.x - self.scroll;

    const mouse = rl.getMousePosition();
    self.hovered = if (self.hit(mouse)) |h| h.index else null;
}

pub fn contains(self: *const TabBar, p: rl.Vector2) bool {
    return rl.checkCollisionPointRec(p, self.rect);
}

/// Which tab (and whether its close button) is under a point.
pub fn hit(self: *const TabBar, p: rl.Vector2) ?Hit {
    if (!self.contains(p)) return null;
    for (self.tab_rects.items, 0..) |r, i| {
        if (!rl.checkCollisionPointRec(p, r)) continue;
        return .{ .index = i, .close = rl.checkCollisionPointRec(p, closeRect(r)) };
    }
    return null;
}

fn closeRect(r: rl.Rectangle) rl.Rectangle {
    return .{ .x = r.x + r.width - pad / 2 - close_size, .y = r.y + (r.height - close_size) / 2, .width = close_size, .height = close_size };
}

pub fn draw(self: *const TabBar, tabs: []const Tab, active: usize, font: Font) void {
    const area = self.rect;
    rl.drawRectangleRec(area, theme.tab_bar_background);
    theme.clip(area);
    defer rl.endScissorMode();

    const mouse = rl.getMousePosition();
    // Same length as `tabs` after `layout`; guarded anyway.
    const n = @min(tabs.len, self.tab_rects.items.len);
    for (tabs[0..n], self.tab_rects.items[0..n], 0..) |*t, r, i| {
        const is_active = i == active;
        const hovered = self.hovered == i;
        if (is_active) {
            rl.drawRectangleRec(r, theme.background);
            rl.drawRectangleRec(.{ .x = r.x, .y = r.y, .width = r.width, .height = 2 }, theme.accent);
        } else if (hovered) {
            rl.drawRectangleRec(r, theme.tab_hover);
        }
        rl.drawRectangleRec(.{ .x = r.x + r.width - 1, .y = r.y, .width = 1, .height = r.height }, theme.tab_separator);

        // Name, ending in "…" when longer than a tab allows.
        const color = if (is_active) theme.foreground else theme.tab_inactive_text;
        const y = r.y + (r.height - theme.font_size) / 2;
        if (t.kind == .file) file_icon.draw(t.name(), .{ .x = r.x + pad + file_icon.radius, .y = r.y + r.height / 2 });
        const name_x = r.x + pad + iconSpace(t);
        const name_end = name_x + @as(f32, @floatFromInt(max_name_cols)) * font.cell_width + 0.5;
        _ = font.drawFit(t.name(), name_x, y, name_end, color);

        // The close button shows on the active or hovered tab; otherwise an
        // unsaved tab shows a dot in its place.
        const c = closeRect(r);
        const center: rl.Vector2 = .{ .x = c.x + c.width / 2, .y = c.y + c.height / 2 };
        if (is_active or hovered) {
            if (rl.checkCollisionPointRec(mouse, c)) rl.drawRectangleRec(c, theme.tab_close_hover);
            if (t.isDirty() and !rl.checkCollisionPointRec(mouse, c)) {
                rl.drawCircleV(center, 4, color);
            } else {
                drawCross(center, color);
            }
        } else if (t.isDirty()) {
            rl.drawCircleV(center, 4, color);
        }
    }
}

fn drawCross(c: rl.Vector2, color: rl.Color) void {
    const s: f32 = 4;
    rl.drawLineEx(.{ .x = c.x - s, .y = c.y - s }, .{ .x = c.x + s, .y = c.y + s }, 1.5, color);
    rl.drawLineEx(.{ .x = c.x - s, .y = c.y + s }, .{ .x = c.x + s, .y = c.y - s }, 1.5, color);
}
