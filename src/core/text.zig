//! Byte-level helpers: UTF-8 boundaries and character classes.
const std = @import("std");

pub fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// Number of codepoints in a UTF-8 byte slice.
pub fn codepointCount(bytes: []const u8) usize {
    var n: usize = 0;
    for (bytes) |b| {
        if (!isContinuation(b)) n += 1;
    }
    return n;
}

/// Tab stops are every `tab_width` columns.
pub const tab_width = 4;

/// Column after a character starting with byte `first` placed at `col`:
/// one column for most characters, up to the next tab stop for a tab.
pub fn advance(col: usize, first: u8) usize {
    return if (first == '\t') (col / tab_width + 1) * tab_width else col + 1;
}

/// On-screen width of `bytes` (a line prefix), with tabs expanded.
pub fn visualColumn(bytes: []const u8) usize {
    var col: usize = 0;
    for (bytes) |b| {
        if (!isContinuation(b)) col = advance(col, b);
    }
    return col;
}

/// Byte offset in `line` at on-screen column `target`. A column in the
/// middle of a tab snaps to whichever side of it is closer.
pub fn offsetAtColumn(line: []const u8, target: usize) usize {
    var col: usize = 0;
    var i: usize = 0;
    while (i < line.len and col < target) {
        const next_col = advance(col, line[i]);
        const next_i = nextBoundary(line, i);
        if (next_col > target) return if (target - col <= next_col - target) i else next_i;
        col = next_col;
        i = next_i;
    }
    return i;
}

/// Guesses a file's indentation: a tab, two spaces or four spaces.
pub fn detectIndent(bytes: []const u8) []const u8 {
    var tabs: usize = 0;
    var spaces: usize = 0;
    var two_space: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '\t') {
            tabs += 1;
            continue;
        }
        const n = std.mem.indexOfNone(u8, line, " ") orelse continue; // blank line
        // A single space is usually a " * " doc-comment continuation.
        if (n < 2) continue;
        spaces += 1;
        // Odd levels of 2-space indentation land between 4-space stops.
        if (n % 4 == 2) two_space += 1;
    }
    if (tabs > spaces) return "\t";
    if (two_space * 10 > spaces) return "  ";
    return "    ";
}

/// Start of the codepoint before `pos`.
pub fn prevBoundary(bytes: []const u8, pos: usize) usize {
    var p = pos;
    while (p > 0) {
        p -= 1;
        if (!isContinuation(bytes[p])) break;
    }
    return p;
}

/// Start of the codepoint after the one at `pos`.
pub fn nextBoundary(bytes: []const u8, pos: usize) usize {
    if (pos >= bytes.len) return bytes.len;
    var p = pos + 1;
    while (p < bytes.len and isContinuation(bytes[p])) p += 1;
    return p;
}

pub fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

pub fn isQuote(c: u8) bool {
    return c == '"' or c == '\'' or c == '`';
}

pub fn isOpenBracket(c: u8) bool {
    return c == '(' or c == '[' or c == '{';
}

/// Anything that can close a pair: brackets and quotes.
pub fn isCloser(c: u8) bool {
    return c == ')' or c == ']' or c == '}' or isQuote(c);
}

/// The auto-closing partner of an opening bracket or quote.
pub fn closerFor(c: u8) ?u8 {
    return switch (c) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '"', '\'', '`' => c,
        else => null,
    };
}

test "tab stops" {
    try std.testing.expectEqual(@as(usize, 4), visualColumn("\t"));
    try std.testing.expectEqual(@as(usize, 4), visualColumn("ab\t"));
    try std.testing.expectEqual(@as(usize, 9), visualColumn("\tab\tx"));
    try std.testing.expectEqual(@as(usize, 2), visualColumn("ö\u{e9}")); // multi-byte chars are one column

    const line = "\tx";
    try std.testing.expectEqual(@as(usize, 0), offsetAtColumn(line, 1)); // closer to the tab's start
    try std.testing.expectEqual(@as(usize, 1), offsetAtColumn(line, 3)); // closer to its end
    try std.testing.expectEqual(@as(usize, 2), offsetAtColumn(line, 5));
    try std.testing.expectEqual(@as(usize, 2), offsetAtColumn(line, 99));
}

test "indent detection" {
    try std.testing.expectEqualStrings("\t", detectIndent("a {\n\tb\n\t\tc\n}"));
    try std.testing.expectEqualStrings("  ", detectIndent("a {\n  b {\n    c\n  }\n}"));
    try std.testing.expectEqualStrings("    ", detectIndent("a {\n    b\n    /**\n     * doc\n     */\n}"));
    try std.testing.expectEqualStrings("    ", detectIndent("no indentation"));
}

test "utf-8 boundaries" {
    const s = "aöb";
    try std.testing.expectEqual(@as(usize, 3), codepointCount(s));
    try std.testing.expectEqual(@as(usize, 3), nextBoundary(s, 1));
    try std.testing.expectEqual(@as(usize, 1), prevBoundary(s, 3));
}
