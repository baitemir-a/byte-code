//! The terminal panel at the bottom of the editor: draws the terminal
//! screen with its colors and cursor, scrolls through history, selects text
//! with the mouse, and can be resized by dragging its top edge.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");
const TerminalPanel_draw = @import("TerminalPanel_draw.zig");

const Screen = core.TerminalScreen;
const TerminalPanel = @This();

pub const line_height: f32 = theme.font_size * 1.25;
pub const header_height: f32 = 28;
const pad: f32 = 8;
const min_height: f32 = 100;

visible: bool = false,
height: f32 = 260,
/// The whole panel, its header and the character grid; set by `layout`.
rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
content: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
/// Grid size that fits the panel.
cols: usize = 80,
rows: usize = 24,
/// Lines scrolled back from the bottom (0 = following the output).
scroll_back: usize = 0,
/// Selected text, in `Screen.lineAt` coordinates, and whether the mouse
/// is still dragging it.
selection: ?struct { anchor: Screen.Pos, head: Screen.Pos } = null,
selecting: bool = false,
/// Dragging the top edge to resize.
resizing: bool = false,

// Drawing, in TerminalPanel_draw.zig.
pub const draw = TerminalPanel_draw.draw;

/// Space the panel takes from the bottom of `area` (0 when hidden).
pub fn takenHeight(self: *const TerminalPanel, area: rl.Rectangle) f32 {
    if (!self.visible) return 0;
    return std.math.clamp(self.height, min_height, @max(min_height, area.height - 120));
}

/// Lays the panel out at the bottom of `area` (the editor column).
pub fn layout(self: *TerminalPanel, area: rl.Rectangle, font: Font) void {
    const h = self.takenHeight(area);
    self.rect = .{ .x = area.x, .y = area.y + area.height - h, .width = area.width, .height = h };
    self.content = .{
        .x = self.rect.x + pad,
        .y = self.rect.y + header_height,
        .width = @max(0, self.rect.width - 2 * pad),
        .height = @max(0, h - header_height - pad / 2),
    };
    self.cols = @max(2, @as(usize, @intFromFloat(self.content.width / font.cell_width)));
    self.rows = @max(1, @as(usize, @intFromFloat(self.content.height / line_height)));
}

pub fn contains(self: *const TerminalPanel, p: rl.Vector2) bool {
    return self.visible and rl.checkCollisionPointRec(p, self.rect);
}

/// The top edge, which drags to resize.
pub fn onDivider(self: *const TerminalPanel, p: rl.Vector2) bool {
    return self.visible and @abs(p.y - self.rect.y) <= 4 and p.x >= self.rect.x and p.x <= self.rect.x + self.rect.width;
}

pub fn closeRect(self: *const TerminalPanel) rl.Rectangle {
    return .{ .x = self.rect.x + self.rect.width - 30, .y = self.rect.y + 4, .width = 22, .height = 20 };
}

pub fn onClose(self: *const TerminalPanel, p: rl.Vector2) bool {
    return self.visible and rl.checkCollisionPointRec(p, self.closeRect());
}

/// First `Screen.lineAt` index shown.
pub fn firstLine(self: *const TerminalPanel, screen: *const Screen) usize {
    return screen.lineCount() -| self.rows -| self.scroll_back;
}

pub fn scrollBy(self: *TerminalPanel, screen: *const Screen, wheel_y: f32) void {
    const lines: isize = @intFromFloat(wheel_y * 3);
    const max = screen.lineCount() -| self.rows;
    const next = @as(isize, @intCast(self.scroll_back)) + lines;
    self.scroll_back = @intCast(std.math.clamp(next, 0, @as(isize, @intCast(max))));
}

/// Screen position (line, column) under a window point, for selection.
pub fn cellAt(self: *const TerminalPanel, screen: *const Screen, p: rl.Vector2, font: Font) Screen.Pos {
    const row: usize = @intFromFloat(std.math.clamp((p.y - self.content.y) / line_height, 0, @as(f32, @floatFromInt(self.rows - 1))));
    const col: usize = @intFromFloat(@max(0, (p.x - self.content.x) / font.cell_width + 0.5));
    return .{ .x = @min(col, self.cols), .y = @min(self.firstLine(screen) + row, screen.lineCount() - 1) };
}

/// The selection with start before end.
pub fn orderedSelection(self: *const TerminalPanel) ?[2]Screen.Pos {
    const s = self.selection orelse return null;
    const a_first = s.anchor.y < s.head.y or (s.anchor.y == s.head.y and s.anchor.x <= s.head.x);
    const r: [2]Screen.Pos = if (a_first) .{ s.anchor, s.head } else .{ s.head, s.anchor };
    if (r[0].x == r[1].x and r[0].y == r[1].y) return null;
    return r;
}

// ----------------------------------------------------------------- colors
