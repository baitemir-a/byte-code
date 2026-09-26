//! Tests for fold.zig, and for how the buffer keeps its folds.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const Highlighter = @import("../../syntax/Highlighter.zig");
const fold = @import("../lib/fold.zig");
const wrap = @import("../lib/wrap.zig");

const testing = std.testing;

fn loaded(s: []const u8, language: Highlighter.Language) !struct { Buffer, Highlighter } {
    var b = Buffer.init(testing.allocator);
    try b.load(s);
    var hl: Highlighter = .init(language);
    try hl.update(testing.allocator, &b);
    return .{ b, hl };
}

/// The hidden text of a region.
fn hiddenText(b: *const Buffer, r: Buffer.Range) []const u8 {
    return b.items()[r.start..r.end];
}

test "a bracket block hides the lines up to its closer" {
    const src = "fn f() {\n    a();\n    b();\n}\nx";
    var b, var hl = try loaded(src, .zig);
    defer b.deinit();
    defer hl.deinit(testing.allocator);
    const r = fold.region(&b, &hl, 0, 0).?;
    try testing.expectEqualStrings("    a();\n    b();", hiddenText(&b, r));
    try testing.expect(fold.foldable(&b, &hl, 0, 0));
    // "    a();" opens nothing and nothing under it is indented further.
    try testing.expect(!fold.foldable(&b, &hl, 9, 1));
    // A block that closes on the next line hides nothing.
    var c, var hl2 = try loaded("f {\n}", .zig);
    defer c.deinit();
    defer hl2.deinit(testing.allocator);
    try testing.expect(fold.region(&c, &hl2, 0, 0) == null);
}

test "indentation blocks, as in Python" {
    const src = "def f():\n    a\n\n    b\n\nc";
    var b, var hl = try loaded(src, .python);
    defer b.deinit();
    defer hl.deinit(testing.allocator);
    const r = fold.region(&b, &hl, 0, 0).?;
    try testing.expectEqualStrings("    a\n\n    b", hiddenText(&b, r));
}

test "folded lines get no rows, and folds follow edits" {
    const src = "a {\n  b\n  c\n}\nd";
    var b, var hl = try loaded(src, .typescript);
    defer b.deinit();
    defer hl.deinit(testing.allocator);
    try b.fold(0);
    var hidden: std.ArrayList(Buffer.Range) = .empty;
    defer hidden.deinit(testing.allocator);
    try fold.hiddenRanges(&b, &hl, &hidden);
    try testing.expectEqual(@as(usize, 1), hidden.items.len);
    try testing.expect(fold.isHidden(hidden.items, 5));
    try testing.expect(!fold.isHidden(hidden.items, 3));

    var rows: std.ArrayList(wrap.Row) = .empty;
    defer rows.deinit(testing.allocator);
    try wrap.buildRows(testing.allocator, &rows, b.items(), 0, hidden.items);
    try testing.expectEqual(@as(usize, 3), rows.items.len);
    try testing.expectEqual(@as(u32, 3), rows.items[1].line);

    // Typing a line above moves the fold along.
    b.moveTo(0, false);
    try b.insert("z\n");
    try testing.expectEqual(@as(usize, 2), b.folds.items[0]);
    try b.undo();
    try testing.expectEqual(@as(usize, 0), b.folds.items[0]);

    // A fold whose block was deleted goes away.
    b.selectAll();
    try b.insert("plain");
    try hl.update(testing.allocator, &b);
    try fold.hiddenRanges(&b, &hl, &hidden);
    try testing.expectEqual(@as(usize, 0), b.folds.items.len);
}
