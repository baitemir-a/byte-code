//! Tests for Conflicts.zig.
const std = @import("std");
const Conflicts = @import("../Conflicts.zig");

const text =
    \\one
    \\<<<<<<< HEAD
    \\mine
    \\=======
    \\theirs
    \\more theirs
    \\>>>>>>> feature
    \\two
    \\<<<<<<< ours
    \\a
    \\||||||| base
    \\o
    \\=======
    \\b
    \\>>>>>>> theirs
    \\
;

test "finds conflicts and resolves them" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(Conflicts.Region) = .empty;
    defer list.deinit(gpa);
    try Conflicts.find(gpa, text, &list);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    const r = list.items[0];
    try std.testing.expectEqual(@as(u32, 1), r.start);
    try std.testing.expectEqual(@as(u32, 3), r.separator);
    try std.testing.expectEqual(@as(u32, 6), r.end);
    try std.testing.expectEqualStrings("<<<<<<< HEAD\nmine\n=======\ntheirs\nmore theirs\n>>>>>>> feature\n", text[r.from..r.to]);

    const both = try Conflicts.resolve(gpa, text, r, .both);
    defer gpa.free(both);
    try std.testing.expectEqualStrings("mine\ntheirs\nmore theirs\n", both);

    // diff3 style: what both started from isn't either side.
    const d = list.items[1];
    try std.testing.expectEqual(@as(u32, 10), d.base);
    const current = try Conflicts.resolve(gpa, text, d, .current);
    defer gpa.free(current);
    try std.testing.expectEqualStrings("a\n", current);
    const incoming = try Conflicts.resolve(gpa, text, d, .incoming);
    defer gpa.free(incoming);
    try std.testing.expectEqualStrings("b\n", incoming);

    // Markers without their partners, and look-alikes, aren't conflicts.
    try std.testing.expect(!try Conflicts.any(gpa, "<<<<<<< HEAD\nx\n"));
    try std.testing.expect(!try Conflicts.any(gpa, "<<<<<<<< long\n=======\n>>>>>>> x\n"));
    try std.testing.expect(try Conflicts.any(gpa, "<<<<<<< HEAD\r\nx\r\n=======\r\ny\r\n>>>>>>> t\r\n"));
}
