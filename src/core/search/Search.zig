//! Find: every occurrence of a query in the buffer, kept up to date as the
//! buffer, query or options change. See `find.Options` for "match case" and
//! "whole word".
const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("../buffer/Buffer.zig");
const find = @import("lib/find.zig");
pub const Options = find.Options;

const Search = @This();
const Range = Buffer.Range;

/// Stop counting beyond this; keeps huge files with a 1-letter query snappy.
pub const max_matches = 100_000;

/// Non-overlapping, in document order.
matches: std.ArrayList(Range) = .empty,
/// The query `matches` were computed for.
query: std.ArrayList(u8) = .empty,
/// Options `matches` were computed with.
options: Options = .{},
/// Buffer version `matches` were computed for.
version: ?u64 = null,

pub fn deinit(self: *Search, gpa: Allocator) void {
    self.matches.deinit(gpa);
    self.query.deinit(gpa);
}

/// Recomputes matches if the query, options or buffer changed. Returns true
/// when the query or options changed (callers then jump to the first match).
pub fn update(self: *Search, gpa: Allocator, buf: *const Buffer, query: []const u8, opts: Options) !bool {
    const query_changed = !std.mem.eql(u8, self.query.items, query) or
        !std.meta.eql(self.options, opts);
    if (!query_changed and self.version == buf.version) return false;

    self.query.clearRetainingCapacity();
    try self.query.appendSlice(gpa, query);
    self.options = opts;
    self.version = buf.version;
    self.matches.clearRetainingCapacity();
    if (query.len == 0) return query_changed;

    const text = buf.items();
    var i: usize = 0;
    while (self.matches.items.len < max_matches) {
        const start = find.next(text, i, query, opts) orelse break;
        try self.matches.append(gpa, .{ .start = start, .end = start + query.len });
        i = start + query.len;
    }
    return query_changed;
}

/// Index of the match exactly covering `r`, e.g. the current selection.
pub fn indexOf(self: *const Search, r: Range) ?usize {
    const i = self.firstStartingAtOrAfter(r.start) orelse return null;
    const m = self.matches.items[i];
    return if (m.start == r.start and m.end == r.end) i else null;
}

/// First match starting at or after `pos`, wrapping to the first one.
pub fn nextFrom(self: *const Search, pos: usize) ?usize {
    if (self.matches.items.len == 0) return null;
    return self.firstStartingAtOrAfter(pos) orelse 0;
}

/// Last match starting before `pos`, wrapping to the last one.
pub fn prevBefore(self: *const Search, pos: usize) ?usize {
    const n = self.matches.items.len;
    if (n == 0) return null;
    const i = self.firstStartingAtOrAfter(pos) orelse n;
    return if (i == 0) n - 1 else i - 1;
}

fn firstStartingAtOrAfter(self: *const Search, pos: usize) ?usize {
    const i = std.sort.lowerBound(Range, self.matches.items, pos, struct {
        fn order(p: usize, r: Range) std.math.Order {
            return std.math.order(p, r.start);
        }
    }.order);
    return if (i < self.matches.items.len) i else null;
}

/// Replaces every match with `replacement` as a single undo step. Returns
/// how many were replaced.
pub fn replaceAll(self: *Search, gpa: Allocator, buf: *Buffer, replacement: []const u8) !usize {
    const ms = self.matches.items;
    if (ms.len == 0) return 0;
    const first = ms[0].start;
    const last = ms[ms.len - 1].end;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var prev = first;
    for (ms) |m| {
        try out.appendSlice(gpa, buf.items()[prev..m.start]);
        try out.appendSlice(gpa, replacement);
        prev = m.end;
    }
    try buf.replace(first, last, out.items, out.items.len, .other);
    return ms.len;
}

test {
    _ = @import("tests/Search_test.zig");
}
