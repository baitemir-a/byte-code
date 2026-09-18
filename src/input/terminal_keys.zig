//! Keyboard input for the terminal: turns this frame's keys into the bytes
//! a terminal sends (Ctrl+C → 0x03, ↑ → ESC [ A, Enter → CR...), plus a few
//! actions the app handles (copy, paste, clear, hide).
const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");

const is_mac = builtin.os.tag == .macos;

pub const Action = enum {
    none,
    copy,
    paste,
    /// Clear the screen and scrollback (Cmd+K).
    clear,
    /// Ctrl+` (or Ctrl+T on Windows/Linux): hide the terminal and go back
    /// to the editor.
    toggle,
    /// A Cmd shortcut on macOS (Cmd+S, Cmd+O, Cmd+W...): the app handles
    /// it as an editor shortcut instead.
    shortcut,
};

/// Appends the bytes for this frame's keys to `out`. `app_cursor` is the
/// terminal's application-cursor-keys mode (vim, less...).
pub fn poll(gpa: std.mem.Allocator, out: *std.ArrayList(u8), app_cursor: bool) !Action {
    const shift = down(.left_shift) or down(.right_shift);
    const ctrl = down(.left_control) or down(.right_control);
    const alt = down(.left_alt) or down(.right_alt);
    const cmd = down(.left_super) or down(.right_super);

    if (ctrl and pressed(.grave)) return .toggle;
    // Option+Tab switches editor tabs, even from the terminal.
    if (alt and pressed(.tab)) return .shortcut;
    if (!is_mac and ctrl and pressed(.t)) return .toggle;

    if (is_mac and cmd) {
        // Line editing like macOS Terminal: Cmd+←/→ to the start/end of the
        // line, Cmd+Backspace deletes to its start.
        if (pressed(.left)) try out.append(gpa, 0x01);
        if (pressed(.right)) try out.append(gpa, 0x05);
        if (pressed(.backspace)) try out.append(gpa, 0x15);
        if (out.items.len > 0) return .none;
        if (pressed(.c)) return .copy;
        if (pressed(.v)) return .paste;
        if (pressed(.k)) return .clear;
        return .shortcut;
    }
    if (!is_mac and ctrl and shift) {
        if (pressed(.c)) return .copy;
        if (pressed(.v)) return .paste;
    }

    // Typed text. With Ctrl held the key codes below produce control bytes.
    while (true) {
        const cp = rl.getCharPressed();
        if (cp == 0) break;
        if (ctrl and !alt) continue;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch continue;
        try out.appendSlice(gpa, buf[0..n]);
    }

    if (ctrl) {
        // Ctrl+A..Z → 0x01..0x1A, and the usual punctuation controls.
        var key: c_int = @intFromEnum(rl.KeyboardKey.a);
        while (key <= @intFromEnum(rl.KeyboardKey.z)) : (key += 1) {
            if (pressed(@enumFromInt(key))) try out.append(gpa, @intCast(key - @intFromEnum(rl.KeyboardKey.a) + 1));
        }
        if (pressed(.left_bracket)) try out.append(gpa, 0x1b);
        if (pressed(.backslash)) try out.append(gpa, 0x1c);
        if (pressed(.right_bracket)) try out.append(gpa, 0x1d);
        if (pressed(.space)) try out.append(gpa, 0x00);
    }

    const cursor_prefix: []const u8 = if (app_cursor) "\x1bO" else "\x1b[";
    const keys = [_]struct { key: rl.KeyboardKey, seq: []const u8 }{
        .{ .key = .enter, .seq = "\r" },
        .{ .key = .kp_enter, .seq = "\r" },
        .{ .key = .escape, .seq = "\x1b" },
        .{ .key = .home, .seq = "\x1b[H" },
        .{ .key = .end, .seq = "\x1b[F" },
        .{ .key = .page_up, .seq = "\x1b[5~" },
        .{ .key = .page_down, .seq = "\x1b[6~" },
        .{ .key = .insert, .seq = "\x1b[2~" },
        .{ .key = .delete, .seq = "\x1b[3~" },
        .{ .key = .f1, .seq = "\x1bOP" },
        .{ .key = .f2, .seq = "\x1bOQ" },
        .{ .key = .f3, .seq = "\x1bOR" },
        .{ .key = .f4, .seq = "\x1bOS" },
        .{ .key = .f5, .seq = "\x1b[15~" },
        .{ .key = .f6, .seq = "\x1b[17~" },
        .{ .key = .f7, .seq = "\x1b[18~" },
        .{ .key = .f8, .seq = "\x1b[19~" },
        .{ .key = .f9, .seq = "\x1b[20~" },
        .{ .key = .f10, .seq = "\x1b[21~" },
        .{ .key = .f11, .seq = "\x1b[23~" },
        .{ .key = .f12, .seq = "\x1b[24~" },
    };
    for (keys) |k| {
        if (pressed(k.key)) try out.appendSlice(gpa, k.seq);
    }
    // Option+Backspace / Option+←→ edit by word, like macOS Terminal.
    if (pressed(.backspace)) try out.appendSlice(gpa, if (alt) "\x1b\x7f" else "\x7f");
    if (pressed(.tab)) try out.appendSlice(gpa, if (shift) "\x1b[Z" else "\t");
    const arrows = [_]struct { key: rl.KeyboardKey, final: u8, word: []const u8 }{
        .{ .key = .up, .final = 'A', .word = "" },
        .{ .key = .down, .final = 'B', .word = "" },
        .{ .key = .right, .final = 'C', .word = "\x1bf" },
        .{ .key = .left, .final = 'D', .word = "\x1bb" },
    };
    for (arrows) |a| {
        if (!pressed(a.key)) continue;
        if (alt and a.word.len > 0) {
            try out.appendSlice(gpa, a.word);
        } else {
            try out.appendSlice(gpa, cursor_prefix);
            try out.append(gpa, a.final);
        }
    }
    return .none;
}

fn down(key: rl.KeyboardKey) bool {
    return rl.isKeyDown(key);
}

fn pressed(key: rl.KeyboardKey) bool {
    return rl.isKeyPressed(key) or rl.isKeyPressedRepeat(key);
}
