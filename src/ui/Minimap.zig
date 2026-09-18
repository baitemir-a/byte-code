//! The minimap: a zoomed-out picture of the whole file at the editor's
//! right edge, with the visible part marked. Click or drag it to scroll.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("theme.zig");
const View = @import("View.zig");

const Minimap = @This();

pub const width: f32 = 96;
/// Size of one line and one character, in UI units.
const line_h: f32 = 2;
const char_w: f32 = 1;
const pad: f32 = 6;
/// The whole minimap is drawn slightly see-through, so it stays in the
/// background of the editor.
pub const opacity: f32 = 0.75;

fn faded(c: rl.Color) rl.Color {
    var out = c;
    out.a = @intFromFloat(@as(f32, @floatFromInt(c.a)) * opacity);
    return out;
}

rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
/// The mouse is dragging the visible-area marker.
dragging: bool = false,

pub fn layout(self: *Minimap, editor: rl.Rectangle) void {
    self.rect = .{ .x = editor.x + editor.width - width, .y = editor.y, .width = width, .height = editor.height };
}

pub fn contains(self: *const Minimap, p: rl.Vector2) bool {
    return rl.checkCollisionPointRec(p, self.rect);
}

/// Lines that fit in the minimap.
fn capacity(self: *const Minimap) usize {
    return @intFromFloat(@max(1, self.rect.height / line_h));
}

/// First line drawn: when the file is taller than the minimap, the minimap
/// scrolls along with the editor, proportionally.
fn firstLine(self: *const Minimap, view: *const View, line_count: usize) usize {
    const cap = self.capacity();
    if (line_count <= cap) return 0;
    const max_scroll = @as(f32, @floatFromInt(line_count - 1)) * theme.line_height;
    const t = if (max_scroll > 0) std.math.clamp(view.scroll.y / max_scroll, 0, 1) else 0;
    return @intFromFloat(t * @as(f32, @floatFromInt(line_count - cap)));
}

/// Mouse press / drag: scrolls the editor so the pointed-at line is in the
/// middle of the view. Returns true if the minimap took the mouse.
pub fn handleMouse(self: *Minimap, view: *View, buf: *const core.Buffer, p: rl.Vector2, pressed: bool) bool {
    if (pressed and self.contains(p)) self.dragging = true;
    if (!rl.isMouseButtonDown(.left)) self.dragging = false;
    if (!self.dragging) return false;
    const lines = buf.lineCount();
    const first = self.firstLine(view, lines);
    const row: f32 = @max(0, (p.y - self.rect.y) / line_h);
    const target = @as(f32, @floatFromInt(first)) + row;
    const visible = view.area.height / theme.line_height;
    view.scroll.y = (target - visible / 2) * theme.line_height;
    view.clampScroll(buf);
    return true;
}

pub fn draw(self: *const Minimap, view: *const View, buf: *const core.Buffer, hl: *const core.syntax.Highlighter) void {
    const r = self.rect;
    rl.drawRectangleRec(r, faded(theme.minimap_background));
    theme.clip(r);
    defer rl.endScissorMode();

    const line_count = buf.lineCount();
    const first = self.firstLine(view, line_count);
    const last = @min(line_count, first + self.capacity() + 1);
    const text = buf.items();
    var pos = buf.posAt(first, 0);
    var index = first;
    while (index < last) : (index += 1) {
        const end = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        const line = text[pos..end];
        const y = r.y + @as(f32, @floatFromInt(index - first)) * line_h;
        var tokens = hl.tokens(index, line);
        // One block per run of non-blank characters, in the token's color.
        var col: usize = 0;
        while (tokens.next()) |span| {
            var color = theme.syntaxColor(span.kind);
            color.a = 170;
            color = faded(color);
            var run_start: ?usize = null;
            var it = std.unicode.Utf8View.initUnchecked(line[span.start..span.end]).iterator();
            while (it.nextCodepoint()) |cp| {
                const blank = cp == ' ' or cp == '\t';
                if (!blank and run_start == null) run_start = col;
                if (blank) if (run_start) |s| {
                    drawRun(r, y, s, col, color);
                    run_start = null;
                };
                col = if (cp == '\t') core.text.advance(col, '\t') else col + 1;
            }
            if (run_start) |s| drawRun(r, y, s, col, color);
        }
        if (end >= text.len) break;
        pos = end + 1;
    }

    // The part of the file the editor shows.
    const view_first = view.scroll.y / theme.line_height;
    const view_lines = view.area.height / theme.line_height;
    const marker: rl.Rectangle = .{
        .x = r.x,
        .y = r.y + (view_first - @as(f32, @floatFromInt(first))) * line_h,
        .width = r.width,
        .height = @max(4, view_lines * line_h),
    };
    const hovered = self.dragging or rl.checkCollisionPointRec(rl.getMousePosition(), r);
    rl.drawRectangleRec(marker, faded(if (hovered) theme.minimap_marker_hover else theme.minimap_marker));
}

fn drawRun(r: rl.Rectangle, y: f32, from: usize, to: usize, color: rl.Color) void {
    const x = r.x + pad + @as(f32, @floatFromInt(from)) * char_w;
    if (x > r.x + r.width) return;
    const w = @min(@as(f32, @floatFromInt(to - from)) * char_w, r.x + r.width - x);
    rl.drawRectangleRec(.{ .x = x, .y = y, .width = w, .height = line_h - 0.5 }, color);
}
