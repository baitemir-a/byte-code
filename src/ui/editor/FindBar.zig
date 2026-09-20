//! Find and replace: a bar in the top-right corner with a query box, the
//! match case / whole word toggles and a match counter, and a replacement
//! box with Replace and Replace All. While one of its boxes has focus it
//! receives all editing commands; the editor keeps showing the current match
//! as its selection.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../theme/lib/theme.zig");
const View = @import("View.zig");
const TextField = @import("../widgets/TextField.zig");
const Mods = @import("../../input/Keymap.zig").Mods;
const controls = @import("../widgets/lib/search_controls.zig");
const FindBar_draw = @import("FindBar_draw.zig");

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
/// Match case / whole word, toggled with the buttons beside the query.
options: core.find.Options = .{},
/// Where the search started: typing jumps to the first match from here.
origin: usize = 0,

// Layout, computed in `layout` for drawing and hit-testing.
rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
query_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
replace_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
match_case_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
whole_word_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
replace_one_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
replace_all_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),

const margin = 16;
pub const pad = 6;
/// Room for "9999 of 9999" — and, with the toggles, for the two buttons
/// under it.
const counter_cols = 14;

// Drawing, in FindBar_draw.zig.
pub const draw = FindBar_draw.draw;

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

/// Opens the bar: find and replace together. Cmd+F focuses the query;
/// Cmd+Option+F (Ctrl+H) the replacement once there's a query. A one-line
/// selection becomes the query.
pub fn show(self: *FindBar, editor: *Buffer, with_replace: bool) !void {
    const was_open = self.is_open;
    self.is_open = true;
    self.show_replace = true;

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
            .replacement => if (mods.primary()) try self.replaceAll(editor) else try self.replaceOne(editor),
            .editor => unreachable,
        },
        .indent => if (self.show_replace) {
            self.focus = if (self.focus == .query) .replacement else .query;
            self.focusedField().?.buffer.selectAll();
        },
        .clear_selection => self.close(),
        // Up / Down: previous / next match (the boxes are one line anyway).
        .move => |m| switch (m.motion) {
            .line_up => try self.prev(editor),
            .line_down => try self.next(editor),
            else => _ = try self.focusedField().?.handle(cmd),
        },
        .copy, .cut, .paste, .open, .open_folder, .new_file, .close_tab, .next_tab, .prev_tab, .toggle_sidebar, .toggle_terminal, .open_settings, .open_help, .close_folder, .quick_open, .show_explorer, .show_search, .show_git, .zoom_in, .zoom_out, .zoom_reset, .save, .save_as, .find, .find_replace, .find_next, .find_prev, .toggle_match_case, .toggle_whole_word => return false,
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
    if (try self.refresh(editor)) try self.jumpFromOrigin(editor);
}

/// Recomputes matches if needed; true when the query or options changed.
fn refresh(self: *FindBar, editor: *const Buffer) !bool {
    return self.search.update(self.gpa, editor, self.query.text(), self.options);
}

/// Keeps matches in sync with editor changes. Call once per frame.
pub fn update(self: *FindBar, editor: *const Buffer) !void {
    if (!self.is_open) return;
    _ = try self.refresh(editor);
}

/// Flips match case or whole word, and selects the first match from the
/// cursor under the new rules.
pub fn toggle(self: *FindBar, option: controls.Option, editor: *Buffer) !void {
    switch (option) {
        .match_case => self.options.match_case = !self.options.match_case,
        .whole_word => self.options.whole_word = !self.options.whole_word,
    }
    if (!self.is_open) return;
    self.origin = editor.selectionOrCursor().start;
    if (try self.refresh(editor)) try self.jumpFromOrigin(editor);
}

pub fn next(self: *FindBar, editor: *Buffer) !void {
    _ = try self.refresh(editor);
    const from = editor.selectionOrCursor();
    // From the end of the current match, so we don't find it again.
    const pos = if (self.search.indexOf(from) != null) from.start + 1 else from.start;
    if (self.search.nextFrom(pos)) |i| self.select(editor, i);
}

pub fn prev(self: *FindBar, editor: *Buffer) !void {
    _ = try self.refresh(editor);
    if (self.search.prevBefore(editor.selectionOrCursor().start)) |i| self.select(editor, i);
}

/// Replaces the current match, then moves to the next one.
pub fn replaceOne(self: *FindBar, editor: *Buffer) !void {
    _ = try self.refresh(editor);
    if (editor.selection()) |sel| if (self.search.indexOf(sel) != null) {
        try editor.insert(self.replacement.text());
        _ = try self.refresh(editor);
        if (self.search.nextFrom(editor.cursor)) |i| self.select(editor, i);
        return;
    };
    try self.next(editor);
}

/// Replaces every match as one undo step.
pub fn replaceAll(self: *FindBar, editor: *Buffer) !void {
    _ = try self.refresh(editor);
    _ = try self.search.replaceAll(self.gpa, editor, self.replacement.text());
}

/// After the query changed: select the first match from where the search
/// began, or go back there if nothing matches.
fn jumpFromOrigin(self: *FindBar, editor: *Buffer) !void {
    _ = try self.refresh(editor);
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
    const tw = controls.toggleWidth(view.font);
    // Right of the boxes: toggles and the counter; under them the buttons.
    const side_w = 2 * (tw + pad) + counter_cols * cw;
    const width = @min(view.right() - view.gutterRight() - margin, 30 * cw + side_w + 3 * pad);
    const rows: f32 = if (self.show_replace) 2 else 1;
    self.rect = .{
        .x = view.right() - width - margin,
        .y = view.area.y,
        .width = width,
        .height = rows * row_h + pad,
    };
    const field_w = @max(4 * cw, width - 3 * pad - side_w);
    const h = row_h - pad;
    self.query_rect = .{ .x = self.rect.x + pad, .y = self.rect.y + pad, .width = field_w, .height = h };
    self.replace_rect = self.query_rect;
    self.replace_rect.y += row_h;

    const side_x = self.query_rect.x + field_w + pad;
    self.match_case_rect = .{ .x = side_x, .y = self.query_rect.y, .width = tw, .height = h };
    self.whole_word_rect = .{ .x = side_x + tw + pad, .y = self.query_rect.y, .width = tw, .height = h };
    const one_w = controls.buttonWidth(view.font, "Replace");
    self.replace_one_rect = .{ .x = side_x, .y = self.replace_rect.y, .width = one_w, .height = h };
    const all_x = side_x + one_w + pad;
    self.replace_all_rect = .{ .x = all_x, .y = self.replace_rect.y, .width = @max(0, self.rect.x + width - pad - all_x), .height = h };

    self.query.layout(field_w, view.font);
    self.replacement.layout(field_w, view.font);
}

pub fn canReplace(self: *const FindBar) bool {
    return self.query.text().len > 0 and self.search.matches.items.len > 0;
}

pub fn contains(self: *const FindBar, p: rl.Vector2) bool {
    return self.is_open and rl.checkCollisionPointRec(p, self.rect);
}

/// A click inside the bar: a toggle or button, or focus the box under it
/// and place its cursor.
pub fn click(self: *FindBar, p: rl.Vector2, view: *const View, editor: *Buffer) !void {
    const hit = rl.checkCollisionPointRec;
    if (hit(p, self.match_case_rect)) return self.toggle(.match_case, editor);
    if (hit(p, self.whole_word_rect)) return self.toggle(.whole_word, editor);
    if (self.show_replace and self.canReplace()) {
        if (hit(p, self.replace_one_rect)) return self.replaceOne(editor);
        if (hit(p, self.replace_all_rect)) return self.replaceAll(editor);
    }
    if (rl.checkCollisionPointRec(p, self.query_rect)) {
        self.focus = .query;
        self.query.buffer.moveTo(self.query.posAtX(self.query_rect, view.font, p.x), false);
    } else if (self.show_replace and rl.checkCollisionPointRec(p, self.replace_rect)) {
        self.focus = .replacement;
        self.replacement.buffer.moveTo(self.replacement.posAtX(self.replace_rect, view.font, p.x), false);
    }
}
