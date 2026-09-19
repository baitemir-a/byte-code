//! Reading the shell's output: plain text, control characters and escape
//! sequences (CSI, OSC), turned into screen operations.
const std = @import("std");
const Screen = @import("../Screen.zig");

/// Processes output from the program.
pub fn feed(self: *Screen, bytes: []const u8) !void {
    for (bytes) |b| try byte(self, b);
    self.generation +%= 1;
}

pub fn byte(self: *Screen, b: u8) !void {
    const p = &self.parser;
    switch (p.state) {
        .ground => try ground(self, b),
        .escape => try escape(self, b),
        .escape_intermediate => p.state = .ground, // ESC # 8 etc.: ignored
        .charset => p.state = .ground, // ESC ( B: character sets, ignored
        .csi => try csiByte(self, b),
        .osc => switch (b) {
            0x07 => try oscDone(
                self,
            ),
            0x1b => p.state = .osc_escape,
            else => if (p.osc.items.len < 1024) try p.osc.append(self.gpa, b),
        },
        .osc_escape => if (b == '\\') try oscDone(
            self,
        ) else {
            p.state = .ground;
        },
    }
}

pub fn ground(self: *Screen, b: u8) !void {
    const p = &self.parser;
    if (p.utf8_need > 0) {
        if (b & 0xC0 == 0x80) {
            p.utf8[p.utf8_len] = b;
            p.utf8_len += 1;
            if (p.utf8_len == p.utf8_need) {
                p.utf8_need = 0;
                const cp = std.unicode.utf8Decode(p.utf8[0..p.utf8_len]) catch 0xFFFD;
                self.print(cp);
            }
            return;
        }
        p.utf8_need = 0; // broken sequence: drop it, handle this byte fresh
        self.print(0xFFFD);
    }
    switch (b) {
        0x07 => {}, // bell
        0x08 => {
            if (self.cursor.x > 0) self.cursor.x -= 1;
            self.wrap_pending = false;
        },
        0x09 => {
            self.cursor.x = @min(self.cols - 1, (self.cursor.x / 8 + 1) * 8);
            self.wrap_pending = false;
        },
        0x0a, 0x0b, 0x0c => try self.lineFeed(),
        0x0d => {
            self.cursor.x = 0;
            self.wrap_pending = false;
        },
        0x1b => p.state = .escape,
        0x00...0x06, 0x0e...0x1a, 0x1c...0x1f, 0x7f => {},
        0x80...0xff => {
            const len = std.unicode.utf8ByteSequenceLength(b) catch return self.print(0xFFFD);
            p.utf8[0] = b;
            p.utf8_len = 1;
            p.utf8_need = len;
        },
        else => self.print(b),
    }
}

pub fn escape(self: *Screen, b: u8) !void {
    const p = &self.parser;
    p.state = .ground;
    switch (b) {
        '[' => {
            p.state = .csi;
            p.param_count = 0;
            p.param_started = false;
            p.private = 0;
            p.intermediate = 0;
        },
        ']' => {
            p.state = .osc;
            p.osc.clearRetainingCapacity();
        },
        '(', ')', '*', '+' => p.state = .charset,
        '#', ' ', '%' => p.state = .escape_intermediate,
        '7' => self.saveCursor(),
        '8' => self.restoreCursor(),
        'D' => try self.lineFeed(),
        'E' => {
            self.cursor.x = 0;
            try self.lineFeed();
        },
        'M' => try self.reverseIndex(),
        'c' => self.reset(),
        else => {}, // ESC = / ESC > keypad modes and others: ignored
    }
}

pub fn csiByte(self: *Screen, b: u8) !void {
    const p = &self.parser;
    switch (b) {
        '0'...'9' => {
            if (!p.param_started) {
                if (p.param_count == p.params.len) return;
                p.params[p.param_count] = 0;
                p.param_count += 1;
                p.param_started = true;
            }
            const v = &p.params[p.param_count - 1];
            v.* = v.* *| 10 +| (b - '0');
        },
        ';', ':' => {
            if (!p.param_started and p.param_count < p.params.len) {
                p.params[p.param_count] = 0; // empty parameter
                p.param_count += 1;
            }
            p.param_started = false;
        },
        '?', '>', '<', '=' => p.private = b,
        0x20...0x2f => p.intermediate = b,
        0x40...0x7e => {
            p.state = .ground;
            try csiDispatch(self, b);
        },
        0x1b => p.state = .escape, // abandoned sequence
        else => {},
    }
}

/// Parameter `i`, or `default` if missing or 0.
pub fn param(self: *const Screen, i: usize, default: u32) u32 {
    const p = &self.parser;
    if (i >= p.param_count or p.params[i] == 0) return default;
    return p.params[i];
}

pub fn csiDispatch(self: *Screen, final: u8) !void {
    const p = &self.parser;
    const n: usize = param(self, 0, 1);
    if (p.intermediate != 0) return; // e.g. CSI SP q (cursor shape): ignored
    switch (final) {
        'A' => self.moveTo(self.cursor.x, self.cursor.y -| n),
        'B', 'e' => self.moveTo(self.cursor.x, self.cursor.y + n),
        'C', 'a' => self.moveTo(self.cursor.x + n, self.cursor.y),
        'D' => self.moveTo(self.cursor.x -| n, self.cursor.y),
        'E' => self.moveTo(0, self.cursor.y + n),
        'F' => self.moveTo(0, self.cursor.y -| n),
        'G', '`' => self.moveTo(n - 1, self.cursor.y),
        'd' => self.moveTo(self.cursor.x, n - 1),
        'H', 'f' => self.moveTo(@as(usize, param(self, 1, 1)) - 1, n - 1),
        'J' => self.eraseDisplay(param(self, 0, 0)),
        'K' => self.eraseLine(param(self, 0, 0)),
        'L' => self.insertLines(n),
        'M' => self.deleteLines(n),
        '@' => self.insertChars(n),
        'P' => self.deleteChars(n),
        'X' => self.eraseChars(n),
        'S' => for (0..n) |_| try self.scrollUp(),
        'T' => for (0..n) |_| self.scrollDown(),
        'm' => sgr(
            self,
        ),
        'r' => if (p.private == 0) {
            const top: usize = param(self, 0, 1) - 1;
            const bottom: usize = @min(self.rows, param(self, 1, @intCast(self.rows))) - 1;
            if (top < bottom) {
                self.scroll_top = top;
                self.scroll_bottom = bottom;
                self.moveTo(0, 0);
            }
        },
        's' => self.saveCursor(),
        'u' => self.restoreCursor(),
        'h', 'l' => try setModes(self, final == 'h'),
        'n' => switch (param(self, 0, 0)) {
            5 => try self.responses.appendSlice(self.gpa, "\x1b[0n"),
            6 => try self.responses.print(self.gpa, "\x1b[{d};{d}R", .{ self.cursor.y + 1, self.cursor.x + 1 }),
            else => {},
        },
        'c' => try self.responses.appendSlice(self.gpa, if (p.private == '>') "\x1b[>0;0;0c" else "\x1b[?1;2c"),
        else => {},
    }
}

pub fn setModes(self: *Screen, on: bool) !void {
    const p = &self.parser;
    if (p.private != '?') return; // ANSI modes (insert mode...): ignored
    for (p.params[0..p.param_count]) |mode| switch (mode) {
        1 => self.app_cursor_keys = on,
        7 => self.autowrap = on,
        25 => self.cursor_visible = on,
        47, 1047 => self.setAltScreen(on, false),
        1049 => self.setAltScreen(on, true),
        2004 => self.bracketed_paste = on,
        else => {}, // mouse reporting, focus events...: ignored
    };
}

pub fn sgr(self: *Screen) void {
    const p = &self.parser;
    if (p.param_count == 0) {
        resetPen(
            self,
        );
        return;
    }
    var i: usize = 0;
    while (i < p.param_count) : (i += 1) {
        const v = p.params[i];
        switch (v) {
            0 => resetPen(
                self,
            ),
            1 => self.pen.attrs.bold = true,
            2 => self.pen.attrs.faint = true,
            3 => self.pen.attrs.italic = true,
            4 => self.pen.attrs.underline = true,
            7 => self.pen.attrs.inverse = true,
            8 => self.pen.attrs.hidden = true,
            9 => self.pen.attrs.strike = true,
            22 => {
                self.pen.attrs.bold = false;
                self.pen.attrs.faint = false;
            },
            23 => self.pen.attrs.italic = false,
            24 => self.pen.attrs.underline = false,
            27 => self.pen.attrs.inverse = false,
            28 => self.pen.attrs.hidden = false,
            29 => self.pen.attrs.strike = false,
            30...37 => self.pen.fg = .{ .palette = @intCast(v - 30) },
            39 => self.pen.fg = .default,
            40...47 => self.pen.bg = .{ .palette = @intCast(v - 40) },
            49 => self.pen.bg = .default,
            90...97 => self.pen.fg = .{ .palette = @intCast(v - 90 + 8) },
            100...107 => self.pen.bg = .{ .palette = @intCast(v - 100 + 8) },
            38, 48 => {
                // 38;5;n (256 colors) or 38;2;r;g;b (true color).
                const color: ?Screen.Color = if (i + 2 < p.param_count and p.params[i + 1] == 5) blk: {
                    defer i += 2;
                    break :blk .{ .palette = @truncate(p.params[i + 2]) };
                } else if (i + 4 < p.param_count and p.params[i + 1] == 2) blk: {
                    defer i += 4;
                    break :blk .{ .rgb = .{ @truncate(p.params[i + 2]), @truncate(p.params[i + 3]), @truncate(p.params[i + 4]) } };
                } else null;
                if (color) |c| {
                    if (v == 38) self.pen.fg = c else self.pen.bg = c;
                }
            },
            else => {},
        }
    }
}

pub fn resetPen(self: *Screen) void {
    self.pen = .{};
}

pub fn oscDone(self: *Screen) !void {
    const p = &self.parser;
    p.state = .ground;
    // "0;title" / "2;title" set the window title; the rest is ignored.
    const s = p.osc.items;
    const semi = std.mem.indexOfScalar(u8, s, ';') orelse return;
    if (std.mem.eql(u8, s[0..semi], "0") or std.mem.eql(u8, s[0..semi], "2")) {
        self.title.clearRetainingCapacity();
        try self.title.appendSlice(self.gpa, s[semi + 1 ..]);
    }
}
