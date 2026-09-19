//! Drawing the Search view: its boxes and toggles, the summary and Replace
//! All, and the results with the matches highlighted.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");
const file_icon = @import("../widgets/lib/file_icon.zig");
const controls = @import("../widgets/lib/search_controls.zig");
const SearchPanel = @import("SearchPanel.zig");

const row_height = theme.line_height;

/// `focus`: which box has the keyboard (0 none, 1 search, 2 replace).
pub fn draw(self: *const SearchPanel, font: Font, focus: u2, show_caret: bool, has_project: bool) void {
    const r = self.rect;
    theme.clip(r);
    defer rl.endScissorMode();
    self.query.draw(self.field_rect, font, "Search", focus == 1, show_caret);
    controls.drawToggle(font, self.match_case_rect, .match_case, self.options.match_case);
    controls.drawToggle(font, self.whole_word_rect, .whole_word, self.options.whole_word);
    self.replacement.draw(self.replace_rect, font, "Replace", focus == 2, show_caret);

    // Replace All, beside the result count.
    const b = self.replace_all_rect;
    controls.drawButton(font, b, "Replace All", self.canReplace(), true);

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
    _ = font.drawFit(summary, r.x + SearchPanel.pad, b.y + (b.height - theme.font_size) / 2, b.x - 6, theme.popup_detail);

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
            file_icon.draw(f.path[base..], .{ .x = r.x + SearchPanel.pad + file_icon.radius, .y = y + row_height / 2 });
            var count_buf: [12]u8 = undefined;
            const count = std.fmt.bufPrint(&count_buf, "{d}", .{f.count}) catch "";
            const count_x = r.x + r.width - SearchPanel.pad - @as(f32, @floatFromInt(count.len)) * font.cell_width;
            const ty = y + (row_height - theme.font_size) / 2;
            var x = font.drawFit(f.path[base..], r.x + SearchPanel.pad + file_icon.radius * 2 + 8, ty, count_x - 8, theme.foreground);
            if (base > 0) _ = font.drawFit(f.path[0 .. base - 1], x + font.cell_width, ty, count_x - 8, theme.popup_detail);
            x = count_x;
            _ = font.drawFit(count, x, ty, r.x + r.width, theme.popup_detail);
            if (hovered(mouse, r, y)) drawRowButton(self, font, y, .{ .file = 0 });
        }
        row += 1;
        // Its matches, indented, with the match highlighted.
        for (res.matches.items[f.first..][0..f.count]) |m| {
            defer row += 1;
            if (row < first_row) continue;
            if (row >= first_row + visible) break;
            const y = top + @as(f32, @floatFromInt(row)) * row_height - self.scroll;
            if (hovered(mouse, r, y)) rl.drawRectangleRec(.{ .x = r.x, .y = y, .width = r.width, .height = row_height }, theme.sidebar_hover);
            drawMatch(font, m, r.x + SearchPanel.pad + 18, y, r.x + r.width - SearchPanel.pad);
            if (hovered(mouse, r, y)) drawRowButton(self, font, y, .{ .match = 0 });
        }
    }
}

pub fn drawRowButton(self: *const SearchPanel, font: Font, y: f32, row: SearchPanel.Row) void {
    if (!self.canReplace()) return;
    const b = self.rowButton(font, y, row);
    // Cover the text under it.
    rl.drawRectangleRec(.{ .x = b.x - 6, .y = y, .width = self.rect.x + self.rect.width - b.x + 6, .height = row_height }, theme.sidebar_hover);
    controls.drawButton(font, b, SearchPanel.rowButtonLabel(row), true, false);
}

/// Tooltips for the toggles; drawn last so nothing covers them.
pub fn drawTooltip(self: *const SearchPanel, font: Font) void {
    const mouse = rl.getMousePosition();
    if (self.onToggle(mouse)) |o| controls.drawTooltip(font, if (o == .match_case) self.match_case_rect else self.whole_word_rect, o.tooltip());
}

pub fn hovered(mouse: rl.Vector2, r: rl.Rectangle, y: f32) bool {
    return mouse.x >= r.x and mouse.x < r.x + r.width and mouse.y >= y and mouse.y < y + row_height;
}

/// The matching line without its indentation, starting a little before the
/// match if the line is long, with the match on a highlight.
pub fn drawMatch(font: Font, m: core.ProjectSearch.Match, x0: f32, y: f32, max_x: f32) void {
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
