//! Tests for protocol.zig.
const std = @import("std");
const protocol = @import("../protocol.zig");

const testing = std.testing;

test "messages are cut out of what arrives in pieces" {
    const gpa = testing.allocator;
    var f: protocol.Framer = .{};
    defer f.deinit(gpa);
    const one = try protocol.frame(gpa, "{\"a\":1}");
    defer gpa.free(one);
    try f.push(gpa, one[0..10]);
    try testing.expect(try f.next(gpa) == null);
    try f.push(gpa, one[10..]);
    try f.push(gpa, "Content-Type: x\r\ncontent-length: 2\r\n\r\n{}");
    const a = (try f.next(gpa)).?;
    defer gpa.free(a);
    try testing.expectEqualStrings("{\"a\":1}", a);
    const b = (try f.next(gpa)).?;
    defer gpa.free(b);
    try testing.expectEqualStrings("{}", b);
    try testing.expect(try f.next(gpa) == null);
}

test "positions count UTF-16 units" {
    const text = "ab\nπ😀x\n";
    // "x" is after π (1 unit) and 😀 (2 units).
    const x = std.mem.indexOfScalar(u8, text, 'x').?;
    const p = protocol.toPosition(text, x);
    try testing.expectEqual(protocol.Position{ .line = 1, .character = 3 }, p);
    try testing.expectEqual(x, protocol.toOffset(text, p));
    // Past the end of a line: its end.
    try testing.expectEqual(@as(usize, 2), protocol.toOffset(text, .{ .line = 0, .character = 99 }));
    try testing.expectEqual(text.len, protocol.toOffset(text, .{ .line = 9, .character = 0 }));
    var lines = try protocol.Lines.init(testing.allocator, text);
    defer lines.deinit(testing.allocator);
    try testing.expectEqual(x, lines.offset(p));
}

test "paths and URIs" {
    const gpa = testing.allocator;
    const uri = try protocol.uriFromPath(gpa, "/home/me/my file#1.zig");
    defer gpa.free(uri);
    try testing.expectEqualStrings("file:///home/me/my%20file%231.zig", uri);
    const back = (try protocol.pathFromUri(gpa, uri)).?;
    defer gpa.free(back);
    try testing.expectEqualStrings("/home/me/my file#1.zig", back);
    const win = (try protocol.pathFromUri(gpa, "file:///C%3A/x/y.ts")).?;
    defer gpa.free(win);
    try testing.expectEqualStrings("C:/x/y.ts", win);
    try testing.expect(try protocol.pathFromUri(gpa, "untitled:1") == null);
}
