//! A searchable list at the top of the editor, like "go to file", for
//! picking a branch or a stash: type to narrow it down, Enter (or a
//! click) picks the selected row, and the row under the pointer or the
//! selection offers buttons of its own (merge, rename, delete...).
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("theme/lib/theme.zig");
const Font = @import("Font.zig");
const Icons = @import("Icons.zig");
const TextField = @import("widgets/TextField.zig");
const search_controls = @import("widgets/lib/search_controls.zig");

const Picker = @This();

/// A button on a row. Which ones a picker offers is up to its owner; a
/// row can leave some out (`Item.without`).
pub const Action = enum {
    merge,
    rename,
    delete,
    apply,
    drop,

    fn icon(a: Action) Icons.Icon {
        return switch (a) {
            .merge => .git_merge,
            .rename => .pencil,
            .delete, .drop => .trash_2,
            .apply => .archive_restore,
        };
    }
};

pub const Item = struct {
    label: []const u8,
    /// Dimmer, after the label: "remote", a stash's age...
    detail: []const u8 = "",
    /// Marked as the one in use (the branch checked out).
    current: bool = false,
    /// Buttons this row doesn't offer.
    without: std.EnumSet(Action) = .initEmpty(),
};

/// What a click hit: a row, and one of its buttons if it was on one.
pub const Hit = struct { item: u32, action: ?Action };

pub const max_rows = 12;
const row_height = theme.line_height + 4;
const pad: f32 = 8;
const button_size: f32 = 22;

gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
is_open: bool = false,
/// What the box says while empty; the buttons the rows offer, and their
/// names (for the tooltip).
placeholder: []const u8 = "",
actions: []const Action = &.{},
action_labels: []const []const u8 = &.{},
query: TextField,
/// Rank the rows by a fuzzy match of the query (commands, symbols)
/// instead of keeping those that contain it in their order.
fuzzy: bool = false,
items: std.ArrayList(Item) = .empty,
/// The rows matching the query, as indexes into `items`.
shown: std.ArrayList(u32) = .empty,
selected: usize = 0,
first: usize = 0,
rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
field_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),

pub fn init(gpa: std.mem.Allocator) Picker {
    return .{ .gpa = gpa, .arena = .init(gpa), .query = .init(gpa) };
}

pub fn deinit(self: *Picker) void {
    self.query.deinit();
    self.items.deinit(self.gpa);
    self.shown.deinit(self.gpa);
    self.arena.deinit();
}

/// Opens empty; `add` fills it, then `filter` shows the rows.
pub fn open(self: *Picker, placeholder: []const u8, actions: []const Action, action_labels: []const []const u8) !void {
    std.debug.assert(actions.len == action_labels.len);
    self.is_open = true;
    self.fuzzy = false;
    self.placeholder = placeholder;
    self.actions = actions;
    self.action_labels = action_labels;
    self.items.clearRetainingCapacity();
    self.shown.clearRetainingCapacity();
    _ = self.arena.reset(.retain_capacity);
    try self.query.setText("");
}

pub fn close(self: *Picker) void {
    self.is_open = false;
}

/// Adds a row; its text is copied.
pub fn add(self: *Picker, item: Item) !void {
    var copy = item;
    copy.label = try self.arena.allocator().dupe(u8, item.label);
    copy.detail = try self.arena.allocator().dupe(u8, item.detail);
    try self.items.append(self.gpa, copy);
}

/// Shows the rows whose label has the query in it (any case), and
/// selects the first.
pub fn filter(self: *Picker) !void {
    self.shown.clearRetainingCapacity();
    self.selected = 0;
    self.first = 0;
    const q = std.mem.trim(u8, self.query.text(), " ");
    if (self.fuzzy and q.len > 0) return self.filterFuzzy(q);
    for (self.items.items, 0..) |item, i| {
        if (q.len == 0 or containsIgnoreCase(item.label, q)) try self.shown.append(self.gpa, @intCast(i));
    }
}

fn filterFuzzy(self: *Picker, q: []const u8) !void {
    var scores: std.ArrayList(i32) = .empty;
    defer scores.deinit(self.gpa);
    for (self.items.items, 0..) |item, i| {
        const m = core.fuzzy.match(item.label, q) orelse continue;
        try self.shown.append(self.gpa, @intCast(i));
        try scores.append(self.gpa, m.score);
    }
    // Best first; equals keep their order.
    const Ctx = struct {
        scores: []i32,
        shown: []u32,
        pub fn lessThan(c: @This(), a: usize, b: usize) bool {
            if (c.scores[a] != c.scores[b]) return c.scores[a] > c.scores[b];
            return c.shown[a] < c.shown[b];
        }
        pub fn swap(c: @This(), a: usize, b: usize) void {
            std.mem.swap(i32, &c.scores[a], &c.scores[b]);
            std.mem.swap(u32, &c.shown[a], &c.shown[b]);
        }
    };
    std.sort.pdqContext(0, self.shown.items.len, Ctx{ .scores = scores.items, .shown = self.shown.items });
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

pub fn selectedItem(self: *const Picker) ?u32 {
    if (self.shown.items.len == 0) return null;
    return self.shown.items[self.selected];
}

pub fn moveSelection(self: *Picker, delta: isize) void {
    const n: isize = @intCast(self.shown.items.len);
    if (n == 0) return;
    self.selected = @intCast(std.math.clamp(@as(isize, @intCast(self.selected)) + delta, 0, n - 1));
}

/// Centered at the top of `area` (the editor column).
pub fn layout(self: *Picker, area: rl.Rectangle, font: Font) void {
    if (!self.is_open) return;
    const w = @min(640, area.width - 40);
    const rows = @min(self.shown.items.len, max_rows);
    if (self.selected < self.first) self.first = self.selected;
    if (self.selected >= self.first + max_rows) self.first = self.selected + 1 - max_rows;
    const field_h = theme.line_height + 10;
    const list_h = @as(f32, @floatFromInt(@max(rows, 1))) * row_height;
    self.rect = .{ .x = area.x + (area.width - w) / 2, .y = area.y + 6, .width = w, .height = pad * 2 + field_h + 6 + list_h };
    self.field_rect = .{ .x = self.rect.x + pad, .y = self.rect.y + pad, .width = w - 2 * pad, .height = field_h };
    self.query.layout(self.field_rect.width, font);
}

pub fn contains(self: *const Picker, p: rl.Vector2) bool {
    return self.is_open and rl.checkCollisionPointRec(p, self.rect);
}

fn listTop(self: *const Picker) f32 {
    return self.field_rect.y + self.field_rect.height + 6;
}

fn rowTop(self: *const Picker, row: usize) f32 {
    return self.listTop() + @as(f32, @floatFromInt(row - self.first)) * row_height;
}

/// Where a row's button `index` (of `actions`) goes: at its right end.
fn buttonRect(self: *const Picker, row: usize, index: usize) rl.Rectangle {
    const from_right = @as(f32, @floatFromInt(self.actions.len - index));
    return .{
        .x = self.rect.x + self.rect.width - pad - from_right * (button_size + 2),
        .y = self.rowTop(row) + (row_height - button_size) / 2,
        .width = button_size,
        .height = button_size,
    };
}

/// The row under a point (by position in `shown`), if any.
fn rowAt(self: *const Picker, p: rl.Vector2) ?usize {
    if (!self.contains(p) or p.y < self.listTop()) return null;
    const row = self.first + @as(usize, @intFromFloat((p.y - self.listTop()) / row_height));
    return if (row < self.shown.items.len and row < self.first + max_rows) row else null;
}

/// Whether a row shows its buttons: under the pointer, or selected.
fn showsButtons(self: *const Picker, row: usize, mouse: rl.Vector2) bool {
    return row == self.selected or self.rowAt(mouse) == row;
}

pub fn hitTest(self: *const Picker, p: rl.Vector2) ?Hit {
    const row = self.rowAt(p) orelse return null;
    const item = self.shown.items[row];
    for (self.actions, 0..) |a, i| {
        if (self.items.items[item].without.contains(a)) continue;
        if (rl.checkCollisionPointRec(p, self.buttonRect(row, i))) return .{ .item = item, .action = a };
    }
    return .{ .item = item, .action = null };
}

pub fn draw(self: *const Picker, font: Font, show_caret: bool, no_matches: []const u8) void {
    if (!self.is_open) return;
    const r = self.rect;
    rl.drawRectangleRec(.{ .x = r.x + 3, .y = r.y + 5, .width = r.width, .height = r.height }, theme.popup_shadow);
    rl.drawRectangleRec(r, theme.popup_background);
    rl.drawRectangleLinesEx(r, 1, theme.popup_border);
    self.query.draw(self.field_rect, font, self.placeholder, true, show_caret);

    const top = self.listTop();
    if (self.shown.items.len == 0) {
        _ = font.drawFit(no_matches, r.x + pad + 4, top + (row_height - theme.font_size) / 2, r.x + r.width - pad, theme.popup_detail);
        return;
    }
    const mouse = rl.getMousePosition();
    var tooltip: ?struct { rect: rl.Rectangle, text: []const u8 } = null;
    const last = @min(self.shown.items.len, self.first + max_rows);
    for (self.first..last) |row| {
        const item = self.items.items[self.shown.items[row]];
        const y = self.rowTop(row);
        if (row == self.selected) rl.drawRectangleRec(.{ .x = r.x + 2, .y = y, .width = r.width - 4, .height = row_height }, theme.accentDim(0.35));
        const ty = y + (row_height - theme.font_size) / 2;
        const buttons = self.showsButtons(row, mouse);
        const text_end = if (buttons and self.actions.len > 0) self.buttonRect(row, 0).x - 8 else r.x + r.width - pad;
        // A dot marks the one in use.
        if (item.current) rl.drawCircleV(.{ .x = r.x + pad + 6, .y = y + row_height / 2 }, 3, theme.accent);
        const x = font.drawFit(item.label, r.x + pad + 16, ty, text_end, theme.foreground);
        if (item.detail.len > 0) _ = font.drawFit(item.detail, x + font.cell_width * 2, ty, text_end, theme.popup_detail);
        if (!buttons) continue;
        for (self.actions, 0..) |a, i| {
            if (item.without.contains(a)) continue;
            const b = self.buttonRect(row, i);
            const hot = rl.checkCollisionPointRec(mouse, b);
            if (hot) {
                rl.drawRectangleRounded(b, 0.3, 6, theme.tab_close_hover);
                tooltip = .{ .rect = b, .text = self.action_labels[i] };
            }
            font.drawIcon(a.icon(), .{ .x = b.x + b.width / 2, .y = b.y + b.height / 2 }, .small, theme.copy(if (hot) theme.foreground else theme.popup_detail));
        }
    }
    if (tooltip) |t| search_controls.drawTooltip(font, t.rect, t.text);
}
