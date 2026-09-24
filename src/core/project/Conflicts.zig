//! The conflicts a merge left in a file: each is the lines between a
//! `<<<<<<<` and a `>>>>>>>` marker, with this branch's version ("current")
//! above the `=======` and the other one ("incoming") below it. A
//! `|||||||` section (git's diff3 style) holds what both started from.
//! The editor offers to keep one side, or both, in place of the markers.
const std = @import("std");

pub const Region = struct {
    /// Lines (0-based) of the markers. `base` is the `|||||||` one when
    /// there is one, else the same as `separator`.
    start: u32,
    base: u32,
    separator: u32,
    end: u32,
    /// Bytes: from the start of the `<<<<<<<` line to the end of the
    /// `>>>>>>>` one (its newline included), and the two sides' text.
    from: usize,
    to: usize,
    current: Span,
    incoming: Span,
};

pub const Span = struct { start: usize, end: usize };

pub const Choice = enum { current, incoming, both };

/// Finds the conflicts in `text`, in order. A marker without its partners
/// (half-deleted by hand, say) doesn't count.
pub fn find(gpa: std.mem.Allocator, text: []const u8, out: *std.ArrayList(Region)) !void {
    out.clearRetainingCapacity();
    // Most files have none: skip the line walk.
    if (std.mem.indexOf(u8, text, "<<<<<<<") == null) return;
    var open: ?struct { line: u32, from: usize, body: usize } = null;
    var base: ?struct { line: u32, at: usize, body: usize } = null;
    var sep: ?struct { line: u32, at: usize, body: usize } = null;
    var line: u32 = 0;
    var pos: usize = 0;
    while (pos < text.len) : (line += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n');
        const end = nl orelse text.len;
        const next = if (nl) |n| n + 1 else text.len;
        const l = std.mem.trimEnd(u8, text[pos..end], "\r");
        defer pos = next;
        if (isMarker(l, '<')) {
            open = .{ .line = line, .from = pos, .body = next };
            base = null;
            sep = null;
        } else if (open != null and sep == null and base == null and isMarker(l, '|')) {
            base = .{ .line = line, .at = pos, .body = next };
        } else if (open != null and sep == null and std.mem.eql(u8, l, "=======")) {
            sep = .{ .line = line, .at = pos, .body = next };
        } else if (open != null and sep != null and isMarker(l, '>')) {
            const o = open.?;
            const s = sep.?;
            try out.append(gpa, .{
                .start = o.line,
                .base = if (base) |b| b.line else s.line,
                .separator = s.line,
                .end = line,
                .from = o.from,
                .to = next,
                .current = .{ .start = o.body, .end = if (base) |b| b.at else s.at },
                .incoming = .{ .start = s.body, .end = pos },
            });
            open = null;
            base = null;
            sep = null;
        }
    }
}

/// `<<<<<<<` alone or followed by a space and a name.
fn isMarker(line: []const u8, c: u8) bool {
    if (line.len < 7) return false;
    for (line[0..7]) |ch| if (ch != c) return false;
    return line.len == 7 or line[7] == ' ';
}

/// What the region becomes: the side (or sides) kept. Caller frees.
pub fn resolve(gpa: std.mem.Allocator, text: []const u8, r: Region, choice: Choice) ![]u8 {
    const current = text[r.current.start..r.current.end];
    const incoming = text[r.incoming.start..r.incoming.end];
    return switch (choice) {
        .current => gpa.dupe(u8, current),
        .incoming => gpa.dupe(u8, incoming),
        .both => std.mem.concat(gpa, u8, &.{ current, incoming }),
    };
}

/// Whether any conflict is left in `text`.
pub fn any(gpa: std.mem.Allocator, text: []const u8) !bool {
    var list: std.ArrayList(Region) = .empty;
    defer list.deinit(gpa);
    try find(gpa, text, &list);
    return list.items.len > 0;
}

test {
    _ = @import("tests/Conflicts_test.zig");
}
