//! A dialog of the editor's own, drawn over the window: a question or a
//! message, a row of buttons, and sometimes a "don't ask again" box or a
//! line to type an answer in (hidden, for a password).
//! Enter picks the default button, Esc the cancel one; Tab and the arrow
//! keys move between them.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("theme/lib/theme.zig");
const Font = @import("Font.zig");
const Icons = @import("Icons.zig");

const Modal = @This();

pub const Kind = enum { warning, failure, question };

pub const Button = struct {
    label: []const u8,
    style: Style = .normal,

    pub const Style = enum { normal, primary, danger };
};

/// What was picked: a button, and whether the box was ticked.
pub const Answer = struct { button: usize, checked: bool };

/// What the pointer is on.
pub const Target = union(enum) { button: usize, checkbox };

const max_buttons = 4;
const max_lines = 24;
const pad: f32 = 20;
const button_height: f32 = theme.line_height + 6;
const button_gap: f32 = 8;
const box_size: f32 = 16;
const field_height: f32 = theme.line_height + 8;
const max_input = 1024;

kind: Kind,
title: []const u8,
message: []const u8 = "",
/// Left to right.
buttons: []const Button,
/// What Enter and Esc pick.
default: usize,
cancel: usize,
/// A box under the message, e.g. "Don't ask again".
checkbox: ?[]const u8 = null,
checked: bool = false,
/// A line to type in, and whether what is typed is shown as dots.
input: bool = false,
secret: bool = false,
typed: [max_input]u8 = undefined,
typed_len: usize = 0,

/// The button the keyboard is on, and whether the keyboard has been used
/// (only then is it outlined).
focus: usize = 0,
keyboard: bool = false,
/// Where the pointer went down: a click counts when it comes up there too.
pressed: ?Target = null,

// Laid out by `layout`.
window: rl.Vector2 = .{ .x = 0, .y = 0 },
rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
button_rects: [max_buttons]rl.Rectangle = undefined,
checkbox_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
field_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
title_lines: [max_lines][]const u8 = undefined,
title_count: usize = 0,
message_lines: [max_lines][]const u8 = undefined,
message_count: usize = 0,

pub fn layout(self: *Modal, font: Font, window: rl.Vector2) void {
    std.debug.assert(self.buttons.len <= max_buttons);
    self.window = window;
    const width = @min(480, window.x - 32);
    const text_width = width - 2 * pad - icon_space;
    self.title_count = wrap(font, self.title, text_width, &self.title_lines);
    self.message_count = wrap(font, self.message, text_width, &self.message_lines);

    var h = pad + lineCount(self.title_count) * theme.line_height;
    if (self.message_count > 0) h += 6 + lineCount(self.message_count) * theme.line_height;
    if (self.checkbox != null) h += 14 + theme.line_height;
    if (self.input) h += 14 + field_height;
    h += 20 + button_height + pad;
    // A message too long for the window is cut off at its bottom.
    h = @min(h, window.y - 32);
    self.rect = .{ .x = @round((window.x - width) / 2), .y = @round(@max(16, (window.y - h) / 2.5)), .width = width, .height = h };

    const bottom = self.rect.y + self.rect.height - pad;
    var right = self.rect.x + self.rect.width - pad;
    var i = self.buttons.len;
    while (i > 0) {
        i -= 1;
        const w = @max(88, font.textWidth(self.buttons[i].label) + 28);
        right -= w;
        self.button_rects[i] = .{ .x = right, .y = bottom - button_height, .width = w, .height = button_height };
        right -= button_gap;
    }
    var above = bottom - button_height;
    if (self.checkbox) |label| {
        above -= 14 + theme.line_height;
        self.checkbox_rect = .{ .x = self.rect.x + pad + icon_space, .y = above, .width = box_size + 8 + font.textWidth(label), .height = theme.line_height };
    }
    if (self.input) {
        above -= 14 + field_height;
        const x = self.rect.x + pad + icon_space;
        self.field_rect = .{ .x = x, .y = above, .width = self.rect.x + self.rect.width - pad - x, .height = field_height };
    }
}

/// What was typed in the line.
pub fn typedText(self: *const Modal) []const u8 {
    return self.typed[0..self.typed_len];
}

/// Adds typed (or pasted) text to the line; the part that doesn't fit is
/// dropped, and so are line breaks.
pub fn typeText(self: *Modal, s: []const u8) void {
    if (!self.input) return;
    for (s) |c| {
        if (c == '\n' or c == '\r') continue;
        if (self.typed_len == self.typed.len) return;
        self.typed[self.typed_len] = c;
        self.typed_len += 1;
    }
}

/// Forgets what was typed, so a password doesn't linger in memory.
pub fn wipe(self: *Modal) void {
    std.crypto.secureZero(u8, &self.typed);
    self.typed_len = 0;
}

const icon_space: f32 = 30;

fn lineCount(n: usize) f32 {
    return @floatFromInt(n);
}

pub fn hitTest(self: *const Modal, p: rl.Vector2) ?Target {
    for (self.button_rects[0..self.buttons.len], 0..) |r, i| {
        if (rl.checkCollisionPointRec(p, r)) return .{ .button = i };
    }
    if (self.checkbox != null and rl.checkCollisionPointRec(p, self.checkbox_rect)) return .checkbox;
    return null;
}

/// A key: returns the answer when it picks a button.
pub fn key(self: *Modal, k: rl.KeyboardKey, shift: bool) ?Answer {
    const n = self.buttons.len;
    switch (k) {
        .escape => return self.answer(self.cancel),
        .enter, .kp_enter => return self.answer(if (self.keyboard and !self.input) self.focus else self.default),
        .space => if (self.keyboard and !self.input) return self.answer(self.focus),
        // The line has the keyboard: the last character goes.
        .backspace => if (self.input and self.typed_len > 0) {
            var end = self.typed_len - 1;
            while (end > 0 and self.typed[end] & 0xC0 == 0x80) end -= 1;
            self.typed_len = end;
        },
        // Between the buttons, unless the line has the keyboard (then
        // Enter answers).
        .left, .right, .tab => if (!self.input) {
            const back = k == .left or (k == .tab and shift);
            if (self.keyboard) self.focus = if (back) (self.focus + n - 1) % n else (self.focus + 1) % n;
            self.keyboard = true;
        },
        else => {},
    }
    return null;
}

pub fn answer(self: *const Modal, button: usize) Answer {
    return .{ .button = button, .checked = self.checked };
}

pub fn draw(self: *const Modal, font: Font) void {
    rl.drawRectangleRec(.{ .x = 0, .y = 0, .width = self.window.x, .height = self.window.y }, .{ .r = 0, .g = 0, .b = 0, .a = 110 });
    const r = self.rect;
    const round = 10 / @min(r.width, r.height);
    rl.drawRectangleRounded(.{ .x = r.x + 2, .y = r.y + 6, .width = r.width, .height = r.height }, round, 8, theme.popup_shadow);
    rl.drawRectangleRounded(r, round, 8, theme.popup_background);
    rl.drawRectangleRoundedLinesEx(r, round, 8, 1, theme.popup_border);
    theme.clip(r);
    defer rl.endScissorMode();

    const x = r.x + pad + icon_space;
    var y = r.y + pad;
    const icon: Icons.Icon, const icon_color = switch (self.kind) {
        .warning => .{ .triangle_alert, theme.diff_modified },
        .failure => .{ .circle_x, theme.diff_deleted },
        .question => .{ .key_round, theme.accent },
    };
    font.drawIcon(icon, .{ .x = r.x + pad + 9, .y = y + theme.line_height / 2 }, .large, theme.copy(icon_color));
    for (self.title_lines[0..self.title_count]) |line| {
        _ = font.drawText(line, x, y + (theme.line_height - theme.font_size) / 2, theme.font_size, theme.foreground);
        y += theme.line_height;
    }
    if (self.message_count > 0) y += 6;
    const text_bottom = if (self.input) self.field_rect.y - 8 else if (self.checkbox != null) self.checkbox_rect.y - 8 else self.button_rects[0].y - 12;
    for (self.message_lines[0..self.message_count]) |line| {
        if (y + theme.line_height > text_bottom) break;
        _ = font.drawText(line, x, y + (theme.line_height - theme.font_size) / 2, theme.font_size, theme.popup_detail);
        y += theme.line_height;
    }

    if (self.input) drawField(self, font);
    const mouse = rl.getMousePosition();
    const hovered = self.hitTest(mouse);
    if (self.checkbox) |label| {
        const c = self.checkbox_rect;
        const box: rl.Rectangle = .{ .x = c.x, .y = c.y + (c.height - box_size) / 2, .width = box_size, .height = box_size };
        if (self.checked) {
            rl.drawRectangleRounded(box, 0.25, 6, theme.accent);
            font.drawIcon(.check, .{ .x = box.x + box_size / 2, .y = box.y + box_size / 2 }, .small, theme.background);
        } else {
            const on = hovered != null and hovered.? == .checkbox;
            rl.drawRectangleRoundedLinesEx(box, 0.25, 6, 1, theme.copy(if (on) theme.accent else theme.popup_detail));
        }
        _ = font.drawText(label, box.x + box_size + 8, c.y + (c.height - theme.font_size) / 2, theme.font_size, theme.foreground);
    }

    for (self.buttons, self.button_rects[0..self.buttons.len], 0..) |b, br, i| {
        const on = hovered != null and hovered.? == .button and hovered.?.button == i;
        const fill: rl.Color = switch (b.style) {
            .primary => if (on) theme.accentDim(0.8) else theme.accent,
            .danger => if (on) dim(theme.diff_deleted) else theme.diff_deleted,
            .normal => if (on) theme.tab_close_hover else theme.popup_background,
        };
        rl.drawRectangleRounded(br, 0.25, 8, theme.copy(fill));
        if (b.style == .normal) rl.drawRectangleRoundedLinesEx(br, 0.25, 8, 1, theme.popup_border);
        if (self.keyboard and self.focus == i) {
            rl.drawRectangleRoundedLinesEx(.{ .x = br.x - 3, .y = br.y - 3, .width = br.width + 6, .height = br.height + 6 }, 0.3, 8, 2, theme.accent);
        }
        const text_color = if (b.style == .normal) theme.foreground else theme.background;
        const tx = br.x + (br.width - font.textWidth(b.label)) / 2;
        _ = font.drawText(b.label, tx, br.y + (br.height - theme.font_size) / 2, theme.font_size, theme.copy(text_color));
    }
}

/// The line being typed in, with the caret at its end; a secret shows a
/// dot for each character.
fn drawField(self: *const Modal, font: Font) void {
    const f = self.field_rect;
    rl.drawRectangleRec(f, theme.background);
    rl.drawRectangleLinesEx(f, 1, theme.accent);
    const y = f.y + (f.height - theme.font_size) / 2;
    const left = f.x + 8;
    const right = f.x + f.width - 8;
    var x = left;
    if (self.secret) {
        const dots = std.unicode.utf8CountCodepoints(self.typedText()) catch self.typed_len;
        const step = font.cell_width;
        const shown = @min(dots, @as(usize, @intFromFloat(@max(1, (right - left) / step))));
        for (0..shown) |_| {
            rl.drawCircleV(.{ .x = x + step / 2, .y = f.y + f.height / 2 }, 3, theme.foreground);
            x += step;
        }
    } else {
        // Long text: its end, where the caret is, stays in view.
        var text = self.typedText();
        while (text.len > 0 and font.textWidth(text) > right - left) {
            text = text[std.unicode.utf8ByteSequenceLength(text[0]) catch 1 ..];
        }
        x = font.drawFit(text, left, y, right, theme.foreground);
    }
    // The caret blinks like the editor's.
    if (@mod(rl.getTime(), 1.0) < 0.5) rl.drawRectangleRec(.{ .x = x, .y = f.y + 4, .width = theme.caret_width, .height = f.height - 8 }, theme.caret);
}

/// A color a little darker, for a button under the pointer.
fn dim(c: rl.Color) rl.Color {
    return .{ .r = c.r - c.r / 6, .g = c.g - c.g / 6, .b = c.b - c.b / 6, .a = c.a };
}

/// Splits `text` into lines no wider than `width`: at its own line
/// breaks, then between words, and inside a word too long for a line (a
/// path, say). Returns how many went into `out`.
pub fn wrap(font: Font, text: []const u8, width: f32, out: [][]const u8) usize {
    var n: usize = 0;
    var paragraphs = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\r\n "), '\n');
    while (paragraphs.next()) |raw| {
        var rest = std.mem.trimEnd(u8, raw, "\r ");
        if (rest.len == 0) {
            if (n == out.len) return n;
            out[n] = "";
            n += 1;
            continue;
        }
        while (rest.len > 0) {
            if (n == out.len) return n;
            const end = fitEnd(font, rest, width);
            out[n] = std.mem.trimEnd(u8, rest[0..end], " ");
            n += 1;
            rest = std.mem.trimStart(u8, rest[end..], " ");
        }
    }
    return n;
}

/// How much of `s` goes on one line: up to the last space that fits, or
/// as many characters as fit when no space does (always at least one).
fn fitEnd(font: Font, s: []const u8, width: f32) usize {
    if (font.textWidth(s) <= width) return s.len;
    var last_space: ?usize = null;
    var last_fit: usize = 0;
    var view = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (view.nextCodepointSlice()) |cp| {
        const end = view.i;
        if (font.textWidth(s[0..end]) > width) break;
        last_fit = end;
        if (cp.len == 1 and cp[0] == ' ') last_space = end;
    }
    if (last_space) |at| return at;
    if (last_fit > 0) return last_fit;
    return @min(s.len, std.unicode.utf8ByteSequenceLength(s[0]) catch 1);
}
