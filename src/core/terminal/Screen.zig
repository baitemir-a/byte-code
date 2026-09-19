//! A terminal emulator's screen: feed it the bytes a program writes and it
//! keeps the grid of colored characters, the cursor and the scrollback.
//! Speaks the xterm dialect programs expect with TERM=xterm-256color: cursor
//! movement, erasing, colors (16 / 256 / true color), scroll regions,
//! insert/delete, the alternate screen (vim, htop, less) and a few queries.
const std = @import("std");
const escapes = @import("lib/escapes.zig");
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

// Reading escape sequences, in escapes.zig.
pub const feed = escapes.feed;

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

// ------------------------------------------------------------- operations

pub fn print(self: *Screen, cp: u21) void {
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

pub fn moveTo(self: *Screen, x: usize, y: usize) void {
    self.cursor = .{ .x = @min(x, self.cols - 1), .y = @min(y, self.rows - 1) };
    self.wrap_pending = false;
}

pub fn lineFeed(self: *Screen) !void {
    self.wrap_pending = false;
    if (self.cursor.y == self.scroll_bottom) {
        try self.scrollUp();
    } else if (self.cursor.y + 1 < self.rows) {
        self.cursor.y += 1;
    }
}

pub fn reverseIndex(self: *Screen) !void {
    if (self.cursor.y == self.scroll_top) self.scrollDown() else if (self.cursor.y > 0) self.cursor.y -= 1;
}

/// A blank cell carrying the current background (as xterm erases).
fn blank(self: *const Screen) Cell {
    return .{ .bg = self.pen.bg };
}

/// Scrolls the scroll region up one line. On the main screen, with the
/// region at the top, the line that leaves goes into the scrollback.
pub fn scrollUp(self: *Screen) !void {
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

pub fn scrollDown(self: *Screen) void {
    const top = self.scroll_top;
    const bottom = self.scroll_bottom;
    const recycled = self.grid[bottom];
    std.mem.copyBackwards([]Cell, self.grid[top + 1 .. bottom + 1], self.grid[top..bottom]);
    @memset(recycled, self.blank());
    self.grid[top] = recycled;
}

pub fn eraseDisplay(self: *Screen, mode: u32) void {
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

pub fn eraseLine(self: *Screen, mode: u32) void {
    const line = self.grid[self.cursor.y];
    switch (mode) {
        0 => @memset(line[self.cursor.x..], self.blank()),
        1 => @memset(line[0 .. self.cursor.x + 1], self.blank()),
        2 => @memset(line, self.blank()),
        else => {},
    }
}

pub fn insertLines(self: *Screen, n: usize) void {
    if (self.cursor.y < self.scroll_top or self.cursor.y > self.scroll_bottom) return;
    const saved_top = self.scroll_top;
    self.scroll_top = self.cursor.y;
    for (0..@min(n, self.scroll_bottom - self.cursor.y + 1)) |_| self.scrollDown();
    self.scroll_top = saved_top;
    self.cursor.x = 0;
}

pub fn deleteLines(self: *Screen, n: usize) void {
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

pub fn insertChars(self: *Screen, n: usize) void {
    const line = self.grid[self.cursor.y];
    const k = @min(n, self.cols - self.cursor.x);
    std.mem.copyBackwards(Cell, line[self.cursor.x + k ..], line[self.cursor.x .. self.cols - k]);
    @memset(line[self.cursor.x..][0..k], self.blank());
}

pub fn deleteChars(self: *Screen, n: usize) void {
    const line = self.grid[self.cursor.y];
    const k = @min(n, self.cols - self.cursor.x);
    std.mem.copyForwards(Cell, line[self.cursor.x .. self.cols - k], line[self.cursor.x + k ..]);
    @memset(line[self.cols - k ..], self.blank());
}

pub fn eraseChars(self: *Screen, n: usize) void {
    const line = self.grid[self.cursor.y];
    @memset(line[self.cursor.x..][0..@min(n, self.cols - self.cursor.x)], self.blank());
}

pub fn saveCursor(self: *Screen) void {
    self.saved_cursor = self.cursor;
    self.saved_pen = self.pen;
}

pub fn restoreCursor(self: *Screen) void {
    self.moveTo(self.saved_cursor.x, self.saved_cursor.y);
    self.pen = self.saved_pen;
}

/// The alternate screen: full-screen programs draw there and the main
/// screen (and its scrollback) comes back untouched when they exit.
pub fn setAltScreen(self: *Screen, on: bool, save_cursor: bool) void {
    if (on == self.alt_active) return;
    if (on and save_cursor) self.saveCursor();
    std.mem.swap([][]Cell, &self.grid, &self.other_grid);
    self.alt_active = on;
    if (on) for (self.grid) |l| @memset(l, .{});
    if (!on and save_cursor) self.restoreCursor();
    self.scroll_top = 0;
    self.scroll_bottom = self.rows - 1;
}

pub fn reset(self: *Screen) void {
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

test {
    _ = @import("tests/Screen_test.zig");
}
