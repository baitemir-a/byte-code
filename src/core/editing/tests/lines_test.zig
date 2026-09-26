//! Tests for lines.zig.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const lines = @import("../lib/lines.zig");
const command = @import("../lib/command.zig");

const testing = std.testing;

fn bufferWith(s: []const u8) !Buffer {
    var b = Buffer.init(testing.allocator);
    try b.load(s);
    return b;
}

test "indent and outdent the selected lines" {
    var b = try bufferWith("a\n\nb\nc");
    defer b.deinit();
    b.moveTo(0, false);
    b.moveTo(4, true); // into "b"
    _ = try lines.indentLines(&b, null);
    try testing.expectEqualStrings("    a\n\n    b\nc", b.items());
    try testing.expectEqualStrings("a\n\n    b", b.selectedText().?);

    _ = try lines.outdentLines(&b, null);
    try testing.expectEqualStrings("a\n\nb\nc", b.items());
    try b.undo();
    try testing.expectEqualStrings("    a\n\n    b\nc", b.items());
    try b.undo();
    try testing.expectEqualStrings("a\n\nb\nc", b.items());
}

test "outdent takes off at most one level" {
    var b = try bufferWith("      x\n\ty\n  z");
    defer b.deinit();
    b.selectAll();
    _ = try lines.outdentLines(&b, null);
    try testing.expectEqualStrings("  x\ny\nz", b.items());
}

test "a selection ending at a line start leaves that line alone" {
    var b = try bufferWith("a\nb\n");
    defer b.deinit();
    b.moveTo(0, false);
    b.moveTo(2, true);
    _ = try lines.indentLines(&b, null);
    try testing.expectEqualStrings("    a\nb\n", b.items());
}

test "tab on a selection of several lines indents them" {
    var b = try bufferWith("a\nb");
    defer b.deinit();
    b.selectAll();
    try command.runAtCursors(&b, .indent, 10);
    try testing.expectEqualStrings("    a\n    b", b.items());
}

test "duplicate lines puts the cursor on the copy" {
    var b = try bufferWith("one\ntwo");
    defer b.deinit();
    b.moveTo(1, false);
    _ = try lines.duplicateLines(&b, null);
    try testing.expectEqualStrings("one\none\ntwo", b.items());
    try testing.expectEqual(@as(usize, 5), b.cursor);
    try b.undo();
    try testing.expectEqualStrings("one\ntwo", b.items());
}

test "delete lines keeps the column" {
    var b = try bufferWith("abc\ndef\nghi");
    defer b.deinit();
    b.moveTo(6, false); // "de|f"
    _ = try lines.deleteLines(&b, null);
    try testing.expectEqualStrings("abc\nghi", b.items());
    try testing.expectEqual(@as(usize, 6), b.cursor);

    // The last line takes the newline before it.
    _ = try lines.deleteLines(&b, null);
    try testing.expectEqualStrings("abc", b.items());
    try testing.expectEqual(@as(usize, 2), b.cursor);
}

test "two cursors on one line delete it once" {
    var b = try bufferWith("a1 a2\nb\nc");
    defer b.deinit();
    b.moveTo(0, false);
    try b.toggleCursor(3);
    try b.toggleCursor(9); // on "c"
    try command.runAtCursors(&b, .delete_lines, 10);
    try testing.expectEqualStrings("b", b.items());
    try b.undo();
    try testing.expectEqualStrings("a1 a2\nb\nc", b.items());
}

test "two cursors on one line duplicate it once" {
    var b = try bufferWith("ab\nc");
    defer b.deinit();
    b.moveTo(0, false);
    try b.toggleCursor(1);
    try command.runAtCursors(&b, .duplicate_lines, 10);
    try testing.expectEqualStrings("ab\nab\nc", b.items());
}
