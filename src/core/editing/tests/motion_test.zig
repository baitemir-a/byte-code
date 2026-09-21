//! Tests for motion.zig.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const motion = @import("../lib/motion.zig");

const testing = std.testing;

test "goal column survives short lines" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("abcdef\nab\nabcdef");
    motion.apply(&b, .line_up, false, 1);
    try testing.expectEqual(@as(usize, 2), b.column(b.cursor));
    motion.apply(&b, .line_up, false, 1);
    try testing.expectEqual(@as(usize, 6), b.column(b.cursor));
}

test "vertical movement keeps the on-screen column across tabs" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("\tfoo\nabcdefgh");
    b.moveTo(b.posAt(1, 5), false); // after "abcde"
    motion.apply(&b, .line_up, false, 1);
    try testing.expectEqual(@as(usize, 2), b.cursor); // after "\tf", also column 5
}

test "words and smart home" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("    foo.bar baz");
    try testing.expectEqual(@as(usize, 12), motion.wordLeft(b.items(), b.cursor));
    try testing.expectEqual(@as(usize, 8), motion.wordLeft(b.items(), 11));
    motion.apply(&b, .line_start, false, 1);
    try testing.expectEqual(@as(usize, 4), b.cursor);
    motion.apply(&b, .line_start, false, 1);
    try testing.expectEqual(@as(usize, 0), b.cursor);
}

test "left collapses selection" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("hello");
    motion.apply(&b, .word_left, true, 1);
    motion.apply(&b, .char_left, false, 1);
    try testing.expectEqual(@as(usize, 0), b.cursor);
    try testing.expectEqual(@as(?Buffer.Range, null), b.selection());
}

test "double-click word range" {
    const b = "    foo.bar_1 baz";
    // Inside a word, and just past its last character.
    try testing.expectEqual(Buffer.Range{ .start = 4, .end = 7 }, motion.wordRange(b, 5));
    try testing.expectEqual(Buffer.Range{ .start = 4, .end = 7 }, motion.wordRange(b, 7));
    // "bar_1" is one word; a punctuation mark on its own is one character.
    try testing.expectEqual(Buffer.Range{ .start = 8, .end = 13 }, motion.wordRange(b, 10));
    try testing.expectEqual(Buffer.Range{ .start = 2, .end = 3 }, motion.wordRange("a + b", 2));
    // The run of blanks, and the end of the text.
    try testing.expectEqual(Buffer.Range{ .start = 0, .end = 4 }, motion.wordRange(b, 2));
    try testing.expectEqual(Buffer.Range{ .start = 14, .end = 17 }, motion.wordRange(b, b.len));
}

test "double-click stays inside the line" {
    const b = "foo\n  bar";
    try testing.expectEqual(Buffer.Range{ .start = 0, .end = 3 }, motion.wordRange(b, 3));
    try testing.expectEqual(Buffer.Range{ .start = 4, .end = 6 }, motion.wordRange(b, 4));
}

test "triple-click line range takes the newline" {
    const b = "one\ntwo\nthree";
    try testing.expectEqual(Buffer.Range{ .start = 0, .end = 4 }, motion.lineRange(b, 1));
    try testing.expectEqual(Buffer.Range{ .start = 4, .end = 8 }, motion.lineRange(b, 4));
    try testing.expectEqual(Buffer.Range{ .start = 4, .end = 8 }, motion.lineRange(b, 7));
    // The last line has no newline to take.
    try testing.expectEqual(Buffer.Range{ .start = 8, .end = 13 }, motion.lineRange(b, 13));
}
