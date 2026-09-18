//! A shell running on a pseudo-terminal (macOS and Linux). The shell sees a
//! real terminal; we read what it prints and write what the user types.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

const Pty = @This();

pub const supported = builtin.os.tag != .windows;

/// The controlling side of the terminal; nonblocking.
master: c_int,
pid: c.pid_t,
exited: bool = false,

pub const SpawnError = error{ Unsupported, OpenPtyFailed, ForkFailed, OutOfMemory };

// Not all of these are declared by std.c, so declare them here.
extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, len: usize) isize;

// Terminal ioctls (std.c doesn't define them for every OS).
const TIOCSWINSZ: c_ulong = switch (builtin.os.tag) {
    .linux => 0x5414,
    else => 0x80087467, // macOS and the BSDs
};
const TIOCSCTTY: c_ulong = switch (builtin.os.tag) {
    .linux => 0x540E,
    else => 0x20007461,
};

/// Starts `shell` as a login shell in `cwd`, on a terminal of the given size.
pub fn spawn(gpa: std.mem.Allocator, shell: []const u8, cwd: []const u8, cols: u16, rows: u16) SpawnError!Pty {
    if (comptime !supported) return error.Unsupported;

    const open_flags: u32 = @bitCast(c.O{ .ACCMODE = .RDWR, .NOCTTY = true });
    const master = posix_openpt(@bitCast(open_flags));
    if (master < 0) return error.OpenPtyFailed;
    errdefer _ = c.close(master);
    if (grantpt(master) != 0 or unlockpt(master) != 0) return error.OpenPtyFailed;
    const slave_name = try gpa.dupeZ(u8, std.mem.span(ptsname(master) orelse return error.OpenPtyFailed));
    defer gpa.free(slave_name);
    setSize(master, cols, rows);

    // Everything the child needs is prepared before fork: after it, the
    // child may only make simple system calls until exec.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shell_z = try arena.dupeZ(u8, shell);
    const cwd_z = try arena.dupeZ(u8, cwd);
    const argv = try arena.allocSentinel(?[*:0]const u8, 2, null);
    argv[0] = shell_z;
    argv[1] = "-l"; // a login shell, so profile files set up PATH as usual
    const envp = try childEnvironment(arena);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // Child: become the session leader with the terminal as its
        // controlling tty, on stdin/stdout/stderr.
        _ = c.setsid();
        const rdwr: u32 = @bitCast(c.O{ .ACCMODE = .RDWR });
        const slave = c.open(slave_name, @bitCast(rdwr));
        if (slave < 0) c._exit(126);
        _ = ioctl(slave, TIOCSCTTY, @as(c_int, 0));
        // Size it here, before the shell starts (macOS drops a size set on
        // the master before the slave was opened).
        setSize(slave, cols, rows);
        _ = c.dup2(slave, 0);
        _ = c.dup2(slave, 1);
        _ = c.dup2(slave, 2);
        if (slave > 2) _ = c.close(slave);
        _ = c.close(master);
        _ = c.chdir(cwd_z);
        _ = c.execve(shell_z, argv, envp);
        c._exit(127);
    }

    // Parent: never block the UI on reads.
    const flags = c.fcntl(master, c.F.GETFL);
    const nonblock: u32 = @bitCast(c.O{ .NONBLOCK = true });
    _ = c.fcntl(master, c.F.SETFL, flags | @as(c_int, @bitCast(nonblock)));
    return .{ .master = master, .pid = pid };
}

/// The inherited environment, adjusted for a terminal: TERM and friends,
/// and a UTF-8 locale (apps started from Finder have none).
fn childEnvironment(arena: std.mem.Allocator) ![*:null]?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    var has_lang = false;
    var i: usize = 0;
    while (c.environ[i]) |entry| : (i += 1) {
        const e = std.mem.span(entry);
        const replaced = [_][]const u8{ "TERM=", "COLORTERM=", "TERM_PROGRAM=" };
        const skip = for (replaced) |p| {
            if (std.mem.startsWith(u8, e, p)) break true;
        } else false;
        if (skip) continue;
        if (std.mem.startsWith(u8, e, "LANG=") or std.mem.startsWith(u8, e, "LC_ALL=")) has_lang = true;
        try list.append(arena, entry);
    }
    try list.append(arena, "TERM=xterm-256color");
    try list.append(arena, "COLORTERM=truecolor");
    try list.append(arena, "TERM_PROGRAM=byte-code");
    if (!has_lang) try list.append(arena, "LANG=en_US.UTF-8");
    return (try list.toOwnedSliceSentinel(arena, null)).ptr;
}

/// The user's shell: $SHELL, else a sensible default.
pub fn defaultShell() []const u8 {
    if (comptime !supported) return "cmd.exe";
    if (c.getenv("SHELL")) |s| return std.mem.span(s);
    return if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/sh";
}

pub fn homeDir() []const u8 {
    if (comptime !supported) return ".";
    return if (c.getenv("HOME")) |h| std.mem.span(h) else "/";
}

/// Reads what's available without blocking. Returns 0 when there's nothing
/// new; sets `exited` when the shell is gone.
pub fn read(self: *Pty, buf: []u8) usize {
    if (comptime !supported) return 0;
    if (self.exited) return 0;
    const n = c.read(self.master, buf.ptr, buf.len);
    if (n > 0) return @intCast(n);
    if (n == 0) {
        self.markExited(); // EOF: the shell closed the terminal (macOS)
        return 0;
    }
    switch (c.errno(n)) {
        .AGAIN, .INTR => {},
        else => self.markExited(), // EIO: the shell exited (Linux)
    }
    return 0;
}

/// Sends input to the shell (what the user typed or pasted).
pub fn writeAll(self: *Pty, bytes: []const u8) void {
    if (comptime !supported) return;
    if (self.exited) return;
    var rest = bytes;
    var attempts: usize = 0;
    while (rest.len > 0 and attempts < 1000) : (attempts += 1) {
        const n = write(self.master, rest.ptr, rest.len);
        if (n > 0) {
            rest = rest[@intCast(n)..];
        } else if (n < 0 and c.errno(n) != .AGAIN and c.errno(n) != .INTR) {
            return; // the shell is gone; `read` will notice
        }
    }
}

/// Tells the shell (and the program in front) the terminal's new size.
pub fn resize(self: *Pty, cols: u16, rows: u16) void {
    if (!self.exited) setSize(self.master, cols, rows);
}

fn setSize(fd: c_int, cols: u16, rows: u16) void {
    if (comptime !supported) return;
    var ws: c.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
    _ = ioctl(fd, TIOCSWINSZ, &ws);
}

fn markExited(self: *Pty) void {
    self.exited = true;
    if (comptime !supported) return;
    _ = c.waitpid(self.pid, null, 1); // WNOHANG: reap it if it's done
}

/// Ends the shell (SIGHUP, as when a terminal window closes).
pub fn deinit(self: *Pty) void {
    if (comptime !supported) return;
    if (!self.exited) _ = c.kill(self.pid, .HUP);
    _ = c.close(self.master);
    _ = c.waitpid(self.pid, null, 1);
}

test "runs a shell and talks to it" {
    if (!supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var pty = try spawn(gpa, "/bin/sh", "/", 80, 24);
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
