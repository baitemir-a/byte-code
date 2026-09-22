//! A one-line text input, such as the find and replace boxes. It edits a
//! `core.Buffer`, so cursor movement, selection, undo and word deletion
//! behave exactly as in the editor.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");

const TextField = @This();

buffer: core.Buffer,
/// First visible column, so the caret stays in view in long text.
scroll_col: usize = 0,

pub fn init(gpa: std.mem.Allocator) TextField {
    return .{ .buffer = .init(gpa) };
}

pub fn deinit(self: *TextField) void {
    self.buffer.deinit();
}

pub fn text(self: *const TextField) []const u8 {
    return self.buffer.items();
}

/// Replaces the text (undoably) and selects all of it.
pub fn setText(self: *TextField, s: []const u8) !void {
    self.buffer.selectAll();
    try self.buffer.insert(s);
    self.buffer.selectAll();
}

/// Inserts text, keeping only its first line.
pub fn paste(self: *TextField, s: []const u8) !void {
    const line = s[0 .. std.mem.indexOfAny(u8, s, "\r\n") orelse s.len];
    try self.buffer.insert(line);
}

/// Applies an editing command. Returns false for commands a one-line field
/// doesn't handle (Enter, Tab, Esc, clipboard...), leaving them to the caller.
pub fn handle(self: *TextField, cmd: core.Command) !bool {
    const buf = &self.buffer;
    switch (cmd) {
        // Plain insertion: no auto-closing pairs in a search box.
        .type_char => |cp| {
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &enc) catch return true;
            try buf.insert(enc[0..n]);
        },
        .backspace => try core.edit.deleteMotion(buf, .char_left),
        .delete_forward => try core.edit.deleteMotion(buf, .char_right),
        .delete => |m| try core.edit.deleteMotion(buf, m),
        .move => |m| switch (m.motion) {
            .line_up, .line_down, .page_up, .page_down => {},
            else => core.motion.apply(buf, m.motion, m.extend, 1),
        },
        .select_all, .undo, .redo => try core.command.run(buf, cmd, 1),
        else => return false,
    }
    return true;
}

/// Buffer position for a click at window x inside `rect`.
pub fn posAtX(self: *const TextField, rect: rl.Rectangle, font: Font, x: f32) usize {
    const col = @max(0, (x - rect.x - pad) / font.cell_width + 0.5);
    return self.buffer.posAt(0, self.scroll_col + @as(usize, @intFromFloat(col)));
}

const pad = 6;

/// Scrolls horizontally so the caret is visible in a field `width` pixels wide.
pub fn layout(self: *TextField, width: f32, font: Font) void {
    const cols: usize = @intFromFloat(@max(1, (width - 2 * pad) / font.cell_width));
    const caret = self.buffer.column(self.buffer.cursor);
    if (caret < self.scroll_col) self.scroll_col = caret;
    if (caret >= self.scroll_col + cols) self.scroll_col = caret + 1 - cols;
}

pub fn draw(self: *const TextField, rect: rl.Rectangle, font: Font, placeholder: []const u8, focused: bool, show_caret: bool) void {
    rl.drawRectangleRec(rect, theme.background);
    rl.drawRectangleLinesEx(rect, 1, theme.copy(if (focused) theme.accent else theme.popup_border));

    const w = font.cell_width;
    const y = rect.y + (rect.height - theme.font_size) / 2;
    const left = rect.x + pad;
    const max_x = rect.x + rect.width - pad;
    const colX = struct {
        fn f(l: f32, cw: f32, col: usize, scroll: usize) f32 {
            return l + (@as(f32, @floatFromInt(col)) - @as(f32, @floatFromInt(scroll))) * cw;
        }
    }.f;

    if (self.text().len == 0) _ = font.drawFit(placeholder, left, y, max_x, theme.popup_detail);

    if (self.buffer.selection()) |sel| if (focused) {
        const a = colX(left, w, self.buffer.column(sel.start), self.scroll_col);
        const b = colX(left, w, self.buffer.column(sel.end), self.scroll_col);
        const x0 = std.math.clamp(a, left, max_x);
        const x1 = std.math.clamp(b, left, max_x);
        rl.drawRectangleRec(.{ .x = x0, .y = rect.y + 3, .width = x1 - x0, .height = rect.height - 6 }, theme.selection);
    };

    var col: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(self.text()).iterator();
    while (it.nextCodepoint()) |cp| {
        const x = colX(left, w, col, self.scroll_col);
        col = core.text.advance(col, if (cp < 0x80) @intCast(cp) else 'x');
        if (x < left) continue;
        if (x + w > max_x + 1) break;
        if (cp != ' ' and cp != '\t') font.drawCodepoint(cp, x, y, theme.foreground);
    }

    if (focused and show_caret) {
        const x = colX(left, w, self.buffer.column(self.buffer.cursor), self.scroll_col);
        rl.drawRectangleRec(.{ .x = x, .y = rect.y + 3, .width = theme.caret_width, .height = rect.height - 6 }, theme.caret);
    }
}
