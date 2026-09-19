//! Tests for Index.zig.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const Highlighter = @import("../../syntax/Highlighter.zig");
const Index = @import("../Index.zig");

test "collects identifiers outside strings and comments" {
    const gpa = std.testing.allocator;
    var buf = Buffer.init(gpa);
    defer buf.deinit();
    var hl = Highlighter.init(.typescript);
    defer hl.deinit(gpa);
    var idx = Index.init(gpa);
    defer idx.deinit();

    try buf.insert("const userName = getUser(); // ignored\nuserName.first = \"not me\"");
    try idx.update(gpa, &buf, &hl);

    try std.testing.expectEqual(@as(u32, 2), idx.words.get("userName").?.count);
    try std.testing.expect(idx.words.get("getUser").?.called);
    try std.testing.expect(idx.words.get("first").?.as_member);
    try std.testing.expect(idx.words.get("ignored") == null);
    try std.testing.expect(idx.words.get("me") == null);
}
