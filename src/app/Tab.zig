//! One open tab: a file being edited, a file's Git changes, or one of the
//! pages (welcome, settings, help).
const std = @import("std");
const i18n = @import("../i18n/i18n.zig");
const rl = @import("raylib");
const core = @import("core");

const Tab = @This();

pub const Kind = enum { file, diff, welcome, settings, help };

kind: Kind,
buffer: core.Buffer,
document: core.Document = .{},
highlighter: core.syntax.Highlighter,
/// What git's copy of the file looks like and how the buffer differs from
/// it: the change marks in the gutter and the Git view's highlighting.
diff: core.Diff,
/// When git's copy was last read, so it isn't re-read every frame.
diff_at: f64 = 0,
/// Who last touched each line, for the bar at the bottom, and when the
/// wait to ask git about it started (0 while there is nothing to ask).
blame: core.Blame,
blame_at: f64 = 0,
/// The name a diff tab shows, e.g. "App.zig (changes)". Owned.
label: ?[]u8 = null,
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
    var tab: Tab = .{ .kind = .file, .buffer = .init(gpa), .highlighter = .init(.typescript), .diff = .init(gpa), .blame = .init(gpa) };
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

/// A tab showing what changed in a file; `openDiffTab` fills it in. Its
/// buffer holds both copies of the file, so it is never saved and never
/// edited (see `Command.changesText`).
pub fn initDiff(gpa: std.mem.Allocator) Tab {
    var tab = initFile(gpa);
    tab.kind = .diff;
    return tab;
}

pub fn initHelp(gpa: std.mem.Allocator) Tab {
    var tab = initFile(gpa);
    tab.kind = .help;
    return tab;
}

pub fn deinit(self: *Tab, gpa: std.mem.Allocator) void {
    if (self.label) |l| gpa.free(l);
    self.blame.deinit();
    self.diff.deinit();
    self.highlighter.deinit(gpa);
    self.document.deinit(gpa);
    self.buffer.deinit();
}

/// Loads a file into this tab.
pub fn load(self: *Tab, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    try self.document.open(gpa, io, std.Io.Dir.cwd(), path, &self.buffer);
    self.diff.clear();
    self.diff_at = 0;
    self.blame.clear();
    self.blame_at = 0;
    self.highlighter.language = .detect(path, self.buffer.items());
    self.kind = .file;
    self.scroll = .{ .x = 0, .y = 0 };
}

/// Names a diff tab after the file and the copies it compares.
pub fn setLabel(self: *Tab, gpa: std.mem.Allocator, path: []const u8, against: core.Diff.Against) !void {
    const t = i18n.tr().git;
    const label = try std.fmt.allocPrint(gpa, "{s} ({s})", .{
        std.fs.path.basename(path),
        if (against == .head) t.staged_tab else t.changes_tab,
    });
    if (self.label) |l| gpa.free(l);
    self.label = label;
}

pub fn name(self: *const Tab) []const u8 {
    return switch (self.kind) {
        .diff => self.label orelse "diff",
        .welcome => i18n.tr().tabs.welcome,
        .settings => i18n.tr().tabs.settings,
        .help => i18n.tr().tabs.help,
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
