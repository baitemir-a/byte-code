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
