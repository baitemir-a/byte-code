//! Searching and replacing across the project (the Search view).
const std = @import("std");
const core = @import("core");
const dialogs = @import("../../platform/lib/dialogs.zig");
const Tab = @import("../Tab.zig");
const App = @import("../App.zig");
const i18n = @import("../../i18n/i18n.zig");

/// Searches the project for the Search view's query. Open tabs are searched
/// as they are in the editor, unsaved edits included. `.keep` the scroll
/// position when re-running after a replace, so the list doesn't jump.
pub fn runSearch(self: *App, scroll: enum { top, keep }) !void {
    const panel = &self.search_panel;
    panel.changed_at = null;
    panel.searched_for.clearRetainingCapacity();
    try panel.searched_for.appendSlice(self.gpa, panel.query.text());
    panel.searched_with = panel.options;
    if (scroll == .top) panel.scroll = 0;
    const project = if (self.project) |*p| p else return panel.results.clear();
    self.file_search.scan(self.io, project.root().path) catch |err| {
        return self.reportError(i18n.tr().errors.list_files, project.root().path, err);
    };
    const overlay: core.ProjectSearch.Overlay = .{ .ctx = self, .get = openTabText };
    try panel.results.run(self.io, project.root().path, self.file_search.files.items, panel.query.text(), panel.options, overlay);
}

/// The text of the open tab for a project file (path relative to the
/// project root), if there is one.
pub fn openTabText(ctx: *const anyopaque, rel: []const u8) ?[]const u8 {
    const self: *const App = @ptrCast(@alignCast(ctx));
    const t = self.tabForProjectFile(rel) orelse return null;
    return t.buffer.items();
}

pub fn tabForProjectFile(self: *const App, rel: []const u8) ?*Tab {
    const root = if (self.project) |*p| p.root().path else return null;
    for (self.tabs.items) |*t| {
        if (t.kind != .file) continue;
        const path = t.document.path orelse continue;
        if (samePath(path, root, rel)) return t;
    }
    return null;
}

/// Whether `abs` is `root` joined with `rel`, either separator allowed.
pub fn samePath(abs: []const u8, root: []const u8, rel: []const u8) bool {
    if (abs.len != root.len + 1 + rel.len or !std.mem.startsWith(u8, abs, root)) return false;
    const rest = abs[root.len..];
    if (!isSep(rest[0])) return false;
    for (rest[1..], rel) |a, b| {
        if (a != b and !(isSep(a) and isSep(b))) return false;
    }
    return true;
}

pub fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

/// Replace All in the Search view, after confirming. Files open in a tab
/// change in the editor (one undo step each, not saved yet); the others
/// are rewritten on disk. Matches are found again in the current content,
/// so nothing is replaced from stale results.
pub fn replaceInProject(self: *App) !void {
    const project = if (self.project) |*p| p else return;
    const root = project.root().path;
    const panel = &self.search_panel;
    const query = panel.query.text();
    const replacement = panel.replacement.text();
    if (query.len == 0) return;
    try self.runSearch(.keep); // fresh counts for the question
    const results = &panel.results;
    if (results.matches.items.len == 0) return;

    const t = i18n.tr().dialogs;
    var count_buf: [16]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buf, "{d}{s}", .{ results.matches.items.len, if (results.truncated) "+" else "" }) catch "";
    var question_buf: [256]u8 = undefined;
    const question = i18n.fill(&question_buf, t.replace_question, .{ count, results.files.items.len });
    // Without a way to ask (no dialogs on this system), the click decides.
    if (!(dialogs.confirm(self.gpa, self.io, question, t.replace_detail, i18n.tr().common.replace_all) catch true)) return;

    var failed: ?struct { path: []u8, err: anyerror } = null;
    defer if (failed) |f| self.gpa.free(f.path);
    for (results.files.items) |f| {
        self.replaceAllInFile(root, f.path, query, replacement, panel.options) catch |err| {
            if (failed == null) failed = .{ .path = try std.fs.path.join(self.gpa, &.{ root, f.path }), .err = err };
        };
    }
    if (failed) |f| self.reportError(i18n.tr().errors.replace_in_file, f.path, f.err);
    self.git_dirty = true;
    try self.runSearch(.keep); // what's left, if anything
}

/// The Replace all button on a file's row in the Search view: that file
/// only, without asking (it's undoable if the file is open).
pub fn replaceInProjectFile(self: *App, file: u32) !void {
    const project = if (self.project) |*p| p else return;
    const panel = &self.search_panel;
    if (panel.stale()) return self.runSearch(.keep); // results don't match the boxes
    const rel = panel.results.files.items[file].path;
    self.replaceAllInFile(project.root().path, rel, panel.query.text(), panel.replacement.text(), panel.options) catch |err| {
        const path = try std.fs.path.join(self.gpa, &.{ project.root().path, rel });
        defer self.gpa.free(path);
        self.reportError(i18n.tr().errors.replace_in_file, path, err);
    };
    self.git_dirty = true;
    try self.runSearch(.keep);
}

/// The Replace button on a match's row: just that match. It's checked to
/// still be there first, in case the file changed since the search.
pub fn replaceMatchInProject(self: *App, index: u32) !void {
    const project = if (self.project) |*p| p else return;
    const root = project.root().path;
    const panel = &self.search_panel;
    if (panel.stale()) return self.runSearch(.keep);
    const query = panel.query.text();
    const replacement = panel.replacement.text();
    const m = panel.results.matches.items[index];
    const rel = panel.results.files.items[m.file].path;

    if (self.tabForProjectFile(rel)) |t| {
        // In the editor: an undoable edit, saved like any other.
        if (core.find.matchesAt(t.buffer.items(), m.start, query, panel.options)) {
            try t.buffer.replace(m.start, m.end, replacement, replacement.len, .other);
        }
    } else {
        const path = try std.fs.path.join(self.gpa, &.{ root, rel });
        defer self.gpa.free(path);
        replaceRangeInFile(self.gpa, self.io, path, m.start, query, replacement, panel.options) catch |err| {
            self.reportError(i18n.tr().errors.replace_in_file, path, err);
        };
        self.git_dirty = true;
    }
    try self.runSearch(.keep);
}

/// Replaces every match in one project file: in its tab if it's open (one
/// undo step, not saved yet), otherwise on disk.
pub fn replaceAllInFile(self: *App, root: []const u8, rel: []const u8, query: []const u8, replacement: []const u8, opts: core.find.Options) !void {
    if (self.tabForProjectFile(rel)) |t| {
        var s: core.Search = .{};
        defer s.deinit(self.gpa);
        _ = try s.update(self.gpa, &t.buffer, query, opts);
        _ = try s.replaceAll(self.gpa, &t.buffer, replacement);
        return;
    }
    const path = try std.fs.path.join(self.gpa, &.{ root, rel });
    defer self.gpa.free(path);
    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(self.io, path, self.gpa, .limited(core.ProjectSearch.max_file_size));
    defer self.gpa.free(data);
    const r = try core.ProjectSearch.replaceAll(self.gpa, data, query, replacement, opts);
    const text = r.text orelse return;
    defer self.gpa.free(text);
    try writeFileAtomic(self.io, path, text);
}

/// Replaces the match of `query` at `at` in a file on disk, if it's
/// still there.
pub fn replaceRangeInFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8, at: usize, query: []const u8, replacement: []const u8, opts: core.find.Options) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(core.ProjectSearch.max_file_size));
    defer gpa.free(data);
    if (!core.find.matchesAt(data, at, query, opts)) return;
    const text = try std.mem.concat(gpa, u8, &.{ data[0..at], replacement, data[at + query.len ..] });
    defer gpa.free(text);
    try writeFileAtomic(io, path, text);
}

pub fn writeFileAtomic(io: std.Io, path: []const u8, text: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, text);
    try file.replace(io);
}
