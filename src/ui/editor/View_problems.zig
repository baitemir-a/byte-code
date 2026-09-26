//! Mistakes in the code: a wavy line under each, and what's wrong dimmed at
//! the end of its line (the first one, when a line has several).
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../theme/lib/theme.zig");
const View = @import("View.zig");

/// Space left between the line's text and the message.
const gap_cols = 4;

pub fn draw(view: View, buf: *const core.Buffer, problems: *const core.Diagnostics, message: fn ([]u8, core.Diagnostics.Item) []const u8) void {
    // Positions are only right for the text they were found in.
    if (!problems.isCurrent(buf)) return;
    var last_line: ?usize = null;
    for (problems.items.items) |it| {
        // Folded away.
        if (view.hides(buf, it.start)) continue;
        underline(view, buf, it.start, @max(it.end, it.start + 1));
        const line = buf.lineStart(it.start);
        if (last_line == line) continue;
        last_line = line;
        var text_buf: [256]u8 = undefined;
        drawMessage(view, buf, line, message(&text_buf, it));
    }
}

fn underline(view: View, buf: *const core.Buffer, start: usize, end: usize) void {
    const a = view.screenPos(buf, start);
    const b = view.screenPos(buf, end);
    if (a.y + theme.line_height < view.area.y or a.y > view.bottom()) return;
    const left = view.gutterRight();
    // Wrapped onto the next row: underline to the row's end, then from its
    // start (rows in between are rare enough to leave).
    if (b.y != a.y) {
        wave(@max(a.x, left), view.right(), a.y);
        wave(view.textLeft() - view.scroll.x, b.x, b.y);
    } else {
        wave(@max(a.x, left), @max(b.x, a.x + view.font.cell_width), a.y);
    }
}

/// A zigzag along the bottom of the row at `top`.
fn wave(x0: f32, x1: f32, top: f32) void {
    if (x1 <= x0) return;
    const y = top + theme.line_height - 3;
    const step: f32 = 2;
    var x = x0;
    var up = false;
    while (x < x1) : (up = !up) {
        const nx = @min(x + step, x1);
        const from: rl.Vector2 = .{ .x = x, .y = if (up) y - 1.5 else y + 1.5 };
        const to: rl.Vector2 = .{ .x = nx, .y = if (up) y + 1.5 else y - 1.5 };
        rl.drawLineEx(from, to, 1.2, theme.problem);
        x = nx;
    }
}

fn drawMessage(view: View, buf: *const core.Buffer, line_start: usize, text: []const u8) void {
    const p = view.screenPos(buf, buf.lineEnd(line_start));
    if (p.y + theme.line_height < view.area.y or p.y > view.bottom()) return;
    const x = @max(p.x, view.gutterRight()) + gap_cols * view.font.cell_width;
    const right = view.right() - view.font.cell_width;
    if (right - x < view.font.cell_width * 12) return;
    const c = theme.problem;
    _ = view.font.drawFit(text, x, p.y + (theme.line_height - theme.font_size) / 2, right, .{ .r = c.r, .g = c.g, .b = c.b, .a = 200 });
}
