//! Putting a project folder back as it was left: its tabs, the cursor
//! and scroll in each, the folded blocks, and the tab that was showing
//! (see core/project/Sessions.zig). Kept when the folder is closed or
//! swapped for another and when the editor quits; brought back when the
//! folder is opened again.
const std = @import("std");
const core = @import("core");
const App = @import("../App.zig");
const theme = @import("../../ui/theme/lib/theme.zig");

const Sessions = core.Sessions;

/// Remembers the open project's tabs (the files among them).
pub fn save(self: *App) void {
    const project = if (self.project) |*p| p else return;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var tabs: std.ArrayList(Sessions.TabState) = .empty;
    var active: u32 = 0;
    for (self.tabs.items, 0..) |*t, i| {
        if (t.kind != .file) continue;
        const path = t.document.path orelse continue;
        const b = &t.buffer;
        var folds: std.ArrayList(u32) = .empty;
        for (b.folds.items) |f| folds.append(a, @intCast(b.lineIndex(f))) catch {};
        // The tabs showing keep their scroll in their view.
        const scroll_y = if (i == self.active) self.view.scroll.y else if (self.split != null and t == self.otherTab()) self.other_view.scroll.y else t.scroll.y;
        if (i == self.active) active = @intCast(tabs.items.len);
        tabs.append(a, .{
            .path = path,
            .line = @intCast(b.lineIndex(b.cursor)),
            .col = @intCast(b.column(b.cursor)),
            .top = scroll_y / theme.line_height,
            .folds = folds.items,
        }) catch return;
    }
    self.sessions.put(.{ .root = project.root().path, .tabs = tabs.items, .active = active }) catch return;
    // Quietly: this runs as the editor quits too, when a dialog can't.
    // Not having it next time is all a failure costs.
    self.sessions.save(self.io, std.Io.Dir.cwd(), self.sessions_path) catch {};
}

/// Opens the tabs the folder had when it was last left, if any. Files
/// gone since are skipped; the rest get their cursor, scroll and folds.
pub fn restore(self: *App) !void {
    const project = if (self.project) |*p| p else return;
    const s = self.sessions.get(project.root().path) orelse return;
    var shown: ?usize = null;
    for (s.tabs, 0..) |state, i| {
        const dir = std.Io.Dir.cwd();
        dir.access(self.io, state.path, .{}) catch continue;
        self.openFile(state.path) catch continue;
        const t = self.tab();
        if (!t.hasPath(state.path)) continue;
        const b = &t.buffer;
        b.moveTo(b.posAt(state.line, state.col), false);
        for (state.folds) |l| if (l < b.lineCount()) try b.fold(b.lineStartOf(l));
        const scroll: @TypeOf(t.scroll) = .{ .x = 0, .y = state.top * theme.line_height };
        t.scroll = scroll;
        self.view.setScroll(scroll);
        if (i == s.active) shown = self.active;
    }
    if (shown) |index| if (index < self.tabs.items.len) try self.activate(index);
}
