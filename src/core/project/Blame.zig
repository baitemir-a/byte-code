//! Who last touched each line of a file, from `git blame --porcelain`:
//! the commit, its author, when it was made and its first line of
//! message. The bar at the bottom of the window shows it for the line the
//! cursor is on.
//!
//! Lines typed since the blame was made don't belong to any commit yet:
//! `sourceLine` follows a line back through those edits (or says it is
//! new) by comparing the text blamed with the text now.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Diff = @import("Diff.zig");

const Blame = @This();

pub const hash_len = 40;
/// How much of a hash is shown: git's own short form.
pub const short_hash = 7;

pub const Commit = struct {
    hash: []const u8,
    author: []const u8,
    /// The commit message's first line.
    summary: []const u8,
    /// When the author made it, in seconds since the epoch, and the
    /// offset of the clock they made it by ("+0200" is 120).
    time: i64,
    tz_minutes: i32,

    /// A line that isn't in any commit yet: git gives it a hash of zeros.
    pub fn uncommitted(c: Commit) bool {
        for (c.hash) |ch| if (ch != '0') return false;
        return true;
    }

    pub fn shortHash(c: Commit) []const u8 {
        return c.hash[0..@min(short_hash, c.hash.len)];
    }
};

/// How long ago something was, in the largest unit that fits.
pub const Age = struct {
    pub const Unit = enum { just_now, minutes, hours, days, months, years };
    unit: Unit,
    count: u32,
};

gpa: Allocator,
/// The strings of `commits` live here.
arena: std.heap.ArenaAllocator,
commits: std.ArrayList(Commit) = .empty,
/// Which commit each line of the blamed text belongs to.
line_commit: std.ArrayList(u32) = .empty,
/// Commits by hash, to tie the porcelain's repeated headers together.
by_hash: std.StringHashMapUnmanaged(u32) = .empty,
/// The file this is for, and the text that was blamed: edits since are
/// diffed against it so the lines still line up.
file: ?[]u8 = null,
text: std.ArrayList(u8) = .empty,
text_lines: std.ArrayList([]const u8) = .empty,
/// The edits between the blamed text and the buffer, and the version of
/// the buffer they were worked out for.
edits: std.ArrayList(Diff.Hunk) = .empty,
edits_version: ?u64 = null,

pub fn init(gpa: Allocator) Blame {
    return .{ .gpa = gpa, .arena = .init(gpa) };
}

pub fn deinit(self: *Blame) void {
    self.commits.deinit(self.gpa);
    self.line_commit.deinit(self.gpa);
    self.by_hash.deinit(self.gpa);
    self.text.deinit(self.gpa);
    self.text_lines.deinit(self.gpa);
    self.edits.deinit(self.gpa);
    if (self.file) |f| self.gpa.free(f);
    self.arena.deinit();
}

pub fn clear(self: *Blame) void {
    self.commits.clearRetainingCapacity();
    self.line_commit.clearRetainingCapacity();
    self.by_hash.clearRetainingCapacity();
    self.text.clearRetainingCapacity();
    self.text_lines.clearRetainingCapacity();
    self.edits.clearRetainingCapacity();
    self.edits_version = null;
    if (self.file) |f| self.gpa.free(f);
    self.file = null;
    _ = self.arena.reset(.retain_capacity);
}

pub fn isFor(self: *const Blame, path: []const u8) bool {
    const p = self.file orelse return false;
    return std.mem.eql(u8, p, path);
}

pub fn isEmpty(self: *const Blame) bool {
    return self.line_commit.items.len == 0;
}

/// Takes the output of `git blame --porcelain` for `path`, whose contents
/// were `text`.
pub fn set(self: *Blame, path: []const u8, text: []const u8, porcelain: []const u8) !void {
    const copy = try self.gpa.dupe(u8, path);
    self.clear();
    self.file = copy;
    try self.text.appendSlice(self.gpa, text);
    try splitLines(self.gpa, &self.text_lines, self.text.items);
    try self.parse(porcelain);
}

/// Nothing to show for this file — it isn't in a repository, or git
/// couldn't blame it — and no reason to ask again.
pub fn setEmpty(self: *Blame, path: []const u8) !void {
    const copy = try self.gpa.dupe(u8, path);
    self.clear();
    self.file = copy;
}

/// The commit a line of the buffer belongs to, or null when the line was
/// typed since the blame was made (or is past the end of the file).
pub fn at(self: *const Blame, line: usize) ?Commit {
    const source = self.sourceLine(line) orelse return null;
    if (source >= self.line_commit.items.len) return null;
    return self.commits.items[self.line_commit.items[source]];
}

/// Keeps the blame lined up with a buffer that has been edited since:
/// `text` is the buffer's, `version` its `Buffer.version`.
pub fn follow(self: *Blame, text: []const u8, version: u64) !void {
    if (self.edits_version == version) return;
    self.edits_version = version;
    self.edits.clearRetainingCapacity();
    if (self.file == null) return;
    if (std.mem.eql(u8, self.text.items, text)) return; // nothing typed since
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(self.gpa);
    try splitLines(self.gpa, &lines, text);
    try Diff.compare(self.gpa, self.text_lines.items, lines.items, &self.edits);
}

/// The line of the blamed text a line of the buffer came from; null for a
/// line that was typed since.
pub fn sourceLine(self: *const Blame, line: usize) ?u32 {
    const at_line: u32 = @intCast(line);
    var delta: i64 = 0;
    for (self.edits.items) |h| {
        if (h.new_start > at_line) break;
        if (at_line < h.new_start + h.new_len) return null; // typed since
        delta += @as(i64, h.old_len) - @as(i64, h.new_len);
    }
    const source = @as(i64, at_line) + delta;
    if (source < 0) return null;
    return @intCast(source);
}

// ------------------------------------------------------------- parsing

/// Reads `git blame --porcelain`: a header line of "<hash> <old> <new>"
/// starts every line, followed by the commit's details the first time it
/// is seen, and then the line's own text after a tab.
fn parse(self: *Blame, out: []const u8) !void {
    const alloc = self.arena.allocator();
    var current: ?u32 = null;
    var at_line: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] == '\t') {
            // The line's own text: it belongs to the commit just read.
            if (current) |c| {
                if (self.line_commit.items.len <= at_line) try self.line_commit.resize(self.gpa, at_line + 1);
                self.line_commit.items[at_line] = c;
            }
            continue;
        }
        if (hashHeader(line)) |header| {
            at_line = header.line -| 1;
            current = self.by_hash.get(header.hash) orelse blk: {
                const hash = try alloc.dupe(u8, header.hash);
                try self.commits.append(self.gpa, .{ .hash = hash, .author = "", .summary = "", .time = 0, .tz_minutes = 0 });
                const index: u32 = @intCast(self.commits.items.len - 1);
                try self.by_hash.put(self.gpa, hash, index);
                break :blk index;
            };
            continue;
        }
        const c = current orelse continue;
        const commit = &self.commits.items[c];
        if (field(line, "author")) |v| {
            commit.author = try alloc.dupe(u8, v);
        } else if (field(line, "author-time")) |v| {
            commit.time = std.fmt.parseInt(i64, v, 10) catch 0;
        } else if (field(line, "author-tz")) |v| {
            commit.tz_minutes = parseTimeZone(v);
        } else if (field(line, "summary")) |v| {
            commit.summary = try alloc.dupe(u8, v);
        }
    }
}

/// "<40 hex> <line in the original> <line in the file> [<how many>]".
fn hashHeader(line: []const u8) ?struct { hash: []const u8, line: usize } {
    if (line.len < hash_len + 2 or line[hash_len] != ' ') return null;
    for (line[0..hash_len]) |c| if (!std.ascii.isHex(c)) return null;
    var fields = std.mem.tokenizeScalar(u8, line[hash_len + 1 ..], ' ');
    _ = fields.next() orelse return null; // the line in the commit's copy
    const final = fields.next() orelse return null;
    return .{ .hash = line[0..hash_len], .line = std.fmt.parseInt(usize, final, 10) catch return null };
}

/// The value of a "<name> <value>" header line.
fn field(line: []const u8, name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, name)) return null;
    if (line.len <= name.len or line[name.len] != ' ') return null;
    return line[name.len + 1 ..];
}

/// "+0200" as minutes east of UTC.
fn parseTimeZone(tz: []const u8) i32 {
    if (tz.len < 5) return 0;
    const hours = std.fmt.parseInt(i32, tz[1..3], 10) catch return 0;
    const minutes = std.fmt.parseInt(i32, tz[3..5], 10) catch return 0;
    const east = hours * 60 + minutes;
    return if (tz[0] == '-') -east else east;
}

fn splitLines(gpa: Allocator, out: *std.ArrayList([]const u8), text: []const u8) !void {
    out.clearRetainingCapacity();
    if (text.len == 0) return;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try out.append(gpa, line);
    if (text[text.len - 1] == '\n') _ = out.pop();
}

// ---------------------------------------------------------------- time

/// How long ago `then` was, in the largest unit that fits (a month is
/// taken as 30 days, a year as 365).
pub fn age(now: i64, then: i64) Age {
    const seconds = @max(0, now - then);
    const minutes = @divFloor(seconds, 60);
    if (minutes < 1) return .{ .unit = .just_now, .count = 0 };
    const hours = @divFloor(minutes, 60);
    if (hours < 1) return .{ .unit = .minutes, .count = @intCast(minutes) };
    const days = @divFloor(hours, 24);
    if (days < 1) return .{ .unit = .hours, .count = @intCast(hours) };
    const months = @divFloor(days, 30);
    if (months < 1) return .{ .unit = .days, .count = @intCast(days) };
    const years = @divFloor(days, 365);
    if (years < 1) return .{ .unit = .months, .count = @intCast(months) };
    return .{ .unit = .years, .count = @intCast(years) };
}

/// "2026-09-23 14:05 +0200": the date and time the author's own clock
/// showed. Writes into `buf`, which needs 22 bytes.
pub fn formatTime(buf: []u8, time: i64, tz_minutes: i32) []const u8 {
    const local = time + @as(i64, tz_minutes) * 60;
    if (local < 0) return "";
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(local) };
    const day = epoch.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const clock = epoch.getDaySeconds();
    const sign: u8 = if (tz_minutes < 0) '-' else '+';
    const offset: u32 = @intCast(@abs(tz_minutes));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} {c}{d:0>2}{d:0>2}", .{
        day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        clock.getHoursIntoDay(),
        clock.getMinutesIntoHour(),
        sign,
        offset / 60,
        offset % 60,
    }) catch "";
}

test {
    _ = @import("tests/Blame_test.zig");
}
