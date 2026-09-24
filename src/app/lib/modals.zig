//! The editor's own dialogs (see ui/Modal.zig) for questions and errors.
//! Each call waits for the answer, like a system dialog would: it runs
//! frames of its own, drawing the editor under the dialog, until a button
//! is picked. File pickers are still the system's (dialogs.zig).
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../../ui/theme/lib/theme.zig");
const Modal = @import("../../ui/Modal.zig");
const App = @import("../App.zig");
const i18n = @import("../../i18n/i18n.zig");

pub const Choice = enum { save, discard, cancel };

/// The answer to `confirmRemember`: go ahead, go ahead and stop asking,
/// or do nothing.
pub const Confirmation = enum { cancel, ok, ok_always };

/// Shows `modal` until a button is picked. Closing the window meanwhile
/// counts as its cancel button.
pub fn runModal(self: *App, modal: Modal) Modal.Answer {
    var m = modal;
    m.focus = m.default;
    self.modal = &m;
    defer self.modal = null;
    defer rl.setMouseCursor(self.cursor_shape);
    // What was typed before it opened isn't meant for it.
    while (rl.getKeyPressed() != .null) {}
    while (rl.getCharPressed() != 0) {}
    var first = true;
    while (true) : (first = false) {
        // The window's close button, unless it is what opened the dialog
        // (this frame's flag is still up then).
        if (!first and rl.windowShouldClose()) return m.answer(m.cancel);
        App.matchMouseToLayout();
        self.relayout() catch {};
        m.layout(self.view.font, App.windowSize());

        const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
        while (true) {
            const k = rl.getKeyPressed();
            if (k == .null) break;
            if (m.key(k, shift)) |a| return a;
        }
        while (rl.getCharPressed() != 0) {}

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

        rl.beginDrawing();
        rl.gl.rlPushMatrix();
        rl.gl.rlScalef(theme.zoom, theme.zoom, 1);
        self.draw();
        rl.gl.rlPopMatrix();
        rl.endDrawing();
    }
}

/// Draws the open dialog, if any, over the frame (App.draw calls it).
pub fn drawModal(self: *const App) void {
    const m = self.modal orelse return;
    m.draw(self.view.font);
}

/// A warning with Cancel and an `ok_label` button. Returns true if the
/// user chose `ok_label`.
pub fn confirm(self: *App, message: []const u8, detail: []const u8, ok_label: []const u8) bool {
    const a = runModal(self, .{
        .kind = .warning,
        .title = message,
        .message = detail,
        .buttons = &.{ .{ .label = i18n.tr().common.cancel }, .{ .label = ok_label, .style = .danger } },
        .default = 1,
        .cancel = 0,
    });
    return a.button == 1;
}

/// The same as `confirm`, with a "don't ask again" box.
pub fn confirmRemember(self: *App, message: []const u8, detail: []const u8, ok_label: []const u8, always_label: []const u8) Confirmation {
    const a = runModal(self, .{
        .kind = .warning,
        .title = message,
        .message = detail,
        .buttons = &.{ .{ .label = i18n.tr().common.cancel }, .{ .label = ok_label, .style = .danger } },
        .default = 1,
        .cancel = 0,
        .checkbox = always_label,
    });
    if (a.button != 1) return .cancel;
    return if (a.checked) .ok_always else .ok;
}

/// "Save changes to <name>?" with Don't Save / Cancel / Save.
pub fn askSaveChanges(self: *App, name: []const u8) !Choice {
    const t = i18n.tr();
    const question = try i18n.fillAlloc(self.gpa, t.dialogs.save_changes, .{name});
    defer self.gpa.free(question);
    const a = runModal(self, .{
        .kind = .warning,
        .title = question,
        .buttons = &.{
            .{ .label = t.dialogs.dont_save },
            .{ .label = t.common.cancel },
            .{ .label = t.dialogs.save, .style = .primary },
        },
        .default = 2,
        .cancel = 1,
    });
    return switch (a.button) {
        0 => .discard,
        2 => .save,
        else => .cancel,
    };
}

/// An error, with an OK button.
pub fn showError(self: *App, title: []const u8, message: []const u8) void {
    _ = runModal(self, .{
        .kind = .failure,
        .title = title,
        .message = message,
        .buttons = &.{.{ .label = i18n.tr().common.ok, .style = .primary }},
        .default = 0,
        .cancel = 0,
    });
}
