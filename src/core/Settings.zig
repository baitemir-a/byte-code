//! User settings, stored as JSON (settings.json in the app's config
//! folder). Unknown or missing fields fall back to defaults, and values are
//! clamped to sensible ranges, so a hand-edited file can't break the app.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Settings = @This();

pub const default_accent = [3]u8{ 24, 163, 255 };

pub const Theme = enum { dark, light };

/// Zoom steps: 50% to 200%.
pub const min_zoom = 50;
pub const max_zoom = 200;
pub const zoom_step = 10;

/// Auto-save delay range, in milliseconds.
pub const min_delay_ms = 250;
pub const max_delay_ms = 60_000;

theme: Theme = .dark,
/// Color of highlights: active tab, focused inputs, links, drop targets.
accent: [3]u8 = default_accent,
/// Save files with unsaved changes once typing pauses for `autosave_delay_ms`.
autosave: bool = false,
autosave_delay_ms: u32 = 1000,
/// UI zoom, in percent.
zoom: u16 = 100,
minimap: bool = true,
/// Opening a folder while one is open starts a new window for it
/// (otherwise it replaces the current project).
open_folder_in_new_window: bool = false,
/// Width of the project sidebar, in UI units (dragged by its edge).
sidebar_width: u16 = 240,

/// Keeps every value in range.
pub fn clamp(self: *Settings) void {
    self.autosave_delay_ms = std.math.clamp(self.autosave_delay_ms, min_delay_ms, max_delay_ms);
    self.zoom = std.math.clamp(self.zoom, min_zoom, max_zoom);
    self.sidebar_width = std.math.clamp(self.sidebar_width, 140, 1200);
}

pub fn zoomIn(self: *Settings) void {
    self.zoom = @min(max_zoom, self.zoom + zoom_step);
}

pub fn zoomOut(self: *Settings) void {
    self.zoom = @max(min_zoom, self.zoom - zoom_step);
}

/// Adds `steps` × 0.5 s to the auto-save delay (negative to shorten).
pub fn adjustDelay(self: *Settings, steps: i32) void {
    const ms = @as(i64, self.autosave_delay_ms) + @as(i64, steps) * 500;
    self.autosave_delay_ms = @intCast(std.math.clamp(ms, min_delay_ms, max_delay_ms));
}

/// Reads settings from `path`. A missing or unreadable file gives defaults.
pub fn load(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) Settings {
    const bytes = dir.readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch return .{};
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(Settings, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return .{};
    defer parsed.deinit();
    var s = parsed.value;
    s.clamp();
    return s;
}

/// Writes settings to `path`, creating its folder if needed.
pub fn save(self: Settings, gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) !void {
    const json = try std.json.Stringify.valueAlloc(gpa, self, .{ .whitespace = .indent_2 });
    defer gpa.free(json);
    if (std.fs.path.dirname(path)) |d| try dir.createDirPath(io, d);
    var file = try dir.createFileAtomic(io, path, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, json);
    try file.replace(io);
}

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
    try std.testing.expectEqual(@as(u16, max_zoom), e.zoom);
    try std.testing.expectEqual(@as(u32, min_delay_ms), e.autosave_delay_ms);
    try std.testing.expect(e.minimap);

    // Broken JSON: defaults rather than an error.
    try tmp.dir.writeFile(io, .{ .sub_path = "broken.json", .data = "{ not json" });
    try std.testing.expectEqual(Settings{}, Settings.load(gpa, io, tmp.dir, "broken.json"));

    s.zoom = 195;
    s.zoomIn();
    try std.testing.expectEqual(@as(u16, 200), s.zoom);
    s.autosave_delay_ms = 500;
    s.adjustDelay(-3);
    try std.testing.expectEqual(@as(u32, min_delay_ms), s.autosave_delay_ms);
}
