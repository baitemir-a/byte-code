//! Drawing the find bar: its boxes, toggles, buttons, match counter and
//! tooltips.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../theme/lib/theme.zig");
const View = @import("View.zig");
const controls = @import("../widgets/lib/search_controls.zig");
const core = @import("core");
const FindBar = @import("FindBar.zig");

const Buffer = core.Buffer;

pub fn draw(self: *const FindBar, view: *const View, editor: *const Buffer, show_caret: bool) void {
    if (!self.is_open) return;
    const r = self.rect;
    rl.drawRectangleRec(.{ .x = r.x + 3, .y = r.y + 4, .width = r.width, .height = r.height }, theme.popup_shadow);
    rl.drawRectangleRec(r, theme.popup_background);
    rl.drawRectangleLinesEx(r, 1, theme.popup_border);

    self.query.draw(self.query_rect, view.font, "Find", self.focus == .query, show_caret);
    controls.drawToggle(view.font, self.match_case_rect, .match_case, self.options.match_case);
    controls.drawToggle(view.font, self.whole_word_rect, .whole_word, self.options.whole_word);
    if (self.show_replace) {
        self.replacement.draw(self.replace_rect, view.font, "Replace", self.focus == .replacement, show_caret);
        const enabled = self.canReplace();
        controls.drawButton(view.font, self.replace_one_rect, "Replace", enabled, false);
        controls.drawButton(view.font, self.replace_all_rect, "Replace All", enabled, false);
    }

    // "3 of 12", "12 found" or "No results" next to the query box.
    var buf: [32]u8 = undefined;
    const n = self.search.matches.items.len;
    const current = if (editor.selection()) |sel| self.search.indexOf(sel) else null;
    const label, const color = if (self.query.text().len == 0)
        .{ "", theme.popup_detail }
    else if (n == 0)
        .{ "No results", theme.find_no_results }
    else if (current) |i|
        .{ std.fmt.bufPrint(&buf, "{d} of {d}", .{ i + 1, n }) catch "", theme.popup_detail }
    else
        .{ std.fmt.bufPrint(&buf, "{d} found", .{n}) catch "", theme.popup_detail };

    const x = self.whole_word_rect.x + self.whole_word_rect.width + FindBar.pad;
    const y = self.query_rect.y + (self.query_rect.height - theme.font_size) / 2;
    _ = view.font.drawFit(label, x, y, r.x + r.width, color);

    const mouse = rl.getMousePosition();
    if (rl.checkCollisionPointRec(mouse, self.match_case_rect)) controls.drawTooltip(view.font, self.match_case_rect, controls.Option.match_case.tooltip());
    if (rl.checkCollisionPointRec(mouse, self.whole_word_rect)) controls.drawTooltip(view.font, self.whole_word_rect, controls.Option.whole_word.tooltip());
    if (self.show_replace and self.canReplace()) {
        if (rl.checkCollisionPointRec(mouse, self.replace_one_rect)) controls.drawTooltip(view.font, self.replace_one_rect, "Replace (Enter)");
        if (rl.checkCollisionPointRec(mouse, self.replace_all_rect)) controls.drawTooltip(view.font, self.replace_all_rect, if (@import("builtin").os.tag == .macos) "Replace All (Cmd+Enter)" else "Replace All (Ctrl+Enter)");
    }
}
