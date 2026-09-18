//! The terminal panel at the bottom of the editor: draws the terminal
//! screen with its colors and cursor, scrolls through history, selects text
//! with the mouse, and can be resized by dragging its top edge.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("theme.zig");
const Font = @import("Font.zig");

const Screen = core.TerminalScreen;
const TerminalPanel = @This();

pub const line_height: f32 = theme.font_size * 1.25;
const header_height: f32 = 28;
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

fn closeRect(self: *const TerminalPanel) rl.Rectangle {
    return .{ .x = self.rect.x + self.rect.width - 30, .y = self.rect.y + 4, .width = 22, .height = 20 };
}

pub fn onClose(self: *const TerminalPanel, p: rl.Vector2) bool {
    return self.visible and rl.checkCollisionPointRec(p, self.closeRect());
}

/// First `Screen.lineAt` index shown.
fn firstLine(self: *const TerminalPanel, screen: *const Screen) usize {
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

// ------------------------------------------------------------------- draw

pub fn draw(self: *const TerminalPanel, screen: *const Screen, font: Font, focused: bool, show_cursor: bool, title: []const u8) void {
    if (!self.visible) return;
    const r = self.rect;
    rl.drawRectangleRec(r, theme.terminal_background);
    rl.drawRectangleRec(.{ .x = r.x, .y = r.y, .width = r.width, .height = 1 }, if (self.resizing) theme.accent else theme.sidebar_border);

    // Header: TERMINAL, the shell's title, and a close button.
    const hy = r.y + (header_height - theme.font_size) / 2;
    var x = drawText(font, "TERMINAL", r.x + 12, hy, if (focused) theme.foreground else theme.sidebar_header);
    x = drawText(font, "  ", x, hy, theme.sidebar_header);
    _ = drawText(font, title[0..@min(title.len, 60)], x, hy, theme.popup_detail);
    const close = self.closeRect();
    if (rl.checkCollisionPointRec(rl.getMousePosition(), close)) rl.drawRectangleRec(close, theme.tab_close_hover);
    const cc: rl.Vector2 = .{ .x = close.x + close.width / 2, .y = close.y + close.height / 2 };
    rl.drawLineEx(.{ .x = cc.x - 4, .y = cc.y - 4 }, .{ .x = cc.x + 4, .y = cc.y + 4 }, 1.5, theme.sidebar_arrow);
    rl.drawLineEx(.{ .x = cc.x - 4, .y = cc.y + 4 }, .{ .x = cc.x + 4, .y = cc.y - 4 }, 1.5, theme.sidebar_arrow);

    const c = self.content;
    theme.clip(.{ .x = c.x, .y = c.y, .width = c.width + 1, .height = c.height + 1 });
    defer rl.endScissorMode();

    const cw = font.cell_width;
    const first = self.firstLine(screen);
    const sel = self.orderedSelection();
    for (0..self.rows) |row| {
        const index = first + row;
        if (index >= screen.lineCount()) break;
        const cells = screen.lineAt(index);
        const top = c.y + @as(f32, @floatFromInt(row)) * line_height;
        const text_y = top + (line_height - theme.font_size) / 2;
        for (cells[0..@min(cells.len, self.cols)], 0..) |cell, col| {
            const cx = c.x + @as(f32, @floatFromInt(col)) * cw;
            var fg = colorOf(cell.fg, true, cell.attrs.bold);
            var bg: ?rl.Color = if (cell.bg == .default) null else colorOf(cell.bg, false, false);
            if (cell.attrs.inverse) {
                const old_fg = fg;
                fg = bg orelse theme.terminal_background;
                bg = old_fg;
            }
            if (sel) |s| if (inSelection(s, index, col)) {
                bg = theme.selection;
            };
            if (bg) |b| rl.drawRectangleRec(.{ .x = cx, .y = top, .width = cw + 0.5, .height = line_height }, b);
            if (cell.attrs.faint) fg.a = 150;
            if (cell.cp != ' ' and !cell.attrs.hidden) font.drawCodepoint(cell.cp, cx, text_y, fg);
            if (cell.attrs.underline) rl.drawRectangleRec(.{ .x = cx, .y = text_y + theme.font_size, .width = cw, .height = 1 }, fg);
            if (cell.attrs.strike) rl.drawRectangleRec(.{ .x = cx, .y = text_y + theme.font_size / 2, .width = cw, .height = 1 }, fg);
        }
    }

    // Cursor: a block when focused, an outline when not.
    const cursor_row = (screen.lineCount() - screen.rows + screen.cursor.y);
    if (screen.cursor_visible and cursor_row >= first and cursor_row < first + self.rows) {
        const cx = c.x + @as(f32, @floatFromInt(screen.cursor.x)) * cw;
        const cy = c.y + @as(f32, @floatFromInt(cursor_row - first)) * line_height;
        const box: rl.Rectangle = .{ .x = cx, .y = cy, .width = cw, .height = line_height };
        if (focused) {
            if (show_cursor) {
                rl.drawRectangleRec(box, theme.terminal_cursor);
                const under = screen.grid[screen.cursor.y][screen.cursor.x];
                if (under.cp != ' ') font.drawCodepoint(under.cp, cx, cy + (line_height - theme.font_size) / 2, theme.terminal_background);
            }
        } else rl.drawRectangleLinesEx(box, 1, theme.terminal_cursor);
    }
}

fn inSelection(s: [2]Screen.Pos, line: usize, col: usize) bool {
    if (line < s[0].y or line > s[1].y) return false;
    if (line == s[0].y and col < s[0].x) return false;
    if (line == s[1].y and col >= s[1].x) return false;
    return true;
}

fn drawText(font: Font, s: []const u8, x0: f32, y: f32, color: rl.Color) f32 {
    var x = x0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| : (x += font.cell_width) {
        if (cp != ' ') font.drawCodepoint(cp, x, y, color);
    }
    return x;
}

// ----------------------------------------------------------------- colors

fn colorOf(c: Screen.Color, is_fg: bool, bold: bool) rl.Color {
    return switch (c) {
        .default => if (is_fg) theme.terminal_foreground else theme.terminal_background,
        // Bold text in one of the 8 basic colors shows the bright variant.
        .palette => |i| if (i < 16) theme.terminal_ansi[if (bold and i < 8) i + 8 else i] else palette256(i),
        .rgb => |v| rgb(v[0], v[1], v[2]),
    };
}

/// xterm's 256 colors: 16-231 a 6×6×6 color cube, 232-255 grays.
fn palette256(i: u8) rl.Color {
    if (i >= 232) {
        const v: u8 = 8 + (i - 232) * 10;
        return rgb(v, v, v);
    }
    const n = i - 16;
    const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
    return rgb(levels[n / 36], levels[(n / 6) % 6], levels[n % 6]);
}

fn rgb(r: u8, g: u8, b: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}
