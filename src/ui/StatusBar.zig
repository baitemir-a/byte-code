//! The bar along the bottom of the window: who last touched the line the
//! cursor is on (author, how long ago, the commit and its message), and
//! where the cursor is. Hovering the blame shows the commit's exact date
//! and time.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("theme/lib/theme.zig");
const Font = @import("Font.zig");

const StatusBar = @This();

pub const height: f32 = theme.line_height + 8;
const pad: f32 = 12;
/// Space around the "·" between the parts.
const gap: f32 = 8;

/// What git says about the line the cursor is on. The strings are made
/// fresh each frame by the caller.
pub const Blame = struct {
    author: []const u8,
    /// How long ago, in the interface's language ("3 d ago").
    age: []const u8,
    /// The short commit hash, empty for a line that isn't committed yet.
    hash: []const u8,
    summary: []const u8,
    /// The date and time the popup shows.
    exact: []const u8,
};

rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),

/// The bar sits across the bottom; everything else is laid out above it.
pub fn layout(self: *StatusBar, window: rl.Vector2) void {
    self.rect = .{ .x = 0, .y = window.y - height, .width = window.x, .height = height };
}

pub fn contains(self: *const StatusBar, p: rl.Vector2) bool {
    return rl.checkCollisionPointRec(p, self.rect);
}

pub fn draw(self: *const StatusBar, font: Font, blame: ?Blame, position: []const u8) void {
    const r = self.rect;
    rl.drawRectangleRec(r, theme.tab_bar_background);
    rl.drawRectangleRec(.{ .x = r.x, .y = r.y, .width = r.width, .height = 1 }, theme.sidebar_border);
    const y = r.y + (height - theme.font_size) / 2;

    // Where the cursor is, at the right end.
    const position_w = font.textWidth(position);
    const right = r.x + r.width - pad;
    _ = font.drawFit(position, right - position_w, y, right, theme.popup_detail);

    const b = blame orelse return;
    const end = right - position_w - 2 * gap;
    var x = r.x + pad;
    x = font.drawFit(b.author, x, y, end, theme.foreground);
    x = separator(font, x, y, end);
    x = font.drawFit(b.age, x, y, end, theme.popup_detail);
    if (b.hash.len > 0) {
        x = separator(font, x, y, end);
        x = font.drawFit(b.hash, x, y, end, theme.git_renamed);
    }
    if (b.summary.len > 0) {
        x = separator(font, x, y, end);
        x = font.drawFit(b.summary, x, y, end, theme.popup_detail);
    }
    // The date hangs off the blame text: everything up to where it ends.
    const over_text: rl.Rectangle = .{ .x = r.x, .y = r.y, .width = @min(x, end) - r.x, .height = height };
    if (rl.checkCollisionPointRec(rl.getMousePosition(), over_text)) drawPopup(font, r, b.exact);
}

fn separator(font: Font, x: f32, y: f32, end: f32) f32 {
    if (x + gap >= end) return x;
    font.drawCodepoint('·', x + gap, y, theme.popup_border);
    return x + 2 * gap + font.cell_width;
}

/// The commit's exact date and time, in a box that sits on top of the
/// bar so it doesn't cover what the bar says.
fn drawPopup(font: Font, bar: rl.Rectangle, text: []const u8) void {
    if (text.len == 0) return;
    const window_width = @as(f32, @floatFromInt(rl.getScreenWidth())) / theme.zoom;
    const w = font.textWidth(text) + 16;
    const x = std.math.clamp(rl.getMousePosition().x - w / 2, 4, @max(4, window_width - w - 4));
    const r: rl.Rectangle = .{ .x = x, .y = bar.y - theme.line_height - 6, .width = w, .height = theme.line_height };
    rl.drawRectangleRec(.{ .x = r.x + 2, .y = r.y + 3, .width = r.width, .height = r.height }, theme.popup_shadow);
    rl.drawRectangleRec(r, theme.popup_background);
    rl.drawRectangleLinesEx(r, 1, theme.popup_border);
    _ = font.drawFit(text, r.x + 8, r.y + (theme.line_height - theme.font_size) / 2, r.x + r.width - 4, theme.foreground);
}
