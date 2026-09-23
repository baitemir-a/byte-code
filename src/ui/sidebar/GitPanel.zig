//! The sidebar's Git view: the branch, a commit message box, and the
//! changed files: staged ones (− to unstage) and the rest (+ to stage,
//! ↺ to throw the changes away).
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");
const TextField = @import("../widgets/TextField.zig");
const file_icon = @import("../widgets/lib/file_icon.zig");
const GitPanel_draw = @import("GitPanel_draw.zig");

const Git = core.Git;
const GitPanel = @This();

const row_height = theme.line_height;
pub const pad: f32 = 8;
pub const action_size: f32 = 20;

/// What a click hit.
pub const Hit = union(enum) {
    message,
    commit,
    stage_all,
    unstage_all,
    /// A file row: show what changed in it. `staged` tells which of the
    /// two lists it is in, and so which changes to show.
    open: struct { index: u32, staged: bool },
    stage: u32,
    unstage: u32,
    /// Throw a file's unstaged changes away, or all of them.
    discard: u32,
    discard_all,
};

/// A row of the file list: a section header or an entry in a section.
const Row = union(enum) {
    header: Section,
    entry: struct { index: u32, section: Section },
};
const Section = enum { staged, changes };

message: TextField,
rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
field_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
commit_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
scroll: f32 = 0,
max_scroll: f32 = 0,

// Drawing, in GitPanel_draw.zig.
pub const draw = GitPanel_draw.draw;

pub fn init(gpa: std.mem.Allocator) GitPanel {
    return .{ .message = .init(gpa) };
}

pub fn deinit(self: *GitPanel) void {
    self.message.deinit();
}

pub fn counts(git: *const Git) struct { staged: usize, changes: usize } {
    var s: usize = 0;
    var c: usize = 0;
    for (git.entries.items) |e| {
        if (e.isStaged()) s += 1;
        if (e.isUnstaged()) c += 1;
    }
    return .{ .staged = s, .changes = c };
}

/// Row `n` of the list (headers only for non-empty sections).
pub fn rowAtIndex(git: *const Git, n: usize) ?Row {
    var i = n;
    for ([_]Section{ .staged, .changes }) |section| {
        const cnt = if (section == .staged) counts(git).staged else counts(git).changes;
        if (cnt == 0) continue;
        if (i == 0) return .{ .header = section };
        i -= 1;
        for (git.entries.items, 0..) |e, idx| {
            const in = if (section == .staged) e.isStaged() else e.isUnstaged();
            if (!in) continue;
            if (i == 0) return .{ .entry = .{ .index = @intCast(idx), .section = section } };
            i -= 1;
        }
    }
    return null;
}

fn rowCount(git: *const Git) usize {
    const c = counts(git);
    return c.staged + c.changes + @intFromBool(c.staged > 0) + @intFromBool(c.changes > 0);
}

pub fn listTop(self: *const GitPanel) f32 {
    return self.commit_rect.y + self.commit_rect.height + 10;
}

pub fn layout(self: *GitPanel, rect: rl.Rectangle, font: Font, git: *const Git) void {
    self.rect = rect;
    const top = rect.y + pad + row_height; // below the branch line
    self.field_rect = .{ .x = rect.x + pad, .y = top, .width = rect.width - 2 * pad, .height = theme.line_height + 8 };
    self.commit_rect = .{ .x = rect.x + pad, .y = top + self.field_rect.height + 6, .width = rect.width - 2 * pad, .height = theme.line_height + 6 };
    self.message.layout(self.field_rect.width, font);
    const content = @as(f32, @floatFromInt(rowCount(git))) * row_height;
    self.max_scroll = @max(0, content - (rect.y + rect.height - self.listTop()));
    self.scroll = std.math.clamp(self.scroll, 0, self.max_scroll);
}

pub fn scrollBy(self: *GitPanel, wheel_y: f32) void {
    self.scroll = std.math.clamp(self.scroll - wheel_y * row_height * 3, 0, self.max_scroll);
}

/// A row's buttons, counted from the right: 0 is + / −, 1 is ↺.
pub fn actionRect(self: *const GitPanel, y: f32, index: usize) rl.Rectangle {
    const from_right = @as(f32, @floatFromInt(index + 1)) * action_size;
    return .{ .x = self.rect.x + self.rect.width - pad - 16 - from_right, .y = y + (row_height - action_size) / 2, .width = action_size, .height = action_size };
}

/// Whether a row offers to throw its changes away: anything in the work
/// tree does. A file git doesn't know yet has no copy to go back to, so
/// for it that means deleting the file.
pub fn canDiscard(e: Git.Entry) bool {
    return e.isUnstaged();
}

/// Whether any row does, so the button is offered on the header too.
pub fn canDiscardAll(git: *const Git) bool {
    for (git.entries.items) |e| if (canDiscard(e)) return true;
    return false;
}

pub fn hitTest(self: *const GitPanel, git: *const Git, p: rl.Vector2) ?Hit {
    if (!rl.checkCollisionPointRec(p, self.rect) or git.state != .ok) return null;
    if (rl.checkCollisionPointRec(p, self.field_rect)) return .message;
    if (rl.checkCollisionPointRec(p, self.commit_rect)) return .commit;
    if (p.y < self.listTop()) return null;
    const n: usize = @intFromFloat((p.y - self.listTop() + self.scroll) / row_height);
    const row = rowAtIndex(git, n) orelse return null;
    const y = self.listTop() + @as(f32, @floatFromInt(n)) * row_height - self.scroll;
    const on_action = rl.checkCollisionPointRec(p, self.actionRect(y, 0));
    const on_discard = rl.checkCollisionPointRec(p, self.actionRect(y, 1));
    return switch (row) {
        .header => |s| if (on_action)
            (if (s == .staged) Hit.unstage_all else Hit.stage_all)
        else if (on_discard and s == .changes and canDiscardAll(git))
            Hit.discard_all
        else
            null,
        .entry => |e| if (on_action)
            (if (e.section == .staged) Hit{ .unstage = e.index } else Hit{ .stage = e.index })
        else if (on_discard and e.section == .changes and canDiscard(git.entries.items[e.index]))
            Hit{ .discard = e.index }
        else
            .{ .open = .{ .index = e.index, .staged = e.section == .staged } },
    };
}
