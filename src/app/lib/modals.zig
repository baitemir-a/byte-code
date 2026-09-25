//! The editor's own dialogs (see ui/Modal.zig) for questions and errors.
//! Each call waits for the answer, like a system dialog would: it runs
//! frames of its own, drawing the editor under the dialog, until a button
//! is picked. File pickers are still the system's (dialogs.zig).
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../../ui/theme/lib/theme.zig");
const Modal = @import("../../ui/Modal.zig");
const anim = @import("../../ui/anim.zig");
const App = @import("../App.zig");
const i18n = @import("../../i18n/i18n.zig");

pub const Choice = enum { save, discard, cancel };

/// The answer to `confirmRemember`: go ahead, go ahead and stop asking,
/// or do nothing.
pub const Confirmation = enum { cancel, ok, ok_always };

/// Shows `modal` until a button is picked. Closing the window meanwhile
/// counts as its cancel button.
pub fn runModal(self: *App, m: *Modal) Modal.Answer {
    self.modal = m;
    defer self.modal = null;
    defer rl.setMouseCursor(self.cursor_shape);
    const picked = ask(self, m);
    // It fades out where it stands before the editor has the window back.
    while (m.shown > 0.02) {
        anim.newFrame();
        m.step(false);
        App.matchMouseToLayout();
        self.relayout() catch {};
        m.layout(self.view.font, App.windowSize());
        drawOnce(self);
        if (!anim.enabled) break;
    }
    return picked;
}

/// The dialog's own frames, until a button is picked.
fn ask(self: *App, m: *Modal) Modal.Answer {
    m.focus = m.default;
    // What was typed before it opened isn't meant for it.
    while (rl.getKeyPressed() != .null) {}
    while (rl.getCharPressed() != 0) {}
    var first = true;
    while (true) : (first = false) {
        // The window's close button, unless it is what opened the dialog
        // (this frame's flag is still up then).
        if (!first and rl.windowShouldClose()) return m.answer(m.cancel);
        App.matchMouseToLayout();
        anim.newFrame();
        m.step(true);
        self.relayout() catch {};
        m.layout(self.view.font, App.windowSize());

        const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
        const primary = if (@import("builtin").os.tag == .macos)
            rl.isKeyDown(.left_super) or rl.isKeyDown(.right_super)
        else
            rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
        while (true) {
            const k = rl.getKeyPressed();
            if (k == .null) break;
            if (primary and k == .v) {
                m.typeText(rl.getClipboardText());
                continue;
            }
            if (m.key(k, shift)) |a| return a;
        }
        // Held down, Backspace keeps going.
        if (rl.isKeyPressedRepeat(.backspace)) _ = m.key(.backspace, false);
        while (true) {
            const cp = rl.getCharPressed();
            if (cp <= 0) break;
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(cp), &enc) catch continue;
            m.typeText(enc[0..n]);
        }

        const p = rl.getMousePosition();
        const hit = m.hitTest(p);
        if (rl.isMouseButtonPressed(.left)) m.pressed = hit;
        // At release, so the editor doesn't get it once the dialog is gone.
        if (rl.isMouseButtonReleased(.left)) {
            if (m.pressed != null and hit != null and std.meta.eql(m.pressed.?, hit.?)) switch (hit.?) {
                .button => |i| return m.answer(i),
                .checkbox => m.checked = !m.checked,
            };
            m.pressed = null;
        }
        rl.setMouseCursor(if (hit != null) .pointing_hand else .default);

        drawOnce(self);
    }
}

/// One frame of the editor with the dialog over it.
fn drawOnce(self: *App) void {
    rl.beginDrawing();
    rl.gl.rlPushMatrix();
    rl.gl.rlScalef(theme.zoom, theme.zoom, 1);
    self.draw();
    rl.gl.rlPopMatrix();
    rl.endDrawing();
}

/// Draws the open dialog, if any, over the frame (App.draw calls it).
pub fn drawModal(self: *const App) void {
    const m = self.modal orelse return;
    m.draw(self.view.font);
}

/// A warning with Cancel and an `ok_label` button. Returns true if the
/// user chose `ok_label`.
pub fn confirm(self: *App, message: []const u8, detail: []const u8, ok_label: []const u8) bool {
    var m: Modal = .{
        .kind = .warning,
        .title = message,
        .message = detail,
        .buttons = &.{ .{ .label = i18n.tr().common.cancel }, .{ .label = ok_label, .style = .danger } },
        .default = 1,
        .cancel = 0,
    };
    return runModal(self, &m).button == 1;
}

/// The same as `confirm`, with a "don't ask again" box.
pub fn confirmRemember(self: *App, message: []const u8, detail: []const u8, ok_label: []const u8, always_label: []const u8) Confirmation {
    var m: Modal = .{
        .kind = .warning,
        .title = message,
        .message = detail,
        .buttons = &.{ .{ .label = i18n.tr().common.cancel }, .{ .label = ok_label, .style = .danger } },
        .default = 1,
        .cancel = 0,
        .checkbox = always_label,
    };
    const a = runModal(self, &m);
    if (a.button != 1) return .cancel;
    return if (a.checked) .ok_always else .ok;
}

/// "Save changes to <name>?" with Don't Save / Cancel / Save.
pub fn askSaveChanges(self: *App, name: []const u8) !Choice {
    const t = i18n.tr();
    const question = try i18n.fillAlloc(self.gpa, t.dialogs.save_changes, .{name});
    defer self.gpa.free(question);
    var m: Modal = .{
        .kind = .warning,
        .title = question,
        .buttons = &.{
            .{ .label = t.dialogs.dont_save },
            .{ .label = t.common.cancel },
            .{ .label = t.dialogs.save, .style = .primary },
        },
        .default = 2,
        .cancel = 1,
    };
    return switch (runModal(self, &m).button) {
        0 => .discard,
        2 => .save,
        else => .cancel,
    };
}

/// An error, with an OK button.
pub fn showError(self: *App, title: []const u8, message: []const u8) void {
    var m: Modal = .{
        .kind = .failure,
        .title = title,
        .message = message,
        .buttons = &.{.{ .label = i18n.tr().common.ok, .style = .primary }},
        .default = 0,
        .cancel = 0,
    };
    _ = runModal(self, &m);
}

/// Asks for a line of text, e.g. a password (`secret` hides it). Null
/// when cancelled. Caller frees, zeroing it first when it is a secret.
pub fn askText(self: *App, title: []const u8, message: []const u8, secret: bool) !?[]u8 {
    const t = i18n.tr().common;
    // The dialog is big (it holds what is typed): not on the stack twice.
    const m = try self.gpa.create(Modal);
    defer self.gpa.destroy(m);
    m.* = .{
        .kind = .question,
        .title = title,
        .message = message,
        .buttons = &.{ .{ .label = t.cancel }, .{ .label = t.ok, .style = .primary } },
        .default = 1,
        .cancel = 0,
        .input = true,
        .secret = secret,
    };
    defer m.wipe();
    if (runModal(self, m).button != 1) return null;
    return try self.gpa.dupe(u8, m.typedText());
}
