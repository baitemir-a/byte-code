//! Tests for Search.zig.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const Search = @import("../Search.zig");

const testing = std.testing;

test "options and navigation" {
    const gpa = testing.allocator;
    var buf = Buffer.init(gpa);
    defer buf.deinit();
    var s: Search = .{};
    defer s.deinit(gpa);

    try buf.insert("foo Foo FOO food");
    try testing.expect(try s.update(gpa, &buf, "foo", .{}));
    try testing.expectEqual(@as(usize, 4), s.matches.items.len);
    try testing.expect(try s.update(gpa, &buf, "foo", .{ .match_case = true }));
    try testing.expectEqual(@as(usize, 2), s.matches.items.len); // foo, food
    _ = try s.update(gpa, &buf, "foo", .{ .whole_word = true });
    try testing.expectEqual(@as(usize, 3), s.matches.items.len); // not food

    _ = try s.update(gpa, &buf, "foo", .{});
    try testing.expectEqual(@as(?usize, 1), s.nextFrom(1));
    try testing.expectEqual(@as(?usize, 0), s.nextFrom(13)); // wraps
    try testing.expectEqual(@as(?usize, 3), s.prevBefore(0)); // wraps
    try testing.expectEqual(@as(?usize, 1), s.indexOf(.{ .start = 4, .end = 7 }));
    try testing.expectEqual(@as(?usize, null), s.indexOf(.{ .start = 4, .end = 6 }));
}

test "tracks buffer edits" {
    const gpa = testing.allocator;
    var buf = Buffer.init(gpa);
    defer buf.deinit();
    var s: Search = .{};
    defer s.deinit(gpa);

    try buf.insert("a a");
    _ = try s.update(gpa, &buf, "a", .{});
    try buf.insert(" a");
    try testing.expect(!try s.update(gpa, &buf, "a", .{}));
    try testing.expectEqual(@as(usize, 3), s.matches.items.len);
}

test "replace all is one undo step" {
    const gpa = testing.allocator;
    var buf = Buffer.init(gpa);
    defer buf.deinit();
    var s: Search = .{};
    defer s.deinit(gpa);

    try buf.insert("let x = x + x;");
    _ = try s.update(gpa, &buf, "x", .{});
    try testing.expectEqual(@as(usize, 3), try s.replaceAll(gpa, &buf, "value"));
    try testing.expectEqualStrings("let value = value + value;", buf.items());
    try buf.undo();
    try testing.expectEqualStrings("let x = x + x;", buf.items());
}
