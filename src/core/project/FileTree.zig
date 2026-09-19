//! A folder opened as a project: its files and subfolders as a tree.
//! Folders read their contents lazily, the first time they're expanded.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const FileTree = @This();

pub const Node = struct {
    name: []const u8,
    /// Absolute path.
    path: []const u8,
    is_dir: bool,
    /// Indentation level; the root's direct children are 0.
    depth: u16,
    /// Index of the containing folder (the root is its own parent).
    parent: u32 = 0,
    expanded: bool = false,
    /// Children's indices in `nodes`: folders first, then by name. Null until
    /// the folder is first expanded.
    children: ?[]const u32 = null,
};

/// Names hidden from the tree (same defaults as VS Code).
const hidden = [_][]const u8{ ".git", ".svn", ".hg", "CVS", ".DS_Store", "Thumbs.db" };

gpa: Allocator,
/// Owns node names, paths and child lists; reset by `refresh`.
arena: std.heap.ArenaAllocator,
/// `nodes[0]` is the root folder itself.
nodes: std.ArrayList(Node) = .empty,
/// Nodes currently shown, top to bottom: children of expanded folders.
rows: std.ArrayList(u32) = .empty,

/// Opens the folder at `path` (relative to the working directory or absolute).
pub fn open(gpa: Allocator, io: Io, path: []const u8) !FileTree {
    var self: FileTree = .{ .gpa = gpa, .arena = .init(gpa) };
    errdefer self.deinit();
    const abs = try Io.Dir.cwd().realPathFileAlloc(io, path, self.arena.allocator());
    try self.loadRoot(io, abs);
    return self;
}

pub fn deinit(self: *FileTree) void {
    self.nodes.deinit(self.gpa);
    self.rows.deinit(self.gpa);
    self.arena.deinit();
}

pub fn root(self: *const FileTree) *const Node {
    return &self.nodes.items[0];
}

pub fn node(self: *const FileTree, index: u32) *const Node {
    return &self.nodes.items[index];
}

/// Whether `path` (absolute) is inside the project folder.
pub fn contains(self: *const FileTree, path: []const u8) bool {
    const r = self.root().path;
    return path.len > r.len and std.mem.startsWith(u8, path, r) and path[r.len] == std.fs.path.sep;
}

/// Expands or collapses a folder.
pub fn toggle(self: *FileTree, io: Io, index: u32) !void {
    if (!self.nodes.items[index].is_dir) return;
    try self.setExpanded(io, index, !self.nodes.items[index].expanded);
}

/// The folder a new entry goes in when `index` is targeted: the node
/// itself if it's a folder, otherwise the folder containing it.
pub fn folderOf(self: *const FileTree, index: u32) u32 {
    const n = self.nodes.items[index];
    return if (n.is_dir) index else n.parent;
}

/// Index of the node at `path` (absolute), if it's loaded.
pub fn find(self: *const FileTree, path: []const u8) ?u32 {
    for (self.nodes.items, 0..) |n, i| {
        if (std.mem.eql(u8, n.path, path)) return @intCast(i);
    }
    return null;
}

/// Collapses every folder, leaving just the project's top level.
pub fn collapseAll(self: *FileTree) !void {
    for (self.nodes.items[1..]) |*n| n.expanded = false;
    try self.rebuildRows();
}

/// Expands a folder (loading its contents if needed).
pub fn expand(self: *FileTree, io: Io, index: u32) !void {
    if (index != 0) try self.setExpanded(io, index, true);
}

pub const EntryKind = enum { file, folder };

pub const CreateError = error{ InvalidName, PathAlreadyExists };

/// Creates an empty file or a folder called `name` inside the folder node
/// `folder`, then refreshes the tree and reveals it. `name` may contain `/`
/// to create intermediate folders ("src/utils/math.ts"). Returns the new
/// entry's absolute path (caller frees).
pub fn create(self: *FileTree, io: Io, folder: u32, name: []const u8, kind: EntryKind) ![]u8 {
    const clean = try validateName(name);
    const path = try std.fs.path.join(self.gpa, &.{ self.nodes.items[folder].path, clean });
    errdefer self.gpa.free(path);

    const cwd = Io.Dir.cwd();
    if (cwd.statFile(io, path, .{ .follow_symlinks = false })) |_| {
        return error.PathAlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
    switch (kind) {
        .folder => try cwd.createDirPath(io, path),
        .file => {
            if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(io, dir);
            const file = try cwd.createFile(io, path, .{ .exclusive = true });
            file.close(io);
        },
    }
    try self.refresh(io);
    _ = try self.reveal(io, path);
    return path;
}

/// Renames a node within its folder; with `/` in `new_name` it moves it
/// into (possibly new) subfolders. Refreshes the tree and reveals the entry.
/// Returns the new absolute path (caller frees).
pub fn rename(self: *FileTree, io: Io, index: u32, new_name: []const u8) ![]u8 {
    if (index == 0) return error.InvalidName; // the project folder itself
    const clean = try validateName(new_name);
    const n = self.nodes.items[index];
    const new_path = try std.fs.path.join(self.gpa, &.{ self.nodes.items[n.parent].path, clean });
    errdefer self.gpa.free(new_path);
    try self.moveTo(io, index, new_path);
    return new_path;
}

/// Moves a node into the folder node `folder`, keeping its name. Returns
/// the new absolute path (caller frees).
pub fn move(self: *FileTree, io: Io, index: u32, folder: u32) ![]u8 {
    if (index == 0) return error.InvalidName;
    const n = self.nodes.items[index];
    const new_path = try std.fs.path.join(self.gpa, &.{ self.nodes.items[folder].path, n.name });
    errdefer self.gpa.free(new_path);
    try self.moveTo(io, index, new_path);
    return new_path;
}

/// Whether moving node `index` into folder node `folder` would do
/// something valid: not where it already is, not into itself.
pub fn canMove(self: *const FileTree, index: u32, folder: u32) bool {
    if (index == 0) return false;
    const n = self.nodes.items[index];
    return folder != n.parent and !isAtOrUnder(self.nodes.items[folder].path, n.path);
}

/// Shared by rename and move: puts node `index` at `new_path`, then
/// refreshes and reveals it.
fn moveTo(self: *FileTree, io: Io, index: u32, new_path: []const u8) !void {
    const n = self.nodes.items[index];
    if (std.mem.eql(u8, new_path, n.path)) return; // unchanged

    const cwd = Io.Dir.cwd();
    // A case-only change ("a.ts" → "A.ts") finds the file itself on
    // case-insensitive disks, so don't count that as taken.
    if (!std.ascii.eqlIgnoreCase(new_path, n.path)) {
        if (cwd.statFile(io, new_path, .{ .follow_symlinks = false })) |_| {
            return error.PathAlreadyExists;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
    }
    // A folder can't move into itself.
    if (std.mem.startsWith(u8, new_path, n.path) and new_path[n.path.len] == std.fs.path.sep) return error.InvalidName;

    if (std.fs.path.dirname(new_path)) |dir| try cwd.createDirPath(io, dir);
    try cwd.rename(n.path, cwd, new_path, io);
    try self.refresh(io); // invalidates `n`'s path
    _ = try self.reveal(io, new_path);
    // Refresh remembers expanded folders by path: re-open a moved one.
    if (n.is_dir and n.expanded) if (self.find(new_path)) |i| try self.expand(io, i);
}

/// Deletes a node from disk for good (a folder with everything in it).
/// Prefer moving to the trash; this is the fallback.
pub fn deletePermanently(self: *FileTree, io: Io, index: u32) !void {
    if (index == 0) return error.InvalidName;
    const n = self.nodes.items[index];
    const cwd = Io.Dir.cwd();
    if (n.is_dir) try cwd.deleteTree(io, n.path) else try cwd.deleteFile(io, n.path);
    try self.refresh(io);
}

/// Whether `path` is `base` or inside it (for updating tabs after a
/// rename or delete).
pub fn isAtOrUnder(path: []const u8, base: []const u8) bool {
    if (!std.mem.startsWith(u8, path, base)) return false;
    return path.len == base.len or path[base.len] == std.fs.path.sep;
}

/// Trims `name` and checks it stays inside the target folder.
fn validateName(name: []const u8) CreateError![]const u8 {
    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, name, " \t"), "/");
    if (trimmed.len == 0 or trimmed[0] == '/' or std.mem.indexOfScalar(u8, trimmed, 0) != null) return error.InvalidName;
    var parts = std.mem.splitScalar(u8, trimmed, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidName;
    }
    return trimmed;
}

/// Expands every folder containing `path`, so its row becomes visible.
/// Returns the file's row, or null if it's not in the project.
pub fn reveal(self: *FileTree, io: Io, path: []const u8) !?usize {
    if (!self.contains(path)) return null;
    var current: u32 = 0;
    var parts = std.mem.tokenizeScalar(u8, path[self.root().path.len..], std.fs.path.sep);
    while (parts.next()) |part| {
        if (current != 0) try self.setExpanded(io, current, true);
        try self.loadChildren(io, current);
        current = for (self.nodes.items[current].children.?) |c| {
            if (std.mem.eql(u8, self.nodes.items[c].name, part)) break c;
        } else return null;
    }
    return std.mem.indexOfScalar(u32, self.rows.items, current);
}

/// Re-reads the folder from disk (e.g. after files were added elsewhere),
/// keeping the same folders expanded.
pub fn refresh(self: *FileTree, io: Io) !void {
    // Remember expanded folders by path; the arena holding paths is reset.
    var expanded: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = expanded.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        expanded.deinit(self.gpa);
    }
    for (self.nodes.items) |n| {
        if (n.expanded) try expanded.put(self.gpa, try self.gpa.dupe(u8, n.path), {});
    }
    const root_path = try self.gpa.dupe(u8, self.root().path);
    defer self.gpa.free(root_path);

    self.nodes.clearRetainingCapacity();
    _ = self.arena.reset(.retain_capacity);
    try self.loadRoot(io, try self.arena.allocator().dupe(u8, root_path));

    // Nodes appended while expanding are visited too, so nested folders reopen.
    var i: u32 = 1;
    while (i < self.nodes.items.len) : (i += 1) {
        const n = self.nodes.items[i];
        if (n.is_dir and expanded.contains(n.path)) {
            try self.loadChildren(io, i);
            self.nodes.items[i].expanded = true;
        }
    }
    try self.rebuildRows();
}

fn loadRoot(self: *FileTree, io: Io, path: []const u8) !void {
    try self.nodes.append(self.gpa, .{
        .name = std.fs.path.basename(path),
        .path = path,
        .is_dir = true,
        .depth = 0,
        .expanded = true,
    });
    try self.loadChildren(io, 0);
    try self.rebuildRows();
}

fn setExpanded(self: *FileTree, io: Io, index: u32, expanded: bool) !void {
    if (expanded) try self.loadChildren(io, index);
    self.nodes.items[index].expanded = expanded;
    try self.rebuildRows();
}

/// Reads a folder's entries once. Unreadable folders just look empty.
fn loadChildren(self: *FileTree, io: Io, index: u32) !void {
    if (self.nodes.items[index].children != null) return;
    const alloc = self.arena.allocator();
    const parent = self.nodes.items[index];
    const depth: u16 = if (index == 0) 0 else parent.depth + 1;

    var entries: std.ArrayList(Node) = .empty;
    defer entries.deinit(self.gpa);
    read: {
        var dir = Io.Dir.cwd().openDir(io, parent.path, .{ .iterate = true }) catch break :read;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch break :read) |e| {
            if (isHidden(e.name)) continue;
            const is_dir = switch (e.kind) {
                .directory => true,
                // Follow symlinks to see what they point at.
                .sym_link => if (dir.statFile(io, e.name, .{})) |st| st.kind == .directory else |_| false,
                else => false,
            };
            try entries.append(self.gpa, .{
                .name = try alloc.dupe(u8, e.name),
                .path = try std.fs.path.join(alloc, &.{ parent.path, e.name }),
                .is_dir = is_dir,
                .depth = depth,
                .parent = index,
            });
        }
    }
    std.mem.sort(Node, entries.items, {}, folderFirstByName);

    const children = try alloc.alloc(u32, entries.items.len);
    for (entries.items, 0..) |e, i| {
        children[i] = @intCast(self.nodes.items.len);
        try self.nodes.append(self.gpa, e);
    }
    self.nodes.items[index].children = children;
}

fn rebuildRows(self: *FileTree) !void {
    self.rows.clearRetainingCapacity();
    try self.addRows(0);
}

fn addRows(self: *FileTree, index: u32) !void {
    const n = self.nodes.items[index];
    if (!n.expanded) return;
    for (n.children orelse return) |c| {
        try self.rows.append(self.gpa, c);
        try self.addRows(c);
    }
}

fn folderFirstByName(_: void, a: Node, b: Node) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

fn isHidden(name: []const u8) bool {
    for (hidden) |h| {
        if (std.mem.eql(u8, name, h)) return true;
    }
    return false;
}

test {
    _ = @import("tests/FileTree_test.zig");
}
