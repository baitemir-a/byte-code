//! The suggestions list drawn under the cursor. `layout` runs during update
//! (so clicks can be hit-tested), `draw` just paints the result.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../theme/lib/theme.zig");
const View = @import("View.zig");

const Completion = core.Completion;
const Popup = @This();

pub const max_rows = 8;
const row_height = theme.line_height;
const icon_cols = 2; // kind letter + gap
const detail_cols = 9; // "function"
const pad = 6;

/// Where the popup is on screen; empty when hidden.
rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
/// Index of the first visible item (the list scrolls with the selection).
first: usize = 0,
visible: bool = false,

pub fn layout(self: *Popup, c: *const Completion, view: *const View, buf: *const core.Buffer) void {
    self.visible = c.is_open and c.items.items.len > 0;
    if (!self.visible) return;

    const n = c.items.items.len;
    const rows = @min(n, max_rows);
    if (c.selected < self.first) self.first = c.selected;
    if (c.selected >= self.first + rows) self.first = c.selected + 1 - rows;
    self.first = @min(self.first, n - rows);

    var longest: usize = 0;
    for (c.items.items) |it| longest = @max(longest, core.text.codepointCount(it.label));
    const cw = view.font.cell_width;
    const cols: f32 = @floatFromInt(icon_cols + longest + 2 + detail_cols);
    const w = std.math.clamp(cols * cw + 2 * pad, 200, 520);
    const h = @as(f32, @floatFromInt(rows)) * row_height + 2;

    // Align the labels with the word being completed; open above the cursor
    // when there's no room below.
    const word = view.screenPos(buf, c.word_start);
    var x = word.x - pad - icon_cols * cw;
    var y = word.y + theme.line_height;
    if (y + h > view.bottom() and word.y - h > view.area.y) y = word.y - h;
    x = std.math.clamp(x, view.area.x, @max(view.area.x, view.right() - w));

    self.rect = .{ .x = x, .y = y, .width = w, .height = h };
}

pub fn contains(self: *const Popup, p: rl.Vector2) bool {
    return self.visible and rl.checkCollisionPointRec(p, self.rect);
}

/// Item index under a point, if it's on a row.
pub fn itemAt(self: *const Popup, c: *const Completion, p: rl.Vector2) ?usize {
    if (!self.contains(p)) return null;
    const row: usize = @intFromFloat((p.y - self.rect.y - 1) / row_height);
    const i = self.first + row;
    return if (i < c.items.items.len) i else null;
}

pub fn draw(self: *const Popup, c: *const Completion, view: *const View) void {
    if (!self.visible) return;
    const r = self.rect;
    const cw = view.font.cell_width;

    // Shadow, background, border.
    rl.drawRectangleRec(.{ .x = r.x + 3, .y = r.y + 4, .width = r.width, .height = r.height }, theme.popup_shadow);
    rl.drawRectangleRec(r, theme.popup_background);
    rl.drawRectangleLinesEx(r, 1, theme.popup_border);

    const rows = @min(c.items.items.len - self.first, max_rows);
    for (0..rows) |row| {
        const i = self.first + row;
        const item = c.items.items[i];
        const top = r.y + 1 + @as(f32, @floatFromInt(row)) * row_height;
        const text_y = top + (row_height - theme.font_size) / 2;

        if (i == c.selected) {
            rl.drawRectangleRec(.{ .x = r.x + 1, .y = top, .width = r.width - 2, .height = row_height }, theme.accentDim(0.35));
        }

        var x = r.x + pad;
        view.font.drawCodepoint(kindLetter(item.kind), x, text_y, kindColor(item.kind));
        x += icon_cols * cw;

        // Label, with the characters that matched the typed word emphasized.
        var it = std.unicode.Utf8View.initUnchecked(item.label).iterator();
        var byte: usize = 0;
        while (it.nextCodepointSlice()) |slice| : (byte += slice.len) {
            const cp = std.unicode.utf8Decode(slice) catch '?';
            const matched = byte < 64 and item.matches & (@as(u64, 1) << @intCast(byte)) != 0;
            if (x + cw > r.x + r.width - pad) break;
            view.font.drawCodepoint(cp, x, text_y, if (matched) theme.accent else theme.foreground);
            x += cw;
        }

        // Kind name on the right, for the selected row only (keeps it calm).
        if (i == c.selected) {
            const name = @tagName(item.kind);
            var dx = r.x + r.width - pad - @as(f32, @floatFromInt(name.len)) * cw;
            if (dx > x + cw) for (name) |ch| {
                view.font.drawCodepoint(ch, dx, text_y, theme.popup_detail);
                dx += cw;
            };
        }
    }
}

fn kindLetter(k: Completion.ItemKind) u21 {
    return switch (k) {
        .keyword => 'k',
        .type => 'T',
        .function => 'f',
        .variable => 'v',
        .member => 'm',
    };
}

fn kindColor(k: Completion.ItemKind) rl.Color {
    return theme.syntaxColor(switch (k) {
        .keyword => .keyword,
        .type => .type,
        .function => .function,
        .variable => .constant,
        .member => .plain,
    });
}
