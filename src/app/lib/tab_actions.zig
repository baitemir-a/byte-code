//! Tabs: switching, new, closing.
const App = @import("../App.zig");

pub fn activate(self: *App, index: usize) !void {
    if (index == self.active) return;
    self.tab().scroll = self.view.scroll;
    self.active = index;
    self.view.scroll = self.tab().scroll;
    self.completion.close();
    self.mouse.dragging = false;
    try self.revealCurrentFile();
}

pub fn cycleTabs(self: *App, delta: isize) !void {
    const n: isize = @intCast(self.tabs.items.len);
    try self.activate(@intCast(@mod(@as(isize, @intCast(self.active)) + delta, n)));
}

pub fn newFile(self: *App) !void {
    try self.tabs.insert(self.gpa, self.active + 1, .initFile(self.gpa));
    try self.activate(self.active + 1);
}

/// Closes a tab, asking about unsaved changes first. Returns false if
/// cancelled.
pub fn closeTab(self: *App, index: usize) !bool {
    if (self.tabs.items[index].isDirty()) {
        try self.activate(index); // show what we're asking about
        if (!try self.resolveUnsavedChanges()) return false;
    }
    var closed = self.tabs.orderedRemove(index);
    closed.deinit(self.gpa);
    if (self.tabs.items.len == 0) try self.tabs.append(self.gpa, .initWelcome(self.gpa));

    // Stay on the same tab, or its right neighbour if it was the one closed.
    if (index < self.active) self.active -= 1;
    if (index == self.active) {
        self.active = @min(index, self.tabs.items.len - 1);
        self.view.scroll = self.tab().scroll;
        self.completion.close();
    }
    try self.revealCurrentFile();
    return true;
}
