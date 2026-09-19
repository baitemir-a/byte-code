//! Tests for Screen.zig.
const std = @import("std");
const Screen = @import("../Screen.zig");

const testing = std.testing;

fn rowText(s: *const Screen, y: usize) ![]u8 {
    return s.text(testing.allocator, .{ .x = 0, .y = s.lineCount() - s.rows + y }, .{ .x = s.cols, .y = s.lineCount() - s.rows + y });
}

fn expectRow(s: *const Screen, y: usize, expected: []const u8) !void {
    const t = try rowText(s, y);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings(expected, t);
}

test "text, wrapping, scrollback" {
    var s = try Screen.init(testing.allocator, 5, 2);
    defer s.deinit();
    try s.feed("hi\r\nthere!"); // "there" fills the row; "!" wraps
    try expectRow(&s, 0, "there");
    try expectRow(&s, 1, "!");
    try testing.expectEqual(@as(usize, 1), s.history.items.len); // "hi"

    try s.feed("\r\nбыстр");
    try expectRow(&s, 0, "!");
    try expectRow(&s, 1, "быстр");
    try s.feed("о"); // wraps: scrolls again
    try expectRow(&s, 0, "быстр");
    try expectRow(&s, 1, "о");
    try testing.expectEqual(@as(usize, 3), s.history.items.len);
}

test "cursor movement, erase, colors" {
    var s = try Screen.init(testing.allocator, 10, 3);
    defer s.deinit();
    try s.feed("abcdef\x1b[2;3Hxy\x1b[1;4H\x1b[K\x1b[31;1mR\x1b[0m");
    try expectRow(&s, 0, "abcR");
    try expectRow(&s, 1, "  xy");
    const r = s.grid[0][3];
    try testing.expectEqual(Screen.Color{ .palette = 1 }, r.fg);
    try testing.expect(r.attrs.bold);
    try testing.expectEqual(Screen.Color.default, s.pen.fg);

    try s.feed("\x1b[38;5;208mA\x1b[48;2;1;2;3mB");
    try testing.expectEqual(Screen.Color{ .palette = 208 }, s.grid[0][4].fg);
    try testing.expectEqual(Screen.Color{ .rgb = .{ 1, 2, 3 } }, s.grid[0][5].bg);

    try s.feed("\x1b[2J");
    try expectRow(&s, 0, "");
}

test "alternate screen keeps the main one" {
    var s = try Screen.init(testing.allocator, 10, 2);
    defer s.deinit();
    try s.feed("$ vim");
    try s.feed("\x1b[?1049h\x1b[Hfull screen");
    try expectRow(&s, 0, "full scree");
    try s.feed("\x1b[?1049l");
    try expectRow(&s, 0, "$ vim");
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
}

test "scroll region, insert and delete lines" {
    var s = try Screen.init(testing.allocator, 4, 4);
    defer s.deinit();
    try s.feed("1\r\n2\r\n3\r\n4");
    try s.feed("\x1b[2;3r\x1b[2;1H\x1b[M"); // delete line 2 inside rows 2-3
    try expectRow(&s, 0, "1");
    try expectRow(&s, 1, "3");
    try expectRow(&s, 2, "");
    try expectRow(&s, 3, "4");
    try s.feed("\x1b[L"); // insert a line at row 2
    try expectRow(&s, 1, "");
    try expectRow(&s, 2, "3");
}

test "queries get answers" {
    var s = try Screen.init(testing.allocator, 10, 5);
    defer s.deinit();
    try s.feed("\x1b[3;4H\x1b[6n\x1b[c");
    try testing.expectEqualStrings("\x1b[3;4R\x1b[?1;2c", s.responses.items);
}

test "sequences split across reads, resize" {
    var s = try Screen.init(testing.allocator, 10, 3);
    defer s.deinit();
    try s.feed("\x1b[3");
    try s.feed("1mX\xd0");
    try s.feed("\xb6\x1b]0;my title\x07");
    try expectRow(&s, 0, "Xж");
    try testing.expectEqual(Screen.Color{ .palette = 1 }, s.grid[0][0].fg);
    try testing.expectEqualStrings("my title", s.title.items);

    try s.feed("\r\nline2\r\nline3");
    try s.resize(4, 2); // the first line goes to the scrollback
    try expectRow(&s, 0, "line");
    try expectRow(&s, 1, "line");
    try testing.expectEqual(@as(usize, 1), s.history.items.len);
}
