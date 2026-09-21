//! Where the app keeps its files.
const std = @import("std");
const builtin = @import("builtin");

/// The settings file: ~/Library/Application Support/byte-code/settings.json
/// on macOS, $XDG_CONFIG_HOME (or ~/.config)/byte-code/settings.json on
/// Linux, %APPDATA%\byte-code\settings.json on Windows. Caller frees.
pub fn settingsFile(gpa: std.mem.Allocator) ![]u8 {
    const sep = std.fs.path.sep_str;
    return switch (builtin.os.tag) {
        .macos => std.fmt.allocPrint(gpa, "{s}/Library/Application Support/byte-code/settings.json", .{env("HOME") orelse "."}),
        .windows => std.fmt.allocPrint(gpa, "{s}" ++ sep ++ "byte-code" ++ sep ++ "settings.json", .{env("APPDATA") orelse "."}),
        else => if (env("XDG_CONFIG_HOME")) |x|
            std.fmt.allocPrint(gpa, "{s}/byte-code/settings.json", .{x})
        else
            std.fmt.allocPrint(gpa, "{s}/.config/byte-code/settings.json", .{env("HOME") orelse "."}),
    };
}

/// The keyboard shortcuts the user changed, next to settings.json.
/// Caller frees.
pub fn keybindingsFile(gpa: std.mem.Allocator) ![]u8 {
    return besideSettings(gpa, "keybindings.json");
}

/// The recent and favorite project folders, next to settings.json.
/// Caller frees.
pub fn projectsFile(gpa: std.mem.Allocator) ![]u8 {
    return besideSettings(gpa, "projects.json");
}

/// A file in the same folder as settings.json. Caller frees.
fn besideSettings(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const settings = try settingsFile(gpa);
    defer gpa.free(settings);
    const dir = std.fs.path.dirname(settings) orelse ".";
    return std.fs.path.join(gpa, &.{ dir, name });
}

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}
