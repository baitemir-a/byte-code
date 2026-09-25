//! The row of tabs above the text. Click a tab to switch to it, its × (or a
//! middle click) to close it. A dot marks unsaved changes.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("theme/lib/theme.zig");
const Font = @import("Font.zig");
const anim = @import("anim.zig");
const Tab = @import("../app/Tab.zig");
const file_icon = @import("widgets/lib/file_icon.zig");

/// Room for the file-type icon in front of a file tab's name.
const icon_space: f32 = file_icon.size + 8;

fn iconSpace(t: *const Tab) f32 {
    return if (t.kind == .file or t.kind == .diff) icon_space else 0;
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
        const name_w = @min(max_name_cols * font.cell_width, font.textWidth(t.name()));
        const w = pad + iconSpace(t) + name_w + 8 + close_size + pad / 2;
        try self.tab_rects.append(gpa, .{ .x = x, .y = area.y, .width = w, .height = height });
        x += w;
    }

    // A pane always has a tab, but never lay out a bar without one.
    if (self.tab_rects.items.len == 0) return;
    // Scroll just enough to keep the active tab in view.
    const a = self.tab_rects.items[@min(active, self.tab_rects.items.len - 1)];
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

/// `focused` is whether this bar's pane has the keyboard: the other one's
/// active tab is marked more faintly.
pub fn draw(self: *const TabBar, tabs: []const Tab, active: usize, font: Font, focused: bool) void {
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
        // One fade per tab, per bar: the two panes' bars are told apart by
        // where they start.
        const id = anim.hash("tab", i *% 31 +% @as(u64, @intFromFloat(@max(0, self.rect.x))));
        const hover_t = anim.fade(id, hovered and !is_active, anim.hover_speed);
        if (is_active) {
            rl.drawRectangleRec(r, theme.background);
        } else if (hover_t > 0) {
            rl.drawRectangleRec(r, anim.alpha(theme.tab_hover, hover_t));
        }
        rl.drawRectangleRec(.{ .x = r.x + r.width - 1, .y = r.y, .width = 1, .height = r.height }, theme.tab_separator);

        // Name, ending in "…" when longer than a tab allows.
        const color = theme.copy(if (is_active) theme.foreground else theme.tab_inactive_text);
        const y = r.y + (r.height - theme.font_size) / 2;
        if (t.kind == .file or t.kind == .diff) file_icon.draw(t.name(), .{ .x = r.x + pad + file_icon.size / 2, .y = r.y + r.height / 2 });
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
                font.drawIcon(.x, center, .small, color);
            }
        } else if (t.isDirty()) {
            rl.drawCircleV(center, 4, color);
        }
    }

    // The accent on the current tab slides over from the last one.
    if (active < n) {
        const a = self.tab_rects.items[active];
        const bar = @as(u64, @intFromFloat(@max(0, self.rect.x)));
        const x = anim.track(anim.hash("tab_line_x", bar), a.x, anim.panel_speed);
        const w = anim.track(anim.hash("tab_line_w", bar), a.width, anim.panel_speed);
        rl.drawRectangleRec(.{ .x = x, .y = a.y, .width = w, .height = 2 }, theme.copy(if (focused) theme.accent else theme.accentDim(0.5)));
    }
}
