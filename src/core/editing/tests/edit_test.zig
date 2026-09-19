//! Tests for edit.zig.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const edit = @import("../lib/edit.zig");

const testing = std.testing;

fn typeStr(b: *Buffer, s: []const u8) !void {
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| try edit.typeCodepoint(b, cp);
}

test "auto-close pairs" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try typeStr(&b, "f(");
    try testing.expectEqualStrings("f()", b.items());
    try testing.expectEqual(@as(usize, 2), b.cursor);

    try typeStr(&b, "\"a");
    try testing.expectEqualStrings("f(\"a\")", b.items());
    try typeStr(&b, "\")"); // steps over both closers
    try testing.expectEqualStrings("f(\"a\")", b.items());
    try testing.expectEqual(b.items().len, b.cursor);

    try typeStr(&b, " don't");
    try testing.expectEqualStrings("f(\"a\") don't", b.items());

    try typeStr(&b, " [");
    try edit.backspace(&b);
    try testing.expectEqualStrings("f(\"a\") don't ", b.items());
}

test "wrap selection" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("x = abc");
    b.moveTo(4, true);
    try typeStr(&b, "(");
    try testing.expectEqualStrings("x = (abc)", b.items());
    try testing.expectEqualStrings("abc", b.selectedText().?);
}

test "newline indents and splits brackets" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try typeStr(&b, "    if {");
    try edit.newline(&b);
    try testing.expectEqualStrings("    if {\n        \n    }", b.items());
    try testing.expectEqual(@as(usize, 8), b.column(b.cursor));
}

test "undo groups typing and deleting" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try typeStr(&b, "hello world");
    try edit.backspace(&b);
    try edit.backspace(&b);
    try testing.expectEqualStrings("hello wor", b.items());

    try b.undo(); // both backspaces
    try testing.expectEqualStrings("hello world", b.items());
    try b.undo(); // " world"
    try testing.expectEqualStrings("hello", b.items());
    try b.redo();
    try testing.expectEqualStrings("hello world", b.items());
}

test "move lines up and down" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("one\ntwo\nthree");
    b.moveTo(5, false); // "t|wo"
    _ = try edit.moveLines(&b, true, null);
    try testing.expectEqualStrings("two\none\nthree", b.items());
    try testing.expectEqual(@as(usize, 1), b.cursor);
    _ = try edit.moveLines(&b, true, null); // already first: nothing
    try testing.expectEqualStrings("two\none\nthree", b.items());

    // A selection over two lines moves both; ending at a line start
    // doesn't take that line along.
    b.moveTo(0, false);
    b.moveTo(8, true); // "two\none\n"
    _ = try edit.moveLines(&b, false, null);
    try testing.expectEqualStrings("three\ntwo\none", b.items());
    try testing.expectEqualStrings("two\none", b.selectedText().?); // no newline after it now
    _ = try edit.moveLines(&b, true, null);
    try testing.expectEqualStrings("two\none\nthree", b.items());
    try testing.expectEqualStrings("two\none", b.selectedText().?);
    try b.undo();
    try testing.expectEqualStrings("three\ntwo\none", b.items());
}

test "delete to line start" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("ab\n    cd");
    try edit.deleteMotion(&b, .line_start);
    try testing.expectEqualStrings("ab\n", b.items());
    try edit.deleteMotion(&b, .line_start);
    try testing.expectEqualStrings("ab", b.items());
}
