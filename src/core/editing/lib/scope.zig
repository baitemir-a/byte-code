//! "Select scope": grows a selection to the next enclosing unit — the word,
//! the line, the inside of the surrounding quotes or brackets, then the
//! quotes or brackets themselves, and so on out to the whole file.
//!
//! Brackets and strings are found with a light scan that works across
//! languages: it skips string literals and `//` / `/* */` comments so that
//! brackets inside them don't count.
const std = @import("std");
const text = @import("text.zig");
const Range = @import("../../buffer/Buffer.zig").Range;

/// The smallest scope strictly containing `sel`, or null when `sel` is
/// already the whole text.
pub fn expand(gpa: std.mem.Allocator, bytes: []const u8, sel: Range) !?Range {
    var best: ?Range = null;
    const consider = struct {
        fn f(b: *?Range, r: Range, s: Range) void {
            if (r.start > s.start or r.end < s.end) return; // doesn't contain it
            if (r.end - r.start <= s.end - s.start) return; // not bigger
            if (b.* == null or r.end - r.start < b.*.?.end - b.*.?.start) b.* = r;
        }
    }.f;

    // The word around the cursor.
    var ws = sel.start;
    while (ws > 0 and text.isWordChar(bytes[ws - 1])) ws -= 1;
    var we = sel.end;
    while (we < bytes.len and text.isWordChar(bytes[we])) we += 1;
    if (onlyWordChars(bytes[sel.start..sel.end])) consider(&best, .{ .start = ws, .end = we }, sel);

    // The line, without its indentation and trailing blanks.
    if (std.mem.indexOfScalar(u8, bytes[sel.start..sel.end], '\n') == null) {
        const ls = if (std.mem.lastIndexOfScalar(u8, bytes[0..sel.start], '\n')) |i| i + 1 else 0;
        const le = std.mem.indexOfScalarPos(u8, bytes, sel.end, '\n') orelse bytes.len;
        consider(&best, trim(bytes, .{ .start = ls, .end = le }), sel);
    }

    // Strings and bracket pairs: inside (trimmed, then as is), then outside.
    var pairs = try findPairs(gpa, bytes);
    defer pairs.deinit(gpa);
    for (pairs.items) |p| {
        const inner: Range = .{ .start = p.open + 1, .end = p.close };
        consider(&best, trim(bytes, inner), sel);
        consider(&best, inner, sel);
        consider(&best, .{ .start = p.open, .end = p.close + 1 }, sel);
    }

    consider(&best, .{ .start = 0, .end = bytes.len }, sel);
    return best;
}

const Pair = struct { open: usize, close: usize };

/// Every matched bracket pair and string literal, in no particular order.
fn findPairs(gpa: std.mem.Allocator, bytes: []const u8) !std.ArrayList(Pair) {
    var pairs: std.ArrayList(Pair) = .empty;
    errdefer pairs.deinit(gpa);
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);

    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        switch (c) {
            '(', '[', '{' => try stack.append(gpa, i),
            ')', ']', '}' => {
                // Pop to the matching opener; a stray closer is ignored.
                var j = stack.items.len;
                while (j > 0) : (j -= 1) {
                    if (bytes[stack.items[j - 1]] == opener(c)) break;
                }
                if (j > 0) {
                    try pairs.append(gpa, .{ .open = stack.items[j - 1], .close = i });
                    stack.shrinkRetainingCapacity(j - 1);
                }
            },
            '"', '\'', '`' => {
                // An apostrophe inside a word ("don't") isn't a quote.
                if (c == '\'' and i > 0 and text.isWordChar(bytes[i - 1])) continue;
                if (stringEnd(bytes, i)) |end| {
                    try pairs.append(gpa, .{ .open = i, .close = end });
                    i = end;
                }
            },
            '/' => if (i + 1 < bytes.len and bytes[i + 1] == '/') {
                i = std.mem.indexOfScalarPos(u8, bytes, i, '\n') orelse bytes.len;
            } else if (i + 1 < bytes.len and bytes[i + 1] == '*') {
                i = if (std.mem.indexOfPos(u8, bytes, i + 2, "*/")) |e| e + 1 else bytes.len;
            },
            else => {},
        }
    }
    return pairs;
}

/// Where the string starting with the quote at `start` ends. Only backticks
/// span lines; an unclosed quote isn't a string.
fn stringEnd(bytes: []const u8, start: usize) ?usize {
    const q = bytes[start];
    var i = start + 1;
    while (i < bytes.len) : (i += 1) {
        switch (bytes[i]) {
            '\\' => i += 1,
            '\n' => if (q != '`') return null,
            else => if (bytes[i] == q) return i,
        }
    }
    return null;
}

fn opener(closer: u8) u8 {
    return switch (closer) {
        ')' => '(',
        ']' => '[',
        else => '{',
    };
}

fn trim(bytes: []const u8, r: Range) Range {
    var s = r.start;
    var e = r.end;
    while (s < e and std.ascii.isWhitespace(bytes[s])) s += 1;
    while (e > s and std.ascii.isWhitespace(bytes[e - 1])) e -= 1;
    return .{ .start = s, .end = e };
}

fn onlyWordChars(s: []const u8) bool {
    for (s) |c| {
        if (!text.isWordChar(c)) return false;
    }
    return true;
}

test {
    _ = @import("../tests/scope_test.zig");
}
