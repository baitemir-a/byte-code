//! Drawing the text area: the text row by row with its highlighting,
//! selections and search matches, the carets and the line-number gutter.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../theme/lib/theme.zig");
const core = @import("core");
const View = @import("View.zig");

const Buffer = core.Buffer;
const Highlighter = core.syntax.Highlighter;
const text = core.text;

pub fn draw(self: View, buf: *const Buffer, hl: *const Highlighter, marks: ?View.Highlights, show_caret: bool) void {
    const rs = self.rows.items;
    if (rs.len == 0) return;
    const first: usize = @min(@as(usize, @intFromFloat(@max(0, self.scroll.y / theme.line_height))), rs.len - 1);
    const last = @min(rs.len - 1, first + @as(usize, @intFromFloat(self.area.height / theme.line_height)) + 2);
    const b = buf.items();

    // Current line: a band behind the text, under the selection (on every
    // cursor's row).
    drawLineBand(self, buf, buf.cursor);
    for (buf.extra.items) |c| drawLineBand(self, buf, c.cursor);

    // Selections and marks, row by row.
    var mark: usize = 0; // first highlight that may touch the current row
    for (first..last + 1) |row| {
        const start = self.rowStart(buf, row);
        const row_text = b[start..self.rowEnd(buf, row)];
        const top = self.rowTop(row);
        const ends_line = !self.rowWraps(row);
        if (buf.selection()) |sel| drawRowRange(self, row_text, start, sel, top, ends_line, theme.selection);
        for (buf.extra.items) |c| {
            const r = c.range();
            if (r.start != r.end) drawRowRange(self, row_text, start, r, top, ends_line, theme.selection);
        }
        if (marks) |m| {
            while (mark < m.ranges.len and m.ranges[mark].end < start) mark += 1;
            var i = mark;
            while (i < m.ranges.len and m.ranges[i].start <= start + row_text.len) : (i += 1) {
                const color = theme.copy(if (m.current == i) theme.find_current else theme.find_match);
                drawRowRange(self, row_text, start, m.ranges[i], top, ends_line, color);
            }
        }
    }

    // Text, line by line (the highlighter works on whole lines).
    var row = first;
    while (row <= last) {
        const line_first = self.rowOfLine(rs[row].line);
        var line_last = row;
        while (self.rowWraps(line_last)) line_last += 1;
        const start = self.rowStart(buf, line_first);
        const line = b[start..buf.lineEnd(start)];
        var tokens = hl.tokens(rs[row].line, line);
        drawLineText(self, buf, line, start, line_first, line_last, first, last, &tokens);
        row = line_last + 1;
    }

    if (show_caret) {
        drawCaret(self, buf, buf.cursor);
        for (buf.extra.items) |c| drawCaret(self, buf, c.cursor);
    }

    // Last, so it covers text scrolled horizontally under it.
    drawGutter(self, buf, first, last);
}

pub fn drawLineBand(self: View, buf: *const Buffer, pos: usize) void {
    const y = self.screenPos(buf, pos).y;
    if (y + theme.line_height < self.area.y or y > self.bottom()) return;
    rl.drawRectangleRec(.{ .x = self.gutterRight(), .y = y, .width = self.right() - self.gutterRight(), .height = theme.line_height }, theme.current_line);
}

pub fn drawCaret(self: View, buf: *const Buffer, pos: usize) void {
    const c = self.screenPos(buf, pos);
    if (c.y + theme.line_height < self.area.y or c.y > self.bottom()) return;
    rl.drawRectangleRec(.{ .x = c.x, .y = c.y, .width = theme.caret_width, .height = theme.line_height }, theme.caret);
}

/// Line numbers, right-aligned on each line's first row, with the cursor's
/// line brighter.
pub fn drawGutter(self: View, buf: *const Buffer, first: usize, last: usize) void {
    rl.drawRectangleRec(.{ .x = self.area.x, .y = self.area.y, .width = self.gutter_width, .height = self.area.height }, theme.background);

    const w = self.font.cell_width;
    const numbers_right = self.gutterRight() - theme.gutter_gap;
    const current = buf.lineIndex(buf.cursor);
    const rs = self.rows.items;
    var digits: [20]u8 = undefined;
    for (first..last + 1) |row| {
        if (row > 0 and rs[row - 1].line == rs[row].line) continue; // a continuation row
        const index = rs[row].line;
        const number = std.fmt.bufPrint(&digits, "{d}", .{index + 1}) catch unreachable;
        const y = self.rowTop(row) + (theme.line_height - theme.font_size) / 2;
        const color = if (index == current) theme.line_number_current else theme.line_number;
        var x = numbers_right - @as(f32, @floatFromInt(number.len)) * w;
        for (number) |d| {
            self.font.drawCodepoint(d, x, y, color);
            x += w;
        }
    }
}

/// Draws a line's visible rows (`line_first..line_last` are its rows,
/// `first..last` the ones on screen), colored by its tokens.
pub fn drawLineText(self: View, buf: *const Buffer, line: []const u8, line_start: usize, line_first: usize, line_last: usize, first: usize, last: usize, tokens: *Highlighter.Tokens) void {
    const w = self.font.cell_width;
    const left = self.textLeft() - self.scroll.x;
    var row = line_first;
    var next_row_at = if (row < line_last) self.rowStart(buf, row + 1) - line_start else line.len;
    var col: usize = 0;
    while (tokens.next()) |span| {
        const color = theme.syntaxColor(span.kind);
        var i = span.start;
        while (i < span.end) {
            const n = text.nextBoundary(line, i);
            defer i = n;
            while (i >= next_row_at and row < line_last) {
                row += 1;
                col = 0;
                next_row_at = if (row < line_last) self.rowStart(buf, row + 1) - line_start else line.len;
            }
            if (row > last) return;
            const x = left + @as(f32, @floatFromInt(col)) * w;
            col = text.advance(col, line[i]);
            if (row < first) continue;
            if (x > self.right()) {
                if (row == line_last) return; // the rest is off to the right
                continue;
            }
            const c = line[i];
            if (c == ' ' or c == '\t' or x + w < self.gutterRight()) continue;
            const cp = std.unicode.utf8Decode(line[i..n]) catch 0xFFFD;
            self.font.drawCodepoint(cp, x, self.rowTop(row) + (theme.line_height - theme.font_size) / 2, color);
        }
    }
}

/// Fills the part of a row (starting at byte `start`) inside `sel`. On a
/// line's last row, a selected newline shows as a little extra.
pub fn drawRowRange(self: View, row_text: []const u8, start: usize, sel: Buffer.Range, top: f32, ends_line: bool, color: rl.Color) void {
    const end = start + row_text.len;
    if (sel.start > end or sel.end < start) return;
    const a = @max(sel.start, start) - start;
    const b = @min(sel.end, end) - start;
    const col_a: f32 = @floatFromInt(text.visualColumn(row_text[0..a]));
    var col_b: f32 = @floatFromInt(text.visualColumn(row_text[0..b]));
    if (sel.end > end and ends_line) col_b += 0.5; // the newline is selected too
    rl.drawRectangleRec(.{
        .x = self.textLeft() - self.scroll.x + col_a * self.font.cell_width,
        .y = top,
        .width = (col_b - col_a) * self.font.cell_width,
        .height = theme.line_height,
    }, color);
}
