//! The conflicts a merge left in the file being edited: found again
//! whenever the text changes, and settled from the buttons over them.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const App = @import("../App.zig");
const View_conflicts = @import("../../ui/editor/View_conflicts.zig");

/// Keeps the active tab's list of conflicts up to date; called once a frame.
pub fn updateConflicts(self: *App) !void {
    const t = self.tab();
    if (t.kind != .file) return;
    if (t.conflicts_version == t.buffer.version) return;
    t.conflicts_version = t.buffer.version;
    try core.Conflicts.find(self.gpa, t.buffer.items(), &t.conflicts);
}

/// The conflicts to show over the text, if any.
pub fn conflicts(self: *const App) []const core.Conflicts.Region {
    const t = self.activeTab();
    if (t.kind != .file or t.conflicts_version != t.buffer.version) return &.{};
    return t.conflicts.items;
}

/// The pointer over a conflict's buttons: a hand, and on a click the
/// side (or sides) picked replace the whole conflict, as one undo step.
/// Returns whether the click was taken.
pub fn conflictMouse(self: *App, point: rl.Vector2, pressed: bool) !bool {
    const list = conflicts(self);
    if (list.len == 0) return false;
    const t = self.tab();
    const button = View_conflicts.buttonAt(self.view, &t.buffer, list, point) orelse return false;
    self.wanted_cursor = .pointing_hand;
    if (!pressed) return false;
    const r = list[button.region];
    const kept = try core.Conflicts.resolve(self.gpa, t.buffer.items(), r, button.choice);
    defer self.gpa.free(kept);
    try t.buffer.replace(r.from, r.to, kept, 0, .other);
    self.gitChanged();
    return true;
}
