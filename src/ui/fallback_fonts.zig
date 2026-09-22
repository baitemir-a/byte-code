//! Fonts for the characters the editor's monospace font doesn't have:
//! Chinese, Japanese and Korean. These come from the system (bundling one
//! would add megabytes), and only the characters the app's text uses are
//! rendered from them (see Font.zig).
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");

const Language = core.Settings.Language;

pub const Candidate = struct {
    path: [:0]const u8,
    /// The language whose glyph shapes it has (the same character can be
    /// drawn differently in Chinese and Japanese); null for any.
    lang: ?Language,
};

/// Where each system keeps a font for the language, best first.
pub const candidates: []const Candidate = switch (builtin.os.tag) {
    .macos => &.{
        .{ .path = "/System/Library/Fonts/Hiragino Sans GB.ttc", .lang = .zh },
        .{ .path = "/System/Library/Fonts/STHeiti Medium.ttc", .lang = .zh },
        .{ .path = "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc", .lang = .ja },
        .{ .path = "/System/Library/Fonts/AppleSDGothicNeo.ttc", .lang = .ko },
        .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf", .lang = null },
    },
    .windows => &.{
        .{ .path = "C:/Windows/Fonts/msyh.ttc", .lang = .zh },
        .{ .path = "C:/Windows/Fonts/simsun.ttc", .lang = .zh },
        .{ .path = "C:/Windows/Fonts/YuGothM.ttc", .lang = .ja },
        .{ .path = "C:/Windows/Fonts/meiryo.ttc", .lang = .ja },
        .{ .path = "C:/Windows/Fonts/msgothic.ttc", .lang = .ja },
        .{ .path = "C:/Windows/Fonts/malgun.ttf", .lang = .ko },
        .{ .path = "C:/Windows/Fonts/gulim.ttc", .lang = .ko },
    },
    // Noto Sans CJK (all three) where the distributions put it, then
    // WenQuanYi, Nanum and Droid.
    else => &.{
        .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", .lang = null },
        .{ .path = "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc", .lang = null },
        .{ .path = "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc", .lang = null },
        .{ .path = "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc", .lang = null },
        .{ .path = "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc", .lang = .zh },
        .{ .path = "/usr/share/fonts/wenquanyi/wqy-microhei/wqy-microhei.ttc", .lang = .zh },
        .{ .path = "/usr/share/fonts/truetype/nanum/NanumGothic.ttf", .lang = .ko },
        .{ .path = "/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf", .lang = null },
    },
};

/// `candidates` with the ones for `lang` first, so its text gets its own
/// glyph shapes; the others still cover the other languages' names.
pub fn ordered(lang: Language) [candidates.len]Candidate {
    var out: [candidates.len]Candidate = undefined;
    var n: usize = 0;
    for (candidates) |c| if (c.lang == lang) {
        out[n] = c;
        n += 1;
    };
    for (candidates) |c| if (c.lang != lang) {
        out[n] = c;
        n += 1;
    };
    return out;
}

/// A font collection (.ttc) holds several fonts sharing tables, which
/// raylib can't open. Copies the first one out as a standalone font (caller
/// frees); returns null if `data` is already a single font.
pub fn firstOfCollection(gpa: std.mem.Allocator, data: []const u8) error{ OutOfMemory, BadFont }!?[]u8 {
    if (data.len < 16 or !std.mem.eql(u8, data[0..4], "ttcf")) return null;
    const start = try be32(data, 12);
    const count = try be16(data, start + 4);
    const header_len = 12 + 16 * @as(usize, count);
    if (start + header_len > data.len) return error.BadFont;

    // The same header, then each table copied after it (4-byte aligned),
    // with its offset rewritten to where it now is.
    var len = header_len;
    for (0..count) |i| {
        const record = start + 12 + 16 * i;
        const table_start = try be32(data, record + 8);
        const table_len = try be32(data, record + 12);
        if (table_start + table_len > data.len) return error.BadFont;
        len += std.mem.alignForward(usize, table_len, 4);
    }
    const out = try gpa.alloc(u8, len);
    @memset(out, 0);
    @memcpy(out[0..header_len], data[start..][0..header_len]);
    var at = header_len;
    for (0..count) |i| {
        const record = start + 12 + 16 * i;
        const table_start = try be32(data, record + 8);
        const table_len = try be32(data, record + 12);
        @memcpy(out[at..][0..table_len], data[table_start..][0..table_len]);
        std.mem.writeInt(u32, out[12 + 16 * i + 8 ..][0..4], @intCast(at), .big);
        at += std.mem.alignForward(usize, table_len, 4);
    }
    return out;
}

fn be32(data: []const u8, at: usize) error{BadFont}!usize {
    if (at + 4 > data.len) return error.BadFont;
    return std.mem.readInt(u32, data[at..][0..4], .big);
}

fn be16(data: []const u8, at: usize) error{BadFont}!u16 {
    if (at + 2 > data.len) return error.BadFont;
    return std.mem.readInt(u16, data[at..][0..2], .big);
}

test "firstOfCollection copies the first font's tables after its header" {
    const gpa = std.testing.allocator;
    // A collection of one font with one 5-byte table "ABCDE".
    var ttc: [16 + 12 + 16 + 5]u8 = @splat(0);
    @memcpy(ttc[0..4], "ttcf");
    std.mem.writeInt(u32, ttc[8..12], 1, .big); // one font
    std.mem.writeInt(u32, ttc[12..16], 16, .big); // at 16 (after its offset)
    // Font header at 16: version, one table.
    std.mem.writeInt(u16, ttc[16 + 4 ..][0..2], 1, .big);
    // Table record at 28: tag, checksum, offset 44, length 5.
    @memcpy(ttc[28..32], "test");
    std.mem.writeInt(u32, ttc[36..40], 44, .big);
    std.mem.writeInt(u32, ttc[40..44], 5, .big);
    @memcpy(ttc[44..49], "ABCDE");

    const font = (try firstOfCollection(gpa, &ttc)).?;
    defer gpa.free(font);
    try std.testing.expectEqual(@as(usize, 12 + 16 + 8), font.len);
    try std.testing.expectEqual(@as(u32, 28), std.mem.readInt(u32, font[20..24], .big));
    try std.testing.expectEqualStrings("ABCDE", font[28..33]);

    try std.testing.expectEqual(null, try firstOfCollection(gpa, "\x00\x01\x00\x00 a plain font"));
}
