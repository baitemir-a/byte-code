//! The Help tab: every keyboard shortcut, grouped, with the combination on
//! the right. Click a row and press the keys to change it; the change is
//! saved to keybindings.json straight away.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../theme/lib/theme.zig");
const anim = @import("../anim.zig");
const Font = @import("../Font.zig");
const i18n = @import("../../i18n/i18n.zig");
const Keymap = @import("../../input/Keymap.zig");
const HelpPage_draw = @import("HelpPage_draw.zig");

const HelpPage = @This();

/// What a click on the page asks for.
pub const Action = union(enum) {
    /// Wait for the keys to bind to this shortcut.
    capture: Keymap.Action,
    /// Put one shortcut back to its default.
    reset: Keymap.Action,
    reset_all,
    /// Stop waiting, leaving the shortcut as it was.
    cancel,
};

/// What was pressed while the page waits for a combination.
pub const Recorded = union(enum) {
    none,
    cancel,
    /// Leave the shortcut with no keys at all.
    clear,
    chord: Keymap.Chord,
};

/// A line under the title about the last change.
pub const Message = union(enum) {
    none,
    /// Letters and digits type text unless a command modifier is held.
    needs_modifier,
    /// The combination was in use, and moved here.
    took_from: Keymap.Action,
};

pub const unbound_label = "—";

const content_cols = 68;
const chord_cols = 22;
const reset_cols = 6;
pub const row_height: f32 = theme.line_height + 8;
const heading_height: f32 = theme.line_height + 20;
const button_height: f32 = 28;
const group_count = blk: {
    var groups: usize = 0;
    var last: ?Keymap.Group = null;
    for (Keymap.entries) |e| {
        if (last == null or last.? != e.group) groups += 1;
        last = e.group;
    }
    break :blk groups;
};

// Set by `layout`, in window coordinates.
area: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
origin: rl.Vector2 = .{ .x = 0, .y = 0 },
width: f32 = 0,
/// One row per shortcut, in the order of `Keymap.entries`.
rows: [Keymap.count]rl.Rectangle = std.mem.zeroes([Keymap.count]rl.Rectangle),
reset_all_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
scroll: f32 = 0,
/// Where the page is headed; `scroll` follows it (see ui/anim.zig).
scroll_to: f32 = 0,
max_scroll: f32 = 0,
hovered: ?usize = null,
/// The shortcut waiting for new keys.
capturing: ?Keymap.Action = null,
message: Message = .none,

// Drawing, in HelpPage_draw.zig.
pub const draw = HelpPage_draw.draw;

pub fn layout(self: *HelpPage, area: rl.Rectangle, font: Font) void {
    self.area = area;
    const w = @min(content_cols * font.cell_width, @max(0, area.width - theme.padding * 4));
    self.width = w;
    const x = area.x + @max(theme.padding * 2, (area.width - w) / 2);
    self.origin = .{ .x = x, .y = area.y + theme.padding * 2 };

    self.max_scroll = @max(0, self.contentHeight() - area.height);
    self.scroll_to = std.math.clamp(self.scroll_to, 0, self.max_scroll);
    self.scroll = std.math.clamp(self.scroll, 0, self.max_scroll);

    const reset_all_w = @max(110, font.textWidth(i18n.tr().help.reset_all) + 16);
    self.reset_all_rect = .{ .x = x + w - reset_all_w, .y = self.origin.y - self.scroll, .width = reset_all_w, .height = button_height };

    var y = self.origin.y + headerHeight() - self.scroll;
    var group: ?Keymap.Group = null;
    for (Keymap.entries, 0..) |e, i| {
        if (group == null or group.? != e.group) {
            group = e.group;
            y += heading_height;
        }
        self.rows[i] = .{ .x = x - 8, .y = y, .width = w + 16, .height = row_height };
        y += row_height;
    }

    const mouse = rl.getMousePosition();
    self.hovered = if (rl.checkCollisionPointRec(mouse, area)) for (self.rows, 0..) |r, i| {
        if (rl.checkCollisionPointRec(mouse, r)) break i;
    } else null else null;
}

/// Title, hint and the message line above the first group.
fn headerHeight() f32 {
    return Font.heading_size + 10 + theme.line_height * 2;
}

fn contentHeight(self: *const HelpPage) f32 {
    _ = self;
    return headerHeight() + heading_height * group_count + row_height * Keymap.count + theme.padding * 4;
}

pub fn scrollBy(self: *HelpPage, wheel_y: f32) void {
    self.scroll_to = std.math.clamp(self.scroll_to - wheel_y * row_height * 3, 0, self.max_scroll);
    if (!anim.enabled) self.scroll = self.scroll_to;
}

/// One frame of following the scroll.
pub fn step(self: *HelpPage) void {
    anim.approach(&self.scroll, self.scroll_to, anim.scroll_speed);
}

/// Where the combination is drawn, and the "Reset" next to it.
pub fn chordRect(row: rl.Rectangle, font: Font) rl.Rectangle {
    const w = chord_cols * font.cell_width;
    return .{ .x = row.x + row.width - w - 8, .y = row.y + 2, .width = w, .height = row.height - 4 };
}

pub fn resetRect(row: rl.Rectangle, font: Font) rl.Rectangle {
    const chord = chordRect(row, font);
    const w = @max(reset_cols * font.cell_width, font.textWidth(i18n.tr().common.reset) + 2 * font.cell_width);
    return .{ .x = chord.x - w - 8, .y = row.y + 2, .width = w, .height = row.height - 4 };
}

pub fn actionAt(self: *const HelpPage, p: rl.Vector2, font: Font, keys: *const Keymap) ?Action {
    if (rl.checkCollisionPointRec(p, self.reset_all_rect)) return .reset_all;
    for (self.rows, Keymap.entries) |r, e| {
        if (!rl.checkCollisionPointRec(p, r)) continue;
        if (!keys.isDefault(e.action) and rl.checkCollisionPointRec(p, resetRect(r, font))) {
            return .{ .reset = e.action };
        }
        return .{ .capture = e.action };
    }
    // A click anywhere else gives up on a combination being recorded.
    return if (self.capturing != null) .cancel else null;
}

pub fn startCapture(self: *HelpPage, action: Keymap.Action) void {
    self.capturing = action;
    self.message = .none;
}

pub fn stopCapture(self: *HelpPage) void {
    self.capturing = null;
}

/// The keys pressed this frame, while waiting for a combination. Esc and
/// Backspace are the page's own: they cancel and clear.
pub fn readChord() Recorded {
    const mods = Keymap.Mods.current();
    // Only on their own: Cmd+Backspace and the like stay bindable.
    if (mods.none()) {
        if (rl.isKeyPressed(.escape)) return .cancel;
        if (rl.isKeyPressed(.backspace) or rl.isKeyPressed(.delete)) return .clear;
    }
    for (Keymap.named_keys) |k| {
        if (rl.isKeyPressed(k.key)) return .{ .chord = .{ .key = k.key, .mods = mods } };
    }
    return .none;
}

/// Scrolls `action`'s row into view (after opening the page from elsewhere).
pub fn reveal(self: *HelpPage, action: Keymap.Action) void {
    const row = self.rows[Keymap.indexOf(action)];
    const above = row.y - self.area.y;
    if (above < 0) self.scroll_to = std.math.clamp(self.scroll_to + above, 0, self.max_scroll);
    const below = row.y + row.height - (self.area.y + self.area.height);
    if (below > 0) self.scroll_to = std.math.clamp(self.scroll_to + below, 0, self.max_scroll);
}
