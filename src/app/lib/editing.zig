//! Editor commands beyond plain editing: moving by screen rows,
//! select scope, comments, Cmd+D, matching brackets and the completion
//! popup.
const std = @import("std");
const core = @import("core");
const Tab = @import("../Tab.zig");
const View = @import("../../ui/editor/View.zig");
const CompletionPopup = @import("../../ui/editor/CompletionPopup.zig");
const App = @import("../App.zig");
const problems = @import("problems.zig");
const lsp = @import("lsp.zig");
const ContextMenu = @import("../../ui/sidebar/ContextMenu.zig");
const i18n = @import("../../i18n/i18n.zig");

/// With word wrap, Up / Down / Page Up / Page Down go by screen rows (a
/// long line has several); with folds too, stepping over the folded
/// lines. Returns false for other moves, or when the rows aren't up to
/// date with an edit this frame.
pub fn moveByRows(self: *App, b: *core.Buffer, m: core.command.Move) bool {
    const folded = self.tab().hidden.items.len > 0;
    if (!(self.view.wrap or folded) or !self.view.rowsCurrent(b)) return false;
    const page: isize = @intCast(self.view.pageLines());
    const delta: isize = switch (m.motion) {
        .line_up => -1,
        .line_down => 1,
        .page_up => -page,
        .page_down => page,
        else => return false,
    };
    const Rows = struct {
        view: *const View,
        delta: isize,
        extend: bool,
        pub fn apply(op: @This(), target: *core.Buffer) !void {
            op.view.moveRows(target, op.delta, op.extend);
        }
    };
    b.eachCursor(Rows{ .view = &self.view, .delta = delta, .extend = m.extend }, false) catch {};
    return true;
}

/// Cmd+/: comments the lines of every cursor out, or back in.
pub fn toggleComment(self: *App, b: *core.Buffer) !void {
    const style = core.comment.styleFor(self.tab().highlighter.language);
    const Op = struct {
        style: core.comment.Style,
        done: *?core.Buffer.Range,
        pub fn apply(op: @This(), target: *core.Buffer) !void {
            op.done.* = try core.comment.toggle(target, op.style, op.done.*);
        }
    };
    var done: ?core.Buffer.Range = null;
    try b.eachCursor(Op{ .style = style, .done = &done }, false);
}

/// Cmd+D: the word at the cursor, then each time the next place with
/// the same text as well. Starting from a word, only whole words count.
pub fn selectNextOccurrence(self: *App, b: *core.Buffer) !void {
    const sel = b.selectionOrCursor();
    const continuing = b.version == self.occurrence_version and
        sel.start == self.occurrence_sel.start and sel.end == self.occurrence_sel.end;
    const whole = continuing and self.occurrence_whole;
    switch (try b.selectNextOccurrence(whole)) {
        .word => self.occurrence_whole = true,
        .added => self.occurrence_whole = whole,
        .none => return,
    }
    self.occurrence_version = b.version;
    self.occurrence_sel = b.selectionOrCursor();
    self.reveal_cursor = true;
}

/// To the bracket that pairs with the one at the cursor.
pub fn jumpToBracket(self: *App, b: *core.Buffer) !void {
    const t = self.tab();
    try t.highlighter.update(self.gpa, b);
    const pair = core.brackets.matchAt(b, &t.highlighter, b.cursor) orelse return;
    b.moveTo(if (b.cursor <= pair.open + 1) pair.close else pair.open, false);
    self.reveal_cursor = true;
}

/// Finds the bracket at the cursor and its partner again when the text,
/// the cursor or the tab changed. Only for a single cursor with nothing
/// selected.
pub fn updateBracketPair(self: *App) void {
    const t = self.tab();
    const b = &t.buffer;
    const key: [3]u64 = .{ b.version, b.cursor, self.active };
    if (std.mem.eql(u64, &key, &self.bracket_key)) return;
    self.bracket_key = key;
    self.bracket_pair = null;
    if (b.selection() != null or b.hasExtraCursors()) return;
    self.bracket_pair = core.brackets.matchAt(b, &t.highlighter, b.cursor);
}

/// What the bar at the bottom says about the file's indentation: "Tabs"
/// or "Spaces: 4". Null when no file is showing.
pub fn indentLabel(self: *const App, out: []u8) ?[]const u8 {
    const t = self.activeTab();
    if (t.kind != .file) return null;
    const s = i18n.tr().status;
    const indent = t.buffer.indent;
    if (std.mem.eql(u8, indent, "\t")) return s.indent_tabs;
    return i18n.fill(out, s.indent_spaces, .{indent.len});
}

/// The ways to indent, in a menu over the bar at the bottom.
pub fn openIndentMenu(self: *App) void {
    const s = i18n.tr().status;
    var rows: [3][96]u8 = undefined;
    const labels = [3][]const u8{
        s.indent_use_tabs,
        i18n.fill(&rows[1], s.indent_use_spaces, .{2}),
        i18n.fill(&rows[2], s.indent_use_spaces, .{4}),
    };
    self.menu_actions[0] = .{ .set_indent = 0 };
    self.menu_actions[1] = .{ .set_indent = 2 };
    self.menu_actions[2] = .{ .set_indent = 4 };
    self.menu_node = null;
    const r = self.status.indent_rect;
    // Above the bar; the menu keeps itself inside the window.
    self.menu.open(&labels, .{ .x = r.x, .y = r.y - 3 * ContextMenu.row_height - 6 }, App.windowSize(), self.view.font);
}

/// What Tab and new lines indent the file with from now on (the text
/// already there stays as it is).
pub fn setIndent(self: *App, spaces: u8) void {
    if (self.activeTab().kind != .file) return;
    self.buf().indent = switch (spaces) {
        0 => "\t",
        2 => "  ",
        else => "    ",
    };
}

/// Grows the selection to the enclosing scope (see core/scope.zig).
pub fn expandSelection(self: *App, b: *core.Buffer) !void {
    const sel = b.selectionOrCursor();
    if (!self.scopeStepsValid(b)) self.scope_steps.clearRetainingCapacity();
    const r = try core.scope.expand(self.gpa, b.items(), sel) orelse return;
    try self.scope_steps.append(self.gpa, sel);
    self.selectScope(b, r);
}

/// Goes back to the selection before the last "select scope" step.
pub fn shrinkSelection(self: *App, b: *core.Buffer) void {
    if (!self.scopeStepsValid(b)) return self.scope_steps.clearRetainingCapacity();
    const prev = self.scope_steps.pop() orelse return;
    if (prev.start == prev.end) {
        b.moveTo(prev.start, false);
        self.scope_current = prev;
        return;
    }
    self.selectScope(b, prev);
}

pub fn selectScope(self: *App, b: *core.Buffer, r: core.Buffer.Range) void {
    b.moveTo(r.start, false);
    b.moveTo(r.end, true);
    self.scope_version = b.version;
    self.scope_current = r;
    self.reveal_cursor = true;
}

/// Whether the steps still apply: same buffer, unedited, selection untouched.
pub fn scopeStepsValid(self: *const App, b: *const core.Buffer) bool {
    const sel = b.selectionOrCursor();
    return self.scope_steps.items.len > 0 and b.version == self.scope_version and
        sel.start == self.scope_current.start and sel.end == self.scope_current.end;
}

/// While suggestions are showing, arrows pick one, Enter/Tab accept it and
/// Esc closes the list. Returns true if the command was consumed.
pub fn handleCompletionKey(self: *App, cmd: core.Command) !bool {
    const c = &self.completion;
    switch (cmd) {
        .move => |m| {
            if (m.extend) return false;
            const page: isize = CompletionPopup.max_rows;
            switch (m.motion) {
                .line_up => c.moveSelection(-1),
                .line_down => c.moveSelection(1),
                .page_up => c.moveSelection(-page),
                .page_down => c.moveSelection(page),
                else => return false,
            }
        },
        .newline, .indent => try acceptCompletion(self),
        .clear_selection => c.close(),
        else => return false,
    }
    return true;
}

/// Inserts the selected suggestion; after a folder in an import path, goes
/// on to suggest what's inside it.
pub fn acceptCompletion(self: *App) !void {
    const c = &self.completion;
    // What the server needs to hear about the pick, copied: accepting
    // closes the list.
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(self.gpa);
    const word = core.lsp.protocol.toPosition(self.buf().items(), c.word_start);
    if (c.selectedItem()) |item| try raw.appendSlice(self.gpa, item.raw);
    try c.accept(self.buf());
    try lsp.completionPicked(self, raw.items, word);
    if (c.reopen) {
        const t = self.tab();
        try c.refresh(&t.buffer, &t.highlighter, false, problems.filesOf(self, t));
    }
}

/// Opens suggestions while typing a word, after `.` or in an import path,
/// keeps them in sync while editing that word, and closes them on anything
/// else.
pub fn updateCompletion(self: *App, cmd: core.Command) !void {
    try lsp.signatureAfter(self, cmd);
    const c = &self.completion;
    const t = self.tab();
    // Suggestions insert at one cursor only: not with several.
    if (t.buffer.hasExtraCursors()) return c.close();
    const files = problems.filesOf(self, t);
    switch (cmd) {
        .type_char => |cp| {
            const word_char = cp >= 0x80 or core.syntax.js.isIdentChar(@intCast(cp));
            // Quotes, slashes and dashes only matter in an import path.
            const path_char = cp < 0x80 and std.mem.indexOfScalar(u8, "./\"'`@-", @intCast(cp)) != null;
            if (word_char or path_char) try c.refresh(&t.buffer, &t.highlighter, false, files) else c.close();
            // The language server's suggestions join the list when they come.
            if (word_char or cp == '.') try lsp.requestCompletion(self, false);
        },
        .backspace, .delete => if (c.is_open) try c.refresh(&t.buffer, &t.highlighter, false, files),
        .complete => {
            try c.refresh(&t.buffer, &t.highlighter, true, files);
            try lsp.requestCompletion(self, true);
        },
        else => c.close(),
    }
}
