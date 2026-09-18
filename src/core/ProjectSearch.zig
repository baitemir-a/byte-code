//! Searching text in every file of a project (the sidebar's Search view).
//! Case-insensitive unless the query has an uppercase letter, like Find.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const ProjectSearch = @This();

/// Limits that keep a search in a big project quick.
pub const max_matches = 5000;
pub const max_file_size = 2 * 1024 * 1024;
/// Longest part of a line kept for display.
const max_preview = 240;

pub const Match = struct {
    file: u32,
    /// Zero-based line number.
    line: u32,
    /// Byte range of the match in the file (for selecting it when opened).
    start: usize,
    end: usize,
    /// The matching line (possibly cut), and the match within it.
    preview: []const u8,
    preview_start: u32,
    preview_end: u32,
};

pub const FileResult = struct {
    /// Path relative to the project, with '/' separators.
    path: []const u8,
    /// Its matches: `matches[first..first + count]`.
    first: u32,
    count: u32,
};

gpa: Allocator,
arena: std.heap.ArenaAllocator,
files: std.ArrayList(FileResult) = .empty,
matches: std.ArrayList(Match) = .empty,
/// Stopped at `max_matches`: there are more.
truncated: bool = false,

pub fn init(gpa: Allocator) ProjectSearch {
    return .{ .gpa = gpa, .arena = .init(gpa) };
}

pub fn deinit(self: *ProjectSearch) void {
    self.files.deinit(self.gpa);
    self.matches.deinit(self.gpa);
    self.arena.deinit();
}

pub fn clear(self: *ProjectSearch) void {
    self.files.clearRetainingCapacity();
    self.matches.clearRetainingCapacity();
    _ = self.arena.reset(.retain_capacity);
    self.truncated = false;
}

/// Searches `paths` (relative to `root`) for `query`. Binary files, and
/// files over `max_file_size`, are skipped.
pub fn run(self: *ProjectSearch, io: Io, root: []const u8, paths: []const []const u8, query: []const u8) !void {
    self.clear();
    if (query.len == 0) return;
    var dir = try Io.Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);
    const exact = hasUpper(query);
    for (paths) |path| {
        if (self.matches.items.len >= max_matches) {
            self.truncated = true;
            break;
        }
        const data = dir.readFileAlloc(io, path, self.gpa, .limited(max_file_size)) catch continue;
        defer self.gpa.free(data);
        if (std.mem.indexOfScalar(u8, data[0..@min(data.len, 8000)], 0) != null) continue; // binary
        try self.searchFile(path, data, query, exact);
    }
}

fn searchFile(self: *ProjectSearch, path: []const u8, data: []const u8, query: []const u8, exact: bool) !void {
    const alloc = self.arena.allocator();
    const first: u32 = @intCast(self.matches.items.len);
    var line_no: u32 = 0;
    var line_start: usize = 0;
    var pos: usize = 0;
    while (find(data, pos, query, exact)) |at| {
        // Advance the line count up to the match.
        while (std.mem.indexOfScalarPos(u8, data, line_start, '\n')) |nl| {
            if (nl >= at) break;
            line_start = nl + 1;
            line_no += 1;
        }
        const line_end = std.mem.indexOfScalarPos(u8, data, at, '\n') orelse data.len;
        // Keep the preview around the match when the line is long.
        const from = if (at - line_start > max_preview / 2) at - max_preview / 2 else line_start;
        const to = @min(line_end, from + max_preview);
        const end = @min(at + query.len, line_end);
        try self.matches.append(self.gpa, .{
            .file = @intCast(self.files.items.len),
            .line = line_no,
            .start = at,
            .end = at + query.len,
            .preview = try alloc.dupe(u8, data[from..to]),
            .preview_start = @intCast(at - from),
            .preview_end = @intCast(@min(end, to) - from),
        });
        if (self.matches.items.len >= max_matches) break;
        pos = at + query.len;
    }
    const count: u32 = @intCast(self.matches.items.len - first);
    if (count > 0) try self.files.append(self.gpa, .{ .path = try alloc.dupe(u8, path), .first = first, .count = count });
}

fn find(data: []const u8, pos: usize, query: []const u8, exact: bool) ?usize {
    if (exact) return std.mem.indexOfPos(u8, data, pos, query);
    var i = pos;
    while (i + query.len <= data.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(data[i..][0..query.len], query)) return i;
    }
    return null;
}

fn hasUpper(s: []const u8) bool {
    for (s) |c| {
        if (std.ascii.isUpper(c)) return true;
    }
    return false;
}

test "finds matches across files with lines and positions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.ts", .data = "const user = 1;\nfunction getUser() {\n  return USER;\n}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.md", .data = "no match here" });
    try tmp.dir.writeFile(io, .{ .sub_path = "img.bin", .data = "user\x00\x01" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var ps = ProjectSearch.init(gpa);
    defer ps.deinit();
    try ps.run(io, root, &.{ "src/a.ts", "b.md", "img.bin" }, "user");
    try std.testing.expectEqual(@as(usize, 1), ps.files.items.len); // binary skipped
    try std.testing.expectEqual(@as(u32, 3), ps.files.items[0].count); // user, User, USER
    const m = ps.matches.items[1];
    try std.testing.expectEqual(@as(u32, 1), m.line);
    try std.testing.expectEqualStrings("function getUser() {", m.preview);
    try std.testing.expectEqualStrings("User", m.preview[m.preview_start..m.preview_end]);

    // Smart case: an uppercase letter makes it exact.
    try ps.run(io, root, &.{"src/a.ts"}, "USER");
    try std.testing.expectEqual(@as(usize, 1), ps.matches.items.len);
    try std.testing.expectEqual(@as(u32, 2), ps.matches.items[0].line);
}
