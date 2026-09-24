//! The conflicts a merge left in the file being edited: each side gets a
//! band of its own color, and the `<<<<<<<` line offers to keep the
//! current side, the incoming one, or both.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../theme/lib/theme.zig");
const View = @import("View.zig");
const i18n = @import("../../i18n/i18n.zig");

const Buffer = core.Buffer;
const Region = core.Conflicts.Region;
const Choice = core.Conflicts.Choice;

pub const Button = struct { region: u32, choice: Choice };

const choices = [_]Choice{ .current, .incoming, .both };
const button_pad: f32 = 6;
const button_gap: f32 = 6;

fn label(choice: Choice) []const u8 {
    const t = i18n.tr().git;
    return switch (choice) {
        .current => t.accept_current,
        .incoming => t.accept_incoming,
        .both => t.accept_both,
    };
}

/// A translucent version of a color, for a band the text shows through.
fn tint(c: rl.Color, alpha: u8) rl.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = alpha };
}

/// The bands, under the text: the markers stronger, each side lighter.
pub fn drawBands(view: View, regions: []const Region) void {
    const current = theme.diff_added;
    const incoming = theme.accent;
    for (regions) |r| {
        band(view, r.start, r.start + 1, tint(current, 90));
        band(view, r.start + 1, r.base, tint(current, 36));
        band(view, r.base, r.separator, tint(theme.popup_detail, 28)); // what both started from
        band(view, r.separator, r.separator + 1, tint(theme.popup_detail, 60));
        band(view, r.separator + 1, r.end, tint(incoming, 36));
        band(view, r.end, r.end + 1, tint(incoming, 90));
    }
}

/// Lines `first` up to (not including) `end`.
fn band(view: View, first: u32, end: u32, color: rl.Color) void {
    if (end <= first) return;
    const top = view.rowTop(view.rowOfLine(first));
    // The last line may wrap onto more rows.
    var last = view.rowOfLine(end - 1);
    while (view.rowWraps(last)) last += 1;
    const bottom = view.rowTop(last) + theme.line_height;
    if (bottom < view.area.y or top > view.bottom()) return;
    const left = view.gutterRight();
    rl.drawRectangleRec(.{ .x = left, .y = top, .width = view.right() - left, .height = bottom - top }, color);
}

/// Where a region's buttons go: on its `<<<<<<<` line, after the marker.
fn buttonRect(view: View, buf: *const Buffer, r: Region, index: usize) rl.Rectangle {
    const line_start = r.from;
    const marker = buf.items()[line_start..buf.lineEnd(line_start)];
    const row = view.rowOfLine(r.start);
    var x = view.textLeft() - view.scroll.x + @as(f32, @floatFromInt(core.text.visualColumn(marker) + 2)) * view.font.cell_width;
    for (choices[0..index]) |c| x += view.font.textWidth(label(c)) + 2 * button_pad + button_gap;
    return .{ .x = x, .y = view.rowTop(row) + 2, .width = view.font.textWidth(label(choices[index])) + 2 * button_pad, .height = theme.line_height - 4 };
}

fn visible(view: View, rect: rl.Rectangle) bool {
    return rect.y + rect.height > view.area.y and rect.y < view.bottom() and rect.x + rect.width > view.gutterRight();
}

pub fn buttonAt(view: View, buf: *const Buffer, regions: []const Region, p: rl.Vector2) ?Button {
    if (p.x < view.gutterRight() or p.x > view.right() or p.y < view.area.y or p.y > view.bottom()) return null;
    for (regions, 0..) |r, i| {
        for (choices, 0..) |c, n| {
            const rect = buttonRect(view, buf, r, n);
            if (visible(view, rect) and rl.checkCollisionPointRec(p, rect)) return .{ .region = @intCast(i), .choice = c };
        }
    }
    return null;
}

/// Over the text: the buttons.
pub fn drawButtons(view: View, buf: *const Buffer, regions: []const Region) void {
    const mouse = rl.getMousePosition();
    theme.clip(.{ .x = view.gutterRight(), .y = view.area.y, .width = view.right() - view.gutterRight(), .height = view.area.height });
    defer rl.endScissorMode();
    for (regions) |r| {
        for (choices, 0..) |c, n| {
            const rect = buttonRect(view, buf, r, n);
            if (!visible(view, rect)) continue;
            const hot = rl.checkCollisionPointRec(mouse, rect);
            rl.drawRectangleRounded(rect, 0.3, 6, theme.copy(if (hot) theme.accent else theme.popup_background));
            rl.drawRectangleRoundedLinesEx(rect, 0.3, 6, 1, theme.popup_border);
            _ = view.font.drawText(label(c), rect.x + button_pad, rect.y + (rect.height - theme.font_size) / 2, theme.font_size, theme.copy(if (hot) theme.background else theme.foreground));
        }
    }
}
