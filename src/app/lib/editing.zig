//! Editor commands beyond plain editing: moving by screen rows,
//! select scope, and the completion popup.
const std = @import("std");
const core = @import("core");
const Tab = @import("../Tab.zig");
const View = @import("../../ui/editor/View.zig");
const CompletionPopup = @import("../../ui/editor/CompletionPopup.zig");
const App = @import("../App.zig");
const problems = @import("problems.zig");

/// With word wrap, Up / Down / Page Up / Page Down go by screen rows (a
/// long line has several). Returns false for other moves, or when the rows
/// aren't up to date with an edit this frame.
pub fn moveByRows(self: *App, b: *core.Buffer, m: core.command.Move) bool {
    if (!self.view.wrap or !self.view.rowsCurrent(b)) return false;
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
    try c.accept(self.buf());
    if (c.reopen) {
        const t = self.tab();
        try c.refresh(&t.buffer, &t.highlighter, false, problems.filesOf(self, t));
    }
}

/// Opens suggestions while typing a word, after `.` or in an import path,
/// keeps them in sync while editing that word, and closes them on anything
/// else.
pub fn updateCompletion(self: *App, cmd: core.Command) !void {
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
        },
        .backspace, .delete => if (c.is_open) try c.refresh(&t.buffer, &t.highlighter, false, files),
        .complete => try c.refresh(&t.buffer, &t.highlighter, true, files),
        else => c.close(),
    }
}
