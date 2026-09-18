//! Finding files by name (Cmd+P): every file under a folder, ranked by
//! fuzzy match. A match in the file name beats one spread over the path.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fuzzy = @import("completion/fuzzy.zig");

const FileSearch = @This();

/// Stop listing beyond this many files; huge trees stay responsive.
pub const max_files = 50_000;

/// Folders never listed: version control, dependencies, build output.
const skipped_dirs = [_][]const u8{
    "node_modules", "zig-out", "target", "dist", "build", "__pycache__", "venv", "vendor",
};

pub const Result = struct {
    /// Index into `files`.
    file: u32,
    score: i32,
    /// Matched bytes of the path (first 64 only), for highlighting.
    matches: u64,
};

gpa: Allocator,
/// Owns the paths.
arena: std.heap.ArenaAllocator,
/// Paths relative to the folder, using '/' separators.
files: std.ArrayList([]const u8) = .empty,

pub fn init(gpa: Allocator) FileSearch {
    return .{ .gpa = gpa, .arena = .init(gpa) };
}

pub fn deinit(self: *FileSearch) void {
    self.files.deinit(self.gpa);
    self.arena.deinit();
}

/// Lists the files under `root` (absolute). Hidden files and folders
/// (".git", ".env"...) and the usual dependency/build folders are skipped.
pub fn scan(self: *FileSearch, io: Io, root: []const u8) !void {
    self.files.clearRetainingCapacity();
    _ = self.arena.reset(.retain_capacity);
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walkSelectively(self.gpa);
    defer walker.deinit();
    while (self.files.items.len < max_files) {
        // Unreadable folders are skipped, not fatal.
        const entry = walker.next(io) catch continue orelse break;
        if (entry.basename.len > 0 and entry.basename[0] == '.') continue;
        switch (entry.kind) {
            .directory => if (!isSkipped(entry.basename)) walker.enter(io, entry) catch {},
            .file, .sym_link => {
                const path = try self.arena.allocator().dupe(u8, entry.path);
                if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, path, std.fs.path.sep, '/');
                try self.files.append(self.gpa, path);
            },
            else => {},
        }
    }
    std.mem.sort([]const u8, self.files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
}

fn isSkipped(name: []const u8) bool {
    for (skipped_dirs) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

/// The best `limit` matches for `query`, best first. An empty query lists
/// files in path order.
pub fn search(self: *const FileSearch, query: []const u8, out: *std.ArrayList(Result), limit: usize) !void {
    out.clearRetainingCapacity();
    const q = std.mem.trim(u8, query, " ");
    for (self.files.items, 0..) |path, i| {
        const r = rank(path, q) orelse continue;
        try out.append(self.gpa, .{ .file = @intCast(i), .score = r.score, .matches = r.positions });
        if (q.len == 0 and out.items.len >= limit) return;
    }
    std.mem.sort(Result, out.items, self, struct {
        fn better(s: *const FileSearch, a: Result, b: Result) bool {
            if (a.score != b.score) return a.score > b.score;
            // Shorter paths first among equals (less nested, more likely).
            return s.files.items[a.file].len < s.files.items[b.file].len;
        }
    }.better);
    if (out.items.len > limit) out.shrinkRetainingCapacity(limit);
}

/// Scores `path` for `query`: a match within the file name gets a bonus,
/// otherwise the whole path is matched (so "src/app" finds src/App.zig).
fn rank(path: []const u8, query: []const u8) ?fuzzy.Match {
    if (query.len == 0) return .{ .score = 0, .positions = 0 };
    const base_start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0;
    if (std.mem.indexOfScalar(u8, query, '/') == null) {
        if (fuzzy.match(path[base_start..], query)) |m| {
            const shift: u6 = @intCast(@min(base_start, 63));
            const positions = if (base_start < 64) m.positions << shift else 0;
            return .{ .score = m.score + 40, .positions = positions };
        }
    }
    return fuzzy.match(path, query);
}

test "lists files, skips hidden and dependency folders, ranks by name" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "src/App.zig", "src/ui/Sidebar.zig", "src/ui/app_icon.png", "README.md", ".git/config", "node_modules/x/index.js", ".env" }) |p| {
        if (std.fs.path.dirname(p)) |d| try tmp.dir.createDirPath(io, d);
        try tmp.dir.writeFile(io, .{ .sub_path = p, .data = "" });
    }
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var fs = FileSearch.init(gpa);
    defer fs.deinit();
    try fs.scan(io, root);
    try std.testing.expectEqual(@as(usize, 4), fs.files.items.len);
    try std.testing.expectEqualStrings("README.md", fs.files.items[0]);

    var results: std.ArrayList(Result) = .empty;
    defer results.deinit(gpa);

    // Both "app" files rank above paths that only contain a…p…p; exact
    // case decides between them.
    try fs.search("app", &results, 10);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try fs.search("App", &results, 10);
    try std.testing.expectEqualStrings("src/App.zig", fs.files.items[results.items[0].file]);

    try fs.search("sidebar", &results, 10);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("src/ui/Sidebar.zig", fs.files.items[results.items[0].file]);

    // With a '/', the path counts: "ui/app" finds the icon under ui/.
    try fs.search("ui/app", &results, 10);
    try std.testing.expectEqualStrings("src/ui/app_icon.png", fs.files.items[results.items[0].file]);

    try fs.search("", &results, 2);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
}
