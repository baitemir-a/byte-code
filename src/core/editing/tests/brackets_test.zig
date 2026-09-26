//! Tests for brackets.zig.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const Highlighter = @import("../../syntax/Highlighter.zig");
const brackets = @import("../lib/brackets.zig");

const testing = std.testing;

const Fixture = struct {
    buf: Buffer,
    hl: Highlighter,

    fn init(s: []const u8) !Fixture {
        var f: Fixture = .{ .buf = Buffer.init(testing.allocator), .hl = .init(.typescript) };
        try f.buf.load(s);
        try f.hl.update(testing.allocator, &f.buf);
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.hl.deinit(testing.allocator);
        f.buf.deinit();
    }
};

test "the partner of the bracket at or before the cursor" {
    var f = try Fixture.init("f(a[1], {\n  b: \")\" // )\n})");
    defer f.deinit();
    const src = f.buf.items();
    const open_paren: usize = 1;
    const close_paren = src.len - 1;
    // Before the "(", and right after it.
    try testing.expectEqual(brackets.Pair{ .open = open_paren, .close = close_paren }, brackets.matchAt(&f.buf, &f.hl, open_paren).?);
    try testing.expectEqual(close_paren, brackets.matchAt(&f.buf, &f.hl, open_paren + 1).?.close);
    // From the ")" back, skipping the ones in the string and the comment.
    try testing.expectEqual(open_paren, brackets.matchAt(&f.buf, &f.hl, close_paren).?.open);
    // "[" and "]".
    const sq = std.mem.indexOfScalar(u8, src, '[').?;
    try testing.expectEqual(sq + 2, brackets.matchAt(&f.buf, &f.hl, sq).?.close);
    // Not at a bracket.
    try testing.expect(brackets.matchAt(&f.buf, &f.hl, 7) == null);
}

test "a line's unclosed opener" {
    var f = try Fixture.init("x");
    defer f.deinit();
    try testing.expectEqual(@as(?usize, 10), brackets.unclosedOpener(&f.hl, 0, "if (a(b)) {"));
    try testing.expect(brackets.unclosedOpener(&f.hl, 0, "f(a) {}") == null);
}
