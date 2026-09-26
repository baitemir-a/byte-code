//! Tests for Buffer.zig.
const std = @import("std");
const Buffer = @import("../Buffer.zig");

const testing = std.testing;

test "positions and lines" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("hello\nwörld");
    try testing.expectEqual(@as(usize, 2), b.lineCount());
    try testing.expectEqual(@as(usize, 1), b.lineIndex(b.cursor));
    try testing.expectEqual(@as(usize, 5), b.column(b.cursor));
    try testing.expectEqual(@as(usize, 9), b.posAt(1, 2)); // after 'ö'
    try testing.expectEqual(@as(usize, 5), b.posAt(0, 99));
}

test "columns count tabs to the next tab stop" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("\tx\nabcdefgh");
    try testing.expectEqual(@as(usize, 5), b.column(2)); // after "\tx"
    try testing.expectEqual(@as(usize, 1), b.posAt(0, 4)); // right after the tab
    try testing.expectEqual(@as(usize, 0), b.posAt(0, 2)); // mid-tab snaps to its start
}

test "selection" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("hello world");
    b.moveTo(6, false);
    b.moveTo(11, true);
    try testing.expectEqualStrings("world", b.selectedText().?);
    try b.insert("there");
    try testing.expectEqualStrings("hello there", b.items());
    try testing.expectEqual(@as(?Buffer.Range, null), b.selection());
}

test "several cursors edit together and undo as one step" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("a\nb\nc");
    b.moveTo(1, false);
    try b.toggleCursor(3);
    try b.toggleCursor(5);
    const Type = struct {
        s: []const u8,
        pub fn apply(op: @This(), buf: *Buffer) !void {
            try buf.insert(op.s);
        }
    };
    try b.eachCursor(Type{ .s = "!!" }, false);
    try testing.expectEqualStrings("a!!\nb!!\nc!!", b.items());
    try testing.expectEqual(@as(usize, 2), b.extra.items.len);
    try testing.expectEqual(@as(usize, 11), b.cursor); // the last one added is the main cursor
    try b.undo();
    try testing.expectEqualStrings("a\nb\nc", b.items());
    try testing.expect(!b.hasExtraCursors());
    try b.redo();
    try testing.expectEqualStrings("a!!\nb!!\nc!!", b.items());
}

test "column selection" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("abcdef\nab\n\nabcdef");
    try b.selectColumns(0, 2, 3, 2); // a cursor at column 2 on each line
    const cs = try b.allCursors(testing.allocator);
    defer testing.allocator.free(cs);
    // The empty line is skipped; "ab" gets its cursor at its end.
    try testing.expectEqual(@as(usize, 3), cs.len);
    try testing.expectEqual(@as(usize, 2), cs[0].cursor);
    try testing.expectEqual(@as(usize, 9), cs[1].cursor);
    try testing.expectEqual(@as(usize, 13), b.cursor); // main: the clicked line

    try b.selectColumns(0, 1, 3, 3); // a box: columns 1..3
    try testing.expectEqualStrings("bc", b.selectedText().?);
    try testing.expectEqual(@as(usize, 2), b.extra.items.len);
}

test "cursors that meet merge" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("abc");
    b.moveTo(1, false);
    try b.toggleCursor(2);
    const Back = struct {
        pub fn apply(_: @This(), buf: *Buffer) !void {
            try buf.deleteRange(.{ .start = buf.prevPos(buf.cursor), .end = buf.cursor });
        }
    };
    try b.eachCursor(Back{}, false);
    try testing.expectEqualStrings("c", b.items());
    try testing.expect(!b.hasExtraCursors());
    try testing.expectEqual(@as(usize, 0), b.cursor);
}

test "undo and redo" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("hello world");
    b.selectAll();
    try b.insert("x");
    try b.undo();
    try testing.expectEqualStrings("hello world", b.items());
    try testing.expectEqualStrings("hello world", b.selectedText().?);
    try b.redo();
    try testing.expectEqualStrings("x", b.items());
}

test "select next occurrence" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.load("foo bar foo foobar foo");
    b.moveTo(1, false);
    try std.testing.expectEqual(Buffer.Occurrence.word, try b.selectNextOccurrence(true));
    try std.testing.expectEqualStrings("foo", b.selectedText().?);
    // Whole words only: "foobar" is skipped.
    try std.testing.expectEqual(Buffer.Occurrence.added, try b.selectNextOccurrence(true));
    try std.testing.expectEqual(@as(usize, 8), b.anchor.?);
    try std.testing.expectEqual(Buffer.Occurrence.added, try b.selectNextOccurrence(true));
    try std.testing.expectEqual(@as(usize, 19), b.anchor.?);
    // Round to the top: the first one is taken already.
    try std.testing.expectEqual(Buffer.Occurrence.none, try b.selectNextOccurrence(true));
    try std.testing.expectEqual(@as(usize, 2), b.extra.items.len);
    // Typing replaces all three.
    try @import("../../editing/lib/command.zig").runAtCursors(&b, .{ .type_char = 'x' }, 10);
    try std.testing.expectEqualStrings("x bar x foobar x", b.items());
}
