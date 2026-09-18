//! Editor commands: what the user asked for, independent of which key did it.
const Buffer = @import("Buffer.zig");
const edit = @import("edit.zig");
const motion = @import("motion.zig");

pub const Command = union(enum) {
    type_char: u21,
    newline,
    indent,
    backspace,
    delete_forward,
    /// Delete from the cursor to where the motion lands (or the selection).
    delete: motion.Motion,
    move: struct { motion: motion.Motion, extend: bool = false },
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
    /// Cmd+K: close the project folder (tabs stay open).
    close_folder,
    /// Cmd+P: find a file in the project by name.
    quick_open,
    /// Sidebar views: Cmd+Shift+E, Cmd+Shift+F, Ctrl+Shift+G.
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
};

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
        .complete, .copy, .cut, .paste, .open, .open_folder, .new_file, .close_tab, .next_tab, .prev_tab, .toggle_sidebar, .toggle_terminal, .open_settings, .close_folder, .quick_open, .show_explorer, .show_search, .show_git, .zoom_in, .zoom_out, .zoom_reset, .save, .save_as, .find, .find_replace, .find_next, .find_prev => unreachable,
    }
}
