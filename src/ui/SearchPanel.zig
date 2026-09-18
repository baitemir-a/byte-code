//! The sidebar's Search view: a query box and every match in the project,
//! grouped by file. Click a match to open it with the match selected.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("theme.zig");
const Font = @import("Font.zig");
const TextField = @import("TextField.zig");
const file_icon = @import("file_icon.zig");

const SearchPanel = @This();

const row_height = theme.line_height;
const pad: f32 = 8;

/// A clicked row: a file (open it) or one of its matches (open and select it).
pub const Row = union(enum) { file: u32, match: u32 };

query: TextField,
results: core.ProjectSearch,
/// The query the results are for; they're re-run when it changes.
searched_for: std.ArrayList(u8) = .empty,
/// When the query last changed: the search runs once typing pauses.
changed_at: ?f64 = null,
rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
field_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
scroll: f32 = 0,
max_scroll: f32 = 0,

pub fn init(gpa: std.mem.Allocator) SearchPanel {
    return .{ .query = .init(gpa), .results = .init(gpa) };
}

pub fn deinit(self: *SearchPanel) void {
    self.query.deinit();
    self.results.deinit();
    self.searched_for.deinit(self.results.gpa);
}

fn listTop(self: *const SearchPanel) f32 {
    return self.field_rect.y + self.field_rect.height + row_height + 4;
}

fn rowCount(self: *const SearchPanel) usize {
    return self.results.files.items.len + self.results.matches.items.len;
}

pub fn layout(self: *SearchPanel, rect: rl.Rectangle, font: Font) void {
    self.rect = rect;
    self.field_rect = .{ .x = rect.x + pad, .y = rect.y + pad, .width = rect.width - 2 * pad, .height = theme.line_height + 8 };
    self.query.layout(self.field_rect.width, font);
    const content = @as(f32, @floatFromInt(self.rowCount())) * row_height;
    self.max_scroll = @max(0, content - (rect.y + rect.height - self.listTop()));
    self.scroll = std.math.clamp(self.scroll, 0, self.max_scroll);
}

pub fn scrollBy(self: *SearchPanel, wheel_y: f32) void {
    self.scroll = std.math.clamp(self.scroll - wheel_y * row_height * 3, 0, self.max_scroll);
}

pub fn onField(self: *const SearchPanel, p: rl.Vector2) bool {
    return rl.checkCollisionPointRec(p, self.field_rect);
}

/// The file or match row under a point.
pub fn rowAt(self: *const SearchPanel, p: rl.Vector2) ?Row {
    if (p.y < self.listTop() or !rl.checkCollisionPointRec(p, self.rect)) return null;
    var row: usize = @intFromFloat((p.y - self.listTop() + self.scroll) / row_height);
    for (self.results.files.items, 0..) |f, i| {
        if (row == 0) return .{ .file = @intCast(i) };
        row -= 1;
        if (row < f.count) return .{ .match = f.first + @as(u32, @intCast(row)) };
        row -= f.count;
    }
    return null;
}

pub fn draw(self: *const SearchPanel, font: Font, focused: bool, show_caret: bool, has_project: bool) void {
    const r = self.rect;
    theme.clip(r);
    defer rl.endScissorMode();
    self.query.draw(self.field_rect, font, "Search", focused, show_caret);

    // Summary under the box.
    var buf: [64]u8 = undefined;
    const res = &self.results;
    const summary = if (!has_project)
        "Open a folder to search in it"
    else if (self.searched_for.items.len == 0)
        ""
    else if (res.matches.items.len == 0)
        "No results"
    else
        std.fmt.bufPrint(&buf, "{d}{s} results in {d} files", .{ res.matches.items.len, if (res.truncated) "+" else "", res.files.items.len }) catch "";
    _ = font.drawFit(summary, r.x + pad, self.field_rect.y + self.field_rect.height + 4, r.x + r.width - pad, theme.popup_detail);

    const top = self.listTop();
    theme.clip(.{ .x = r.x, .y = top, .width = r.width, .height = r.y + r.height - top });
    const mouse = rl.getMousePosition();
    const first_row: usize = @intFromFloat(self.scroll / row_height);
    const visible: usize = @intFromFloat(r.height / row_height + 2);
    var row: usize = 0;
    for (res.files.items) |f| {
        if (row >= first_row + visible) break;
        // File header: icon, name, folder (dimmed), match count.
        if (row >= first_row) {
            const y = top + @as(f32, @floatFromInt(row)) * row_height - self.scroll;
            const base = if (std.mem.lastIndexOfScalar(u8, f.path, '/')) |i| i + 1 else 0;
            if (hovered(mouse, r, y)) rl.drawRectangleRec(.{ .x = r.x, .y = y, .width = r.width, .height = row_height }, theme.sidebar_hover);
            file_icon.draw(f.path[base..], .{ .x = r.x + pad + file_icon.radius, .y = y + row_height / 2 });
            var count_buf: [12]u8 = undefined;
            const count = std.fmt.bufPrint(&count_buf, "{d}", .{f.count}) catch "";
            const count_x = r.x + r.width - pad - @as(f32, @floatFromInt(count.len)) * font.cell_width;
            const ty = y + (row_height - theme.font_size) / 2;
            var x = font.drawFit(f.path[base..], r.x + pad + file_icon.radius * 2 + 8, ty, count_x - 8, theme.foreground);
            if (base > 0) _ = font.drawFit(f.path[0 .. base - 1], x + font.cell_width, ty, count_x - 8, theme.popup_detail);
            x = count_x;
            _ = font.drawFit(count, x, ty, r.x + r.width, theme.popup_detail);
        }
        row += 1;
        // Its matches, indented, with the match highlighted.
        for (res.matches.items[f.first..][0..f.count]) |m| {
            defer row += 1;
            if (row < first_row) continue;
            if (row >= first_row + visible) break;
            const y = top + @as(f32, @floatFromInt(row)) * row_height - self.scroll;
            if (hovered(mouse, r, y)) rl.drawRectangleRec(.{ .x = r.x, .y = y, .width = r.width, .height = row_height }, theme.sidebar_hover);
            drawMatch(font, m, r.x + pad + 18, y, r.x + r.width - pad);
        }
    }
}

fn hovered(mouse: rl.Vector2, r: rl.Rectangle, y: f32) bool {
    return mouse.x >= r.x and mouse.x < r.x + r.width and mouse.y >= y and mouse.y < y + row_height;
}

/// The matching line without its indentation, starting a little before the
/// match if the line is long, with the match on a highlight.
fn drawMatch(font: Font, m: core.ProjectSearch.Match, x0: f32, y: f32, max_x: f32) void {
    const text = m.preview;
    var start: usize = 0;
    while (start < m.preview_start and (text[start] == ' ' or text[start] == '\t')) start += 1;
    // Keep the match in view: skip ahead so it starts within the first third.
    const cols: usize = @intFromFloat(@max(1, (max_x - x0) / font.cell_width));
    if (m.preview_start - start > cols / 3) start = m.preview_start - cols / 3;
    while (start < text.len and start > 0 and (text[start] & 0xC0) == 0x80) start += 1;

    const ty = y + (row_height - theme.font_size) / 2;
    const match_x = x0 + @as(f32, @floatFromInt(std.unicode.utf8CountCodepoints(text[start..m.preview_start]) catch 0)) * font.cell_width;
    const match_w = @as(f32, @floatFromInt(std.unicode.utf8CountCodepoints(text[m.preview_start..m.preview_end]) catch 0)) * font.cell_width;
    if (match_x < max_x) rl.drawRectangleRec(.{ .x = match_x, .y = y + 3, .width = @min(match_w, max_x - match_x), .height = row_height - 6 }, theme.find_current);
    _ = font.drawFit(text[start..], x0, ty, max_x, theme.foreground);
}
