//! Editor commands: what the user asked for, independent of which key did it.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const edit = @import("edit.zig");
const lines = @import("lines.zig");
const motion = @import("motion.zig");

/// A cursor movement; `extend` grows the selection (Shift).
pub const Move = struct { motion: motion.Motion, extend: bool = false };

pub const Command = union(enum) {
    type_char: u21,
    newline,
    indent,
    backspace,
    delete_forward,
    /// Delete from the cursor to where the motion lands (or the selection).
    delete: motion.Motion,
    move: Move,
    select_all,
    clear_selection,
    undo,
    redo,
    /// Open suggestions for the word at the cursor (Ctrl+Space).
    complete,
    // Handled by the app: they need the clipboard, dialogs or completion.
    copy,
    cut,
    paste,
    open,
    open_folder,
    new_file,
    close_tab,
    next_tab,
    prev_tab,
    toggle_sidebar,
    /// Show / focus / hide the terminal panel (Ctrl+`).
    toggle_terminal,
    open_settings,
    /// The Help tab: every shortcut, and changing them.
    open_help,
    /// Cmd+K: close the project folder (tabs stay open).
    close_folder,
    /// Cmd+P: find a file in the project by name.
    quick_open,
    /// Sidebar views: Cmd+Shift+E, Cmd+Shift+F, Cmd+G.
    show_explorer,
    show_search,
    show_git,
    zoom_in,
    zoom_out,
    zoom_reset,
    save,
    save_as,
    find,
    find_replace,
    find_next,
    find_prev,
    /// Search options, in Find and the Search view.
    toggle_match_case,
    toggle_whole_word,
    /// Select the enclosing scope (word, line, brackets...); shrink goes
    /// back a step.
    expand_selection,
    shrink_selection,
    /// Swap the cursor's lines with the ones above / below.
    move_line_up,
    move_line_down,
    /// Word wrap on/off (Option+Z).
    toggle_word_wrap,
    /// Comment the lines out, or back in (Cmd+/).
    toggle_comment,
    /// One level of indentation less / more on the lines (Shift+Tab,
    /// Cmd+[ / Cmd+]).
    outdent,
    indent_lines,
    /// Copy the lines below themselves; delete them.
    duplicate_lines,
    delete_lines,
    /// Cmd+D: the word at the cursor, then the next place with the same
    /// text gets a cursor too.
    select_next_occurrence,
    /// The lists at the top of the editor: a line to go to, a name the
    /// file declares, any command.
    go_to_line,
    go_to_symbol,
    command_palette,
    /// To the bracket that pairs with the one at the cursor.
    jump_to_bracket,
    /// Back to where the cursor was before a jump, and forward again.
    nav_back,
    nav_forward,
    /// Hide the block the cursor is in, show it again; all of them.
    fold,
    unfold,
    fold_all,
    unfold_all,
    /// Run the file through its language's formatter (Shift+Option+F).
    format_document,
};

/// Whether the command changes the text. A read-only view (the tab
/// showing a file's Git changes) lets the others through and ignores
/// these.
pub fn changesText(cmd: Command) bool {
    return switch (cmd) {
        .type_char, .newline, .indent, .backspace, .delete_forward, .delete, .undo, .redo, .cut, .paste, .complete, .move_line_up, .move_line_down, .save, .save_as, .find_replace, .toggle_comment, .outdent, .indent_lines, .duplicate_lines, .delete_lines, .format_document => true,
        else => false,
    };
}

/// Runs a buffer command at every cursor (see `Buffer.eachCursor`).
pub fn runAtCursors(buf: *Buffer, cmd: Command, page_lines: usize) !void {
    switch (cmd) {
        // Whole-buffer commands; they leave a single cursor.
        .select_all, .undo, .redo, .clear_selection => return run(buf, cmd, page_lines),
        // Each block of lines moves once, even with several cursors on it.
        .move_line_up, .move_line_down => {
            const MoveLines = struct {
                up: bool,
                moved: *?Buffer.Range,
                pub fn apply(op: @This(), b: *Buffer) !void {
                    op.moved.* = try edit.moveLines(b, op.up, op.moved.*);
                }
            };
            var moved: ?Buffer.Range = null;
            return buf.eachCursor(MoveLines{ .up = cmd == .move_line_up, .moved = &moved }, cmd == .move_line_down);
        },
        // Tab on a selection of several lines indents them.
        .indent => if (spansLines(buf)) return runAtCursors(buf, .indent_lines, page_lines),
        // The same for these: a block of lines with two cursors on it
        // changes once. Deleting goes from the bottom up, so a cursor
        // left on a deleted line is recognised as done.
        .outdent, .indent_lines, .duplicate_lines, .delete_lines => {
            const LineOp = struct {
                cmd: Command,
                done: *?Buffer.Range,
                pub fn apply(op: @This(), b: *Buffer) !void {
                    op.done.* = try switch (op.cmd) {
                        .outdent => lines.outdentLines(b, op.done.*),
                        .indent_lines => lines.indentLines(b, op.done.*),
                        .duplicate_lines => lines.duplicateLines(b, op.done.*),
                        else => lines.deleteLines(b, op.done.*),
                    };
                }
            };
            var done: ?Buffer.Range = null;
            return buf.eachCursor(LineOp{ .cmd = cmd, .done = &done }, cmd == .delete_lines);
        },
        else => {},
    }
    const Op = struct {
        cmd: Command,
        page_lines: usize,
        pub fn apply(op: @This(), b: *Buffer) !void {
            try run(b, op.cmd, op.page_lines);
        }
    };
    try buf.eachCursor(Op{ .cmd = cmd, .page_lines = page_lines }, false);
}

/// Runs a command that only touches the buffer.
pub fn run(buf: *Buffer, cmd: Command, page_lines: usize) !void {
    switch (cmd) {
        .type_char => |cp| try edit.typeCodepoint(buf, cp),
        .newline => try edit.newline(buf),
        .indent => try edit.indent(buf),
        .backspace => try edit.backspace(buf),
        .delete_forward => try edit.deleteForward(buf),
        .delete => |m| try edit.deleteMotion(buf, m),
        .move => |m| motion.apply(buf, m.motion, m.extend, page_lines),
        .select_all => buf.selectAll(),
        .clear_selection => buf.moveTo(buf.cursor, false),
        .undo => try buf.undo(),
        .redo => try buf.redo(),
        .move_line_up => _ = try edit.moveLines(buf, true, null),
        .move_line_down => _ = try edit.moveLines(buf, false, null),
        .outdent => _ = try lines.outdentLines(buf, null),
        .indent_lines => _ = try lines.indentLines(buf, null),
        .duplicate_lines => _ = try lines.duplicateLines(buf, null),
        .delete_lines => _ = try lines.deleteLines(buf, null),
        .toggle_comment, .select_next_occurrence, .go_to_line, .go_to_symbol, .command_palette, .jump_to_bracket, .nav_back, .nav_forward, .fold, .unfold, .fold_all, .unfold_all, .format_document, .complete, .copy, .cut, .paste, .open, .open_folder, .new_file, .close_tab, .next_tab, .prev_tab, .toggle_sidebar, .toggle_terminal, .open_settings, .open_help, .close_folder, .quick_open, .show_explorer, .show_search, .show_git, .zoom_in, .zoom_out, .zoom_reset, .save, .save_as, .find, .find_replace, .find_next, .find_prev, .toggle_match_case, .toggle_whole_word, .expand_selection, .shrink_selection, .toggle_word_wrap => unreachable,
    }
}

/// Whether the selection goes over more than one line.
fn spansLines(buf: *const Buffer) bool {
    const s = buf.selection() orelse return false;
    return std.mem.indexOfScalar(u8, buf.items()[s.start..s.end], '\n') != null;
}

test {
    _ = @import("../tests/command_test.zig");
}
