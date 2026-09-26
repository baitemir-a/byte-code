//! Folding blocks of code away: the commands, the marks in the gutter
//! that fold and unfold on a click, and keeping the cursor out of what is
//! hidden (a cursor that gets there — a search, going to a line — opens
//! the fold up again).
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../../ui/theme/lib/theme.zig");
const Tab = @import("../Tab.zig");
const App = @import("../App.zig");
const View = @import("../../ui/editor/View.zig");
const View_draw = @import("../../ui/editor/View_draw.zig");

/// How far up "fold" looks for the block the cursor is in.
const max_lines_up = 2000;

/// Works out the lines the tab's folds hide, when the text or the folds
/// changed. Before the view lays out its rows.
pub fn updateHidden(gpa: std.mem.Allocator, t: *Tab) !void {
    const b = &t.buffer;
    if (t.hidden_version == b.version and t.hidden_folds == b.folds_version) return;
    try t.highlighter.update(gpa, b);
    try core.fold.hiddenRanges(b, &t.highlighter, &t.hidden);
    t.hidden_version = b.version;
    t.hidden_folds = b.folds_version;
}

fn canFold(self: *App) bool {
    return self.activeTab().kind == .file;
}

/// Folds the block the cursor is in: the one its line starts, or else the
/// nearest one around it.
pub fn foldAtCursor(self: *App) !void {
    if (!canFold(self)) return;
    const t = self.tab();
    const b = &t.buffer;
    try t.highlighter.update(self.gpa, b);
    const here = b.lineStart(b.cursor);
    var start = here;
    var index = b.lineIndex(b.cursor);
    for (0..max_lines_up) |_| {
        if (!b.isFolded(start)) if (core.fold.region(b, &t.highlighter, start, index)) |r| {
            if (start == here or (b.cursor >= r.start and b.cursor <= r.end)) {
                try b.fold(start);
                if (b.cursor >= r.start) b.moveTo(b.lineEnd(start), false);
                self.reveal_cursor = true;
                return;
            }
        };
        if (start == 0) return;
        start = b.lineStart(start - 1);
        index -= 1;
    }
}

/// Unfolds the block the cursor's line starts.
pub fn unfoldAtCursor(self: *App) void {
    if (!canFold(self)) return;
    const b = self.buf();
    _ = b.unfold(b.lineStart(b.cursor));
}

/// Folds every block there is (the cursor ends up on the first line of
/// the outermost one it was in).
pub fn foldAll(self: *App) !void {
    if (!canFold(self)) return;
    const t = self.tab();
    const b = &t.buffer;
    try t.highlighter.update(self.gpa, b);
    const bytes = b.items();
    var start: usize = 0;
    var index: usize = 0;
    while (true) : (index += 1) {
        if (core.fold.foldable(b, &t.highlighter, start, index)) {
            if (core.fold.region(b, &t.highlighter, start, index) != null) try b.fold(start);
        }
        const end = b.lineEnd(start);
        if (end >= bytes.len) break;
        start = end + 1;
    }
    try updateHidden(self.gpa, t);
    for (t.hidden.items) |r| {
        if (b.cursor >= r.start and b.cursor <= r.end) b.moveTo(r.start - 1, false);
    }
    self.reveal_cursor = true;
}

pub fn unfoldAll(self: *App) void {
    self.buf().unfoldAll();
}

/// Opens the folds a cursor has got into. Returns whether any did.
pub fn unfoldCursors(self: *App) !bool {
    if (!self.isEditing()) return false;
    const t = self.tab();
    const b = &t.buffer;
    if (t.hidden.items.len == 0) return false;
    try updateHidden(self.gpa, t);
    var any = false;
    if (core.fold.isHidden(t.hidden.items, b.cursor)) any = try unfoldAround(t, b.cursor) or any;
    for (b.extra.items) |c| {
        if (core.fold.isHidden(t.hidden.items, c.cursor)) any = try unfoldAround(t, c.cursor) or any;
    }
    if (any) try updateHidden(self.gpa, t);
    return any;
}

/// Removes every fold that hides `pos`.
fn unfoldAround(t: *Tab, pos: usize) !bool {
    const b = &t.buffer;
    var any = false;
    var i: usize = 0;
    while (i < b.folds.items.len) {
        const start = b.folds.items[i];
        if (start > pos) break;
        const r = core.fold.region(b, &t.highlighter, start, b.lineIndex(start));
        if (r != null and pos >= r.?.start and pos <= r.?.end) {
            _ = b.unfold(start);
            any = true;
            continue;
        }
        i += 1;
    }
    return any;
}

/// A click on a fold's mark in the gutter, or on the "…" after a folded
/// line. Returns whether it was one.
pub fn foldClick(self: *App, point: rl.Vector2) !bool {
    if (!canFold(self)) return false;
    const t = self.tab();
    const b = &t.buffer;
    const view = &self.view;
    if (point.y < view.area.y or point.y > view.bottom()) return false;
    const row = view.rowAtY(point.y);
    if (row >= view.rows.items.len) return false;
    if (row > 0 and view.rows.items[row - 1].line == view.rows.items[row].line) return false;
    const start = view.rows.items[row].start;
    const line = view.rows.items[row].line;
    if (b.isFolded(start)) {
        const on_mark = View_draw.foldMarkContains(view.*, point);
        const on_dots = rl.checkCollisionPointRec(point, View_draw.foldDotsRect(view.*, b, start, row));
        if (!on_mark and !on_dots) return false;
        _ = b.unfold(start);
        return true;
    }
    if (!View_draw.foldMarkContains(view.*, point)) return false;
    try t.highlighter.update(self.gpa, b);
    const r = core.fold.region(b, &t.highlighter, start, line) orelse return true;
    try b.fold(start);
    if (b.cursor >= r.start and b.cursor <= r.end) b.moveTo(b.lineEnd(start), false);
    return true;
}
