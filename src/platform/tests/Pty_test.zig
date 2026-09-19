//! Tests for Pty.zig.
const std = @import("std");
const Pty = @import("../Pty.zig");

test "runs a shell and talks to it" {
    if (!Pty.supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var pty = try Pty.spawn(gpa, "/bin/sh", "/", 80, 24);
    defer pty.deinit();
    pty.writeAll("echo \"pty:$((6*7)):$(stty size)\"\nexit\n");

    // Collect output until the shell exits (or ~5 s pass).
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var buf: [4096]u8 = undefined;
    var waited: usize = 0;
    while (!pty.exited and waited < 500) {
        const n = pty.read(&buf);
        if (n > 0) try out.appendSlice(gpa, buf[0..n]) else {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            waited += 1;
        }
    }
    // The computed answer proves the shell ran; "24 80" that the size stuck.
    errdefer std.debug.print("pty output ({d} bytes, exited={}): {f}\n", .{ out.items.len, pty.exited, std.zig.fmtString(out.items) });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "pty:42:24 80") != null);
    try std.testing.expect(pty.exited);
}
