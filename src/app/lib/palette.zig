//! The lists at the top of the editor that aren't about git: every
//! command (Cmd+Shift+P), a line to go to (Ctrl+G) and the names the file
//! declares (Cmd+R). They use the same picker as the branches. Go to File
//! hands over to them when its query starts with `>`, `:` or `@`.
//!
//! Going to a line or a name shows it while it is being chosen; Esc puts
//! the cursor back where it was.
const std = @import("std");
const core = @import("core");
const Keymap = @import("../../input/Keymap.zig");
const App = @import("../App.zig");
const i18n = @import("../../i18n/i18n.zig");

/// Where the cursor was when a list that moves it opened.
pub const Origin = struct {
    cursor: usize,
    anchor: ?usize,
    scroll_y: f32,
};

/// Commands the palette leaves out: moving the cursor and typing are
/// done with the keys, and the palette doesn't list itself.
fn listed(e: Keymap.Entry) bool {
    if (e.group == .cursor or e.group == .selection) return false;
    return switch (e.action) {
        .command_palette, .newline, .backspace, .delete_forward, .delete_word_left, .delete_word_right, .delete_line_start, .delete_line_end, .clear_selection, .indent => false,
        else => true,
    };
}

pub fn openCommandPalette(self: *App, query: []const u8) !void {
    const t = i18n.tr().palette;
    try self.picker.open(t.commands, &.{}, &.{});
    self.picker.fuzzy = true;
    self.palette_actions.clearRetainingCapacity();
    for (Keymap.entries) |e| {
        if (!listed(e)) continue;
        var buf: [48]u8 = undefined;
        const chord = if (self.keys.chordFor(e.action)) |c| c.write(&buf) else "";
        try self.picker.add(.{ .label = Keymap.label(e.action), .detail = chord });
        try self.palette_actions.append(self.gpa, e.action);
    }
    try finishOpening(self, .command, query);
}

pub fn openGoToLine(self: *App, query: []const u8) !void {
    if (!self.isEditing()) return;
    try self.picker.open(i18n.tr().palette.line, &.{}, &.{});
    rememberOrigin(self);
    try finishOpening(self, .go_to_line, query);
}

pub fn openSymbols(self: *App, query: []const u8) !void {
    if (!self.isEditing()) return;
    const t = self.tab();
    try t.highlighter.update(self.gpa, &t.buffer);
    try core.symbols.outline(self.gpa, t.buffer.items(), &t.highlighter, &self.symbols);
    try self.picker.open(i18n.tr().palette.symbols, &.{}, &.{});
    self.picker.fuzzy = true;
    for (self.symbols.items) |s| {
        var buf: [32]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "{s}  :{d}", .{ s.kind, s.line + 1 }) catch "";
        try self.picker.add(.{ .label = t.buffer.items()[s.start..s.end], .detail = detail });
    }
    rememberOrigin(self);
    try finishOpening(self, .symbol, query);
}

fn finishOpening(self: *App, mode: @import("git_pickers.zig").Mode, query: []const u8) !void {
    self.picker_mode = mode;
    try self.picker.query.setText(query);
    try self.picker.filter();
    self.quick_open.close();
    self.completion.close();
    self.side_focus = .none;
    self.terminal_focused = false;
    try preview(self);
}

fn rememberOrigin(self: *App) void {
    const b = self.buf();
    self.jump_origin = .{ .cursor = b.cursor, .anchor = b.anchor, .scroll_y = self.view.scroll_to.y };
}

/// Whether the picker is showing one of these lists.
pub fn isOwn(self: *const App) bool {
    return switch (self.picker_mode) {
        .command, .go_to_line, .symbol => true,
        else => false,
    };
}

/// What the list says when it has no rows.
pub fn emptyMessage(self: *const App, out: []u8) []const u8 {
    const t = i18n.tr().palette;
    return switch (self.picker_mode) {
        .command => t.no_commands,
        .symbol => t.no_symbols,
        .go_to_line => i18n.fill(out, t.line_hint, .{self.activeTab().buffer.lineCount()}),
        else => i18n.tr().quick_open.no_matches,
    };
}

/// Shows the line typed so far, or the selected name, while choosing.
pub fn preview(self: *App) !void {
    switch (self.picker_mode) {
        .go_to_line => if (parseLine(self.picker.query.text())) |at| goToLine(self, at.line, at.col),
        .symbol => if (self.picker.selectedItem()) |i| selectSymbol(self, i),
        else => {},
    }
}

/// Enter, or a click on a row.
pub fn choose(self: *App, item: ?u32) !void {
    self.picker.close();
    const origin = self.jump_origin;
    self.jump_origin = null;
    switch (self.picker_mode) {
        // Run once this frame's input is through (see `App.update`).
        .command => if (item) |i| {
            self.pending_command = Keymap.command(self.palette_actions.items[i]);
        },
        .go_to_line => if (parseLine(self.picker.query.text())) |at| {
            if (origin) |o| self.nav.jumped(self, o.cursor);
            goToLine(self, at.line, at.col);
        },
        .symbol => if (item) |i| {
            if (origin) |o| self.nav.jumped(self, o.cursor);
            selectSymbol(self, i);
        },
        else => {},
    }
}

/// Esc: the cursor goes back to where it was.
pub fn cancel(self: *App) void {
    self.picker.close();
    const o = self.jump_origin orelse return;
    self.jump_origin = null;
    self.nav.quiet = true;
    if (!self.isEditing()) return;
    const b = self.buf();
    const len = b.items().len;
    b.moveTo(@min(o.cursor, len), false);
    if (o.anchor) |a| {
        b.anchor = @min(a, len);
    }
    self.view.scroll_to.y = o.scroll_y;
}

const LineCol = struct { line: usize, col: ?usize };

/// "42" or "42:7" (one-based), as typed.
fn parseLine(q: []const u8) ?LineCol {
    const s = std.mem.trim(u8, q, " :");
    if (s.len == 0) return null;
    var parts = std.mem.splitScalar(u8, s, ':');
    const line = std.fmt.parseInt(usize, std.mem.trim(u8, parts.first(), " "), 10) catch return null;
    const col = if (parts.next()) |c| std.fmt.parseInt(usize, std.mem.trim(u8, c, " "), 10) catch null else null;
    return .{ .line = @max(line, 1) - 1, .col = if (col) |c| @max(c, 1) - 1 else null };
}

/// Puts the cursor on a line (zero-based; past the end means the last)
/// and scrolls it to the middle of the view.
pub fn goToLine(self: *App, line: usize, col: ?usize) void {
    const b = self.buf();
    const l = @min(line, b.lineCount() - 1);
    const start = b.posAt(l, 0);
    const pos = if (col) |c| b.posAt(l, c) else core.motion.smartLineStart(b, start);
    b.moveTo(pos, false);
    center(self, l);
}

fn selectSymbol(self: *App, item: u32) void {
    if (item >= self.symbols.items.len) return;
    const s = self.symbols.items[item];
    const b = self.buf();
    if (s.end > b.items().len) return;
    b.moveTo(s.start, false);
    b.moveTo(s.end, true);
    center(self, s.line);
}

/// Scrolls so `line` is in the middle of the view, unless it is on
/// screen already.
pub fn center(self: *App, line: usize) void {
    self.reveal_cursor = true;
    const top = self.view.topLine();
    const shown = self.view.visibleLines();
    const l: f32 = @floatFromInt(line);
    if (l >= top and l + 1 <= top + shown) return;
    self.view.scrollToLine(@max(0, l - shown / 2));
}
