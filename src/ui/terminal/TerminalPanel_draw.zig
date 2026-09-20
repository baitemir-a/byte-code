//! Drawing the terminal panel: its header, the screen's cells with their
//! colors, the selection and the cursor.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");
const core = @import("core");
const TerminalPanel = @import("TerminalPanel.zig");

const Screen = core.TerminalScreen;

pub fn draw(self: *const TerminalPanel, screen: *const Screen, font: Font, focused: bool, show_cursor: bool, title: []const u8) void {
    if (!self.visible) return;
    const r = self.rect;
    rl.drawRectangleRec(r, theme.terminal_background);
    rl.drawRectangleRec(.{ .x = r.x, .y = r.y, .width = r.width, .height = 1 }, theme.copy(if (self.resizing) theme.accent else theme.sidebar_border));

    // Header: TERMINAL, the shell's title, and a close button.
    const hy = r.y + (TerminalPanel.header_height - theme.font_size) / 2;
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
        const top = c.y + @as(f32, @floatFromInt(row)) * TerminalPanel.line_height;
        const text_y = top + (TerminalPanel.line_height - theme.font_size) / 2;
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
            if (bg) |b| rl.drawRectangleRec(.{ .x = cx, .y = top, .width = cw + 0.5, .height = TerminalPanel.line_height }, theme.copy(b));
            if (cell.attrs.faint) fg.a = 150;
            if (cell.cp != ' ' and !cell.attrs.hidden) font.drawCodepoint(cell.cp, cx, text_y, fg);
            if (cell.attrs.underline) rl.drawRectangleRec(.{ .x = cx, .y = text_y + theme.font_size, .width = cw, .height = 1 }, theme.copy(fg));
            if (cell.attrs.strike) rl.drawRectangleRec(.{ .x = cx, .y = text_y + theme.font_size / 2, .width = cw, .height = 1 }, theme.copy(fg));
        }
    }

    // Cursor: a block when focused, an outline when not.
    const cursor_row = (screen.lineCount() - screen.rows + screen.cursor.y);
    if (screen.cursor_visible and cursor_row >= first and cursor_row < first + self.rows) {
        const cx = c.x + @as(f32, @floatFromInt(screen.cursor.x)) * cw;
        const cy = c.y + @as(f32, @floatFromInt(cursor_row - first)) * TerminalPanel.line_height;
        const box: rl.Rectangle = .{ .x = cx, .y = cy, .width = cw, .height = TerminalPanel.line_height };
        if (focused) {
            if (show_cursor) {
                rl.drawRectangleRec(box, theme.terminal_cursor);
                const under = screen.grid[screen.cursor.y][screen.cursor.x];
                if (under.cp != ' ') font.drawCodepoint(under.cp, cx, cy + (TerminalPanel.line_height - theme.font_size) / 2, theme.terminal_background);
            }
        } else rl.drawRectangleLinesEx(box, 1, theme.terminal_cursor);
    }
}

pub fn inSelection(s: [2]Screen.Pos, line: usize, col: usize) bool {
    if (line < s[0].y or line > s[1].y) return false;
    if (line == s[0].y and col < s[0].x) return false;
    if (line == s[1].y and col >= s[1].x) return false;
    return true;
}

pub fn drawText(font: Font, s: []const u8, x0: f32, y: f32, color: rl.Color) f32 {
    var x = x0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| : (x += font.cell_width) {
        if (cp != ' ') font.drawCodepoint(cp, x, y, color);
    }
    return x;
}

pub fn colorOf(c: Screen.Color, is_fg: bool, bold: bool) rl.Color {
    return switch (c) {
        .default => if (is_fg) theme.terminal_foreground else theme.terminal_background,
        // Bold text in one of the 8 basic colors shows the bright variant.
        .palette => |i| if (i < 16) theme.terminal_ansi[if (bold and i < 8) i + 8 else i] else palette256(i),
        .rgb => |v| rgb(v[0], v[1], v[2]),
    };
}

/// xterm's 256 colors: 16-231 a 6×6×6 color cube, 232-255 grays.
pub fn palette256(i: u8) rl.Color {
    if (i >= 232) {
        const v: u8 = 8 + (i - 232) * 10;
        return rgb(v, v, v);
    }
    const n = i - 16;
    const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
    return rgb(levels[n / 36], levels[(n / 6) % 6], levels[n % 6]);
}

pub fn rgb(r: u8, g: u8, b: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}
