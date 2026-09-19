//! A monospace font plus the width of one character cell. It's rendered at
//! each size it's drawn at (text, headings, hints) and glyphs are placed on
//! whole screen pixels, so text stays sharp rather than scaled or smeared.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("theme/lib/theme.zig");

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

/// Headings and hints are drawn at these sizes (Welcome, Settings).
pub const heading_size = theme.font_size * 2.4;
pub const small_size = theme.font_size * 0.8;

/// Characters for the heading and hint sizes: text in these is short and
/// Latin, Cyrillic or Greek, so keep their atlases small.
const small_set_ranges = char_ranges[0..4];
const small_set = blk: {
    var n: usize = 0;
    for (small_set_ranges) |r| n += @intCast(r[1] - r[0] + 1);
    break :blk codepoints[0..n].*;
};

handle: rl.Font,
/// The same font rendered for headings and hints (null if they couldn't
/// be loaded; the main one is scaled then).
heading: ?rl.Font = null,
small: ?rl.Font = null,
/// Horizontal advance of one character (fonts are assumed monospace).
cell_width: f32,
owned: bool,
/// One screen pixel, in UI units (0.5 on a Retina display at 100% zoom).
pixel: f32 = 1,

const Source = union(enum) { path: [:0]const u8, bundled };

/// DejaVu Sans Mono, built into the executable so text looks right (and
/// Cyrillic works) on systems without any of `theme.font_paths`.
/// License: fonts/DejaVu-LICENSE.txt.
const bundled_font = @embedFile("fonts/DejaVuSansMono.ttf");

/// Loads the first available font from `theme.font_paths`, else the bundled
/// one. Call after the window exists: it rasterizes for the display's pixel
/// density and the current zoom, so text stays sharp at any size.
pub fn load() Font {
    // Screen pixels per UI unit: display density times zoom.
    const scale = @max(1, rl.getWindowScaleDPI().x) * theme.zoom;
    const source: Source, const main = for (theme.font_paths) |path| {
        if (loadFrom(.{ .path = path }, pixels(theme.font_size, scale), &codepoints)) |f| break .{ .{ .path = path }, f };
    } else if (loadFrom(.bundled, pixels(theme.font_size, scale), &codepoints)) |f|
        .{ Source.bundled, f }
    else {
        var font = fromHandle(rl.getFontDefault() catch unreachable, false);
        font.pixel = 1 / scale;
        return font;
    };
    var font = fromHandle(main, true);
    font.pixel = 1 / scale;
    font.heading = loadFrom(source, pixels(heading_size, scale), &small_set);
    font.small = loadFrom(source, pixels(small_size, scale), &small_set);
    return font;
}

fn pixels(size: f32, scale: f32) i32 {
    return @intFromFloat(@round(size * scale));
}

fn loadFrom(source: Source, px: i32, cps: []const i32) ?rl.Font {
    const f = switch (source) {
        .path => |p| rl.loadFontEx(p, px, cps),
        .bundled => rl.loadFontFromMemory(".ttf", bundled_font, px, cps),
    } catch return null;
    rl.setTextureFilter(f.texture, .bilinear);
    return f;
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
    if (self.heading) |f| rl.unloadFont(f);
    if (self.small) |f| rl.unloadFont(f);
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
    // The rendering made for this size, so glyphs aren't stretched.
    const f = if (@abs(size - heading_size) < 0.01 and self.heading != null)
        self.heading.?
    else if (@abs(size - small_size) < 0.01 and self.small != null)
        self.small.?
    else
        self.handle;
    // On whole screen pixels: between them, smoothing blurs each glyph.
    const px = self.pixel;
    rl.drawTextCodepoint(f, cp, .{ .x = @round(x / px) * px, .y = @round(y / px) * px }, size, color);
}
