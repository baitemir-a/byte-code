//! Tests for Terminal.zig.
const std = @import("std");
const Pty = @import("../../platform/Pty.zig");
const Terminal = @import("../Terminal.zig");

test "a real shell's output lands on the screen" {
    if (!Pty.supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var term = try Terminal.init(gpa, "/", 60, 12);
    defer term.deinit();
    term.send("printf 'mark:%s\\n' $((7*6))\r");

    var found = false;
    var tries: usize = 0;
    while (!found and tries < 500) : (tries += 1) {
        if (!try term.pump()) {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            continue;
        }
        const all = try term.screen.text(gpa, .{ .x = 0, .y = 0 }, .{ .x = term.screen.cols, .y = term.screen.lineCount() - 1 });
        defer gpa.free(all);
        found = std.mem.indexOf(u8, all, "mark:42") != null;
    }
    try std.testing.expect(found);
    // Resizing reaches the shell without trouble.
    try term.resize(40, 8);
    try std.testing.expectEqual(@as(usize, 40), term.screen.cols);
}
