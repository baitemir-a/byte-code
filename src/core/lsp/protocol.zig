//! The Language Server Protocol's plumbing: messages framed by a
//! `Content-Length` header, positions as lines and UTF-16 columns, and
//! files as `file://` URIs.
const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------- framing

/// `body` with its header, ready to write.
pub fn frame(alloc: Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

/// Collects what a server writes and cuts it into messages.
pub const Framer = struct {
    bytes: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Framer, gpa: Allocator) void {
        self.bytes.deinit(gpa);
    }

    pub fn push(self: *Framer, gpa: Allocator, data: []const u8) !void {
        try self.bytes.appendSlice(gpa, data);
    }

    /// The next whole message's body (caller frees), or null until one
    /// has come in completely.
    pub fn next(self: *Framer, gpa: Allocator) !?[]u8 {
        const b = self.bytes.items;
        const header_end = std.mem.indexOf(u8, b, "\r\n\r\n") orelse return null;
        var len: ?usize = null;
        var lines = std.mem.splitSequence(u8, b[0..header_end], "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), "content-length")) continue;
            len = std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " "), 10) catch null;
        }
        const start = header_end + 4;
        const n = len orelse {
            // A header without a length: skip it rather than stall.
            self.drop(start);
            return null;
        };
        if (b.len < start + n) return null;
        const body = try gpa.dupe(u8, b[start .. start + n]);
        self.drop(start + n);
        return body;
    }

    fn drop(self: *Framer, n: usize) void {
        const b = self.bytes.items;
        std.mem.copyForwards(u8, b[0 .. b.len - n], b[n..]);
        self.bytes.shrinkRetainingCapacity(b.len - n);
    }
};

// -------------------------------------------------------------- positions

/// A place as LSP names it: zero-based line, and column in UTF-16 units.
pub const Position = struct { line: u32, character: u32 };

/// The LSP position of byte offset `pos` in `text`.
pub fn toPosition(text: []const u8, pos: usize) Position {
    const p = @min(pos, text.len);
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..p], '\n')) |i| i + 1 else 0;
    const line: u32 = @intCast(std.mem.count(u8, text[0..line_start], "\n"));
    return .{ .line = line, .character = utf16Len(text[line_start..p]) };
}

/// The byte offset of an LSP position; past the end of its line (or the
/// text) it stops there.
pub fn toOffset(text: []const u8, p: Position) usize {
    var start: usize = 0;
    var l: u32 = 0;
    while (l < p.line) : (l += 1) {
        start = (std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return text.len) + 1;
    }
    return start + offsetInLine(text[start..(std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len)], p.character);
}

/// Line starts, for turning many positions into offsets quickly.
pub const Lines = struct {
    text: []const u8,
    starts: std.ArrayList(usize) = .empty,

    pub fn init(gpa: Allocator, text: []const u8) !Lines {
        var self: Lines = .{ .text = text };
        try self.starts.append(gpa, 0);
        for (text, 0..) |c, i| if (c == '\n') try self.starts.append(gpa, i + 1);
        return self;
    }

    pub fn deinit(self: *Lines, gpa: Allocator) void {
        self.starts.deinit(gpa);
    }

    pub fn offset(self: *const Lines, p: Position) usize {
        if (p.line >= self.starts.items.len) return self.text.len;
        const start = self.starts.items[p.line];
        const end = std.mem.indexOfScalarPos(u8, self.text, start, '\n') orelse self.text.len;
        return start + offsetInLine(self.text[start..end], p.character);
    }
};

/// UTF-16 units in `s`.
pub fn utf16Len(s: []const u8) u32 {
    var n: u32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        n += if (len == 4) 2 else 1;
        i += len;
    }
    return n;
}

fn offsetInLine(line: []const u8, units: u32) usize {
    var n: u32 = 0;
    var i: usize = 0;
    while (i < line.len and n < units) {
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        n += if (len == 4) 2 else 1;
        i = @min(line.len, i + len);
    }
    return i;
}

// ------------------------------------------------------------------- URIs

/// `file:///path/to/a%20file.zig` for an absolute path.
pub fn uriFromPath(alloc: Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "file://");
    // Windows: C:\x → /C:/x.
    if (path.len > 0 and path[0] != '/') try out.append(alloc, '/');
    for (path) |c| {
        const keep = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~/:@!$&'()*+,;=", c) != null;
        if (c == '\\') {
            try out.append(alloc, '/');
        } else if (keep) {
            try out.append(alloc, c);
        } else {
            try out.print(alloc, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(alloc);
}

/// The path of a `file://` URI, or null for any other kind.
pub fn pathFromUri(alloc: Allocator, uri: []const u8) !?[]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    var rest = uri[prefix.len..];
    // file://host/path: the host is dropped.
    if (!std.mem.startsWith(u8, rest, "/")) rest = rest[(std.mem.indexOfScalar(u8, rest, '/') orelse return null)..];
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            if (std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16)) |c| {
                try out.append(alloc, c);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(alloc, rest[i]);
    }
    // /C:/x → C:/x.
    const p = out.items;
    if (p.len >= 3 and p[0] == '/' and std.ascii.isAlphabetic(p[1]) and p[2] == ':') {
        std.mem.copyForwards(u8, p[0 .. p.len - 1], p[1..]);
        out.shrinkRetainingCapacity(p.len - 1);
    }
    return try out.toOwnedSlice(alloc);
}

test {
    _ = @import("tests/protocol_test.zig");
}
