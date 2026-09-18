//! Translates this frame's keyboard input into editor commands.
//! Shortcuts follow platform conventions: Cmd/Option on macOS, Ctrl elsewhere.
const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const core = @import("core");

const Command = core.Command;
const Motion = core.Motion;

const is_mac = builtin.os.tag == .macos;

pub const Mods = struct {
    shift: bool,
    /// Cmd on macOS, Ctrl elsewhere: clipboard, undo, line/document jumps.
    primary: bool,
    /// Option on macOS, Ctrl elsewhere: word-wise movement and deletion.
    word: bool,

    pub fn current() Mods {
        const ctrl = down(.left_control) or down(.right_control);
        return .{
            .shift = down(.left_shift) or down(.right_shift),
            .primary = if (is_mac) down(.left_super) or down(.right_super) else ctrl,
            .word = if (is_mac) down(.left_alt) or down(.right_alt) else ctrl,
        };
    }
};

/// Appends the commands for everything pressed this frame to `out`.
pub fn poll(gpa: std.mem.Allocator, out: *std.ArrayList(Command)) !void {
    const m = Mods.current();
    const extend = m.shift;
    const ctrl = down(.left_control) or down(.right_control);
    const alt = down(.left_alt) or down(.right_alt);

    // Typed text. GLFW withholds characters while Cmd is held, so shortcuts
    // like Cmd+C don't also type a 'c'. Ctrl combos (e.g. Ctrl+Space) can
    // still leak a character, so drop those too; Ctrl+Alt is AltGr on Windows.
    while (true) {
        const cp = rl.getCharPressed();
        if (cp == 0) break;
        if (cp < 32 or cp == 127 or (ctrl and !alt)) continue;
        try out.append(gpa, .{ .type_char = @intCast(cp) });
    }

    if (ctrl and pressed(.space)) try out.append(gpa, .complete);
    if (ctrl and m.shift and pressed(.g)) try out.append(gpa, .show_git);
    // Cmd+T (Ctrl+T elsewhere) toggles the terminal; so do Ctrl+` and
    // Cmd/Ctrl+J, as in VS Code.
    if (ctrl and pressed(.grave)) try out.append(gpa, .toggle_terminal);

    if (m.primary) {
        if (pressed(.a)) try out.append(gpa, .select_all);
        if (pressed(.c)) try out.append(gpa, .copy);
        if (pressed(.x)) try out.append(gpa, .cut);
        if (pressed(.v)) try out.append(gpa, .paste);
        if (pressed(.z)) try out.append(gpa, if (m.shift) .redo else .undo);
        if (!is_mac and pressed(.y)) try out.append(gpa, .redo);
        if (pressed(.o)) try out.append(gpa, if (m.shift) .open_folder else .open);
        if (pressed(.b)) try out.append(gpa, .toggle_sidebar);
        if (pressed(.n)) try out.append(gpa, .new_file);
        if (pressed(.t) or pressed(.j)) try out.append(gpa, .toggle_terminal);
        if (pressed(.comma)) try out.append(gpa, .open_settings);
        if (pressed(.k)) try out.append(gpa, .close_folder);
        if (pressed(.p)) try out.append(gpa, .quick_open);
        // Cmd+= (Cmd++ with Shift), Cmd+-, Cmd+0 zoom, as in browsers.
        if (pressed(.equal) or pressed(.kp_add)) try out.append(gpa, .zoom_in);
        if (pressed(.minus) or pressed(.kp_subtract)) try out.append(gpa, .zoom_out);
        if (pressed(.zero) or pressed(.kp_0)) try out.append(gpa, .zoom_reset);
        if (pressed(.w)) try out.append(gpa, .close_tab);
        // Cmd+Shift+[ and ] switch tabs, like in other macOS apps.
        if (m.shift and pressed(.left_bracket)) try out.append(gpa, .prev_tab);
        if (m.shift and pressed(.right_bracket)) try out.append(gpa, .next_tab);
        if (pressed(.s)) try out.append(gpa, if (m.shift) .save_as else .save);
        // Cmd+F find, Cmd+Option+F find & replace (macOS convention),
        // Cmd+Shift+F search the project.
        if (pressed(.f)) try out.append(gpa, if (m.shift) .show_search else if (is_mac and alt) .find_replace else .find);
        if (m.shift and pressed(.e)) try out.append(gpa, .show_explorer);
        if (!is_mac and pressed(.h)) try out.append(gpa, .find_replace);
        // (Ctrl+Shift+G is the Git view, below.)
        if (pressed(.g) and !(ctrl and m.shift)) try out.append(gpa, if (m.shift) .find_prev else .find_next);
    }

    if (pressed(.f3)) try out.append(gpa, if (m.shift) .find_prev else .find_next);
    if (pressed(.enter) or pressed(.kp_enter)) try out.append(gpa, .newline);
    // Ctrl+Tab and Option+Tab cycle tabs; plain Tab indents.
    if (pressed(.tab)) try out.append(gpa, if (ctrl or alt) (if (m.shift) Command.prev_tab else .next_tab) else .indent);
    if (pressed(.escape)) try out.append(gpa, .clear_selection);

    if (pressed(.backspace)) try out.append(gpa, if (m.primary)
        .{ .delete = .line_start }
    else if (m.word)
        .{ .delete = .word_left }
    else
        .backspace);

    if (pressed(.delete)) try out.append(gpa, if (m.primary)
        .{ .delete = .line_end }
    else if (m.word)
        .{ .delete = .word_right }
    else
        .delete_forward);

    const moves = [_]struct { key: rl.KeyboardKey, motion: Motion }{
        .{ .key = .left, .motion = if (m.primary and is_mac) .line_start else if (m.word) .word_left else .char_left },
        .{ .key = .right, .motion = if (m.primary and is_mac) .line_end else if (m.word) .word_right else .char_right },
        .{ .key = .up, .motion = if (m.primary) .doc_start else .line_up },
        .{ .key = .down, .motion = if (m.primary) .doc_end else .line_down },
        .{ .key = .home, .motion = if (m.primary) .doc_start else .line_start },
        .{ .key = .end, .motion = if (m.primary) .doc_end else .line_end },
        .{ .key = .page_up, .motion = .page_up },
        .{ .key = .page_down, .motion = .page_down },
    };
    for (moves) |mv| {
        if (pressed(mv.key)) try out.append(gpa, .{ .move = .{ .motion = mv.motion, .extend = extend } });
    }
}

fn down(key: rl.KeyboardKey) bool {
    return rl.isKeyDown(key);
}

/// Pressed this frame, including OS key-repeat while held.
fn pressed(key: rl.KeyboardKey) bool {
    return rl.isKeyPressed(key) or rl.isKeyPressedRepeat(key);
}
