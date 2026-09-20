//! Turns this frame's keyboard input into editor commands, following the
//! user's keymap (see ../Keymap.zig, which holds the combinations and their
//! defaults).
const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const core = @import("core");
const Keymap = @import("../Keymap.zig");

const Command = core.Command;

const is_mac = builtin.os.tag == .macos;

pub const Mods = Keymap.Mods;

/// Appends the commands for everything pressed this frame to `out`.
pub fn poll(gpa: std.mem.Allocator, keys: *const Keymap, out: *std.ArrayList(Command)) !void {
    // Shortcuts first: whether one fired decides if the same keys may also
    // type text (Option+Z is word wrap on macOS, not "Ω").
    var shortcut = false;
    for (Keymap.entries) |e| {
        const chord = keys.pressedChord(e.action) orelse continue;
        if (chord.mods.command()) shortcut = true;
        try out.append(gpa, Keymap.command(e.action));
    }

    // Typed text. GLFW withholds characters while Cmd is held, so shortcuts
    // like Cmd+C don't also type a 'c'. Ctrl combos (e.g. Ctrl+Space) can
    // still leak a character, so drop those too; Ctrl+Alt is AltGr on Windows.
    // Left Alt alone is for shortcuts (Alt+C) except on macOS, where Option
    // types accented letters. (Right Alt can be AltGr on Linux.)
    const ctrl = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
    const alt = rl.isKeyDown(.left_alt) or rl.isKeyDown(.right_alt);
    const left_alt_only = !is_mac and rl.isKeyDown(.left_alt) and !ctrl;
    while (true) {
        const cp = rl.getCharPressed();
        if (cp == 0) break;
        if (cp < 32 or cp == 127 or (ctrl and !alt) or left_alt_only or shortcut) continue;
        try out.append(gpa, .{ .type_char = @intCast(cp) });
    }
}

/// Drops everything typed this frame: used while the Help tab is waiting
/// for a new combination, so recording one doesn't also edit a file.
pub fn discardTyped() void {
    while (rl.getCharPressed() != 0) {}
}
