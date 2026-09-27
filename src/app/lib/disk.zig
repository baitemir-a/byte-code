//! Files changed by something else (a git checkout in the terminal, a
//! formatter, another editor): noticed when the window gets the focus
//! back and every little while, by the file's time and size. A tab with
//! no unsaved changes is read again quietly, keeping its cursor, scroll
//! and folds on the same lines; one with changes asks first, so neither
//! copy is lost unseen.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const App = @import("../App.zig");
const Tab = @import("../Tab.zig");
const i18n = @import("../../i18n/i18n.zig");

/// Seconds between looks while the window has the focus.
const check_every = 1.5;

/// Called once a frame: looks at the files when it's time.
pub fn update(self: *App, regained_focus: bool) !void {
    const now = rl.getTime();
    if (!regained_focus and now - self.disk_checked_at < check_every) return;
    self.disk_checked_at = now;
    if (!rl.isWindowFocused() and !regained_focus) return;
    try check(self);
}

/// Compares each file tab with its file on disk.
pub fn check(self: *App) !void {
    const dir = std.Io.Dir.cwd();
    var i: usize = 0;
    // By index: asking (a dialog) runs frames, but tabs stay put.
    while (i < self.tabs.items.len) : (i += 1) {
        const t = &self.tabs.items[i];
        if (t.kind != .file) continue;
        switch (t.document.onDisk(self.io, dir)) {
            // Deleted: the tab keeps what it has (saving writes it back).
            .same, .gone => continue,
            .changed => {},
        }
        if (!t.isDirty()) {
            try reloadTab(self, i);
            continue;
        }
        const path = t.document.path.?;
        const s = i18n.tr().disk;
        var title_buf: [256]u8 = undefined;
        const title = i18n.fill(&title_buf, s.changed_title, .{std.fs.path.basename(path)});
        if (self.confirm(title, s.changed_detail, s.reload)) {
            try reloadTab(self, i);
        } else {
            // Kept: not asked again until it changes once more.
            self.tabs.items[i].document.stamp = core.Document.stampOf(self.io, dir, path);
        }
    }
}

/// Reads a tab's file again, keeping the cursor, the scroll and the
/// folds on the lines they were on.
pub fn reloadTab(self: *App, index: usize) !void {
    const t = &self.tabs.items[index];
    const path = try self.gpa.dupe(u8, t.document.path orelse return);
    defer self.gpa.free(path);
    const b = &t.buffer;
    const line = b.lineIndex(b.cursor);
    const col = b.column(b.cursor);
    var fold_lines: std.ArrayList(usize) = .empty;
    defer fold_lines.deinit(self.gpa);
    for (b.folds.items) |f| try fold_lines.append(self.gpa, b.lineIndex(f));

    const active = index == self.active;
    const in_other = self.split != null and t == self.otherTab();
    const scroll = if (active) self.view.scroll else if (in_other) self.other_view.scroll else t.scroll;
    // Deleted meanwhile, or unreadable: it stays as it was.
    t.load(self.gpa, self.io, path) catch return;
    t.scroll = scroll;
    if (active) self.view.setScroll(scroll);
    if (in_other) self.other_view.setScroll(scroll);

    const nb = &t.buffer;
    nb.moveTo(nb.posAt(line, col), false);
    for (fold_lines.items) |l| if (l < nb.lineCount()) try nb.fold(nb.lineStartOf(l));
    t.problems.invalidate();
    self.gitChanged();
}
