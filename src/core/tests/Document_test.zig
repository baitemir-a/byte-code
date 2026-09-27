//! Tests for Document.zig.
const std = @import("std");
const Buffer = @import("../buffer/Buffer.zig");
const Document = @import("../Document.zig");

const testing = std.testing;

test "open, edit, save round trip keeps CRLF" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "one\r\ntwo\r\n" });

    var buf = Buffer.init(gpa);
    defer buf.deinit();
    var doc: Document = .{};
    defer doc.deinit(gpa);

    try doc.open(gpa, testing.io, tmp.dir, "a.ts", &buf);
    try testing.expectEqualStrings("one\ntwo\n", buf.items());
    try testing.expect(!doc.isDirty(&buf));
    try testing.expectEqualStrings("a.ts", doc.name());

    buf.moveTo(buf.items().len, false);
    try buf.insert("three\n");
    try testing.expect(doc.isDirty(&buf));

    try doc.save(gpa, testing.io, tmp.dir, &buf);
    try testing.expect(!doc.isDirty(&buf));
    const saved = try tmp.dir.readFileAlloc(testing.io, "a.ts", gpa, .unlimited);
    defer gpa.free(saved);
    try testing.expectEqualStrings("one\r\ntwo\r\nthree\r\n", saved);
}

test "missing file opens empty, invalid UTF-8 is refused" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bin", .data = "\xff\xfe" });

    var buf = Buffer.init(gpa);
    defer buf.deinit();
    var doc: Document = .{};
    defer doc.deinit(gpa);

    try doc.open(gpa, testing.io, tmp.dir, "new.js", &buf);
    try testing.expectEqualStrings("", buf.items());
    try testing.expectError(error.NotUtf8, doc.open(gpa, testing.io, tmp.dir, "bin", &buf));
    try testing.expectEqualStrings("new.js", doc.name()); // unchanged by the failed open
}

test "a file changed by something else is noticed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\n" });
    var buf = Buffer.init(gpa);
    defer buf.deinit();
    var doc: Document = .{};
    defer doc.deinit(gpa);
    try doc.open(gpa, io, tmp.dir, "a.txt", &buf);
    try std.testing.expectEqual(Document.DiskState.same, doc.onDisk(io, tmp.dir));

    // Another size is enough, whatever the clock says.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one two\n" });
    try std.testing.expectEqual(Document.DiskState.changed, doc.onDisk(io, tmp.dir));

    // Saving makes the file ours again.
    try doc.save(gpa, io, tmp.dir, &buf);
    try std.testing.expectEqual(Document.DiskState.same, doc.onDisk(io, tmp.dir));

    try tmp.dir.deleteFile(io, "a.txt");
    try std.testing.expectEqual(Document.DiskState.gone, doc.onDisk(io, tmp.dir));
}
