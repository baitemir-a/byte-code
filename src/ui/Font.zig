//! A monospace font plus the width of one character cell. It's rendered at
//! each size it's drawn at (text, headings, hints) and glyphs are placed on
//! whole screen pixels, so text stays sharp rather than scaled or smeared.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("theme/lib/theme.zig");
const Icons = @import("Icons.zig");
const fallback_fonts = @import("fallback_fonts.zig");
const i18n = @import("../i18n/i18n.zig");

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
/// Lucide's icons, one rendering per `Icons.Size` (null if they couldn't
/// be loaded: icons are then left out).
icons: [icon_sizes.len]?rl.Font = @splat(null),
/// System fonts for the characters of the app's text the main font lacks
/// (Chinese, Japanese, Korean), each rendered at the three text sizes.
fallbacks: [max_fallbacks][text_sizes.len]?rl.Font = undefined,
fallback_count: usize = 0,
/// Horizontal advance of one character (fonts are assumed monospace).
cell_width: f32,
owned: bool,
/// One screen pixel, in UI units (0.5 on a Retina display at 100% zoom).
pixel: f32 = 1,

const icon_sizes = std.enums.values(Icons.Size);
const text_sizes = [_]f32{ theme.font_size, heading_size, small_size };
const max_fallbacks = 4;

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
    for (&font.icons, icon_sizes) |*f, size| f.* = loadIcons(pixels(size.px(), scale));
    font.loadFallbacks(scale);
    return font;
}

/// Loads system fonts for the characters of the current language's text
/// (and of every language's name, for the language menu) that the main
/// font can't draw: each font gets the ones still missing that it has.
fn loadFallbacks(self: *Font, scale: f32) void {
    var missing = neededFallbackCodepoints();
    for (fallback_fonts.ordered(i18n.language())) |candidate| {
        if (missing.len == 0 or self.fallback_count == max_fallbacks) break;
        if (!rl.fileExists(candidate.path)) continue;
        const file = rl.loadFileData(candidate.path) catch continue;
        defer rl.unloadFileData(file);
        const gpa = std.heap.page_allocator;
        const single = fallback_fonts.firstOfCollection(gpa, file) catch continue;
        defer if (single) |d| gpa.free(d);
        const data = single orelse file;

        // Which of them it has: read at a tiny size, without building a
        // texture (raylib can't build one when it has none of them).
        var found: CodepointList = .{};
        const probe = rl.loadFontData(data, 4, missing.slice(), .default) catch continue;
        for (probe) |g| found.append(g.value);
        rl.unloadFontData(probe);
        if (found.len == 0) continue;

        var sizes: [text_sizes.len]?rl.Font = @splat(null);
        for (text_sizes, &sizes) |size, *f| f.* = loadFromMemory(data, pixels(size, scale), found.slice());
        self.fallbacks[self.fallback_count] = sizes;
        self.fallback_count += 1;
        missing.removeAll(found.slice());
    }
}

fn loadFromMemory(data: []const u8, px: i32, cps: []const i32) ?rl.Font {
    const f = rl.loadFontFromMemory(".ttf", data, px, cps) catch return null;
    rl.setTextureFilter(f.texture, .bilinear);
    return f;
}

const CodepointList = struct {
    items: [4096]i32 = undefined,
    len: usize = 0,

    fn append(self: *CodepointList, cp: i32) void {
        if (self.len == self.items.len or std.mem.indexOfScalar(i32, self.slice(), cp) != null) return;
        self.items[self.len] = cp;
        self.len += 1;
    }

    fn slice(self: *const CodepointList) []const i32 {
        return self.items[0..self.len];
    }

    fn removeAll(self: *CodepointList, gone: []const i32) void {
        var kept: usize = 0;
        for (self.items[0..self.len]) |cp| {
            if (std.mem.indexOfScalar(i32, gone, cp) != null) continue;
            self.items[kept] = cp;
            kept += 1;
        }
        self.len = kept;
    }
};

/// Characters of the current language's text and of the language names
/// that aren't in `char_ranges`.
fn neededFallbackCodepoints() CodepointList {
    var list: CodepointList = .{};
    i18n.forEachString(i18n.tr(), &list, addMissing);
    for (std.enums.values(i18n.Language)) |lang| addMissing(&list, lang.nativeName());
    return list;
}

fn addMissing(list: *CodepointList, s: []const u8) void {
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| if (!inMainFont(cp)) list.append(cp);
}

fn inMainFont(cp: u21) bool {
    for (char_ranges) |r| if (cp >= r[0] and cp <= r[1]) return true;
    return cp < 0x20;
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

fn loadIcons(px: i32) ?rl.Font {
    const f = rl.loadFontFromMemory(".ttf", Icons.font_data, px, &Icons.all_codepoints) catch return null;
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
    for (self.icons) |icon| if (icon) |f| rl.unloadFont(f);
    for (self.fallbacks[0..self.fallback_count]) |sizes| for (sizes) |size| if (size) |f| rl.unloadFont(f);
}

pub fn drawCodepoint(self: Font, cp: u21, x: f32, y: f32, color: rl.Color) void {
    self.drawCodepointSized(cp, x, y, theme.font_size, color);
}

/// How many cells a character takes in a grid (the editor, the terminal):
/// two for the wide ones of Chinese, Japanese and Korean, one for the rest.
pub fn columns(cp: u21) usize {
    const wide = (cp >= 0x1100 and cp <= 0x115F) or // Hangul Jamo
        (cp >= 0x2E80 and cp <= 0x303E) or // CJK radicals, punctuation
        (cp >= 0x3041 and cp <= 0x33FF) or // kana, CJK compatibility
        (cp >= 0x3400 and cp <= 0x4DBF) or // CJK extension A
        (cp >= 0x4E00 and cp <= 0x9FFF) or // CJK ideographs
        (cp >= 0xA000 and cp <= 0xA4CF) or // Yi
        (cp >= 0xAC00 and cp <= 0xD7A3) or // Hangul syllables
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK compatibility ideographs
        (cp >= 0xFE30 and cp <= 0xFE4F) or // CJK compatibility forms
        (cp >= 0xFF00 and cp <= 0xFF60) or // full-width forms
        (cp >= 0xFFE0 and cp <= 0xFFE6);
    return if (wide) 2 else 1;
}

/// One cell's width for text of `size`.
pub fn cellWidthAt(self: Font, size: f32) f32 {
    return self.cell_width * size / theme.font_size;
}

/// How far text moves on after `cp` at `size`: a cell for the monospace
/// font's characters, the glyph's own width for a fallback font's (their
/// scripts aren't monospace; a two-cell slot leaves Hangul gappy).
pub fn advance(self: Font, cp: u21, size: f32) f32 {
    if (inMainFont(cp)) return self.cellWidthAt(size);
    const g = self.fallbackGlyph(cp, size) orelse return @as(f32, @floatFromInt(columns(cp))) * self.cellWidthAt(size);
    return @as(f32, @floatFromInt(g.font.glyphs[g.index].advanceX)) * size / @as(f32, @floatFromInt(g.font.baseSize));
}

/// How wide `s` is at `size`.
pub fn textWidthAt(self: Font, s: []const u8, size: f32) f32 {
    var w: f32 = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| w += self.advance(cp, size);
    return w;
}

/// How wide `s` is at the usual text size.
pub fn textWidth(self: Font, s: []const u8) f32 {
    return self.textWidthAt(s, theme.font_size);
}

/// Draws `s` from `x` at text `size`; returns where it ended.
pub fn drawText(self: Font, s: []const u8, x: f32, y: f32, size: f32, color: rl.Color) f32 {
    var cx = x;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp != ' ') self.drawCodepointSized(cp, cx, y, size, color);
        cx += self.advance(cp, size);
    }
    return cx;
}

/// Draws `s` from `x`, cut to end before `max_x`: text that doesn't fit
/// ends with "…". Returns where the text ended.
pub fn drawFit(self: Font, s: []const u8, x: f32, y: f32, max_x: f32, color: rl.Color) f32 {
    return self.drawFitSized(s, x, y, max_x, theme.font_size, color);
}

/// `drawFit` for text of another size.
pub fn drawFitSized(self: Font, s: []const u8, x: f32, y: f32, max_x: f32, size: f32, color: rl.Color) f32 {
    // Half a pixel of slack: widths are sums of fractions.
    const room = max_x - x + 0.5;
    const fits = self.textWidthAt(s, size) <= room;
    // Room for "…" when it doesn't all fit.
    const end = if (fits) max_x + 0.5 else max_x + 0.5 - self.cellWidthAt(size);
    var cx = x;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        const a = self.advance(cp, size);
        if (cx + a > end) break;
        if (cp != ' ') self.drawCodepointSized(cp, cx, y, size, color);
        cx += a;
    }
    if (!fits and room >= self.cellWidthAt(size)) {
        self.drawCodepointSized(0x2026, cx, y, size, color);
        cx += self.cellWidthAt(size);
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
    if (!inMainFont(cp)) if (self.fallbackGlyph(cp, size)) |g| return self.drawOnPixels(g.font, cp, x, y, size, color);
    self.drawOnPixels(f, cp, x, y, size, color);
}

/// On whole screen pixels: between them, smoothing blurs each glyph.
fn drawOnPixels(self: Font, f: rl.Font, cp: u21, x: f32, y: f32, size: f32, color: rl.Color) void {
    const px = self.pixel;
    rl.drawTextCodepoint(f, cp, .{ .x = @round(x / px) * px, .y = @round(y / px) * px }, size, theme.copy(color));
}

/// The fallback font rendered for `size` that has `cp`, and where.
fn fallbackGlyph(self: Font, cp: u21, size: f32) ?struct { font: rl.Font, index: usize } {
    const s = for (text_sizes, 0..) |t, i| {
        if (@abs(size - t) < 0.01) break i;
    } else 0;
    for (self.fallbacks[0..self.fallback_count]) |sizes| {
        const f = sizes[s] orelse sizes[0] orelse continue;
        const i: usize = @intCast(rl.getGlyphIndex(f, cp));
        if (f.glyphs[i].value == cp) return .{ .font = f, .index = i };
    }
    return null;
}

/// Draws `icon` centered at `center`. Lucide's glyphs fill the whole em
/// (ascent 1, descent 0), so the glyph box is `size` square from its
/// top-left.
pub fn drawIcon(self: Font, icon: Icons.Icon, center: rl.Vector2, size: Icons.Size, color: rl.Color) void {
    const f = self.icons[std.mem.indexOfScalar(Icons.Size, icon_sizes, size).?] orelse return;
    const s = size.px();
    const px = self.pixel;
    const pos: rl.Vector2 = .{ .x = @round((center.x - s / 2) / px) * px, .y = @round((center.y - s / 2) / px) * px };
    rl.drawTextCodepoint(f, icon.codepoint(), pos, s, theme.copy(color));
}
