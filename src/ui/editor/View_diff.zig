//! A file's Git changes in the text area.
//!
//! While the file is being edited, each changed line gets a mark beside
//! its number: green for a new line, blue for a changed one, red where
//! lines were removed. The tab showing a file's changes holds both copies
//! of it at once: the removed lines are there in red, the added ones in
//! green, and the change under the pointer offers the buttons that undo,
//! stage or unstage it.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../theme/lib/theme.zig");
const Icons = @import("../Icons.zig");
const View = @import("View.zig");

const Diff = core.Diff;

/// The changes to show, and how: the diff tab has both copies of the file
/// in its buffer (`combined`), everywhere else the buffer is the file
/// itself and only the marks are drawn.
pub const Changes = struct {
    diff: *const Diff,
    combined: bool,
};

/// What the buttons beside a change do.
pub const Action = enum { revert, stage, unstage };

pub const Button = struct { hunk: u32, action: Action };

const button_size: f32 = 18;
const gap: f32 = 3;
/// Width of a mark in the gutter, and of the one removed lines leave.
const mark_width: f32 = 3;
const removed_mark_width: f32 = 7;

pub fn kindColor(kind: Diff.Kind) rl.Color {
    return switch (kind) {
        .added => theme.diff_added,
        .modified => theme.diff_modified,
        .deleted => theme.diff_deleted,
    };
}

/// The changes the buttons can make: a file's own changes can be undone
/// or staged; the staged ones can only be taken back out.
fn actions(ch: Changes) []const Action {
    return if (ch.diff.against == .head) &.{.unstage} else &.{ .revert, .stage };
}

/// The color a line's change is marked with, wherever it is shown: in
/// the gutter, and in the minimap. Null for a line nothing happened to.
pub fn lineColor(ch: Changes, line: usize) ?rl.Color {
    if (ch.combined) return switch (ch.diff.viewLine(line).kind) {
        .context => null,
        .removed => theme.diff_deleted,
        .added => theme.diff_added,
    };
    const i = ch.diff.hunkAt(line) orelse return null;
    return kindColor(ch.diff.hunks.items[i].kind());
}

/// The change a line of the buffer belongs to.
fn hunkOfLine(ch: Changes, line: usize) ?u32 {
    if (!ch.combined) return ch.diff.hunkAt(line);
    return ch.diff.viewLine(line).hunk;
}

// ---------------------------------------------------------- hit-testing

/// The change under the pointer, if it is over one.
pub fn hunkAt(view: View, ch: Changes, p: rl.Vector2) ?u32 {
    if (p.x < view.area.x or p.x > view.right() or p.y < view.area.y or p.y > view.bottom()) return null;
    const row = view.rowAtY(p.y);
    if (row >= view.rows.items.len) return null;
    return hunkOfLine(ch, view.rows.items[row].line);
}

/// The button under the pointer, for a click.
pub fn buttonAt(view: View, ch: Changes, p: rl.Vector2) ?Button {
    if (!ch.combined) return null;
    const hunk = hunkAt(view, ch, p) orelse return null;
    const top = buttonsTop(view, ch, hunk);
    const list = actions(ch);
    for (list, 0..) |a, i| {
        if (rl.checkCollisionPointRec(p, buttonRect(view, top, i, list.len))) return .{ .hunk = hunk, .action = a };
    }
    return null;
}

/// Where a change's buttons sit: on its first line, kept in the view when
/// the change starts above it.
fn buttonsTop(view: View, ch: Changes, hunk: u32) f32 {
    const starts = ch.diff.combined_starts.items;
    const line = if (hunk < starts.len) starts[hunk] else 0;
    const row = view.rowOfLine(line);
    return std.math.clamp(view.rowTop(row), view.area.y, view.bottom() - theme.line_height);
}

/// The buttons share the gutter with the line numbers, at its right edge.
fn buttonRect(view: View, top: f32, index: usize, count: usize) rl.Rectangle {
    const right = view.gutterRight() - gap;
    const from_right: f32 = @floatFromInt(count - index);
    return .{
        .x = right - from_right * button_size - (from_right - 1) * gap,
        .y = top + (theme.line_height - button_size) / 2,
        .width = button_size,
        .height = button_size,
    };
}

// -------------------------------------------------------------- drawing

/// The bands behind the removed and added lines of the diff tab. Under
/// the text, so it stays readable.
pub fn drawBands(view: View, ch: Changes, first: usize, last: usize) void {
    if (!ch.combined) return;
    const rows = view.rows.items;
    const left = view.gutterRight();
    const width = view.right() - left;
    for (first..last + 1) |row| {
        if (row >= rows.len) break;
        const color = switch (ch.diff.viewLine(rows[row].line).kind) {
            .context => continue,
            .removed => theme.diff_deleted_band,
            .added => theme.diff_added_band,
        };
        rl.drawRectangleRec(.{ .x = left, .y = view.rowTop(row), .width = width, .height = theme.line_height }, theme.copy(color));
    }
}

/// What the gutter shows beside a line: the number to print, and the
/// color it and its mark take (null keeps the usual one).
pub const Gutter = struct { number: u32, color: ?rl.Color };

pub fn drawGutter(view: View, ch: Changes, row: usize, line: usize, y: f32) Gutter {
    if (ch.combined) return drawCombinedGutter(view, ch, line, y);
    return drawMark(view, ch, row, line, y);
}

/// In the diff tab every line keeps the number it has in the copy it came
/// from, and the removed and added ones are marked.
fn drawCombinedGutter(view: View, ch: Changes, line: usize, y: f32) Gutter {
    const color = lineColor(ch, line);
    if (color) |c| rl.drawRectangleRec(.{ .x = view.area.x + 4, .y = y, .width = mark_width, .height = theme.line_height }, theme.copy(c));
    return .{ .number = ch.diff.viewLine(line).number, .color = color };
}

/// While editing: a bar beside the changed lines, and a stub where lines
/// were removed. The line's number takes the same color.
fn drawMark(view: View, ch: Changes, row: usize, line: usize, y: f32) Gutter {
    const number: u32 = @intCast(line + 1);
    const i = ch.diff.hunkAt(line) orelse return .{ .number = number, .color = null };
    const h = ch.diff.hunks.items[i];
    const color = kindColor(h.kind());
    const x = view.area.x + 4;
    if (h.new_len == 0) {
        // Only removed: a stub between the lines they sat between.
        rl.drawRectangleRec(.{ .x = x, .y = y - 2, .width = removed_mark_width, .height = 4 }, theme.copy(color));
        return .{ .number = number, .color = color };
    }
    // A wrapped line is several rows tall.
    var span: usize = 1;
    while (view.rowWraps(row + span - 1)) span += 1;
    const height = @as(f32, @floatFromInt(span)) * theme.line_height;
    rl.drawRectangleRec(.{ .x = x, .y = y, .width = mark_width, .height = height }, theme.copy(color));
    if (h.old_len > 0 and line == h.new_start) {
        rl.drawRectangleRec(.{ .x = x, .y = y - 1, .width = removed_mark_width, .height = 3 }, theme.diff_deleted);
    }
    return .{ .number = number, .color = color };
}

/// On top of the gutter: the buttons of the change under the pointer.
pub fn drawOverlay(view: View, ch: Changes) void {
    if (!ch.combined or ch.diff.hunks.items.len == 0) return;
    const mouse = rl.getMousePosition();
    const hunk = hunkAt(view, ch, mouse) orelse return;
    const top = buttonsTop(view, ch, hunk);
    const list = actions(ch);
    const first = buttonRect(view, top, 0, list.len);
    rl.drawRectangleRec(.{ .x = first.x - gap, .y = top, .width = view.gutterRight() - first.x + gap, .height = theme.line_height }, theme.background);
    for (list, 0..) |a, i| {
        const b = buttonRect(view, top, i, list.len);
        const hot = rl.checkCollisionPointRec(mouse, b);
        if (hot) rl.drawRectangleRounded(b, 0.3, 6, theme.tab_close_hover);
        const center: rl.Vector2 = .{ .x = b.x + b.width / 2, .y = b.y + b.height / 2 };
        const color = if (hot) theme.foreground else theme.popup_detail;
        const icon: Icons.Icon = switch (a) {
            .revert => .undo_2,
            .stage => .plus,
            .unstage => .minus,
        };
        view.font.drawIcon(icon, center, .small, theme.copy(color));
    }
}
