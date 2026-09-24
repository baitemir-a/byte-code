//! Who last touched the line the cursor is on: `git blame` for the file
//! being edited, kept lined up with the buffer, and the text the bar at
//! the bottom of the window shows.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const App = @import("../App.zig");
const Tab = @import("../Tab.zig");
const StatusBar = @import("../../ui/StatusBar.zig");
const i18n = @import("../../i18n/i18n.zig");

/// A file bigger than this isn't blamed: git would take long enough over
/// it to be felt, and the bar isn't worth that.
const max_size = 4 * 1024 * 1024;
/// git is asked once the file has been open (or saved) this long, so
/// flipping through tabs doesn't start a blame for each one.
const settle_seconds = 0.3;
/// Lines are followed through edits once typing pauses.
const follow_seconds = 0.2;

/// Keeps the active tab's blame up to date; called once a frame.
pub fn updateBlame(self: *App) !void {
    const t = self.tab();
    if (t.kind != .file) return;
    const path = t.document.path orelse return t.blame.clear();
    const now = rl.getTime();
    if (self.blame_dirty) {
        self.blame_dirty = false;
        t.blame_at = 0; // start waiting again
    }
    if (!t.blame.isFor(path) or t.blame_at != 0) {
        // Wait for the file to settle, so flipping through tabs doesn't
        // start a blame for each one.
        if (t.blame_at == 0) {
            t.blame_at = now;
            return;
        }
        if (now - t.blame_at < settle_seconds) return;
        t.blame_at = 0;
        try read(self, t, path);
        return;
    }
    if (t.blame.edits_version != t.buffer.version and now - t.changed_at > follow_seconds) {
        try t.blame.follow(t.buffer.items(), t.buffer.version);
    }
}

/// Asks git who last touched each line of the file as it is on disk.
fn read(self: *App, t: *Tab, path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse ".";
    const found = try core.Git.topLevel(self.gpa, self.io, dir);
    const repo = found orelse return t.blame.setEmpty(path);
    defer self.gpa.free(repo);
    const under = try relativePath(self.gpa, repo, path);
    const rel = under orelse return t.blame.setEmpty(path);
    defer self.gpa.free(rel);

    // The blame is of the file on disk: the buffer is only that too when
    // it has no unsaved changes.
    const saved: ?[]u8 = if (t.isDirty())
        std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(max_size)) catch null
    else
        null;
    defer if (saved) |s| self.gpa.free(s);
    const text = saved orelse t.buffer.items();
    if (text.len > max_size) return t.blame.setEmpty(path);

    const porcelain = try core.Git.blame(self.gpa, self.io, repo, rel);
    defer if (porcelain) |p| self.gpa.free(p);
    const out = porcelain orelse return t.blame.setEmpty(path);
    try t.blame.set(path, text, out);
    try t.blame.follow(t.buffer.items(), t.buffer.version);
}

/// Where a file sits inside its repository, '/' separated as git wants it.
fn relativePath(gpa: std.mem.Allocator, repo: []const u8, path: []const u8) !?[]u8 {
    const slashed = try gpa.dupe(u8, path);
    defer gpa.free(slashed);
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, slashed, std.fs.path.sep, '/');
    const top = std.mem.trimEnd(u8, repo, "/");
    if (slashed.len <= top.len + 1 or slashed[top.len] != '/') return null;
    if (!std.mem.eql(u8, slashed[0..top.len], top)) return null;
    return try gpa.dupe(u8, slashed[top.len + 1 ..]);
}

/// What the bar shows for the line the cursor is on. The strings are
/// written into the caller's buffers, so they last as long as the frame.
pub fn blameAt(self: *const App, age_buf: []u8, exact_buf: []u8) ?StatusBar.Blame {
    const t = self.activeTab();
    if (t.kind != .file or t.blame.isEmpty()) return null;
    const line = lineAtCursor(t);
    const commit = t.blame.at(line) orelse return null;
    const s = i18n.tr().status;
    if (commit.uncommitted()) return .{ .author = s.uncommitted, .age = "", .hash = "", .summary = "", .exact = "" };
    const ago = core.Blame.age(nowSeconds(self.io), commit.time);
    const unit = switch (ago.unit) {
        .just_now => s.just_now,
        .minutes => s.minutes,
        .hours => s.hours,
        .days => s.days,
        .months => s.months,
        .years => s.years,
    };
    return .{
        .author = commit.author,
        .age = if (ago.unit == .just_now) unit else i18n.fill(age_buf, unit, .{ago.count}),
        .hash = commit.shortHash(),
        .summary = commit.summary,
        .exact = core.Blame.formatTime(exact_buf, commit.time, commit.tz_minutes),
    };
}

/// What goes at the end of the cursor's line: who changed it last, when,
/// and why. Nothing while typing (it would jump about), over a
/// selection, or with Settings' inline blame off. Written into `buf`.
pub fn inlineBlame(self: *const App, buf: []u8) ?[]const u8 {
    if (!self.settings.inline_blame) return null;
    const t = self.activeTab();
    if (t.kind != .file or t.buffer.selection() != null) return null;
    if (rl.getTime() - t.changed_at < 0.8) return null;
    var age_buf: [64]u8 = undefined;
    var exact_buf: [32]u8 = undefined;
    const b = self.blameAt(&age_buf, &exact_buf) orelse return null;
    if (b.age.len == 0) return b.author; // not committed yet
    return std.fmt.bufPrint(buf, "{s}, {s} • {s}", .{ b.author, b.age, b.summary }) catch null;
}

/// "Ln 12, Col 3" at the right end of the bar.
pub fn cursorPosition(self: *const App, buf: []u8) []const u8 {
    const t = self.activeTab();
    if (t.kind != .file and t.kind != .diff) return "";
    const b = &t.buffer;
    return i18n.fill(buf, i18n.tr().status.line_column, .{ b.lineIndex(b.cursor) + 1, b.column(b.cursor) + 1 });
}

/// The wall clock, in seconds since the epoch.
fn nowSeconds(io: std.Io) i64 {
    const ts = std.Io.Timestamp.now(io, .real);
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
}

fn lineAtCursor(t: *const Tab) usize {
    return t.buffer.lineIndex(t.buffer.cursor);
}
