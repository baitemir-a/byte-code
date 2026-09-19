//! The integrated terminal: a shell on a pseudo-terminal, and the screen
//! its output is drawn on. When the shell exits, Enter starts a new one.
const std = @import("std");
const core = @import("core");
const Pty = @import("../platform/Pty.zig");

const Terminal = @This();
const Screen = core.TerminalScreen;

gpa: std.mem.Allocator,
screen: Screen,
/// Null when no shell could be started (e.g. on Windows).
pty: ?Pty = null,
/// Where new shells start.
cwd: []u8,

pub fn init(gpa: std.mem.Allocator, cwd: []const u8, cols: u16, rows: u16) !Terminal {
    var self: Terminal = .{
        .gpa = gpa,
        .screen = try .init(gpa, cols, rows),
        .cwd = try gpa.dupe(u8, cwd),
    };
    errdefer self.deinit();
    try self.start();
    return self;
}

pub fn deinit(self: *Terminal) void {
    if (self.pty) |*p| p.deinit();
    self.screen.deinit();
    self.gpa.free(self.cwd);
}

fn start(self: *Terminal) !void {
    const cols: u16 = @intCast(self.screen.cols);
    const rows: u16 = @intCast(self.screen.rows);
    self.pty = Pty.spawn(self.gpa, Pty.defaultShell(), self.cwd, cols, rows) catch |err| {
        self.pty = null;
        const why = if (err == error.Unsupported) "The terminal isn't available on this system yet." else "Couldn't start a shell.";
        try self.screen.feed(why);
        try self.screen.feed("\r\n");
        return;
    };
}

/// Whether the shell ended (or never started).
pub fn exited(self: *const Terminal) bool {
    return if (self.pty) |p| p.exited else true;
}

/// Starts a fresh shell after the previous one exited.
pub fn restart(self: *Terminal) !void {
    if (self.pty) |*p| p.deinit();
    self.pty = null;
    try self.screen.feed("\x1b[0m\r\n");
    try self.start();
}

/// Reads the shell's output (up to a limit per frame, so a flood of output
/// can't freeze the UI) and answers its queries. Returns true if anything
/// changed.
pub fn pump(self: *Terminal) !bool {
    const pty = if (self.pty) |*p| p else return false;
    if (pty.exited) return false;
    var buf: [16 * 1024]u8 = undefined;
    var changed = false;
    for (0..8) |_| {
        const n = pty.read(&buf);
        if (n == 0) break;
        try self.screen.feed(buf[0..n]);
        changed = true;
    }
    if (self.screen.responses.items.len > 0) {
        pty.writeAll(self.screen.responses.items);
        self.screen.responses.clearRetainingCapacity();
    }
    if (pty.exited) {
        try self.screen.feed("\x1b[0m\r\n\x1b[2m[process exited — press Enter to start a new shell]\x1b[0m");
        changed = true;
    }
    return changed;
}

/// Sends typed input to the shell.
pub fn send(self: *Terminal, bytes: []const u8) void {
    if (self.pty) |*p| p.writeAll(bytes);
}

/// Pastes text: line breaks become Enter presses, wrapped in the
/// bracketed-paste markers when the shell asked for them (so a pasted
/// command isn't run line by line).
pub fn paste(self: *Terminal, text: []const u8) !void {
    const converted = try self.gpa.alloc(u8, text.len);
    defer self.gpa.free(converted);
    var n: usize = 0;
    for (text, 0..) |b, i| {
        if (b == '\r' and i + 1 < text.len and text[i + 1] == '\n') continue;
        converted[n] = if (b == '\n') '\r' else b;
        n += 1;
    }
    if (self.screen.bracketed_paste) self.send("\x1b[200~");
    self.send(converted[0..n]);
    if (self.screen.bracketed_paste) self.send("\x1b[201~");
}

pub fn resize(self: *Terminal, cols: usize, rows: usize) !void {
    if (cols == self.screen.cols and rows == self.screen.rows) return;
    try self.screen.resize(cols, rows);
    if (self.pty) |*p| p.resize(@intCast(self.screen.cols), @intCast(self.screen.rows));
}

test {
    _ = @import("tests/Terminal_test.zig");
}
