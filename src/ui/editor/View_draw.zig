//! Drawing the text area: the text row by row with its highlighting,
//! selections and search matches, the carets and the line-number gutter.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../theme/lib/theme.zig");
const core = @import("core");
const View = @import("View.zig");
const View_diff = @import("View_diff.zig");

const Buffer = core.Buffer;
const Highlighter = core.syntax.Highlighter;
const text = core.text;

pub fn draw(self: View, buf: *const Buffer, hl: *const Highlighter, marks: ?View.Highlights, show_caret: bool, changes: ?View.Changes) void {
    const rs = self.rows.items;
    if (rs.len == 0) return;
    const first: usize = @min(@as(usize, @intFromFloat(@max(0, self.scroll.y / theme.line_height))), rs.len - 1);
    const last = @min(rs.len - 1, first + @as(usize, @intFromFloat(self.area.height / theme.line_height)) + 2);
    const b = buf.items();
    // The lines git sees as changed, under everything else.
    if (changes) |ch| View_diff.drawBands(self, ch, first, last);

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
    drawGutter(self, buf, first, last, changes);
    // The diff tab's gutter has its buttons where the fold marks go.
    const combined = if (changes) |ch| ch.combined else false;
    if (!combined) drawFolds(self, buf, hl, first, last);
    if (changes) |ch| View_diff.drawOverlay(self, ch);
}

// ------------------------------------------------------------------ folds

/// Size of a fold's mark, in the gap between the line numbers and the text.
const mark_size: f32 = 14;

fn markCenterX(self: View) f32 {
    return self.gutterRight() - theme.gutter_gap / 2;
}

/// Whether a point is on the column of fold marks.
pub fn foldMarkContains(self: View, p: rl.Vector2) bool {
    const x = markCenterX(self);
    return p.x >= x - theme.gutter_gap / 2 and p.x <= self.gutterRight() and p.y >= self.area.y and p.y <= self.bottom();
}

/// The "…" drawn after a folded line (`start` begins it, on `row`).
pub fn foldDotsRect(self: View, buf: *const Buffer, start: usize, row: usize) rl.Rectangle {
    const line = buf.items()[start..buf.lineEnd(start)];
    const col: f32 = @floatFromInt(text.visualColumn(line));
    const w = self.font.cell_width;
    return .{
        .x = self.textLeft() - self.scroll.x + (col + 1) * w,
        .y = self.rowTop(row) + 3,
        .width = 3 * w,
        .height = theme.line_height - 6,
    };
}

/// A fold's mark beside the first line of each folded block (pointing
/// right), and — while the pointer is over the gutter — beside each line
/// that could be folded (pointing down). A folded line ends with "…".
fn drawFolds(self: View, buf: *const Buffer, hl: *const Highlighter, first: usize, last: usize) void {
    const rs = self.rows.items;
    const mouse = rl.getMousePosition();
    const hover = mouse.x >= self.area.x and mouse.x <= self.gutterRight() and mouse.y >= self.area.y and mouse.y <= self.bottom();
    const x = markCenterX(self);
    for (first..last + 1) |row| {
        if (row > 0 and rs[row - 1].line == rs[row].line) continue;
        const start = rs[row].start;
        const center: rl.Vector2 = .{ .x = x, .y = self.rowTop(row) + theme.line_height / 2 };
        if (buf.isFolded(start)) {
            self.font.drawIcon(.chevron_right, center, .small, theme.line_number_current);
            const r = foldDotsRect(self, buf, start, row);
            if (r.x + r.width < self.gutterRight()) continue;
            rl.drawRectangleRounded(r, 0.4, 6, theme.accentDim(0.25));
            const dot_y = r.y + r.height / 2;
            for (0..3) |i| {
                const dx = r.x + r.width / 2 + (@as(f32, @floatFromInt(i)) - 1) * self.font.cell_width * 0.7;
                if (dx > self.gutterRight()) rl.drawCircleV(.{ .x = dx, .y = dot_y }, 1.6, theme.line_number_current);
            }
        } else if (hover and core.fold.foldable(buf, hl, start, rs[row].line)) {
            self.font.drawIcon(.chevron_down, center, .small, theme.line_number);
        }
    }
}

/// Outlines the bracket at `pos` (one of a matching pair).
pub fn drawBracket(self: View, buf: *const Buffer, pos: usize) void {
    if (self.hides(buf, pos)) return;
    const p = self.screenPos(buf, pos);
    if (p.x < self.gutterRight() or p.x > self.right() or p.y + theme.line_height < self.area.y or p.y > self.bottom()) return;
    const r: rl.Rectangle = .{ .x = p.x, .y = p.y + 1, .width = self.font.cell_width, .height = theme.line_height - 2 };
    rl.drawRectangleRec(r, theme.accentDim(0.15));
    rl.drawRectangleLinesEx(r, 1, theme.line_number);
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
pub fn drawGutter(self: View, buf: *const Buffer, first: usize, last: usize, changes: ?View.Changes) void {
    rl.drawRectangleRec(.{ .x = self.area.x, .y = self.area.y, .width = self.gutter_width, .height = self.area.height }, theme.background);

    const w = self.font.cell_width;
    const numbers_right = self.gutterRight() - theme.gutter_gap;
    const current = buf.lineIndex(buf.cursor);
    const rs = self.rows.items;
    var digits: [20]u8 = undefined;
    for (first..last + 1) |row| {
        if (row > 0 and rs[row - 1].line == rs[row].line) continue; // a continuation row
        const index = rs[row].line;
        const top = self.rowTop(row);
        const y = top + (theme.line_height - theme.font_size) / 2;
        // A changed line is marked, and takes its mark's color; in the
        // diff tab a line also keeps the number it has in its own copy.
        const g: View_diff.Gutter = if (changes) |ch|
            View_diff.drawGutter(self, ch, row, index, top)
        else
            .{ .number = @intCast(index + 1), .color = null };
        if (g.number == 0) continue;
        const number = std.fmt.bufPrint(&digits, "{d}", .{g.number}) catch unreachable;
        const color = g.color orelse if (index == current) theme.line_number_current else theme.line_number;
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
