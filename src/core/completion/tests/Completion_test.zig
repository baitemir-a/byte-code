//! Tests for Completion.zig.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const Highlighter = @import("../../syntax/Highlighter.zig");
const Completion = @import("../Completion.zig");

const testing = std.testing;

const Fixture = struct {
    buf: Buffer,
    hl: Highlighter,
    c: Completion,

    fn init(content: []const u8) !*Fixture {
        const f = try testing.allocator.create(Fixture);
        f.* = .{ .buf = .init(testing.allocator), .hl = .init(.typescript), .c = .init(testing.allocator) };
        try f.buf.insert(content);
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.c.deinit();
        f.hl.deinit(testing.allocator);
        f.buf.deinit();
        testing.allocator.destroy(f);
    }

    fn has(f: *Fixture, label: []const u8) bool {
        for (f.c.items.items) |it| if (std.mem.eql(u8, it.label, label)) return true;
        return false;
    }
};

test "suggests document words first, then keywords" {
    const f = try Fixture.init("let counter = 1;\nco");
    defer f.deinit();
    try f.c.refresh(&f.buf, &f.hl, false);
    try testing.expect(f.c.is_open);
    try testing.expectEqualStrings("counter", f.c.items.items[0].label);
    try testing.expect(f.has("const"));
    try testing.expect(!f.has("co")); // the word being typed
}

test "members after a dot" {
    const f = try Fixture.init("console.");
    defer f.deinit();
    try f.c.refresh(&f.buf, &f.hl, false);
    try testing.expect(f.c.is_open);
    try testing.expectEqualStrings("log", f.c.items.items[0].label);
    try testing.expect(!f.has("const"));
}

test "accept replaces the word" {
    const f = try Fixture.init("const value = 1;\nva");
    defer f.deinit();
    try f.c.refresh(&f.buf, &f.hl, false);
    try testing.expectEqualStrings("value", f.c.selectedItem().?.label);
    try f.c.accept(&f.buf);
    try testing.expectEqualStrings("const value = 1;\nvalue", f.buf.items());
    try testing.expect(!f.c.is_open);
}

test "stays closed in strings, comments and numbers" {
    inline for (.{ "const s = \"co", "// co", "x = 12" }) |src| {
        const f = try Fixture.init(src);
        defer f.deinit();
        try f.c.refresh(&f.buf, &f.hl, false);
        try testing.expect(!f.c.is_open);
    }
}

test "opens after a closed string" {
    const f = try Fixture.init("let counter = \"a\" + co");
    defer f.deinit();
    try f.c.refresh(&f.buf, &f.hl, false);
    try testing.expect(f.c.is_open);
}
