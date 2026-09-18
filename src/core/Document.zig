//! The file behind the buffer: where it lives, its line endings, and
//! whether the buffer has unsaved changes.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Buffer = @import("Buffer.zig");
const text_util = @import("text.zig");

const Document = @This();

/// Largest file we'll open; beyond this a flat buffer gets sluggish.
pub const max_file_size = 64 * 1024 * 1024;

pub const OpenError = error{ NotUtf8, FileTooBig } || Allocator.Error || Io.Dir.ReadFileAllocError;
pub const SaveError = error{NoPath} || Allocator.Error || Io.Dir.CreateFileAtomicError ||
    Io.File.Writer.Error || Io.File.Atomic.ReplaceError;

/// Null for a new, never-saved document.
path: ?[]u8 = null,
/// `Buffer.version` when last loaded or saved.
saved_version: u64 = 0,
/// The file used "\r\n"; the buffer always holds "\n" and saving converts back.
crlf: bool = false,

pub fn deinit(self: *Document, gpa: Allocator) void {
    if (self.path) |p| gpa.free(p);
}

pub fn isDirty(self: *const Document, buf: *const Buffer) bool {
    return buf.version != self.saved_version;
}

/// File name for display, e.g. in the window title.
pub fn name(self: *const Document) []const u8 {
    const p = self.path orelse return "untitled";
    return std.fs.path.basename(p);
}

/// Directory of the file, used as the starting point for file dialogs.
pub fn dirname(self: *const Document) ?[]const u8 {
    return std.fs.path.dirname(self.path orelse return null);
}

pub fn setPath(self: *Document, gpa: Allocator, path: []const u8) Allocator.Error!void {
    const copy = try gpa.dupe(u8, path);
    if (self.path) |p| gpa.free(p);
    self.path = copy;
}

/// Loads `path` into `buf`. A missing file opens as a new, empty document
/// that will be created on first save.
pub fn open(self: *Document, gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, buf: *Buffer) OpenError!void {
    const bytes = dir.readFileAlloc(io, path, gpa, .limited(max_file_size)) catch |err| switch (err) {
        error.FileNotFound => try gpa.alloc(u8, 0),
        error.StreamTooLong => return error.FileTooBig,
        else => |e| return e,
    };
    defer gpa.free(bytes);
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.NotUtf8;

    const crlf = std.mem.indexOf(u8, bytes, "\r\n") != null;
    const text = if (crlf) removeCarriageReturns(bytes) else bytes;

    try self.setPath(gpa, path);
    try buf.load(text);
    buf.indent = text_util.detectIndent(text);
    self.crlf = crlf;
    self.saved_version = buf.version;
}

/// Writes `buf` to the document's path. The file is replaced atomically, so
/// a failed save never leaves a half-written file behind.
pub fn save(self: *Document, gpa: Allocator, io: Io, dir: Io.Dir, buf: *const Buffer) SaveError!void {
    const path = self.path orelse return error.NoPath;

    const data = if (self.crlf) try addCarriageReturns(gpa, buf.items()) else buf.items();
    defer if (self.crlf) gpa.free(data);

    var file = try dir.createFileAtomic(io, path, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, data);
    try file.replace(io);
    self.saved_version = buf.version;
}

/// Turns "\r\n" into "\n" in place and returns the shortened slice.
fn removeCarriageReturns(bytes: []u8) []u8 {
    var out: usize = 0;
    for (bytes, 0..) |b, i| {
        if (b == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') continue;
        bytes[out] = b;
        out += 1;
    }
    return bytes[0..out];
}

fn addCarriageReturns(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    const lines = std.mem.count(u8, text, "\n");
    const out = try gpa.alloc(u8, text.len + lines);
    var i: usize = 0;
    for (text) |b| {
        if (b == '\n') {
            out[i] = '\r';
            i += 1;
        }
        out[i] = b;
        i += 1;
    }
    return out;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "open, edit, save round trip keeps CRLF" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "one\r\ntwo\r\n" });

    var buf = Buffer.init(gpa);
    defer buf.deinit();
    var doc: Document = .{};
    defer doc.deinit(gpa);

    try doc.open(gpa, testing.io, tmp.dir, "a.ts", &buf);
    try testing.expectEqualStrings("one\ntwo\n", buf.items());
    try testing.expect(!doc.isDirty(&buf));
    try testing.expectEqualStrings("a.ts", doc.name());

    buf.moveTo(buf.items().len, false);
    try buf.insert("three\n");
    try testing.expect(doc.isDirty(&buf));

    try doc.save(gpa, testing.io, tmp.dir, &buf);
    try testing.expect(!doc.isDirty(&buf));
    const saved = try tmp.dir.readFileAlloc(testing.io, "a.ts", gpa, .unlimited);
    defer gpa.free(saved);
    try testing.expectEqualStrings("one\r\ntwo\r\nthree\r\n", saved);
}

test "missing file opens empty, invalid UTF-8 is refused" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bin", .data = "\xff\xfe" });

    var buf = Buffer.init(gpa);
    defer buf.deinit();
    var doc: Document = .{};
    defer doc.deinit(gpa);

    try doc.open(gpa, testing.io, tmp.dir, "new.js", &buf);
    try testing.expectEqualStrings("", buf.items());
    try testing.expectError(error.NotUtf8, doc.open(gpa, testing.io, tmp.dir, "bin", &buf));
    try testing.expectEqualStrings("new.js", doc.name()); // unchanged by the failed open
}
