//! File-type icons: a small colored circle by file extension (the language's
//! usual color), gray for everything else. Python gets its yellow and blue.
const std = @import("std");
const rl = @import("raylib");

pub const radius: f32 = 4.5;

const Style = union(enum) {
    solid: rl.Color,
    /// Top half, bottom half.
    split: [2]rl.Color,
};

const gray = rgb(125, 125, 135);

const by_extension = [_]struct { exts: []const []const u8, style: Style }{
    .{ .exts = &.{ ".html", ".htm", ".xhtml", ".xml", ".svg", ".xsd", ".xsl", ".plist" }, .style = .{ .solid = rgb(228, 110, 46) } }, // orange
    .{ .exts = &.{ ".js", ".mjs", ".cjs", ".jsx" }, .style = .{ .solid = rgb(240, 212, 60) } }, // yellow
    .{ .exts = &.{ ".css", ".less" }, .style = .{ .solid = rgb(90, 190, 245) } }, // light blue
    .{ .exts = &.{ ".scss", ".sass" }, .style = .{ .solid = rgb(205, 103, 153) } }, // pink
    .{ .exts = &.{ ".ts", ".mts", ".cts", ".tsx" }, .style = .{ .solid = rgb(49, 120, 198) } }, // dark blue
    .{ .exts = &.{".go"}, .style = .{ .solid = rgb(0, 173, 181) } }, // green-blue
    .{ .exts = &.{ ".zig", ".zon" }, .style = .{ .solid = rgb(220, 60, 50) } }, // red
    .{ .exts = &.{".rs"}, .style = .{ .solid = rgb(160, 100, 60) } }, // brown
    .{ .exts = &.{ ".md", ".markdown" }, .style = .{ .solid = rgb(150, 110, 220) } }, // purple
    .{ .exts = &.{ ".py", ".pyw", ".pyi" }, .style = .{ .split = .{ rgb(55, 118, 171), rgb(255, 212, 59) } } }, // blue / yellow
};

fn styleFor(name: []const u8) Style {
    const ext = std.fs.path.extension(name);
    for (by_extension) |entry| {
        for (entry.exts) |e| {
            if (std.ascii.eqlIgnoreCase(ext, e)) return entry.style;
        }
    }
    return .{ .solid = gray };
}

/// Draws the icon for file `name` centered at `center`.
pub fn draw(name: []const u8, center: rl.Vector2) void {
    switch (styleFor(name)) {
        .solid => |c| rl.drawCircleV(center, radius, c),
        .split => |c| {
            // raylib's angles start at 3 o'clock and go clockwise (y down).
            rl.drawCircleSector(center, radius, 180, 360, 16, c[0]); // top
            rl.drawCircleSector(center, radius, 0, 180, 16, c[1]); // bottom
        },
    }
}

fn rgb(r: u8, g: u8, b: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}
