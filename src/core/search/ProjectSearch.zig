//! Searching text in every file of a project (the sidebar's Search view).
//! Matching options (match case, whole word) are shared with Find.
const std = @import("std");
const find = @import("lib/find.zig");
pub const Options = find.Options;
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

/// Text to search instead of the file on disk, e.g. an open tab with
/// unsaved edits (so match positions agree with what's in the editor).
pub const Overlay = struct {
    ctx: *const anyopaque,
    get: *const fn (ctx: *const anyopaque, path: []const u8) ?[]const u8,
};

/// Searches `paths` (relative to `root`) for `query`. Binary files, and
/// files over `max_file_size`, are skipped.
pub fn run(self: *ProjectSearch, io: Io, root: []const u8, paths: []const []const u8, query: []const u8, opts: Options, overlay: ?Overlay) !void {
    self.clear();
    if (query.len == 0) return;
    var dir = try Io.Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);
    for (paths) |path| {
        if (self.matches.items.len >= max_matches) {
            self.truncated = true;
            break;
        }
        if (overlay) |o| if (o.get(o.ctx, path)) |data| {
            try self.searchFile(path, data, query, opts);
            continue;
        };
        const data = dir.readFileAlloc(io, path, self.gpa, .limited(max_file_size)) catch continue;
        defer self.gpa.free(data);
        if (std.mem.indexOfScalar(u8, data[0..@min(data.len, 8000)], 0) != null) continue; // binary
        try self.searchFile(path, data, query, opts);
    }
}

fn searchFile(self: *ProjectSearch, path: []const u8, data: []const u8, query: []const u8, opts: Options) !void {
    const alloc = self.arena.allocator();
    const first: u32 = @intCast(self.matches.items.len);
    var line_no: u32 = 0;
    var line_start: usize = 0;
    var pos: usize = 0;
    while (find.next(data, pos, query, opts)) |at| {
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

/// Replaces every match of `query` in `text` (same matching as `run`).
/// Returns the new text (caller frees) and how many were replaced, or
/// null text when nothing matched.
pub fn replaceAll(gpa: Allocator, text: []const u8, query: []const u8, replacement: []const u8, opts: Options) !struct { text: ?[]u8, count: usize } {
    if (query.len == 0) return .{ .text = null, .count = 0 };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var count: usize = 0;
    var pos: usize = 0;
    while (find.next(text, pos, query, opts)) |at| {
        try out.appendSlice(gpa, text[pos..at]);
        try out.appendSlice(gpa, replacement);
        pos = at + query.len;
        count += 1;
    }
    if (count == 0) {
        out.deinit(gpa);
        return .{ .text = null, .count = 0 };
    }
    try out.appendSlice(gpa, text[pos..]);
    return .{ .text = try out.toOwnedSlice(gpa), .count = count };
}

test {
    _ = @import("tests/ProjectSearch_test.zig");
}
