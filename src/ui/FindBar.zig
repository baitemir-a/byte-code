//! Find and replace: a bar in the top-right corner with a query box, an
//! optional replacement box and a match counter. While one of its boxes has
//! focus it receives all editing commands; the editor keeps showing the
//! current match as its selection.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("theme.zig");
const View = @import("View.zig");
const TextField = @import("TextField.zig");
const Mods = @import("../input/keymap.zig").Mods;

const Buffer = core.Buffer;
const FindBar = @This();

pub const Focus = enum { editor, query, replacement };

gpa: std.mem.Allocator,
is_open: bool = false,
show_replace: bool = false,
focus: Focus = .editor,
query: TextField,
replacement: TextField,
search: core.Search = .{},
/// Where the search started: typing jumps to the first match from here.
origin: usize = 0,

// Layout, computed in `layout` for drawing and hit-testing.
rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
query_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
replace_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),

const margin = 16;
const pad = 6;
const counter_cols = 12; // "9999 of 9999"

pub fn init(gpa: std.mem.Allocator) FindBar {
    return .{ .gpa = gpa, .query = .init(gpa), .replacement = .init(gpa) };
}

pub fn deinit(self: *FindBar) void {
    self.query.deinit();
    self.replacement.deinit();
    self.search.deinit(self.gpa);
}

/// Whether keyboard input goes to one of the bar's boxes.
pub fn hasFocus(self: *const FindBar) bool {
    return self.is_open and self.focus != .editor;
}

/// The box with keyboard focus, if any.
pub fn focusedField(self: *FindBar) ?*TextField {
    if (!self.is_open) return null;
    return switch (self.focus) {
        .editor => null,
        .query => &self.query,
        .replacement => &self.replacement,
    };
}

/// Opens the bar (Cmd+F, or with the replace box for Cmd+Alt+F / Ctrl+H).
/// A one-line selection becomes the query.
pub fn show(self: *FindBar, editor: *Buffer, with_replace: bool) !void {
    const was_open = self.is_open;
    self.is_open = true;
    self.show_replace = with_replace or (was_open and self.show_replace);

    if (editor.selectedText()) |sel| if (std.mem.indexOfScalar(u8, sel, '\n') == null) {
        try self.query.setText(sel);
    };
    self.query.buffer.selectAll();
    self.origin = editor.selectionOrCursor().start;

    // Replace shortcut with a query already there: straight to the replacement.
    self.focus = if (with_replace and was_open and self.query.text().len > 0) .replacement else .query;
    if (self.focus == .replacement) self.replacement.buffer.selectAll();
    try self.jumpFromOrigin(editor);
}

pub fn close(self: *FindBar) void {
    self.is_open = false;
    self.focus = .editor;
}

/// Handles a command while a box has focus. Returns false for commands the
/// app should handle itself (clipboard, files, global find shortcuts).
pub fn handle(self: *FindBar, cmd: core.Command, editor: *Buffer, mods: Mods) !bool {
    switch (cmd) {
        .newline => switch (self.focus) {
            .query => if (mods.shift) try self.prev(editor) else try self.next(editor),
            .replacement => if (mods.primary) try self.replaceAll(editor) else try self.replaceOne(editor),
            .editor => unreachable,
        },
        .indent => if (self.show_replace) {
            self.focus = if (self.focus == .query) .replacement else .query;
            self.focusedField().?.buffer.selectAll();
        },
        .clear_selection => self.close(),
        .copy, .cut, .paste, .open, .open_folder, .new_file, .close_tab, .next_tab, .prev_tab, .toggle_sidebar, .toggle_terminal, .open_settings, .close_folder, .quick_open, .show_explorer, .show_search, .show_git, .zoom_in, .zoom_out, .zoom_reset, .save, .save_as, .find, .find_replace, .find_next, .find_prev => return false,
        else => {
            _ = try self.focusedField().?.handle(cmd);
            try self.queryEdited(editor);
        },
    }
    return true;
}

/// Pastes into the focused box (first line only).
pub fn paste(self: *FindBar, s: []const u8, editor: *Buffer) !void {
    const field = self.focusedField() orelse return;
    try field.paste(s);
    try self.queryEdited(editor);
}

/// Jumps to the first match only when the query text actually changed, so
/// moving the cursor inside the box doesn't lose your place.
fn queryEdited(self: *FindBar, editor: *Buffer) !void {
    if (self.focus != .query) return;
    if (try self.search.update(self.gpa, editor, self.query.text())) try self.jumpFromOrigin(editor);
}

/// Keeps matches in sync with editor changes. Call once per frame.
pub fn update(self: *FindBar, editor: *const Buffer) !void {
    if (!self.is_open) return;
    _ = try self.search.update(self.gpa, editor, self.query.text());
}

pub fn next(self: *FindBar, editor: *Buffer) !void {
    _ = try self.search.update(self.gpa, editor, self.query.text());
    const from = editor.selectionOrCursor();
    // From the end of the current match, so we don't find it again.
    const pos = if (self.search.indexOf(from) != null) from.start + 1 else from.start;
    if (self.search.nextFrom(pos)) |i| self.select(editor, i);
}

pub fn prev(self: *FindBar, editor: *Buffer) !void {
    _ = try self.search.update(self.gpa, editor, self.query.text());
    if (self.search.prevBefore(editor.selectionOrCursor().start)) |i| self.select(editor, i);
}

/// Replaces the current match, then moves to the next one.
pub fn replaceOne(self: *FindBar, editor: *Buffer) !void {
    _ = try self.search.update(self.gpa, editor, self.query.text());
    if (editor.selection()) |sel| if (self.search.indexOf(sel) != null) {
        try editor.insert(self.replacement.text());
        _ = try self.search.update(self.gpa, editor, self.query.text());
        if (self.search.nextFrom(editor.cursor)) |i| self.select(editor, i);
        return;
    };
    try self.next(editor);
}

pub fn replaceAll(self: *FindBar, editor: *Buffer) !void {
    _ = try self.search.update(self.gpa, editor, self.query.text());
    _ = try self.search.replaceAll(self.gpa, editor, self.replacement.text());
}

/// After the query changed: select the first match from where the search
/// began, or go back there if nothing matches.
fn jumpFromOrigin(self: *FindBar, editor: *Buffer) !void {
    _ = try self.search.update(self.gpa, editor, self.query.text());
    if (self.search.nextFrom(self.origin)) |i| self.select(editor, i) else editor.moveTo(@min(self.origin, editor.items().len), false);
}

fn select(self: *FindBar, editor: *Buffer, i: usize) void {
    const m = self.search.matches.items[i];
    editor.moveTo(m.start, false);
    editor.moveTo(m.end, true);
}

/// Match highlights for the view, while the bar is open.
pub fn highlights(self: *const FindBar, editor: *const Buffer) ?View.Highlights {
    if (!self.is_open or self.query.text().len == 0) return null;
    const current = if (editor.selection()) |sel| self.search.indexOf(sel) else null;
    return .{ .ranges = self.search.matches.items, .current = current };
}

// ------------------------------------------------------------ layout & draw

pub fn layout(self: *FindBar, view: *const View) void {
    if (!self.is_open) return;
    const cw = view.font.cell_width;
    const row_h = theme.line_height + 8;
    const width = @min(view.right() - view.gutterRight() - margin, 44 * cw + 2 * pad);
    const rows: f32 = if (self.show_replace) 2 else 1;
    self.rect = .{
        .x = view.right() - width - margin,
        .y = view.area.y,
        .width = width,
        .height = rows * row_h + pad,
    };
    const field_w = width - 3 * pad - counter_cols * cw;
    self.query_rect = .{ .x = self.rect.x + pad, .y = self.rect.y + pad, .width = field_w, .height = row_h - pad };
    self.replace_rect = self.query_rect;
    self.replace_rect.y += row_h;
    self.query.layout(field_w, view.font);
    self.replacement.layout(field_w, view.font);
}

pub fn contains(self: *const FindBar, p: rl.Vector2) bool {
    return self.is_open and rl.checkCollisionPointRec(p, self.rect);
}

/// A click inside the bar: focus the box under it and place its cursor.
pub fn click(self: *FindBar, p: rl.Vector2, view: *const View) void {
    if (rl.checkCollisionPointRec(p, self.query_rect)) {
        self.focus = .query;
        self.query.buffer.moveTo(self.query.posAtX(self.query_rect, view.font, p.x), false);
    } else if (self.show_replace and rl.checkCollisionPointRec(p, self.replace_rect)) {
        self.focus = .replacement;
        self.replacement.buffer.moveTo(self.replacement.posAtX(self.replace_rect, view.font, p.x), false);
    }
}

pub fn draw(self: *const FindBar, view: *const View, editor: *const Buffer, show_caret: bool) void {
    if (!self.is_open) return;
    const r = self.rect;
    rl.drawRectangleRec(.{ .x = r.x + 3, .y = r.y + 4, .width = r.width, .height = r.height }, theme.popup_shadow);
    rl.drawRectangleRec(r, theme.popup_background);
    rl.drawRectangleLinesEx(r, 1, theme.popup_border);

    self.query.draw(self.query_rect, view.font, "Find", self.focus == .query, show_caret);
    if (self.show_replace) {
        self.replacement.draw(self.replace_rect, view.font, "Replace", self.focus == .replacement, show_caret);
    }

    // "3 of 12", "12 found" or "No results" next to the query box.
    var buf: [32]u8 = undefined;
    const n = self.search.matches.items.len;
    const current = if (editor.selection()) |sel| self.search.indexOf(sel) else null;
    const label, const color = if (self.query.text().len == 0)
        .{ "", theme.popup_detail }
    else if (n == 0)
        .{ "No results", theme.find_no_results }
    else if (current) |i|
        .{ std.fmt.bufPrint(&buf, "{d} of {d}", .{ i + 1, n }) catch "", theme.popup_detail }
    else
        .{ std.fmt.bufPrint(&buf, "{d} found", .{n}) catch "", theme.popup_detail };

    var x = self.query_rect.x + self.query_rect.width + pad;
    const y = self.query_rect.y + (self.query_rect.height - theme.font_size) / 2;
    for (label) |c| {
        view.font.drawCodepoint(c, x, y, color);
        x += view.font.cell_width;
    }
}
