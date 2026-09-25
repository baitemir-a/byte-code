//! The editor split in two panes, side by side or one above the other.
//!
//! The tabs stay in one list, split in two runs: the first pane's tabs come
//! first, the second pane's from `split_at` on. Everything that belongs to
//! the pane with the keyboard — its view, its tab bar, its minimap and the
//! active tab — is the app's usual `view`, `tab_bar`, `minimap` and
//! `active`; the other pane's are kept in `other_*` and swapped in when it
//! takes the keyboard. That way the rest of the editor goes on working on
//! "the" view without knowing about panes at all.
const std = @import("std");
const rl = @import("raylib");
const App = @import("../App.zig");
const Tab = @import("../Tab.zig");
const View = @import("../../ui/editor/View.zig");
const TabBar = @import("../../ui/TabBar.zig");
const Minimap = @import("../../ui/editor/Minimap.zig");
const theme = @import("../../ui/theme/lib/theme.zig");

/// Where the second pane goes.
pub const Dir = enum { right, down };

/// The line between the panes, and how far from it the mouse still grabs it.
pub const divider: f32 = 1;
pub const grab: f32 = 4;
/// Neither pane gets smaller than this.
const min_pane: f32 = 160;

/// A tab pressed in a tab bar. It becomes a drag once the mouse moves a
/// few pixels; otherwise the press was the click that switched to it.
pub const TabPress = struct {
    index: usize,
    start: rl.Vector2,
    dragging: bool = false,
};

/// Where a dragged tab would land.
pub const Drop = union(enum) {
    /// Into the pane that is already there.
    pane: u1,
    /// Into a second pane, made by this drop.
    new: Dir,
};

// ------------------------------------------------------------- the panes

/// Which pane a tab belongs to.
pub fn paneOf(self: *const App, index: usize) u1 {
    if (self.split == null) return 0;
    return if (index < self.split_at) 0 else 1;
}

pub fn paneStart(self: *const App, pane: u1) usize {
    return if (self.split == null or pane == 0) 0 else self.split_at;
}

pub fn paneEnd(self: *const App, pane: u1) usize {
    return if (self.split == null or pane == 1) self.tabs.items.len else self.split_at;
}

pub fn paneTabs(self: *const App, pane: u1) []Tab {
    return self.tabs.items[paneStart(self, pane)..paneEnd(self, pane)];
}

pub fn paneCount(self: *const App, pane: u1) usize {
    return paneEnd(self, pane) - paneStart(self, pane);
}

fn other(pane: u1) u1 {
    return if (pane == 0) 1 else 0;
}

/// The tab the pane without the keyboard shows.
pub fn otherTab(self: *const App) *Tab {
    return &self.tabs.items[self.other_active];
}

// ------------------------------------------------------------ the focus

/// Moves the keyboard to a pane: its view, tab bar and minimap swap in, so
/// the editor's own `view` is always the one being typed in.
pub fn focusPane(self: *App, pane: u1) void {
    if (self.split == null or pane == self.pane) return;
    saveScrolls(self);
    swapPanes(self);
    self.completion.close();
    self.find.close();
    self.mouse.dragging = false;
    self.terminal_focused = false;
    self.side_focus = .none;
    self.reveal_cursor = true;
}

/// Each pane's view keeps the scroll of the tab it shows; the tab keeps it
/// too, for when another tab is shown in its place.
fn saveScrolls(self: *App) void {
    self.tab().scroll = self.view.scroll;
    if (self.split != null) otherTab(self).scroll = self.other_view.scroll;
}

fn swapPanes(self: *App) void {
    std.mem.swap(View, &self.view, &self.other_view);
    std.mem.swap(TabBar, &self.tab_bar, &self.other_bar);
    std.mem.swap(Minimap, &self.minimap, &self.other_minimap);
    std.mem.swap(usize, &self.active, &self.other_active);
    self.pane = other(self.pane);
}

/// The pane a point is in, or null for the sidebar, the terminal panel and
/// everything else outside them.
pub fn paneAt(self: *const App, p: rl.Vector2) ?u1 {
    if (self.split == null) return if (rl.checkCollisionPointRec(p, self.pane_rects[0])) 0 else null;
    if (rl.checkCollisionPointRec(p, self.pane_rects[0])) return 0;
    if (rl.checkCollisionPointRec(p, self.pane_rects[1])) return 1;
    return null;
}

// ------------------------------------------------------------ the layout

/// The panes' areas (each including its own tab bar) inside the editor
/// column, and the divider between them.
pub fn paneRects(self: *const App, column: rl.Rectangle) [2]rl.Rectangle {
    const dir = self.split orelse return .{ column, std.mem.zeroes(rl.Rectangle) };
    return switch (dir) {
        .right => blk: {
            const w = paneSize(column.width, self.split_ratio);
            break :blk .{
                .{ .x = column.x, .y = column.y, .width = w, .height = column.height },
                .{ .x = column.x + w + divider, .y = column.y, .width = column.width - w - divider, .height = column.height },
            };
        },
        .down => blk: {
            const h = paneSize(column.height, self.split_ratio);
            break :blk .{
                .{ .x = column.x, .y = column.y, .width = column.width, .height = h },
                .{ .x = column.x, .y = column.y + h + divider, .width = column.width, .height = column.height - h - divider },
            };
        },
    };
}

/// The first pane's share, never leaving either of them too small.
fn paneSize(total: f32, ratio: f32) f32 {
    const usable = total - divider;
    if (usable < 2 * min_pane) return @round(usable / 2);
    return @round(std.math.clamp(usable * ratio, min_pane, usable - min_pane));
}

/// The divider's grab area: drag it to give one pane more room.
pub fn dividerRect(self: *const App) rl.Rectangle {
    const a = self.pane_rects[0];
    const b = self.pane_rects[1];
    return switch (self.split orelse return std.mem.zeroes(rl.Rectangle)) {
        .right => .{ .x = a.x + a.width - grab, .y = a.y, .width = b.x - a.x - a.width + 2 * grab, .height = a.height },
        .down => .{ .x = a.x, .y = a.y + a.height - grab, .width = a.width, .height = b.y - a.y - a.height + 2 * grab },
    };
}

/// Dragging the divider: the pointer sets the first pane's share.
pub fn resizeSplit(self: *App, p: rl.Vector2) void {
    const dir = self.split orelse return;
    const a = self.pane_rects[0];
    const b = self.pane_rects[1];
    self.split_ratio = switch (dir) {
        .right => std.math.clamp((p.x - a.x) / @max(1, b.x + b.width - a.x), 0.05, 0.95),
        .down => std.math.clamp((p.y - a.y) / @max(1, b.y + b.height - a.y), 0.05, 0.95),
    };
}

// ---------------------------------------------------------- moving tabs

/// Right-click on a tab: split the editor with it, or, when it is already
/// split, move it to the other pane.
pub fn openTabMenu(self: *App, index: usize, at: rl.Vector2) void {
    self.menu_tab = index;
    const actions: []const App.MenuAction = if (self.split == null)
        &.{ .split_right, .split_down }
    else
        &.{.move_to_other_pane};
    var labels: [2][]const u8 = undefined;
    for (actions, 0..) |a, i| {
        self.menu_actions[i] = a;
        labels[i] = a.label();
    }
    self.menu.open(labels[0..actions.len], at, App.windowSize(), self.view.font);
}

/// The menu's actions, on the tab it was opened on.
pub fn runTabMenuAction(self: *App, action: App.MenuAction) !void {
    const index = self.menu_tab orelse return;
    if (index >= self.tabs.items.len) return;
    switch (action) {
        .split_right => try splitTab(self, index, .right),
        .split_down => try splitTab(self, index, .down),
        .move_to_other_pane => try moveTab(self, index, other(paneOf(self, index))),
        else => {},
    }
}

/// Puts a tab in a second pane. When it is the only tab open, the second
/// pane starts with a new empty file instead, so neither pane is left with
/// nothing to show.
pub fn splitTab(self: *App, index: usize, dir: Dir) !void {
    if (self.split != null) return moveTab(self, index, other(paneOf(self, index)));
    if (self.tabs.items.len < 2) return splitWithNewTab(self, dir);
    saveScrolls(self);
    // The second pane is empty for as long as it takes the move to fill it.
    self.split = dir;
    self.split_at = self.tabs.items.len;
    self.other_active = self.active;
    try moveTabTo(self, index, 1);
}

/// The second pane starts with a new empty file.
fn splitWithNewTab(self: *App, dir: Dir) !void {
    saveScrolls(self);
    try self.tabs.append(self.gpa, .initFile(self.gpa));
    self.split = dir;
    self.split_at = self.tabs.items.len - 1;
    setPanes(self, 1, .{ self.active, self.split_at });
}

/// Moves a tab to the other pane, which takes the keyboard. The pane it
/// leaves has to keep a tab, so a pane is never empty.
pub fn moveTab(self: *App, index: usize, to: u1) !void {
    if (self.split == null) return;
    saveScrolls(self);
    try moveTabTo(self, index, to);
}

/// The move itself, with both panes' scrolls already kept.
fn moveTabTo(self: *App, index: usize, to: u1) !void {
    const from = paneOf(self, index);
    if (from == to) return;
    // The last tab of a pane: it rejoins the other one, and with nothing
    // left beside it the editor goes back to a single pane.
    if (paneCount(self, from) < 2) {
        collapse(self, to);
        self.active = index;
        startPane(self, &self.view, self.active);
        self.completion.close();
        self.find.close();
        self.mouse.dragging = false;
        self.reveal_cursor = true;
        return;
    }

    // Both panes' tabs, followed through the move.
    var act: [2]usize = undefined;
    act[self.pane] = self.active;
    act[other(self.pane)] = self.other_active;
    var split_at = self.split_at;

    // Taking it out, then putting it back in at the end of its new pane.
    try self.tabs.ensureUnusedCapacity(self.gpa, 1);
    const moved = self.tabs.orderedRemove(index);
    if (index < split_at) split_at -= 1;
    for (&act) |*a| {
        if (a.* > index) a.* -= 1;
    }
    const at: usize = if (to == 1) self.tabs.items.len else split_at;
    self.tabs.insertAssumeCapacity(at, moved);
    if (at < split_at or (at == split_at and to == 0)) split_at += 1;
    for (&act) |*a| {
        if (a.* >= at) a.* += 1;
    }

    // The tab it was showing is gone from the pane it left.
    self.split_at = split_at;
    act[to] = at;
    act[from] = std.math.clamp(act[from], paneStart(self, from), paneEnd(self, from) - 1);
    setPanes(self, to, act);
}

/// Puts the panes' tabs back and gives one of them the keyboard. `act`
/// holds each pane's tab, by pane.
fn setPanes(self: *App, focus: u1, act: [2]usize) void {
    if (focus != self.pane) swapPanes(self);
    self.active = act[self.pane];
    self.other_active = act[other(self.pane)];
    startPane(self, &self.view, self.active);
    startPane(self, &self.other_view, self.other_active);
    self.completion.close();
    self.find.close();
    self.mouse.dragging = false;
    self.reveal_cursor = true;
}

/// A view showing a tab it wasn't showing before: the editor's font and
/// wrapping, the tab's own scroll, and rows to be built again.
fn startPane(self: *App, view: *View, index: usize) void {
    view.font = self.view.font;
    view.wrap = self.settings.word_wrap;
    view.scroll = self.tabs.items[index].scroll;
    view.rows_version = null;
}

/// Back to one pane, keeping `keep`'s tabs — the other pane has none left.
pub fn collapse(self: *App, keep: u1) void {
    if (self.split == null) return;
    if (keep != self.pane) swapPanes(self);
    self.split = null;
    self.split_at = 0;
    self.pane = 0;
    self.other_active = 0;
    self.split_resizing = false;
}

// ------------------------------------------------------- dragging a tab

pub fn startTabPress(self: *App, index: usize, at: rl.Vector2) void {
    self.tab_press = .{ .index = index, .start = at };
}

/// Each frame while a tab is held: it becomes a drag after a few pixels,
/// and the drop moves it to the pane it was let go over.
pub fn updateTabPress(self: *App, point: rl.Vector2) !void {
    const press = if (self.tab_press) |*p| p else return;
    const released = rl.isMouseButtonReleased(.left);
    if (!released and !rl.isMouseButtonDown(.left)) {
        self.tab_press = null;
        return;
    }
    if (!press.dragging and std.math.hypot(point.x - press.start.x, point.y - press.start.y) > App.drag_threshold) {
        press.dragging = true;
    }
    if (!press.dragging) {
        if (released) self.tab_press = null;
        return;
    }
    const index = press.index;
    const target = dropAt(self, index, point);
    if (!released) return;
    self.tab_press = null;
    switch (target orelse return) {
        .pane => |p| try moveTab(self, index, p),
        .new => |dir| try splitTab(self, index, dir),
    }
}

/// Where the tab being dragged would land: the other pane, or a second
/// pane made along the editor's right or bottom edge.
pub fn dropAt(self: *const App, index: usize, p: rl.Vector2) ?Drop {
    if (index >= self.tabs.items.len) return null;
    if (self.split != null) {
        const over = paneAt(self, p) orelse return null;
        if (over == paneOf(self, index)) return null;
        return .{ .pane = over };
    }
    if (self.tabs.items.len < 2) return null;
    const area = self.pane_rects[0];
    if (!rl.checkCollisionPointRec(p, area)) return null;
    if (p.x > area.x + area.width * 0.6) return .{ .new = .right };
    if (p.y > area.y + area.height * 0.6) return .{ .new = .down };
    return null;
}

/// The half (or the whole pane) a drop would fill, for the mark drawn
/// under the pointer while dragging.
pub fn dropRect(self: *const App, drop: Drop) rl.Rectangle {
    const area = self.pane_rects[0];
    return switch (drop) {
        .pane => |p| self.pane_rects[p],
        .new => |dir| switch (dir) {
            .right => .{ .x = area.x + area.width / 2, .y = area.y, .width = area.width / 2, .height = area.height },
            .down => .{ .x = area.x, .y = area.y + area.height / 2, .width = area.width, .height = area.height / 2 },
        },
    };
}

/// The name of the tab being dragged, shown beside the pointer.
pub fn draggedTab(self: *const App) ?*const Tab {
    const press = self.tab_press orelse return null;
    if (!press.dragging or press.index >= self.tabs.items.len) return null;
    return &self.tabs.items[press.index];
}

// ------------------------------------------------------------- drawing

/// The line between the panes, brighter while it is being dragged.
pub fn drawDivider(self: *const App) void {
    const dir = self.split orelse return;
    const a = self.pane_rects[0];
    const hot = self.split_resizing or rl.checkCollisionPointRec(rl.getMousePosition(), dividerRect(self));
    const color = theme.copy(if (hot) theme.accent else theme.tab_separator);
    const line: rl.Rectangle = switch (dir) {
        .right => .{ .x = a.x + a.width, .y = a.y, .width = divider, .height = a.height },
        .down => .{ .x = a.x, .y = a.y + a.height, .width = a.width, .height = divider },
    };
    rl.drawRectangleRec(line, color);
}
