//! A monospace font plus the width of one character cell.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("theme.zig");

const Font = @This();

/// Unicode ranges rasterized into the font atlas. raylib's default is ASCII
/// only; anything outside these draws as the font's missing-glyph shape.
const char_ranges = [_][2]i32{
    .{ 0x0020, 0x007E }, // ASCII
    .{ 0x00A0, 0x017F }, // Latin-1 Supplement, Latin Extended-A (é, ß, ł, ...)
    .{ 0x0370, 0x03FF }, // Greek
    .{ 0x0400, 0x052F }, // Cyrillic and Cyrillic Supplement (Kazakh, Ukrainian, ...)
    .{ 0x2010, 0x205E }, // Dashes, quotes, bullet, ellipsis
    .{ 0x20A0, 0x20BF }, // Currency (€, ₽, ₸, ...)
    .{ 0x2190, 0x21FF }, // Arrows
    .{ 0x2500, 0x257F }, // Box drawing
};

const codepoints = blk: {
    var n: usize = 0;
    for (char_ranges) |r| n += @intCast(r[1] - r[0] + 1);
    var list: [n]i32 = undefined;
    var i: usize = 0;
    @setEvalBranchQuota(10_000);
    for (char_ranges) |r| {
        var cp = r[0];
        while (cp <= r[1]) : (cp += 1) {
            list[i] = cp;
            i += 1;
        }
    }
    break :blk list;
};

handle: rl.Font,
/// Horizontal advance of one character (fonts are assumed monospace).
cell_width: f32,
owned: bool,

/// DejaVu Sans Mono, built into the executable so text looks right (and
/// Cyrillic works) on systems without any of `theme.font_paths`.
/// License: fonts/DejaVu-LICENSE.txt.
const bundled_font = @embedFile("fonts/DejaVuSansMono.ttf");

/// Loads the first available font from `theme.font_paths`, else the bundled
/// one. Call after the window exists: it rasterizes for the display's pixel
/// density and the current zoom, so text stays sharp at any size.
pub fn load() Font {
    const dpi = rl.getWindowScaleDPI().x;
    const raster_size: i32 = @intFromFloat(@round(theme.font_size * @max(1, dpi) * theme.zoom));
    for (theme.font_paths) |path| {
        const f = rl.loadFontEx(path, raster_size, &codepoints) catch continue;
        return fromHandle(f, true);
    }
    if (rl.loadFontFromMemory(".ttf", bundled_font, raster_size, &codepoints)) |f| {
        return fromHandle(f, true);
    } else |_| {}
    return fromHandle(rl.getFontDefault() catch unreachable, false);
}

fn fromHandle(f: rl.Font, owned: bool) Font {
    if (owned) rl.setTextureFilter(f.texture, .bilinear);
    return .{
        .handle = f,
        .cell_width = rl.measureTextEx(f, "M", theme.font_size, 0).x,
        .owned = owned,
    };
}

pub fn unload(self: Font) void {
    if (self.owned) rl.unloadFont(self.handle);
}

pub fn drawCodepoint(self: Font, cp: u21, x: f32, y: f32, color: rl.Color) void {
    self.drawCodepointSized(cp, x, y, theme.font_size, color);
}

/// Draws `s` from `x`, cut to end before `max_x`: text that doesn't fit
/// ends with "…". Returns where the text ended.
pub fn drawFit(self: Font, s: []const u8, x: f32, y: f32, max_x: f32, color: rl.Color) f32 {
    const cols = @as(usize, @intFromFloat(@max(0, (max_x - x) / self.cell_width)));
    const len = std.unicode.utf8CountCodepoints(s) catch s.len;
    const shown = if (len > cols) cols -| 1 else len; // room for "…"
    var cx = x;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |cp| : (i += 1) {
        if (i == shown) break;
        if (cp != ' ') self.drawCodepoint(cp, cx, y, color);
        cx += self.cell_width;
    }
    if (len > cols and cols > 0) {
        self.drawCodepoint(0x2026, cx, y, color);
        cx += self.cell_width;
    }
    return cx;
}

/// Like `drawCodepoint` at another size (e.g. a heading); the advance is
/// `cell_width * size / theme.font_size`.
pub fn drawCodepointSized(self: Font, cp: u21, x: f32, y: f32, size: f32, color: rl.Color) void {
    rl.drawTextCodepoint(self.handle, cp, .{ .x = x, .y = y }, size, color);
}
