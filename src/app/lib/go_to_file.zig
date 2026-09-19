//! Go to file (Cmd+P).
const std = @import("std");
const core = @import("core");
const QuickOpen = @import("../../ui/QuickOpen.zig");
const App = @import("../App.zig");
const clipboard = @import("clipboard.zig");

/// Cmd+P: lists the project's files (read fresh each time) to pick from.
pub fn openQuickOpen(self: *App) !void {
    self.file_search.files.clearRetainingCapacity();
    if (self.project) |*p| self.file_search.scan(self.io, p.root().path) catch |err| {
        self.reportError("Couldn't list the project's files", p.root().path, err);
    };
    try self.quick_open.open(&self.file_search);
    self.completion.close();
    self.find.focus = .editor;
    self.sidebar.cancelInput();
    self.terminal_focused = false;
}

/// Keys while "go to file" is open: type to filter, arrows to choose,
/// Enter to open, Esc to close.
pub fn quickOpenKey(self: *App, cmd: core.Command) !void {
    const q = &self.quick_open;
    switch (cmd) {
        .newline => try self.openQuickOpenSelection(),
        .clear_selection => q.close(),
        .move => |m| switch (m.motion) {
            .line_up => q.moveSelection(-1),
            .line_down => q.moveSelection(1),
            .page_up => q.moveSelection(-QuickOpen.max_rows),
            .page_down => q.moveSelection(QuickOpen.max_rows),
            else => _ = try q.query.handle(cmd),
        },
        .copy, .cut => try clipboard.copyOrCut(self.gpa, &q.query.buffer, cmd == .cut),
        .paste => if (clipboard.getClipboard()) |s| {
            try q.query.paste(s);
            try q.refresh(&self.file_search);
        },
        else => if (try q.query.handle(cmd)) try q.refresh(&self.file_search),
    }
}

pub fn openQuickOpenSelection(self: *App) !void {
    const project = if (self.project) |*p| p else return self.quick_open.close();
    const file = self.quick_open.selectedFile() orelse return;
    const path = try std.fs.path.join(self.gpa, &.{ project.root().path, self.file_search.files.items[file] });
    defer self.gpa.free(path);
    self.quick_open.close();
    self.openFile(path) catch |err| self.reportError("Couldn't open file", path, err);
}
