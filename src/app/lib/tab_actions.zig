//! Tabs: switching, new, closing. With the editor split in two panes, a
//! tab belongs to the pane its place in the list falls in (see split.zig),
//! so adding and removing tabs keeps that boundary up to date.
const std = @import("std");
const App = @import("../App.zig");
const Tab = @import("../Tab.zig");

/// Adds a tab to the pane that has the keyboard.
pub fn insertTab(self: *App, at: usize, new: Tab) !void {
    try self.tabs.insert(self.gpa, at, new);
    if (self.split == null) return;
    if (at < self.split_at or (at == self.split_at and self.pane == 0)) self.split_at += 1;
    if (self.other_active >= at) self.other_active += 1;
}

pub fn activate(self: *App, index: usize) !void {
    self.focusPane(self.paneOf(index));
    if (index == self.active) return;
    self.tab().scroll = self.view.scroll;
    self.active = index;
    self.view.setScroll(self.tab().scroll);
    self.completion.close();
    if (self.readOnly()) self.find.close(); // nothing here to replace
    self.mouse.dragging = false;
    try self.revealCurrentFile();
}

/// Ctrl+Tab: through the tabs of the pane that has the keyboard.
pub fn cycleTabs(self: *App, delta: isize) !void {
    const start = self.paneStart(self.pane);
    const n: isize = @intCast(self.paneCount(self.pane));
    const at: isize = @intCast(self.active - start);
    try self.activate(start + @as(usize, @intCast(@mod(at + delta, n))));
}

pub fn newFile(self: *App) !void {
    try insertTab(self, self.active + 1, .initFile(self.gpa));
    try self.activate(self.active + 1);
}

/// Closes a tab, asking about unsaved changes first. Returns false if
/// cancelled. The last tab of a pane closes the split with it.
pub fn closeTab(self: *App, index: usize) !bool {
    if (self.tabs.items[index].isDirty()) {
        try self.activate(index); // show what we're asking about
        if (!try self.resolveUnsavedChanges()) return false;
    }
    // Both panes' tabs, followed through the removal.
    const pane = self.paneOf(index);
    const was_focused = index == self.active;
    const was_other = self.split != null and index == self.other_active;
    var act: [2]usize = undefined;
    act[self.pane] = self.active;
    act[flip(self.pane)] = self.other_active;

    var closed = self.tabs.orderedRemove(index);
    closed.deinit(self.gpa);
    if (self.split != null and index < self.split_at) self.split_at -= 1;
    for (&act) |*a| {
        if (a.* > index) a.* -= 1;
    }
    if (self.tabs.items.len == 0) try self.tabs.append(self.gpa, .initWelcome(self.gpa));

    // With nothing left in the pane it was in, the editor goes back to
    // one; otherwise that pane shows the tab that moved into its place.
    var collapsed = false;
    if (self.split != null and self.paneCount(pane) == 0) {
        const keep = flip(pane);
        const kept = act[keep];
        self.collapseSplit(keep);
        act = .{ kept, kept };
        collapsed = true;
    }
    act[0] = std.math.clamp(act[0], self.paneStart(0), self.paneEnd(0) - 1);
    self.active = act[self.pane];
    if (self.split != null) {
        act[1] = std.math.clamp(act[1], self.paneStart(1), self.paneEnd(1) - 1);
        self.active = act[self.pane];
        self.other_active = act[flip(self.pane)];
    }
    // A pane whose tab is gone shows another one, from where it left off.
    if (was_focused and !collapsed) {
        self.view.setScroll(self.tab().scroll);
        self.completion.close();
    }
    if (was_other and !collapsed) self.other_view.setScroll(self.otherTab().scroll);
    try self.revealCurrentFile();
    return true;
}

fn flip(pane: u1) u1 {
    return if (pane == 0) 1 else 0;
}
