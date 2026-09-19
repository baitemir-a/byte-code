//! Text matching shared by Find (in a file) and project search: the
//! "match case" and "whole word" options.
const std = @import("std");
const text = @import("../../editing/lib/text.zig");

pub const Options = struct {
    /// Off: "user" also finds "User" and "USER" (ASCII letters).
    match_case: bool = false,
    /// On: only matches not inside a longer word ("user" but not "username").
    whole_word: bool = false,
};

/// First match of `query` in `haystack` at or after `pos`.
pub fn next(haystack: []const u8, pos: usize, query: []const u8, opts: Options) ?usize {
    if (query.len == 0) return null;
    var i = pos;
    while (i + query.len <= haystack.len) {
        const at = (if (opts.match_case)
            std.mem.indexOfPos(u8, haystack, i, query)
        else
            indexOfIgnoreCasePos(haystack, i, query)) orelse return null;
        if (!opts.whole_word or isWholeWord(haystack, at, query.len)) return at;
        i = at + 1;
    }
    return null;
}

/// Whether `query` matches right at `at` (to check a remembered match is
/// still there before replacing it).
pub fn matchesAt(haystack: []const u8, at: usize, query: []const u8, opts: Options) bool {
    if (at + query.len > haystack.len or query.len == 0) return false;
    const s = haystack[at..][0..query.len];
    const same = if (opts.match_case) std.mem.eql(u8, s, query) else std.ascii.eqlIgnoreCase(s, query);
    return same and (!opts.whole_word or isWholeWord(haystack, at, query.len));
}

fn isWholeWord(haystack: []const u8, at: usize, len: usize) bool {
    const before_ok = at == 0 or !text.isWordChar(haystack[at - 1]);
    const after_ok = at + len >= haystack.len or !text.isWordChar(haystack[at + len]);
    return before_ok and after_ok;
}

fn indexOfIgnoreCasePos(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

test {
    _ = @import("../tests/find_test.zig");
}
