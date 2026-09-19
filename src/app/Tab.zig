//! One open tab: a file being edited, or the welcome page.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");

const Tab = @This();

pub const Kind = enum { file, welcome, settings };

kind: Kind,
buffer: core.Buffer,
document: core.Document = .{},
highlighter: core.syntax.Highlighter,
/// The view's scroll position, kept while another tab is showing.
scroll: rl.Vector2 = .{ .x = 0, .y = 0 },
/// Auto save: the buffer version last seen and when it changed, so saving
/// waits until typing pauses; and whether a failed save was reported.
seen_version: u64 = 0,
changed_at: f64 = 0,
autosave_error_shown: bool = false,

/// A new, untitled file. It's treated as TypeScript (which covers JS) until
/// saved under another name.
pub fn initFile(gpa: std.mem.Allocator) Tab {
    var tab: Tab = .{ .kind = .file, .buffer = .init(gpa), .highlighter = .init(.typescript) };
    tab.document.saved_version = tab.buffer.version;
    return tab;
}

pub fn initWelcome(gpa: std.mem.Allocator) Tab {
    var tab = initFile(gpa);
    tab.kind = .welcome;
    return tab;
}

pub fn initSettings(gpa: std.mem.Allocator) Tab {
    var tab = initFile(gpa);
    tab.kind = .settings;
    return tab;
}

pub fn deinit(self: *Tab, gpa: std.mem.Allocator) void {
    self.highlighter.deinit(gpa);
    self.document.deinit(gpa);
    self.buffer.deinit();
}

/// Loads a file into this tab.
pub fn load(self: *Tab, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    try self.document.open(gpa, io, std.Io.Dir.cwd(), path, &self.buffer);
    self.highlighter.language = .detect(path, self.buffer.items());
    self.kind = .file;
    self.scroll = .{ .x = 0, .y = 0 };
}

pub fn name(self: *const Tab) []const u8 {
    return switch (self.kind) {
        .welcome => "Welcome",
        .settings => "Settings",
        .file => self.document.name(),
    };
}

pub fn isDirty(self: *const Tab) bool {
    return self.kind == .file and self.document.isDirty(&self.buffer);
}

/// A fresh untitled tab nobody typed in, which opening a file can reuse.
pub fn isPristine(self: *const Tab) bool {
    return self.kind == .file and self.document.path == null and !self.isDirty() and self.buffer.items().len == 0;
}

/// Whether this tab shows the file at `path` (absolute).
pub fn hasPath(self: *const Tab, path: []const u8) bool {
    const p = self.document.path orelse return false;
    return self.kind == .file and std.mem.eql(u8, p, path);
}
