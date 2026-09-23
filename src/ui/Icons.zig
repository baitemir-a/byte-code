//! Icons from Lucide (lucide.dev), drawn from its icon font: each icon is
//! a glyph, rendered like text for the display's density and the zoom (see
//! Font.zig), so it stays sharp at any size. The font and its codepoints
//! come from the lucide-static package (build.zig.zon). License (ISC):
//! fonts/Lucide-LICENSE.txt.
const std = @import("std");

pub const font_data = @embedFile("lucide.ttf");

/// The icons the app uses. A name is Lucide's, with `_` for `-`
/// (lucide.dev/icons lists them all).
pub const Icon = enum {
    files,
    search,
    git_branch,
    circle_question_mark,
    settings,
    folder_open,
    file_plus,
    folder_plus,
    copy_minus,
    chevron_right,
    chevron_down,
    x,
    plus,
    minus,
    undo_2,

    pub fn codepoint(self: Icon) u21 {
        return codepoints[@intFromEnum(self)];
    }
};

/// Icons are drawn at these sizes, each rendered separately so none is
/// scaled. Lucide draws on a 24-unit grid with 2-unit strokes.
pub const Size = enum(u8) {
    small = 14,
    medium = 16,
    large = 18,

    pub fn px(self: Size) f32 {
        return @floatFromInt(@intFromEnum(self));
    }
};

const codepoints = blk: {
    const fields = @typeInfo(Icon).@"enum".fields;
    var list: [fields.len]u21 = undefined;
    for (fields, 0..) |f, i| list[i] = lookup(f.name);
    break :blk list;
};

/// All of them, for loading the font.
pub const all_codepoints = blk: {
    var list: [codepoints.len]i32 = undefined;
    for (codepoints, 0..) |cp, i| list[i] = cp;
    break :blk list;
};

/// Finds `"name": 12345` in the package's codepoints.json, so a new Lucide
/// version can't silently move an icon.
fn lookup(comptime field: []const u8) u21 {
    @setEvalBranchQuota(10_000_000);
    const json = @embedFile("lucide_codepoints.json");
    var name: [field.len]u8 = field[0..field.len].*;
    std.mem.replaceScalar(u8, &name, '_', '-');
    const key = "\"" ++ name ++ "\": ";
    const at = std.mem.indexOf(u8, json, key) orelse @compileError("no Lucide icon named " ++ name);
    var end = at + key.len;
    while (std.ascii.isDigit(json[end])) end += 1;
    return std.fmt.parseInt(u21, json[at + key.len .. end], 10) catch unreachable;
}
