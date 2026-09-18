//! A terminal emulator's screen: feed it the bytes a program writes and it
//! keeps the grid of colored characters, the cursor and the scrollback.
//! Speaks the xterm dialect programs expect with TERM=xterm-256color: cursor
//! movement, erasing, colors (16 / 256 / true color), scroll regions,
//! insert/delete, the alternate screen (vim, htop, less) and a few queries.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Screen = @This();

pub const Color = union(enum) {
    default,
    /// 0-15 are the standard/bright colors, 16-255 the xterm 256 palette.
    palette: u8,
    rgb: [3]u8,
};

pub const Attrs = packed struct(u8) {
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strike: bool = false,
    _: u1 = 0,
};

pub const Cell = struct {
    cp: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attrs = .{},
};

pub const Pos = struct { x: usize, y: usize };

/// Lines kept after scrolling off the top.
pub const max_history = 5000;

gpa: Allocator,
cols: usize,
rows: usize,
/// The visible lines of the active screen, each `cols` wide.
grid: [][]Cell,
/// The other screen: the main one while the alternate is active, and vice versa.
other_grid: [][]Cell,
alt_active: bool = false,
/// Lines scrolled off the top of the main screen, oldest first.
history: std.ArrayList([]Cell) = .empty,

cursor: Pos = .{ .x = 0, .y = 0 },
saved_cursor: Pos = .{ .x = 0, .y = 0 },
saved_pen: Cell = .{},
/// Colors and attributes for newly written characters.
pen: Cell = .{},
/// A character was written in the last column: the next one wraps first.
wrap_pending: bool = false,
scroll_top: usize = 0,
scroll_bottom: usize,

cursor_visible: bool = true,
/// Arrow keys send ESC O A instead of ESC [ A (set by vim, less...).
app_cursor_keys: bool = false,
autowrap: bool = true,
/// Pasted text should be wrapped in ESC[200~ ... ESC[201~.
bracketed_paste: bool = false,
title: std.ArrayList(u8) = .empty,
/// Replies to queries (cursor position, device attributes) for the app to
/// send back to the program.
responses: std.ArrayList(u8) = .empty,
/// Bumped whenever content changes, so views can tell.
generation: u64 = 0,

parser: Parser = .{},

const Parser = struct {
    state: enum { ground, escape, escape_intermediate, csi, osc, osc_escape, charset } = .ground,
    params: [16]u32 = undefined,
    param_count: usize = 0,
    /// The digit being read belongs to params[param_count].
    param_started: bool = false,
    /// '?' or '>' right after CSI.
    private: u8 = 0,
    intermediate: u8 = 0,
    osc: std.ArrayList(u8) = .empty,
    /// A UTF-8 sequence being assembled.
    utf8: [4]u8 = undefined,
    utf8_len: u8 = 0,
    utf8_need: u8 = 0,
};

pub fn init(gpa: Allocator, cols: usize, rows: usize) !Screen {
    const c = @max(cols, 1);
    const r = @max(rows, 1);
    const grid = try allocGrid(gpa, c, r);
    errdefer freeGrid(gpa, grid);
    return .{
        .gpa = gpa,
        .cols = c,
        .rows = r,
        .grid = grid,
        .other_grid = try allocGrid(gpa, c, r),
        .scroll_bottom = r - 1,
    };
}

pub fn deinit(self: *Screen) void {
    freeGrid(self.gpa, self.grid);
    freeGrid(self.gpa, self.other_grid);
    for (self.history.items) |l| self.gpa.free(l);
    self.history.deinit(self.gpa);
    self.title.deinit(self.gpa);
    self.responses.deinit(self.gpa);
    self.parser.osc.deinit(self.gpa);
}

fn allocGrid(gpa: Allocator, cols: usize, rows: usize) ![][]Cell {
    const grid = try gpa.alloc([]Cell, rows);
    var done: usize = 0;
    errdefer {
        for (grid[0..done]) |l| gpa.free(l);
        gpa.free(grid);
    }
    for (grid) |*l| {
        l.* = try gpa.alloc(Cell, cols);
        @memset(l.*, .{});
        done += 1;
    }
    return grid;
}

fn freeGrid(gpa: Allocator, grid: [][]Cell) void {
    for (grid) |l| gpa.free(l);
    gpa.free(grid);
}

// ------------------------------------------------------------------ input

/// Processes output from the program.
pub fn feed(self: *Screen, bytes: []const u8) !void {
    for (bytes) |b| try self.byte(b);
    self.generation +%= 1;
}

fn byte(self: *Screen, b: u8) !void {
    const p = &self.parser;
    switch (p.state) {
        .ground => try self.ground(b),
        .escape => try self.escape(b),
        .escape_intermediate => p.state = .ground, // ESC # 8 etc.: ignored
        .charset => p.state = .ground, // ESC ( B: character sets, ignored
        .csi => try self.csiByte(b),
        .osc => switch (b) {
            0x07 => try self.oscDone(),
            0x1b => p.state = .osc_escape,
            else => if (p.osc.items.len < 1024) try p.osc.append(self.gpa, b),
        },
        .osc_escape => if (b == '\\') try self.oscDone() else {
            p.state = .ground;
        },
    }
}

fn ground(self: *Screen, b: u8) !void {
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

fn escape(self: *Screen, b: u8) !void {
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

fn csiByte(self: *Screen, b: u8) !void {
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
            try self.csiDispatch(b);
        },
        0x1b => p.state = .escape, // abandoned sequence
        else => {},
    }
}

/// Parameter `i`, or `default` if missing or 0.
fn param(self: *const Screen, i: usize, default: u32) u32 {
    const p = &self.parser;
    if (i >= p.param_count or p.params[i] == 0) return default;
    return p.params[i];
}

fn csiDispatch(self: *Screen, final: u8) !void {
    const p = &self.parser;
    const n: usize = self.param(0, 1);
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
        'H', 'f' => self.moveTo(@as(usize, self.param(1, 1)) - 1, n - 1),
        'J' => self.eraseDisplay(self.param(0, 0)),
        'K' => self.eraseLine(self.param(0, 0)),
        'L' => self.insertLines(n),
        'M' => self.deleteLines(n),
        '@' => self.insertChars(n),
        'P' => self.deleteChars(n),
        'X' => self.eraseChars(n),
        'S' => for (0..n) |_| try self.scrollUp(),
        'T' => for (0..n) |_| self.scrollDown(),
        'm' => self.sgr(),
        'r' => if (p.private == 0) {
            const top: usize = self.param(0, 1) - 1;
            const bottom: usize = @min(self.rows, self.param(1, @intCast(self.rows))) - 1;
            if (top < bottom) {
                self.scroll_top = top;
                self.scroll_bottom = bottom;
                self.moveTo(0, 0);
            }
        },
        's' => self.saveCursor(),
        'u' => self.restoreCursor(),
        'h', 'l' => try self.setModes(final == 'h'),
        'n' => switch (self.param(0, 0)) {
            5 => try self.responses.appendSlice(self.gpa, "\x1b[0n"),
            6 => try self.responses.print(self.gpa, "\x1b[{d};{d}R", .{ self.cursor.y + 1, self.cursor.x + 1 }),
            else => {},
        },
        'c' => try self.responses.appendSlice(self.gpa, if (p.private == '>') "\x1b[>0;0;0c" else "\x1b[?1;2c"),
        else => {},
    }
}

fn setModes(self: *Screen, on: bool) !void {
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

fn sgr(self: *Screen) void {
    const p = &self.parser;
    if (p.param_count == 0) {
        self.resetPen();
        return;
    }
    var i: usize = 0;
    while (i < p.param_count) : (i += 1) {
        const v = p.params[i];
        switch (v) {
            0 => self.resetPen(),
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
                const color: ?Color = if (i + 2 < p.param_count and p.params[i + 1] == 5) blk: {
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

fn resetPen(self: *Screen) void {
    self.pen = .{};
}

fn oscDone(self: *Screen) !void {
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

// ------------------------------------------------------------- operations

fn print(self: *Screen, cp: u21) void {
    if (self.wrap_pending and self.autowrap) {
        self.cursor.x = 0;
        self.lineFeed() catch {};
    }
    self.wrap_pending = false;
    var cell = self.pen;
    cell.cp = cp;
    self.grid[self.cursor.y][self.cursor.x] = cell;
    if (self.cursor.x + 1 < self.cols) self.cursor.x += 1 else self.wrap_pending = true;
}

fn moveTo(self: *Screen, x: usize, y: usize) void {
    self.cursor = .{ .x = @min(x, self.cols - 1), .y = @min(y, self.rows - 1) };
    self.wrap_pending = false;
}

fn lineFeed(self: *Screen) !void {
    self.wrap_pending = false;
    if (self.cursor.y == self.scroll_bottom) {
        try self.scrollUp();
    } else if (self.cursor.y + 1 < self.rows) {
        self.cursor.y += 1;
    }
}

fn reverseIndex(self: *Screen) !void {
    if (self.cursor.y == self.scroll_top) self.scrollDown() else if (self.cursor.y > 0) self.cursor.y -= 1;
}

/// A blank cell carrying the current background (as xterm erases).
fn blank(self: *const Screen) Cell {
    return .{ .bg = self.pen.bg };
}

/// Scrolls the scroll region up one line. On the main screen, with the
/// region at the top, the line that leaves goes into the scrollback.
fn scrollUp(self: *Screen) !void {
    const top = self.scroll_top;
    const bottom = self.scroll_bottom;
    const gone = self.grid[top];
    const fresh = if (!self.alt_active and top == 0) blk: {
        // Keep `gone` in the history and give the grid a new line.
        const line = try self.gpa.alloc(Cell, self.cols);
        errdefer self.gpa.free(line);
        try self.history.append(self.gpa, gone);
        if (self.history.items.len > max_history) self.gpa.free(self.history.orderedRemove(0));
        break :blk line;
    } else gone;
    std.mem.copyForwards([]Cell, self.grid[top..bottom], self.grid[top + 1 .. bottom + 1]);
    @memset(fresh, self.blank());
    self.grid[bottom] = fresh;
}

fn scrollDown(self: *Screen) void {
    const top = self.scroll_top;
    const bottom = self.scroll_bottom;
    const recycled = self.grid[bottom];
    std.mem.copyBackwards([]Cell, self.grid[top + 1 .. bottom + 1], self.grid[top..bottom]);
    @memset(recycled, self.blank());
    self.grid[top] = recycled;
}

fn eraseDisplay(self: *Screen, mode: u32) void {
    const c = self.cursor;
    switch (mode) {
        0 => {
            @memset(self.grid[c.y][c.x..], self.blank());
            for (self.grid[c.y + 1 ..]) |l| @memset(l, self.blank());
        },
        1 => {
            for (self.grid[0..c.y]) |l| @memset(l, self.blank());
            @memset(self.grid[c.y][0 .. c.x + 1], self.blank());
        },
        2 => for (self.grid) |l| @memset(l, self.blank()),
        3 => { // also clear the scrollback (`clear` does this)
            for (self.history.items) |l| self.gpa.free(l);
            self.history.clearRetainingCapacity();
        },
        else => {},
    }
}

fn eraseLine(self: *Screen, mode: u32) void {
    const line = self.grid[self.cursor.y];
    switch (mode) {
        0 => @memset(line[self.cursor.x..], self.blank()),
        1 => @memset(line[0 .. self.cursor.x + 1], self.blank()),
        2 => @memset(line, self.blank()),
        else => {},
    }
}

fn insertLines(self: *Screen, n: usize) void {
    if (self.cursor.y < self.scroll_top or self.cursor.y > self.scroll_bottom) return;
    const saved_top = self.scroll_top;
    self.scroll_top = self.cursor.y;
    for (0..@min(n, self.scroll_bottom - self.cursor.y + 1)) |_| self.scrollDown();
    self.scroll_top = saved_top;
    self.cursor.x = 0;
}

fn deleteLines(self: *Screen, n: usize) void {
    if (self.cursor.y < self.scroll_top or self.cursor.y > self.scroll_bottom) return;
    // Like scrolling up within [cursor.y, bottom], without history.
    const line_count = @min(n, self.scroll_bottom - self.cursor.y + 1);
    for (0..line_count) |_| {
        const gone = self.grid[self.cursor.y];
        std.mem.copyForwards([]Cell, self.grid[self.cursor.y..self.scroll_bottom], self.grid[self.cursor.y + 1 .. self.scroll_bottom + 1]);
        @memset(gone, self.blank());
        self.grid[self.scroll_bottom] = gone;
    }
    self.cursor.x = 0;
}

fn insertChars(self: *Screen, n: usize) void {
    const line = self.grid[self.cursor.y];
    const k = @min(n, self.cols - self.cursor.x);
    std.mem.copyBackwards(Cell, line[self.cursor.x + k ..], line[self.cursor.x .. self.cols - k]);
    @memset(line[self.cursor.x..][0..k], self.blank());
}

fn deleteChars(self: *Screen, n: usize) void {
    const line = self.grid[self.cursor.y];
    const k = @min(n, self.cols - self.cursor.x);
    std.mem.copyForwards(Cell, line[self.cursor.x .. self.cols - k], line[self.cursor.x + k ..]);
    @memset(line[self.cols - k ..], self.blank());
}

fn eraseChars(self: *Screen, n: usize) void {
    const line = self.grid[self.cursor.y];
    @memset(line[self.cursor.x..][0..@min(n, self.cols - self.cursor.x)], self.blank());
}

fn saveCursor(self: *Screen) void {
    self.saved_cursor = self.cursor;
    self.saved_pen = self.pen;
}

fn restoreCursor(self: *Screen) void {
    self.moveTo(self.saved_cursor.x, self.saved_cursor.y);
    self.pen = self.saved_pen;
}

/// The alternate screen: full-screen programs draw there and the main
/// screen (and its scrollback) comes back untouched when they exit.
fn setAltScreen(self: *Screen, on: bool, save_cursor: bool) void {
    if (on == self.alt_active) return;
    if (on and save_cursor) self.saveCursor();
    std.mem.swap([][]Cell, &self.grid, &self.other_grid);
    self.alt_active = on;
    if (on) for (self.grid) |l| @memset(l, .{});
    if (!on and save_cursor) self.restoreCursor();
    self.scroll_top = 0;
    self.scroll_bottom = self.rows - 1;
}

fn reset(self: *Screen) void {
    if (self.alt_active) self.setAltScreen(false, false);
    for (self.grid) |l| @memset(l, .{});
    self.pen = .{};
    self.cursor = .{ .x = 0, .y = 0 };
    self.scroll_top = 0;
    self.scroll_bottom = self.rows - 1;
    self.cursor_visible = true;
    self.app_cursor_keys = false;
    self.autowrap = true;
}

/// Changes the size. Lines that no longer fit above the cursor go into the
/// scrollback; lines are cut or padded to the new width.
pub fn resize(self: *Screen, cols: usize, rows: usize) !void {
    const c = @max(cols, 1);
    const r = @max(rows, 1);
    if (c == self.cols and r == self.rows) return;
    const new_grid = try allocGrid(self.gpa, c, r);
    errdefer freeGrid(self.gpa, new_grid);
    const new_other = try allocGrid(self.gpa, c, r);

    // Keep the bottom part (where the cursor is) when shrinking.
    const drop = if (self.cursor.y + 1 > r) self.cursor.y + 1 - r else 0;
    for (0..drop) |y| {
        if (self.alt_active) continue;
        const line = try self.gpa.dupe(Cell, self.grid[y]);
        try self.history.append(self.gpa, line);
    }
    for (0..@min(r, self.rows - drop)) |y| copyLine(new_grid[y], self.grid[y + drop]);
    for (0..@min(r, self.rows)) |y| copyLine(new_other[y], self.other_grid[y]);

    freeGrid(self.gpa, self.grid);
    freeGrid(self.gpa, self.other_grid);
    self.grid = new_grid;
    self.other_grid = new_other;
    self.cols = c;
    self.rows = r;
    self.cursor = .{ .x = @min(self.cursor.x, c - 1), .y = self.cursor.y - drop };
    self.scroll_top = 0;
    self.scroll_bottom = r - 1;
    self.wrap_pending = false;
    self.generation +%= 1;
}

fn copyLine(dst: []Cell, src: []const Cell) void {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
}

// ---------------------------------------------------------------- reading

/// Lines available for display: scrollback (on the main screen) then the grid.
pub fn lineCount(self: *const Screen) usize {
    return (if (self.alt_active) 0 else self.history.items.len) + self.rows;
}

/// Line `i` of `lineCount()`; scrollback lines may be narrower or wider.
pub fn lineAt(self: *const Screen, i: usize) []const Cell {
    const h = if (self.alt_active) 0 else self.history.items.len;
    return if (i < h) self.history.items[i] else self.grid[i - h];
}

/// Text between two positions (line index from `lineAt`, column), with
/// trailing spaces trimmed from each line. Caller frees.
pub fn text(self: *const Screen, gpa: Allocator, from: Pos, to: Pos) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var y = from.y;
    while (y <= to.y and y < self.lineCount()) : (y += 1) {
        const cells = self.lineAt(y);
        const start = if (y == from.y) @min(from.x, cells.len) else 0;
        const end = if (y == to.y) @min(to.x, cells.len) else cells.len;
        const line_start = out.items.len;
        for (cells[start..@max(start, end)]) |c| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c.cp, &buf) catch 1;
            try out.appendSlice(gpa, buf[0..n]);
        }
        // Trim trailing blanks of each line.
        while (out.items.len > line_start and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
        if (y != to.y) try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn rowText(s: *const Screen, y: usize) ![]u8 {
    return s.text(testing.allocator, .{ .x = 0, .y = s.lineCount() - s.rows + y }, .{ .x = s.cols, .y = s.lineCount() - s.rows + y });
}

fn expectRow(s: *const Screen, y: usize, expected: []const u8) !void {
    const t = try rowText(s, y);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings(expected, t);
}

test "text, wrapping, scrollback" {
    var s = try Screen.init(testing.allocator, 5, 2);
    defer s.deinit();
    try s.feed("hi\r\nthere!"); // "there" fills the row; "!" wraps
    try expectRow(&s, 0, "there");
    try expectRow(&s, 1, "!");
    try testing.expectEqual(@as(usize, 1), s.history.items.len); // "hi"

    try s.feed("\r\nбыстр");
    try expectRow(&s, 0, "!");
    try expectRow(&s, 1, "быстр");
    try s.feed("о"); // wraps: scrolls again
    try expectRow(&s, 0, "быстр");
    try expectRow(&s, 1, "о");
    try testing.expectEqual(@as(usize, 3), s.history.items.len);
}

test "cursor movement, erase, colors" {
    var s = try Screen.init(testing.allocator, 10, 3);
    defer s.deinit();
    try s.feed("abcdef\x1b[2;3Hxy\x1b[1;4H\x1b[K\x1b[31;1mR\x1b[0m");
    try expectRow(&s, 0, "abcR");
    try expectRow(&s, 1, "  xy");
    const r = s.grid[0][3];
    try testing.expectEqual(Color{ .palette = 1 }, r.fg);
    try testing.expect(r.attrs.bold);
    try testing.expectEqual(Color.default, s.pen.fg);

    try s.feed("\x1b[38;5;208mA\x1b[48;2;1;2;3mB");
    try testing.expectEqual(Color{ .palette = 208 }, s.grid[0][4].fg);
    try testing.expectEqual(Color{ .rgb = .{ 1, 2, 3 } }, s.grid[0][5].bg);

    try s.feed("\x1b[2J");
    try expectRow(&s, 0, "");
}

test "alternate screen keeps the main one" {
    var s = try Screen.init(testing.allocator, 10, 2);
    defer s.deinit();
    try s.feed("$ vim");
    try s.feed("\x1b[?1049h\x1b[Hfull screen");
    try expectRow(&s, 0, "full scree");
    try s.feed("\x1b[?1049l");
    try expectRow(&s, 0, "$ vim");
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
}

test "scroll region, insert and delete lines" {
    var s = try Screen.init(testing.allocator, 4, 4);
    defer s.deinit();
    try s.feed("1\r\n2\r\n3\r\n4");
    try s.feed("\x1b[2;3r\x1b[2;1H\x1b[M"); // delete line 2 inside rows 2-3
    try expectRow(&s, 0, "1");
    try expectRow(&s, 1, "3");
    try expectRow(&s, 2, "");
    try expectRow(&s, 3, "4");
    try s.feed("\x1b[L"); // insert a line at row 2
    try expectRow(&s, 1, "");
    try expectRow(&s, 2, "3");
}

test "queries get answers" {
    var s = try Screen.init(testing.allocator, 10, 5);
    defer s.deinit();
    try s.feed("\x1b[3;4H\x1b[6n\x1b[c");
    try testing.expectEqualStrings("\x1b[3;4R\x1b[?1;2c", s.responses.items);
}

test "sequences split across reads, resize" {
    var s = try Screen.init(testing.allocator, 10, 3);
    defer s.deinit();
    try s.feed("\x1b[3");
    try s.feed("1mX\xd0");
    try s.feed("\xb6\x1b]0;my title\x07");
    try expectRow(&s, 0, "Xж");
    try testing.expectEqual(Color{ .palette = 1 }, s.grid[0][0].fg);
    try testing.expectEqualStrings("my title", s.title.items);

    try s.feed("\r\nline2\r\nline3");
    try s.resize(4, 2); // the first line goes to the scrollback
    try expectRow(&s, 0, "line");
    try expectRow(&s, 1, "line");
    try testing.expectEqual(@as(usize, 1), s.history.items.len);
}
