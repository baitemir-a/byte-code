//! The sidebar's Search view: find and replace across the project, with
//! match case / whole word toggles. Every match is listed, grouped by file;
//! click one to open it with the match selected. Replace one match or one
//! file with the button on its row (on hover), or everything at once.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../theme/lib/theme.zig");
const anim = @import("../anim.zig");
const Font = @import("../Font.zig");
const TextField = @import("../widgets/TextField.zig");
const file_icon = @import("../widgets/lib/file_icon.zig");
const controls = @import("../widgets/lib/search_controls.zig");
const SearchPanel_draw = @import("SearchPanel_draw.zig");
const i18n = @import("../../i18n/i18n.zig");

const SearchPanel = @This();

const row_height = theme.line_height;
pub const pad: f32 = 8;

/// A clicked row: a file (open it) or one of its matches (open and select it).
pub const Row = union(enum) { file: u32, match: u32 };

query: TextField,
replacement: TextField,
results: core.ProjectSearch,
options: core.find.Options = .{},
/// The options the results are for.
searched_with: core.find.Options = .{},
/// The query the results are for; they're re-run when it changes.
searched_for: std.ArrayList(u8) = .empty,
/// When the query last changed: the search runs once typing pauses.
changed_at: ?f64 = null,
rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
field_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
replace_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
replace_all_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
match_case_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
whole_word_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
scroll: f32 = 0,
/// Where the list is headed; `scroll` follows it (see ui/anim.zig).
scroll_to: f32 = 0,
max_scroll: f32 = 0,

// Drawing, in SearchPanel_draw.zig.
pub const draw = SearchPanel_draw.draw;
pub const drawTooltip = SearchPanel_draw.drawTooltip;

pub fn init(gpa: std.mem.Allocator) SearchPanel {
    return .{ .query = .init(gpa), .replacement = .init(gpa), .results = .init(gpa) };
}

pub fn deinit(self: *SearchPanel) void {
    self.query.deinit();
    self.replacement.deinit();
    self.results.deinit();
    self.searched_for.deinit(self.results.gpa);
}

/// The row with the result count and the Replace All button.
fn summaryY(self: *const SearchPanel) f32 {
    return self.replace_rect.y + self.replace_rect.height + 6;
}

pub fn listTop(self: *const SearchPanel) f32 {
    return self.summaryY() + self.replace_all_rect.height + 6;
}

fn rowCount(self: *const SearchPanel) usize {
    return self.results.files.items.len + self.results.matches.items.len;
}

pub fn layout(self: *SearchPanel, rect: rl.Rectangle, font: Font) void {
    self.rect = rect;
    const h = theme.line_height + 8;
    const tw = controls.toggleWidth(font);
    // The query box, then the two toggles on its right.
    self.field_rect = .{ .x = rect.x + pad, .y = rect.y + pad, .width = @max(4 * font.cell_width, rect.width - 3 * pad - 2 * (tw + 4)), .height = h };
    const toggle_x = self.field_rect.x + self.field_rect.width + pad;
    self.match_case_rect = .{ .x = toggle_x, .y = self.field_rect.y + 2, .width = tw, .height = h - 4 };
    self.whole_word_rect = self.match_case_rect;
    self.whole_word_rect.x += tw + 4;
    self.replace_rect = .{ .x = rect.x + pad, .y = self.field_rect.y + h + 6, .width = rect.width - 2 * pad, .height = h };
    const button_w = controls.buttonWidth(font, i18n.tr().common.replace_all);
    self.replace_all_rect = .{ .x = rect.x + rect.width - pad - button_w, .y = self.summaryY(), .width = button_w, .height = theme.line_height + 4 };
    self.query.layout(self.field_rect.width, font);
    self.replacement.layout(self.replace_rect.width, font);
    const content = @as(f32, @floatFromInt(self.rowCount())) * row_height;
    self.max_scroll = @max(0, content - (rect.y + rect.height - self.listTop()));
    self.scroll_to = std.math.clamp(self.scroll_to, 0, self.max_scroll);
    self.scroll = std.math.clamp(self.scroll, 0, self.max_scroll);
}

pub fn scrollBy(self: *SearchPanel, wheel_y: f32) void {
    self.scroll_to = std.math.clamp(self.scroll_to - wheel_y * row_height * 3, 0, self.max_scroll);
    if (!anim.enabled) self.scroll = self.scroll_to;
}

/// One frame of following the scroll.
pub fn step(self: *SearchPanel) void {
    anim.approach(&self.scroll, self.scroll_to, anim.scroll_speed);
}

pub fn onField(self: *const SearchPanel, p: rl.Vector2) bool {
    return rl.checkCollisionPointRec(p, self.field_rect);
}

pub fn onReplaceField(self: *const SearchPanel, p: rl.Vector2) bool {
    return rl.checkCollisionPointRec(p, self.replace_rect);
}

pub fn onReplaceAll(self: *const SearchPanel, p: rl.Vector2) bool {
    return self.canReplace() and rl.checkCollisionPointRec(p, self.replace_all_rect);
}

pub fn onToggle(self: *const SearchPanel, p: rl.Vector2) ?controls.Option {
    if (rl.checkCollisionPointRec(p, self.match_case_rect)) return .match_case;
    if (rl.checkCollisionPointRec(p, self.whole_word_rect)) return .whole_word;
    return null;
}

pub fn toggle(self: *SearchPanel, option: controls.Option) void {
    switch (option) {
        .match_case => self.options.match_case = !self.options.match_case,
        .whole_word => self.options.whole_word = !self.options.whole_word,
    }
}

/// Whether the results are out of date with the query box or options.
pub fn stale(self: *const SearchPanel) bool {
    return !std.mem.eql(u8, self.query.text(), self.searched_for.items) or
        !std.meta.eql(self.options, self.searched_with);
}

pub fn canReplace(self: *const SearchPanel) bool {
    return self.results.matches.items.len > 0;
}

/// The Replace button a hovered row shows at its right end: one match, or
/// all of a file's matches.
pub fn rowButton(self: *const SearchPanel, font: Font, row_top: f32, row: Row) rl.Rectangle {
    const w = controls.buttonWidth(font, rowButtonLabel(row));
    return .{ .x = self.rect.x + self.rect.width - pad - w, .y = row_top + 2, .width = w, .height = row_height - 4 };
}

pub fn rowButtonLabel(row: Row) []const u8 {
    return switch (row) {
        .file => i18n.tr().search.replace_in_file,
        .match => i18n.tr().search.replace_match,
    };
}

/// The row whose Replace button is under a point.
pub fn replaceButtonAt(self: *const SearchPanel, font: Font, p: rl.Vector2) ?Row {
    if (!self.canReplace()) return null;
    const row = self.rowAt(p) orelse return null;
    const top = self.listTop() + @floor((p.y - self.listTop() + self.scroll) / row_height) * row_height - self.scroll;
    return if (rl.checkCollisionPointRec(p, self.rowButton(font, top, row))) row else null;
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
