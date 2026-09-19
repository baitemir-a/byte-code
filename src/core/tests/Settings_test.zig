//! Tests for Settings.zig.
const std = @import("std");
const Settings = @import("../Settings.zig");

test "round trip, defaults and clamping" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Missing file: defaults.
    try std.testing.expectEqual(Settings{}, Settings.load(gpa, io, tmp.dir, "none.json"));

    var s: Settings = .{ .theme = .light, .accent = .{ 1, 2, 3 }, .autosave = true, .autosave_delay_ms = 2500, .zoom = 120, .minimap = false };
    try s.save(gpa, io, tmp.dir, "conf/settings.json");
    try std.testing.expectEqual(s, Settings.load(gpa, io, tmp.dir, "conf/settings.json"));

    // Hand-edited: unknown fields ignored, missing ones default, values clamped.
    try tmp.dir.writeFile(io, .{ .sub_path = "edited.json", .data = "{\"zoom\": 999, \"autosave_delay_ms\": 1, \"font\": \"x\"}" });
    const e = Settings.load(gpa, io, tmp.dir, "edited.json");
    try std.testing.expectEqual(@as(u16, Settings.max_zoom), e.zoom);
    try std.testing.expectEqual(@as(u32, Settings.min_delay_ms), e.autosave_delay_ms);
    try std.testing.expect(e.minimap);

    // Broken JSON: defaults rather than an error.
    try tmp.dir.writeFile(io, .{ .sub_path = "broken.json", .data = "{ not json" });
    try std.testing.expectEqual(Settings{}, Settings.load(gpa, io, tmp.dir, "broken.json"));

    s.zoom = 195;
    s.zoomIn();
    try std.testing.expectEqual(@as(u16, 200), s.zoom);
    s.autosave_delay_ms = 500;
    s.adjustDelay(-3);
    try std.testing.expectEqual(@as(u32, Settings.min_delay_ms), s.autosave_delay_ms);
}
