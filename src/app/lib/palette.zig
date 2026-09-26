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
const lsp = @import("lsp.zig");

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

/// Cmd+R: the language server's list of what the file declares when
/// there is one (it opens when the answer comes), else the editor's own
/// guess from the shape of the lines.
pub fn openSymbols(self: *App, query: []const u8) !void {
    if (!self.isEditing()) return;
    if (try lsp.requestSymbols(self, query)) return;
    try ownOutline(self);
    try showSymbols(self, query);
}

/// The declarations found by the shape of their lines, into `symbols`.
pub fn ownOutline(self: *App) !void {
    const t = self.tab();
    try t.highlighter.update(self.gpa, &t.buffer);
    try core.symbols.outline(self.gpa, t.buffer.items(), &t.highlighter, &self.symbols);
}

/// Opens the list of `symbols`; nested ones are indented under theirs.
pub fn showSymbols(self: *App, query: []const u8) !void {
    const t = self.tab();
    try self.picker.open(i18n.tr().palette.symbols, &.{}, &.{});
    self.picker.fuzzy = true;
    for (self.symbols.items) |s| {
        var buf: [32]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "{s}  :{d}", .{ s.kind, s.line + 1 }) catch "";
        var label_buf: [160]u8 = undefined;
        const name = t.buffer.items()[s.start..s.end];
        const indent = @min(@as(usize, s.depth) * 2, 16);
        @memset(label_buf[0..indent], ' ');
        const n = @min(name.len, label_buf.len - indent);
        @memcpy(label_buf[indent..][0..n], name[0..n]);
        try self.picker.add(.{ .label = label_buf[0 .. indent + n], .detail = detail });
    }
    rememberOrigin(self);
    try finishOpening(self, .symbol, query);
}

/// Every declaration in the project the language server knows, searched
/// as the query is typed (Cmd+Shift+R, or `#` in Go to File).
pub fn openWorkspaceSymbols(self: *App, query: []const u8) !void {
    try self.picker.open(i18n.tr().palette.workspace_symbols, &.{}, &.{});
    self.picker.fuzzy = true;
    self.lsp.workspace_query.clearRetainingCapacity();
    try finishOpening(self, .workspace_symbol, query);
}

/// Every problem known: in the open files, and what language servers
/// reported for the others (Cmd+Shift+M).
pub fn openProblems(self: *App) !void {
    try lsp.collectProblems(self);
    try self.picker.open(i18n.tr().palette.problems, &.{}, &.{});
    self.picker.fuzzy = true;
    for (self.lsp.problem_list.items) |p| {
        var buf: [300]u8 = undefined;
        const t = i18n.tr().palette;
        const detail = std.fmt.bufPrint(&buf, "{s} · {s}:{d}", .{ if (p.warning) t.warning else t.@"error", relative(self, p.path), p.start.line + 1 }) catch "";
        // The first line of a long message.
        const first = std.mem.sliceTo(p.message, '\n');
        try self.picker.add(.{ .label = first, .detail = detail });
    }
    try finishOpening(self, .problems, "");
}

/// `path` inside the project, without the project's folder.
pub fn relative(self: *const App, path: []const u8) []const u8 {
    if (self.project) |*p| {
        const root = p.root().path;
        if (std.mem.startsWith(u8, path, root) and path.len > root.len + 1) return path[root.len + 1 ..];
    }
    return std.fs.path.basename(path);
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
        .command, .go_to_line, .symbol, .workspace_symbol, .problems => true,
        else => false,
    };
}

/// What the list says when it has no rows.
pub fn emptyMessage(self: *const App, out: []u8) []const u8 {
    const t = i18n.tr().palette;
    return switch (self.picker_mode) {
        .command => t.no_commands,
        .symbol => t.no_symbols,
        .workspace_symbol => t.no_workspace_symbols,
        .problems => t.no_problems,
        .go_to_line => i18n.fill(out, t.line_hint, .{self.activeTab().buffer.lineCount()}),
        else => i18n.tr().quick_open.no_matches,
    };
}

/// Shows the line typed so far, or the selected name, while choosing.
pub fn preview(self: *App) !void {
    switch (self.picker_mode) {
        .go_to_line => if (parseLine(self.picker.query.text())) |at| goToLine(self, at.line, at.col),
        .symbol => if (self.picker.selectedItem()) |i| selectSymbol(self, i),
        .workspace_symbol => try lsp.requestWorkspaceSymbols(self, self.picker.query.text()),
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
        .workspace_symbol => if (item) |i| if (i < self.lsp.workspace_symbols.len) {
            const s = self.lsp.workspace_symbols[i];
            try goTo(self, s.path orelse return, s.start, s.end);
        },
        .problems => if (item) |i| if (i < self.lsp.problem_list.items.len) {
            const p = self.lsp.problem_list.items[i];
            try goTo(self, p.path, p.start, p.end);
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

/// Opens `path` and selects a place in it, as a language server names it.
fn goTo(self: *App, path: []const u8, start: core.lsp.protocol.Position, end: core.lsp.protocol.Position) !void {
    const here = self.tab().document.path;
    if (here == null or !std.mem.eql(u8, here.?, path)) {
        self.openFile(path) catch |err| return self.reportError(i18n.tr().errors.open_file, path, err);
    }
    const b = self.buf();
    const a = core.lsp.protocol.toOffset(b.items(), start);
    const z = core.lsp.protocol.toOffset(b.items(), end);
    b.moveTo(a, false);
    if (z > a and std.mem.indexOfScalar(u8, b.items()[a..z], '\n') == null) b.moveTo(z, true);
    center(self, b.lineIndex(a));
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
