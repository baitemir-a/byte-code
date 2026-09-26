//! Matching brackets: the partner of the bracket at the cursor, for
//! highlighting both and jumping between them, and the bracket a line
//! leaves open, for folding. Brackets in strings and comments don't
//! count; the highlighter says which those are.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const Highlighter = @import("../../syntax/Highlighter.zig");

/// How many lines a search goes through before giving up.
pub const max_lines = 5000;

pub const Pair = struct { open: usize, close: usize };

fn isOpen(c: u8) bool {
    return c == '(' or c == '[' or c == '{';
}

fn isClose(c: u8) bool {
    return c == ')' or c == ']' or c == '}';
}

fn partner(c: u8) u8 {
    return switch (c) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        ')' => '(',
        ']' => '[',
        else => '{',
    };
}

/// The brackets of a line that are code: a bit per byte, set for a
/// bracket outside strings and comments (lines longer than the mask are
/// cut off).
const Mask = std.StaticBitSet(4096);

fn codeBrackets(hl: *const Highlighter, index: usize, line: []const u8) Mask {
    var mask: Mask = .initEmpty();
    var tokens = hl.tokens(index, line);
    while (tokens.next()) |span| {
        switch (span.kind) {
            .string, .regex, .comment => continue,
            else => {},
        }
        var i = span.start;
        while (i < span.end and i < Mask.bit_length) : (i += 1) {
            if (isOpen(line[i]) or isClose(line[i])) mask.set(i);
        }
    }
    return mask;
}

/// The bracket touching `pos` — the one after it, else the one before —
/// and its partner. Null when neither is a bracket in code, or the
/// partner isn't found.
pub fn matchAt(buf: *const Buffer, hl: *const Highlighter, pos: usize) ?Pair {
    const b = buf.items();
    const candidates = [2]?usize{ if (pos < b.len) pos else null, if (pos > 0) pos - 1 else null };
    for (candidates) |maybe| {
        const at = maybe orelse continue;
        const c = b[at];
        if (!isOpen(c) and !isClose(c)) continue;
        const start = buf.lineStart(at);
        const index = buf.lineIndex(at);
        const mask = codeBrackets(hl, index, b[start..buf.lineEnd(start)]);
        if (at - start >= Mask.bit_length or !mask.isSet(at - start)) continue;
        if (isOpen(c)) {
            if (findClose(buf, hl, at, index)) |close| return .{ .open = at, .close = close };
        } else {
            if (findOpen(buf, hl, at, index)) |open| return .{ .open = open, .close = at };
        }
    }
    return null;
}

/// The closer of the opener at `open` (on line `index`).
pub fn findClose(buf: *const Buffer, hl: *const Highlighter, open: usize, index: usize) ?usize {
    const b = buf.items();
    const want = b[open];
    var depth: usize = 0;
    var start = buf.lineStart(open);
    var line_index = index;
    var from = open - start;
    for (0..max_lines) |_| {
        const end = buf.lineEnd(start);
        const line = b[start..end];
        const mask = codeBrackets(hl, line_index, line);
        var i = from;
        while (i < line.len and i < Mask.bit_length) : (i += 1) {
            if (!mask.isSet(i)) continue;
            const c = line[i];
            if (c == want) {
                depth += 1;
            } else if (c == partner(want)) {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return start + i;
            }
        }
        if (end >= b.len) return null;
        start = end + 1;
        line_index += 1;
        from = 0;
    }
    return null;
}

/// The opener of the closer at `close` (on line `index`).
pub fn findOpen(buf: *const Buffer, hl: *const Highlighter, close: usize, index: usize) ?usize {
    const b = buf.items();
    const want = b[close];
    var depth: usize = 0;
    var start = buf.lineStart(close);
    var line_index = index;
    var upto = close - start + 1;
    for (0..max_lines) |_| {
        const line = b[start..buf.lineEnd(start)];
        const mask = codeBrackets(hl, line_index, line);
        var i = @min(upto, line.len, Mask.bit_length);
        while (i > 0) {
            i -= 1;
            if (!mask.isSet(i)) continue;
            const c = line[i];
            if (c == want) {
                depth += 1;
            } else if (c == partner(want)) {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return start + i;
            }
        }
        if (start == 0) return null;
        start = buf.lineStart(start - 1);
        line_index -= 1;
        upto = std.math.maxInt(usize);
    }
    return null;
}

/// The last bracket a line opens and doesn't close (in code), as an
/// offset into the line.
pub fn unclosedOpener(hl: *const Highlighter, index: usize, line: []const u8) ?usize {
    const mask = codeBrackets(hl, index, line);
    var stack: [64]usize = undefined;
    var n: usize = 0;
    var it = mask.iterator(.{});
    while (it.next()) |i| {
        if (i >= line.len) break;
        const c = line[i];
        if (isOpen(c)) {
            if (n == stack.len) {
                std.mem.copyForwards(usize, stack[0 .. n - 1], stack[1..n]);
                n -= 1;
            }
            stack[n] = i;
            n += 1;
        } else if (n > 0 and line[stack[n - 1]] == partner(c)) {
            n -= 1;
        }
    }
    return if (n > 0) stack[n - 1] else null;
}

test {
    _ = @import("../tests/brackets_test.zig");
}
