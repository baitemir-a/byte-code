//! The terminal panel at the bottom of the editor: draws the terminal
//! screen with its colors and cursor, scrolls through history, selects text
//! with the mouse, and can be resized by dragging its top edge.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");
const anim = @import("../anim.zig");
const TerminalPanel_draw = @import("TerminalPanel_draw.zig");

const Screen = core.TerminalScreen;
const TerminalPanel = @This();

pub const line_height: f32 = theme.font_size * 1.25;
pub const header_height: f32 = 28;
const pad: f32 = 8;
const min_height: f32 = 100;

visible: bool = false,
height: f32 = 260,
/// How far the panel is out: 0 closed, 1 its full height. It slides when
/// smooth animations are on (see ui/anim.zig).
shown: f32 = 0,
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
/// Fractional lines left over while a drag scrolls the panel by itself.
drag_scroll: f32 = 0,
/// Dragging the top edge to resize.
resizing: bool = false,

// Drawing, in TerminalPanel_draw.zig.
pub const draw = TerminalPanel_draw.draw;

/// Space the panel takes from the bottom of `area` (0 when hidden, less
/// than its height while it slides in or out).
pub fn takenHeight(self: *const TerminalPanel, area: rl.Rectangle) f32 {
    if (!self.visible and self.shown <= 0) return 0;
    return std.math.clamp(self.height, min_height, @max(min_height, area.height - 120)) * anim.ease(self.shown);
}

/// One frame of sliding open or shut. Called once a frame, before layout.
pub fn step(self: *TerminalPanel) void {
    anim.approach(&self.shown, if (self.visible) 1 else 0, anim.panel_speed);
}

/// The panel is all the way open or all the way shut.
pub fn settled(self: *const TerminalPanel) bool {
    return self.shown <= 0 or self.shown >= 1;
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
    // The grid keeps its size while the panel slides: the shell would
    // otherwise be resized on every frame of the animation.
    if (!self.settled()) return;
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
    self.scrollLines(screen, @intFromFloat(wheel_y * 3));
}

/// Goes `lines` back through the history (negative goes forward again).
pub fn scrollLines(self: *TerminalPanel, screen: *const Screen, lines: isize) void {
    const max = screen.lineCount() -| self.rows;
    const next = @as(isize, @intCast(self.scroll_back)) + lines;
    self.scroll_back = @intCast(std.math.clamp(next, 0, @as(isize, @intCast(max))));
}

/// Scrolls the history while a selection is dragged to the top or bottom
/// of the grid, so it can reach lines off screen. Only whole lines
/// scroll; the fraction left over carries over to the next frame.
pub fn dragScroll(self: *TerminalPanel, screen: *const Screen, p: rl.Vector2) void {
    const bottom = self.content.y + self.content.height;
    const lines = theme.dragScrollLines(p.y, self.content.y, bottom, line_height);
    if (lines == 0) {
        self.drag_scroll = 0;
        return;
    }
    self.drag_scroll += lines * rl.getFrameTime();
    const whole = @trunc(self.drag_scroll);
    if (whole == 0) return;
    self.drag_scroll -= whole;
    // Dragging up goes back through the history, like the wheel.
    self.scrollLines(screen, -@as(isize, @intFromFloat(whole)));
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
