//! Tests for command.zig.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const command = @import("../lib/command.zig");

test "move lines with several cursors" {
    const testing = @import("std").testing;
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("a\nb\nc\nd");
    b.moveTo(2, false); // b
    try b.toggleCursor(3); // also b: the line moves once
    try b.toggleCursor(4); // c
    try command.runAtCursors(&b, .move_line_up, 10);
    try testing.expectEqualStrings("b\nc\na\nd", b.items());
    try command.runAtCursors(&b, .move_line_down, 10);
    try testing.expectEqualStrings("a\nb\nc\nd", b.items());
    try b.undo();
    try testing.expectEqualStrings("b\nc\na\nd", b.items());
}
