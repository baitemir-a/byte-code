//! The text area: scrolling, mapping between screen and buffer positions,
//! and drawing the line-number gutter and the buffer with its selection
//! and caret.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("theme.zig");
const Font = @import("Font.zig");

const Buffer = core.Buffer;
const Highlighter = core.syntax.Highlighter;
const View = @This();

font: Font,
/// Content offset in pixels; (0, 0) shows the top-left of the buffer.
scroll: rl.Vector2 = .{ .x = 0, .y = 0 },
/// Where the view draws: right of the sidebar, below the tab bar.
area: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
/// Width of the line-number gutter, and the line count it was sized for.
/// Both set by `layout`.
gutter_width: f32 = 0,
line_count: usize = 1,

/// Extra ranges to mark, e.g. search matches.
pub const Highlights = struct {
    /// Sorted, non-overlapping.
    ranges: []const Buffer.Range,
    /// Index of the emphasized range.
    current: ?usize = null,
};

pub fn init(font: Font) View {
    return .{ .font = font };
}

/// Call once per frame after the buffer changed and before hit-testing or
/// drawing: sizes the gutter to fit the largest line number.
pub fn layout(self: *View, buf: *const Buffer, area: rl.Rectangle) void {
    self.area = area;
    self.line_count = buf.lineCount();
    const digits: f32 = @floatFromInt(@max(theme.gutter_min_digits, std.math.log10_int(self.line_count) + 1));
    self.gutter_width = theme.padding + digits * self.font.cell_width + theme.gutter_gap;
}

/// Window x where column 0 of the text is drawn when not scrolled.
fn textLeft(self: View) f32 {
    return self.gutterRight() + theme.padding;
}

/// Window y of the first line when not scrolled.
fn textTop(self: View) f32 {
    return self.area.y + theme.padding;
}

/// Window x of the gutter's right edge; text scrolled left of it is hidden.
pub fn gutterRight(self: View) f32 {
    return self.area.x + self.gutter_width;
}

pub fn right(self: View) f32 {
    return self.area.x + self.area.width;
}

pub fn bottom(self: View) f32 {
    return self.area.y + self.area.height;
}

/// Number of whole lines that fit in the view.
pub fn pageLines(self: View) usize {
    const n: usize = @intFromFloat(@max(0, self.area.height / theme.line_height));
    return @max(1, n -| 1);
}

/// Buffer position under a point in window coordinates.
pub fn posAt(self: View, buf: *const Buffer, p: rl.Vector2) usize {
    const line = @max(0, (p.y + self.scroll.y - self.textTop()) / theme.line_height);
    const col = @max(0, (p.x + self.scroll.x - self.textLeft()) / self.font.cell_width + 0.5);
    return buf.posAt(@intFromFloat(line), @intFromFloat(col));
}

pub fn scrollBy(self: *View, wheel: rl.Vector2) void {
    self.scroll.y -= wheel.y * theme.line_height * 3;
    self.scroll.x -= wheel.x * self.font.cell_width * 3;
}

/// Scrolls just enough to bring the cursor into view.
pub fn revealCursor(self: *View, buf: *const Buffer) void {
    const c = self.cursorOffset(buf);
    const w = self.right() - self.textLeft() - theme.padding;
    const h = self.area.height - 2 * theme.padding;
    if (c.y < self.scroll.y) self.scroll.y = c.y;
    if (c.y + theme.line_height > self.scroll.y + h) self.scroll.y = c.y + theme.line_height - h;
    if (c.x < self.scroll.x) self.scroll.x = c.x;
    if (c.x + self.font.cell_width > self.scroll.x + w) self.scroll.x = c.x + self.font.cell_width - w;
}

/// Keeps the scroll inside the content (the last line may reach the top).
pub fn clampScroll(self: *View, buf: *const Buffer) void {
    const lines: f32 = @floatFromInt(buf.lineCount());
    self.scroll.y = std.math.clamp(self.scroll.y, 0, @max(0, (lines - 1) * theme.line_height));
    self.scroll.x = @max(0, self.scroll.x);
}

/// Top-left corner of the character at `pos`, in window coordinates.
pub fn screenPos(self: View, buf: *const Buffer, pos: usize) rl.Vector2 {
    const o = self.contentOffset(buf, pos);
    return .{ .x = self.textLeft() + o.x - self.scroll.x, .y = self.textTop() + o.y - self.scroll.y };
}

fn cursorOffset(self: View, buf: *const Buffer) rl.Vector2 {
    return self.contentOffset(buf, buf.cursor);
}

/// Position of `pos` in content pixels (before scrolling and padding).
fn contentOffset(self: View, buf: *const Buffer, pos: usize) rl.Vector2 {
    const line: f32 = @floatFromInt(buf.lineIndex(pos));
    const col: f32 = @floatFromInt(buf.column(pos));
    return .{ .x = col * self.font.cell_width, .y = line * theme.line_height };
}

// ---------------------------------------------------------------- drawing

pub fn draw(self: View, buf: *const Buffer, hl: *const Highlighter, marks: ?Highlights, show_caret: bool) void {
    const first: usize = @intFromFloat(@max(0, self.scroll.y / theme.line_height));
    const last = first + @as(usize, @intFromFloat(self.area.height / theme.line_height)) + 2;

    // Current line: a band behind the text, under the selection.
    const cursor_y = self.screenPos(buf, buf.cursor).y;
    rl.drawRectangleRec(.{ .x = self.gutterRight(), .y = cursor_y, .width = self.right() - self.gutterRight(), .height = theme.line_height }, theme.current_line);

    var lines = std.mem.splitScalar(u8, buf.items(), '\n');
    var index: usize = 0;
    var start: usize = 0;
    var mark: usize = 0; // first highlight that may touch the current line
    while (lines.next()) |line| : ({
        index += 1;
        start += line.len + 1;
    }) {
        if (index < first) continue;
        if (index > last) break;
        const top = self.textTop() + @as(f32, @floatFromInt(index)) * theme.line_height - self.scroll.y;
        if (buf.selection()) |sel| self.drawLineRange(line, start, sel, top, theme.selection);
        if (marks) |m| {
            while (mark < m.ranges.len and m.ranges[mark].end < start) mark += 1;
            var i = mark;
            while (i < m.ranges.len and m.ranges[i].start <= start + line.len) : (i += 1) {
                const color = if (m.current == i) theme.find_current else theme.find_match;
                self.drawLineRange(line, start, m.ranges[i], top, color);
            }
        }
        var tokens = hl.tokens(index, line);
        self.drawLineText(line, &tokens, top);
    }

    if (show_caret) {
        const c = self.screenPos(buf, buf.cursor);
        rl.drawRectangleRec(.{ .x = c.x, .y = c.y, .width = theme.caret_width, .height = theme.line_height }, theme.caret);
    }

    // Last, so it covers text scrolled horizontally under it.
    self.drawGutter(buf, first, last);
}

/// Line numbers, right-aligned, with the cursor's line brighter.
fn drawGutter(self: View, buf: *const Buffer, first: usize, last: usize) void {
    rl.drawRectangleRec(.{ .x = self.area.x, .y = self.area.y, .width = self.gutter_width, .height = self.area.height }, theme.background);

    const w = self.font.cell_width;
    const numbers_right = self.gutterRight() - theme.gutter_gap;
    const current = buf.lineIndex(buf.cursor);
    var digits: [20]u8 = undefined;
    for (@min(first, self.line_count)..@min(last + 1, self.line_count)) |index| {
        const number = std.fmt.bufPrint(&digits, "{d}", .{index + 1}) catch unreachable;
        const top = self.textTop() + @as(f32, @floatFromInt(index)) * theme.line_height - self.scroll.y;
        const y = top + (theme.line_height - theme.font_size) / 2;
        const color = if (index == current) theme.line_number_current else theme.line_number;
        var x = numbers_right - @as(f32, @floatFromInt(number.len)) * w;
        for (number) |d| {
            self.font.drawCodepoint(d, x, y, color);
            x += w;
        }
    }
}

fn drawLineText(self: View, line: []const u8, tokens: *Highlighter.Tokens, top: f32) void {
    const w = self.font.cell_width;
    const y = top + (theme.line_height - theme.font_size) / 2;
    const left = self.textLeft() - self.scroll.x;
    var col: usize = 0;
    while (tokens.next()) |span| {
        const color = theme.syntaxColor(span.kind);
        var it = std.unicode.Utf8View.initUnchecked(line[span.start..span.end]).iterator();
        while (it.nextCodepoint()) |cp| {
            const x = left + @as(f32, @floatFromInt(col)) * w;
            if (x > self.right()) return;
            col = if (cp == '\t') core.text.advance(col, '\t') else col + 1;
            if (cp == ' ' or cp == '\t' or x + w < self.gutterRight()) continue;
            self.font.drawCodepoint(cp, x, y, color);
        }
    }
}

/// Fills the part of `line` (starting at byte `start`) inside `sel`.
fn drawLineRange(self: View, line: []const u8, start: usize, sel: Buffer.Range, top: f32, color: rl.Color) void {
    const end = start + line.len;
    if (sel.start > end or sel.end < start) return;
    const a = @max(sel.start, start) - start;
    const b = @min(sel.end, end) - start;
    const col_a: f32 = @floatFromInt(core.text.visualColumn(line[0..a]));
    var col_b: f32 = @floatFromInt(core.text.visualColumn(line[0..b]));
    if (sel.end > end) col_b += 0.5; // the newline is selected too
    rl.drawRectangleRec(.{
        .x = self.textLeft() - self.scroll.x + col_a * self.font.cell_width,
        .y = top,
        .width = (col_b - col_a) * self.font.cell_width,
        .height = theme.line_height,
    }, color);
}
