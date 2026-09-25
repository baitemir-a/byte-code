//! "Go to file" (Cmd+P): a search box at the top of the editor listing the
//! project's files that match what's typed. Enter or a click opens one.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("theme/lib/theme.zig");
const anim = @import("anim.zig");
const Font = @import("Font.zig");
const TextField = @import("widgets/TextField.zig");
const file_icon = @import("widgets/lib/file_icon.zig");
const i18n = @import("../i18n/i18n.zig");

const QuickOpen = @This();

pub const max_rows = 12;
const row_height = theme.line_height + 4;
const pad: f32 = 8;

gpa: std.mem.Allocator,
is_open: bool = false,
query: TextField,
results: std.ArrayList(core.FileSearch.Result) = .empty,
selected: usize = 0,
/// First result shown (the list scrolls with the selection).
first: usize = 0,
/// Layout, for drawing and clicks.
rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
field_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),

pub fn init(gpa: std.mem.Allocator) QuickOpen {
    return .{ .gpa = gpa, .query = .init(gpa) };
}

pub fn deinit(self: *QuickOpen) void {
    self.query.deinit();
    self.results.deinit(self.gpa);
}

/// Opens with an empty query, listing `search`'s files.
pub fn open(self: *QuickOpen, search: *const core.FileSearch) !void {
    self.is_open = true;
    try self.query.setText("");
    try self.refresh(search);
}

pub fn close(self: *QuickOpen) void {
    self.is_open = false;
}

/// Re-runs the search after the query changed.
pub fn refresh(self: *QuickOpen, search: *const core.FileSearch) !void {
    try search.search(self.query.text(), &self.results, 200);
    self.selected = 0;
    self.first = 0;
}

pub fn selectedFile(self: *const QuickOpen) ?u32 {
    if (self.results.items.len == 0) return null;
    return self.results.items[self.selected].file;
}

pub fn moveSelection(self: *QuickOpen, delta: isize) void {
    const n: isize = @intCast(self.results.items.len);
    if (n == 0) return;
    self.selected = @intCast(std.math.clamp(@as(isize, @intCast(self.selected)) + delta, 0, n - 1));
}

/// Centered at the top of `area` (the editor column).
pub fn layout(self: *QuickOpen, area: rl.Rectangle, font: Font) void {
    if (!self.is_open) return;
    const w = @min(640, area.width - 40);
    const rows = @min(self.results.items.len, max_rows);
    if (self.selected < self.first) self.first = self.selected;
    if (self.selected >= self.first + max_rows) self.first = self.selected + 1 - max_rows;
    const field_h = theme.line_height + 10;
    const list_h = @as(f32, @floatFromInt(@max(rows, 1))) * row_height;
    self.rect = .{ .x = area.x + (area.width - w) / 2, .y = area.y + 6, .width = w, .height = pad * 2 + field_h + 6 + list_h };
    self.field_rect = .{ .x = self.rect.x + pad, .y = self.rect.y + pad, .width = w - 2 * pad, .height = field_h };
    self.query.layout(self.field_rect.width, font);
}

pub fn contains(self: *const QuickOpen, p: rl.Vector2) bool {
    return self.is_open and rl.checkCollisionPointRec(p, self.rect);
}

fn listTop(self: *const QuickOpen) f32 {
    return self.field_rect.y + self.field_rect.height + 6;
}

/// Result index under a point.
pub fn itemAt(self: *const QuickOpen, p: rl.Vector2) ?usize {
    if (!self.contains(p) or p.y < self.listTop()) return null;
    const i = self.first + @as(usize, @intFromFloat((p.y - self.listTop()) / row_height));
    return if (i < self.results.items.len) i else null;
}

pub fn draw(self: *const QuickOpen, search: *const core.FileSearch, font: Font, show_caret: bool, has_project: bool) void {
    const t = anim.ease(anim.fade(anim.hash("quick_open", 0), self.is_open, anim.popup_speed));
    if (!self.is_open or t <= 0) return;
    // It comes down from the top of the editor as it fades in.
    rl.gl.rlPushMatrix();
    defer rl.gl.rlPopMatrix();
    rl.gl.rlTranslatef(0, -(1 - t) * 10, 0);
    const r = self.rect;
    rl.drawRectangleRec(.{ .x = r.x + 3, .y = r.y + 5, .width = r.width, .height = r.height }, anim.alpha(theme.popup_shadow, t));
    rl.drawRectangleRec(r, anim.alpha(theme.popup_background, t));
    rl.drawRectangleLinesEx(r, 1, anim.alpha(theme.popup_border, t));
    self.query.draw(self.field_rect, font, i18n.tr().quick_open.placeholder, true, show_caret);

    const cw = font.cell_width;
    const top = self.listTop();
    if (self.results.items.len == 0) {
        const msg = if (!has_project) i18n.tr().quick_open.open_folder_first else i18n.tr().quick_open.no_matches;
        _ = drawText(font, msg, r.x + pad + 4, top + (row_height - theme.font_size) / 2, theme.popup_detail, 0, 0);
        return;
    }
    const rows = @min(self.results.items.len - self.first, max_rows);
    for (0..rows) |row| {
        const i = self.first + row;
        const res = self.results.items[i];
        const path = search.files.items[res.file];
        const y = top + @as(f32, @floatFromInt(row)) * row_height;
        if (i == self.selected) rl.drawRectangleRec(.{ .x = r.x + 2, .y = y, .width = r.width - 4, .height = row_height }, theme.accentDim(0.35));
        const ty = y + (row_height - theme.font_size) / 2;

        // "Name.zig   src/ui" with matched characters in the accent color.
        const base_start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| s + 1 else 0;
        file_icon.draw(path[base_start..], .{ .x = r.x + pad + 4 + file_icon.size / 2, .y = y + row_height / 2 });
        const name_x = r.x + pad + 4 + file_icon.size + 8;
        var x = drawText(font, path[base_start..], name_x, ty, theme.foreground, res.matches, base_start);
        if (base_start > 0) {
            x += cw * 2;
            _ = drawText(font, path[0 .. base_start - 1], x, ty, theme.popup_detail, res.matches, 0);
        }
    }
}

/// Draws `s` (bytes `offset..` of the path, for the match bitmask) and
/// returns where it ended.
fn drawText(font: Font, s: []const u8, x0: f32, y: f32, color: rl.Color, matches: u64, offset: usize) f32 {
    var x = x0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    var byte: usize = offset;
    while (it.nextCodepointSlice()) |slice| : (byte += slice.len) {
        const cp = std.unicode.utf8Decode(slice) catch '?';
        const matched = byte < 64 and matches & (@as(u64, 1) << @intCast(byte)) != 0;
        if (cp != ' ') font.drawCodepoint(cp, x, y, if (matched) theme.accent else color);
        x += font.cell_width;
    }
    return x;
}
