//! What changed in a file since git last saw it: the lines added, changed
//! and removed between two copies of it. The editor marks them beside the
//! line numbers, the tab that shows a file's changes puts the removed
//! lines back among the others, and one change at a time can be undone,
//! staged or unstaged.
//!
//! The comparison is line by line (Myers' algorithm); the texts come from
//! `Git.showIndex` and `Git.showHead`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Diff = @This();

pub const Kind = enum { added, modified, deleted };

/// Which two copies of the file are compared.
pub const Against = enum {
    /// The file as it is now against what's staged: the changes `git add`
    /// would stage.
    index,
    /// What's staged against the last commit: the changes a commit would
    /// carry.
    head,
    /// A commit against its parent: what it changed (see `setCommit`).
    commit,
};

/// A line of the combined text (see `buildCombined`).
pub const LineKind = enum { context, removed, added };

pub const ViewLine = struct {
    kind: LineKind,
    /// The change it belongs to; null for a line neither side touched.
    hunk: ?u32,
    /// Its line number in the copy it comes from (1-based).
    number: u32,
};

/// A run of changed lines: `old_len` lines of git's copy replaced by
/// `new_len` lines of the buffer. Line numbers are 0-based, and a hunk has
/// lines on at least one of the two sides.
pub const Hunk = struct {
    old_start: u32,
    old_len: u32,
    new_start: u32,
    new_len: u32,

    pub fn kind(h: Hunk) Kind {
        if (h.old_len == 0) return .added;
        if (h.new_len == 0) return .deleted;
        return .modified;
    }
};

/// Lines of context around a change in the patch handed to git.
const patch_context = 3;

/// A file that needs more than this many single-line edits to line up with
/// git's copy isn't worth diffing in detail: it counts as changed as a
/// whole. Keeps the memory Myers' algorithm needs bounded.
const max_edits = 800;

gpa: Allocator,
/// The file being compared (an absolute path), the top folder of its
/// repository, and its path inside that repository ('/' separated). All
/// null until `setFile`; then there is something to compare with.
file: ?[]u8 = null,
repo: ?[]u8 = null,
rel: ?[]u8 = null,
/// Which copies `base` and `new` are.
against: Against = .index,
/// For `.commit`: which one.
commit_hash: [64]u8 = undefined,
commit_len: u8 = 0,
/// The older copy (git's) and its lines. Empty for a file git doesn't
/// know yet, whose every line is then an addition.
base: std.ArrayList(u8) = .empty,
base_lines: std.ArrayList([]const u8) = .empty,
/// The newer copy (the text being edited, or the file on disk) and its
/// lines, kept so a change can be turned into a patch later.
new: std.ArrayList(u8) = .empty,
new_lines: std.ArrayList([]const u8) = .empty,
/// Whether git has the file in its index at all.
tracked: bool = false,
/// git's copy ends its lines with "\r\n"; the buffer always holds "\n"
/// (see Document), so the base is converted on the way in and patches are
/// written back with the carriage returns.
crlf: bool = false,
/// The changes, in line order.
hunks: std.ArrayList(Hunk) = .empty,
/// Lines in the newer copy, so a removal at the end of the file still
/// has a line to mark.
line_count: u32 = 0,
/// The two copies in one text, with the removed lines back where they
/// were, and what each of its lines is. Only for the tab that shows a
/// file's changes; `buildCombined` fills them in.
combined: std.ArrayList(u8) = .empty,
combined_lines: std.ArrayList(ViewLine) = .empty,
/// The combined line each change starts on.
combined_starts: std.ArrayList(u32) = .empty,
/// The `Buffer.version` the hunks were computed for; null when they need
/// computing again.
version: ?u64 = null,

pub fn init(gpa: Allocator) Diff {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Diff) void {
    self.clear();
    self.base.deinit(self.gpa);
    self.base_lines.deinit(self.gpa);
    self.new.deinit(self.gpa);
    self.new_lines.deinit(self.gpa);
    self.combined.deinit(self.gpa);
    self.combined_lines.deinit(self.gpa);
    self.combined_starts.deinit(self.gpa);
    self.hunks.deinit(self.gpa);
}

/// Forgets the file: nothing is marked until another `setFile`.
pub fn clear(self: *Diff) void {
    if (self.file) |p| self.gpa.free(p);
    if (self.repo) |p| self.gpa.free(p);
    if (self.rel) |p| self.gpa.free(p);
    self.file = null;
    self.repo = null;
    self.rel = null;
    self.base.clearRetainingCapacity();
    self.base_lines.clearRetainingCapacity();
    self.new.clearRetainingCapacity();
    self.new_lines.clearRetainingCapacity();
    self.combined.clearRetainingCapacity();
    self.combined_lines.clearRetainingCapacity();
    self.combined_starts.clearRetainingCapacity();
    self.hunks.clearRetainingCapacity();
    self.tracked = false;
    self.crlf = false;
    self.version = null;
    self.commit_len = 0;
}

/// Names the commit a `.commit` diff shows (after `setFile`).
pub fn setCommit(self: *Diff, hash: []const u8) void {
    self.commit_len = @intCast(@min(hash.len, self.commit_hash.len));
    @memcpy(self.commit_hash[0..self.commit_len], hash[0..self.commit_len]);
}

pub fn commit(self: *const Diff) []const u8 {
    return self.commit_hash[0..self.commit_len];
}

/// Whether the diff is for `path` (so its base can be kept).
pub fn isFor(self: *const Diff, path: []const u8) bool {
    const p = self.file orelse return false;
    return std.mem.eql(u8, p, path);
}

/// Names the file to compare, in the repository at `repo` under `rel`,
/// and which two of its copies to compare.
pub fn setFile(self: *Diff, path: []const u8, repo: []const u8, rel: []const u8, against: Against) !void {
    const file_copy = try self.gpa.dupe(u8, path);
    errdefer self.gpa.free(file_copy);
    const repo_copy = try self.gpa.dupe(u8, repo);
    errdefer self.gpa.free(repo_copy);
    const rel_copy = try self.gpa.dupe(u8, rel);
    self.clear();
    self.file = file_copy;
    self.repo = repo_copy;
    self.rel = rel_copy;
    self.against = against;
}

/// Takes git's copy of the file. `tracked` is false when git doesn't have
/// the file yet, so `text` is empty and every line counts as added.
pub fn setBase(self: *Diff, text: []const u8, tracked: bool) !void {
    self.base.clearRetainingCapacity();
    try self.base.appendSlice(self.gpa, text);
    self.crlf = std.mem.indexOf(u8, self.base.items, "\r\n") != null;
    if (self.crlf) self.base.items.len = removeCarriageReturns(self.base.items).len;
    self.tracked = tracked;
    try splitLines(self.gpa, &self.base_lines, self.base.items);
    self.version = null;
}

/// Compares `text` (the newer copy) with git's. `version` is the buffer's
/// it came from, so the result can be reused until that changes.
pub fn compute(self: *Diff, text: []const u8, version: u64) !void {
    self.hunks.clearRetainingCapacity();
    self.version = version;
    self.new.clearRetainingCapacity();
    try self.new.appendSlice(self.gpa, text);
    try splitLines(self.gpa, &self.new_lines, self.new.items);
    self.line_count = @intCast(self.new_lines.items.len);
    if (self.file == null) return;
    try diffLines(self.gpa, self.base_lines.items, self.new_lines.items, &self.hunks);
}

/// Puts both copies in one text: the lines they share, the removed lines
/// where they were, and the added ones after them. That text is what the
/// tab showing a file's changes holds.
pub fn buildCombined(self: *Diff) !void {
    self.combined.clearRetainingCapacity();
    self.combined_lines.clearRetainingCapacity();
    self.combined_starts.clearRetainingCapacity();
    var line: u32 = 0;
    var next: u32 = 0;
    while (line < self.new_lines.items.len or next < self.hunks.items.len) {
        if (next < self.hunks.items.len and self.hunks.items[next].new_start == line) {
            const h = self.hunks.items[next];
            try self.combined_starts.append(self.gpa, @intCast(self.combined_lines.items.len));
            for (0..h.old_len) |i| {
                const at: u32 = h.old_start + @as(u32, @intCast(i));
                try self.appendCombined(.removed, next, at + 1, self.base_lines.items[at]);
            }
            for (0..h.new_len) |_| {
                try self.appendCombined(.added, next, line + 1, self.new_lines.items[line]);
                line += 1;
            }
            next += 1;
            continue;
        }
        try self.appendCombined(.context, null, line + 1, self.new_lines.items[line]);
        line += 1;
    }
}

fn appendCombined(self: *Diff, kind: LineKind, hunk: ?u32, number: u32, text: []const u8) !void {
    try self.combined_lines.append(self.gpa, .{ .kind = kind, .hunk = hunk, .number = number });
    try self.combined.appendSlice(self.gpa, text);
    try self.combined.append(self.gpa, '\n');
}

/// What a line of the combined text is; `.context` for one past its end
/// (a buffer keeps a last empty line the text doesn't have).
pub fn viewLine(self: *const Diff, line: usize) ViewLine {
    if (line >= self.combined_lines.items.len) return .{ .kind = .context, .hunk = null, .number = 0 };
    return self.combined_lines.items[line];
}

/// The buffer line a change is marked on: its first line, or for a
/// removal the line that took the removed lines' place.
pub fn markedLine(self: *const Diff, h: Hunk) u32 {
    if (h.new_len > 0) return h.new_start;
    return @min(h.new_start, self.line_count -| 1);
}

/// The last buffer line the change covers.
pub fn lastLine(self: *const Diff, h: Hunk) u32 {
    if (h.new_len == 0) return self.markedLine(h);
    return h.new_start + h.new_len - 1;
}

/// Whether `line` of the buffer belongs to the change.
pub fn covers(self: *const Diff, h: Hunk, line: usize) bool {
    return line >= self.markedLine(h) and line <= self.lastLine(h);
}

/// The change covering a buffer line, if any.
pub fn hunkAt(self: *const Diff, line: usize) ?u32 {
    const h = self.hunks.items;
    var lo: usize = 0;
    var hi: usize = h.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (self.lastLine(h[mid]) < line) lo = mid + 1 else hi = mid;
    }
    if (lo < h.len and self.covers(h[lo], line)) return @intCast(lo);
    return null;
}

/// The lines a change removed, to show above it.
pub fn removedLines(self: *const Diff, h: Hunk) []const []const u8 {
    if (h.old_len == 0) return &.{};
    return self.base_lines.items[h.old_start..][0..h.old_len];
}

/// git's text for the lines a change replaced, newline included, as it
/// goes back into the buffer when the change is undone.
pub fn removedText(self: *const Diff, h: Hunk) []const u8 {
    if (h.old_len == 0) return "";
    const lines = self.base_lines.items;
    const start = self.offsetOf(lines[h.old_start]);
    const last = lines[h.old_start + h.old_len - 1];
    var end = self.offsetOf(last) + last.len;
    if (end < self.base.items.len) end += 1; // the newline after it
    return self.base.items[start..end];
}

/// Where a line of `base_lines` sits in `base` (they are slices of it).
fn offsetOf(self: *const Diff, line: []const u8) usize {
    return @intFromPtr(line.ptr) - @intFromPtr(self.base.items.ptr);
}

/// A unified diff of one change, as `git apply --cached` wants it, so the
/// change alone can be staged. Caller frees.
pub fn hunkPatch(self: *const Diff, gpa: Allocator, h: Hunk) ![]u8 {
    const rel = self.rel orelse return error.NoPath;
    const base_lines = self.base_lines.items;
    const new_lines = self.new_lines.items;
    // The context around the change is the same on both sides, so it
    // shifts both by the same number of lines.
    const a0 = h.old_start -| patch_context;
    const a1: u32 = @intCast(@min(base_lines.len, h.old_start + h.old_len + patch_context));
    const b0 = h.new_start - (h.old_start - a0);
    const b1 = h.new_start + h.new_len + (a1 - (h.old_start + h.old_len));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "diff --git a/{s} b/{s}\n--- a/{s}\n+++ b/{s}\n", .{ rel, rel, rel, rel });
    // An empty side is numbered by the line before it, not the line itself.
    try out.print(gpa, "@@ -{d},{d} +{d},{d} @@\n", .{
        if (a1 > a0) a0 + 1 else a0,
        a1 - a0,
        if (b1 > b0) b0 + 1 else b0,
        b1 - b0,
    });
    const base_nl = endsWithNewline(self.base.items);
    const new_nl = endsWithNewline(self.new.items);
    for (a0..h.old_start) |i| try self.patchLine(gpa, &out, ' ', base_lines, i, base_nl);
    for (h.old_start..h.old_start + h.old_len) |i| try self.patchLine(gpa, &out, '-', base_lines, i, base_nl);
    for (h.new_start..h.new_start + h.new_len) |i| try self.patchLine(gpa, &out, '+', new_lines, i, new_nl);
    for (h.old_start + h.old_len..a1) |i| try self.patchLine(gpa, &out, ' ', base_lines, i, base_nl);
    return out.toOwnedSlice(gpa);
}

/// One line of a patch. A file whose last line has no newline of its own
/// needs git's note saying so, or the patch won't apply.
fn patchLine(self: *const Diff, gpa: Allocator, out: *std.ArrayList(u8), sign: u8, lines: []const []const u8, i: usize, final_newline: bool) !void {
    try out.append(gpa, sign);
    try out.appendSlice(gpa, lines[i]);
    if (self.crlf) try out.append(gpa, '\r');
    try out.append(gpa, '\n');
    if (i + 1 == lines.len and !final_newline) {
        try out.appendSlice(gpa, "\\ No newline at end of file\n");
    }
}

fn endsWithNewline(text: []const u8) bool {
    return text.len == 0 or text[text.len - 1] == '\n';
}

// ------------------------------------------------------------------ lines

/// Splits into lines without their newline. A final newline ends the last
/// line rather than starting an empty one.
fn splitLines(gpa: Allocator, out: *std.ArrayList([]const u8), text: []const u8) !void {
    out.clearRetainingCapacity();
    if (text.len == 0) return;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try out.append(gpa, line);
    if (text[text.len - 1] == '\n') _ = out.pop();
}

/// Turns "\r\n" into "\n" in place and returns the shortened slice.
fn removeCarriageReturns(bytes: []u8) []u8 {
    var out: usize = 0;
    for (bytes, 0..) |b, i| {
        if (b == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') continue;
        bytes[out] = b;
        out += 1;
    }
    return bytes[0..out];
}

// ------------------------------------------------------------------- diff

/// The changes turning one text's lines into another's, in line order.
/// `Blame` uses it to follow lines through edits.
pub const compare = diffLines;

/// The changes turning `a` into `b`, in line order. The lines shared at
/// the start and the end are skipped first: an edit in the middle of a
/// long file then only costs the part around it.
fn diffLines(gpa: Allocator, a: []const []const u8, b: []const []const u8, out: *std.ArrayList(Hunk)) !void {
    var lo: usize = 0;
    while (lo < a.len and lo < b.len and eql(a[lo], b[lo])) lo += 1;
    var a_end = a.len;
    var b_end = b.len;
    while (a_end > lo and b_end > lo and eql(a[a_end - 1], b[b_end - 1])) {
        a_end -= 1;
        b_end -= 1;
    }
    const mid_a = a[lo..a_end];
    const mid_b = b[lo..b_end];
    if (mid_a.len == 0 and mid_b.len == 0) return;
    // Only added or only removed lines: one change, no searching needed.
    if (mid_a.len == 0 or mid_b.len == 0) return whole(gpa, out, lo, mid_a.len, mid_b.len);
    myers(gpa, mid_a, mid_b, lo, out) catch |err| switch (err) {
        // Too different to line up: the whole middle is the change.
        error.TooManyEdits => {
            out.clearRetainingCapacity();
            return whole(gpa, out, lo, mid_a.len, mid_b.len);
        },
        else => |e| return e,
    };
}

fn whole(gpa: Allocator, out: *std.ArrayList(Hunk), start: usize, old_len: usize, new_len: usize) !void {
    try out.append(gpa, .{
        .old_start = @intCast(start),
        .old_len = @intCast(old_len),
        .new_start = @intCast(start),
        .new_len = @intCast(new_len),
    });
}

fn eql(a: []const u8, b: []const u8) bool {
    return a.len == b.len and std.mem.eql(u8, a, b);
}

/// Myers' diff: the shortest way from `a` to `b`, walked back into the
/// lines the two share. What lies between those is a change. `offset` is
/// the line both sides start at in the whole file.
fn myers(gpa: Allocator, a: []const []const u8, b: []const []const u8, offset: usize, out: *std.ArrayList(Hunk)) !void {
    const n: i32 = @intCast(a.len);
    const m: i32 = @intCast(b.len);
    const cap: i32 = @intCast(@min(a.len + b.len, max_edits));

    // Furthest reach on each diagonal k, indexed k + mid.
    const mid: usize = @intCast(cap + 1);
    const v = try gpa.alloc(i32, 2 * mid + 1);
    defer gpa.free(v);
    @memset(v, 0);
    // What `v` held before each step, to walk the path back afterwards.
    var trace: std.ArrayList([]i32) = .empty;
    defer {
        for (trace.items) |row| gpa.free(row);
        trace.deinit(gpa);
    }

    var d: i32 = 0;
    const steps = found: while (d <= cap) : (d += 1) {
        const width: usize = @intCast(d + 1);
        try trace.append(gpa, try gpa.dupe(i32, v[mid - width .. mid + width + 1]));
        var k: i32 = -d;
        while (k <= d) : (k += 2) {
            const i: usize = @intCast(@as(i32, @intCast(mid)) + k);
            var x = if (k == -d or (k != d and v[i - 1] < v[i + 1])) v[i + 1] else v[i - 1] + 1;
            var y = x - k;
            while (x < n and y < m and eql(a[@intCast(x)], b[@intCast(y)])) {
                x += 1;
                y += 1;
            }
            v[i] = x;
            if (x >= n and y >= m) break :found d;
        }
    } else return error.TooManyEdits;

    // Back along the path, collecting the lines the two sides share.
    var shared: std.ArrayList([2]u32) = .empty;
    defer shared.deinit(gpa);
    var x = n;
    var y = m;
    var step = steps;
    while (step >= 0) : (step -= 1) {
        const row = trace.items[@intCast(step)];
        const width: i32 = step + 1;
        const k = x - y;
        const prev_k: i32 = if (step == 0)
            0
        else if (k == -step or (k != step and rowAt(row, k - 1, width) < rowAt(row, k + 1, width)))
            k + 1
        else
            k - 1;
        const prev_x = if (step == 0) 0 else rowAt(row, prev_k, width);
        const prev_y = prev_x - prev_k;
        while (x > prev_x and y > prev_y) {
            x -= 1;
            y -= 1;
            try shared.append(gpa, .{ @intCast(x), @intCast(y) });
        }
        x = prev_x;
        y = prev_y;
    }
    std.mem.reverse([2]u32, shared.items);

    // Everything between two shared lines is a change.
    var old_at: u32 = 0;
    var new_at: u32 = 0;
    for (shared.items) |s| {
        if (s[0] > old_at or s[1] > new_at) try out.append(gpa, .{
            .old_start = old_at + @as(u32, @intCast(offset)),
            .old_len = s[0] - old_at,
            .new_start = new_at + @as(u32, @intCast(offset)),
            .new_len = s[1] - new_at,
        });
        old_at = s[0] + 1;
        new_at = s[1] + 1;
    }
    if (a.len > old_at or b.len > new_at) try out.append(gpa, .{
        .old_start = old_at + @as(u32, @intCast(offset)),
        .old_len = @as(u32, @intCast(a.len)) - old_at,
        .new_start = new_at + @as(u32, @intCast(offset)),
        .new_len = @as(u32, @intCast(b.len)) - new_at,
    });
}

/// Diagonal `k` of a saved step, which covers -width..width.
fn rowAt(row: []const i32, k: i32, width: i32) i32 {
    if (k < -width or k > width) return 0;
    return row[@intCast(k + width)];
}

test {
    _ = @import("tests/Diff_test.zig");
}
