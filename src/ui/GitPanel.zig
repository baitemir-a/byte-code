//! The sidebar's Git view: the branch, a commit message box, and the
//! changed files: staged ones (− to unstage) and the rest (+ to stage).
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("theme.zig");
const Font = @import("Font.zig");
const TextField = @import("TextField.zig");
const file_icon = @import("file_icon.zig");

const Git = core.Git;
const GitPanel = @This();

const row_height = theme.line_height;
const pad: f32 = 8;
const action_size: f32 = 20;

/// What a click hit.
pub const Hit = union(enum) {
    message,
    commit,
    stage_all,
    unstage_all,
    /// A file row: open it.
    open: u32,
    stage: u32,
    unstage: u32,
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

pub fn init(gpa: std.mem.Allocator) GitPanel {
    return .{ .message = .init(gpa) };
}

pub fn deinit(self: *GitPanel) void {
    self.message.deinit();
}

fn counts(git: *const Git) struct { staged: usize, changes: usize } {
    var s: usize = 0;
    var c: usize = 0;
    for (git.entries.items) |e| {
        if (e.isStaged()) s += 1;
        if (e.isUnstaged()) c += 1;
    }
    return .{ .staged = s, .changes = c };
}

/// Row `n` of the list (headers only for non-empty sections).
fn rowAtIndex(git: *const Git, n: usize) ?Row {
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

fn listTop(self: *const GitPanel) f32 {
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

/// The + / − button at the right of a row.
fn actionRect(self: *const GitPanel, y: f32) rl.Rectangle {
    return .{ .x = self.rect.x + self.rect.width - pad - 16 - action_size, .y = y + (row_height - action_size) / 2, .width = action_size, .height = action_size };
}

pub fn hitTest(self: *const GitPanel, git: *const Git, p: rl.Vector2) ?Hit {
    if (!rl.checkCollisionPointRec(p, self.rect) or git.state != .ok) return null;
    if (rl.checkCollisionPointRec(p, self.field_rect)) return .message;
    if (rl.checkCollisionPointRec(p, self.commit_rect)) return .commit;
    if (p.y < self.listTop()) return null;
    const n: usize = @intFromFloat((p.y - self.listTop() + self.scroll) / row_height);
    const row = rowAtIndex(git, n) orelse return null;
    const y = self.listTop() + @as(f32, @floatFromInt(n)) * row_height - self.scroll;
    const on_action = rl.checkCollisionPointRec(p, self.actionRect(y));
    return switch (row) {
        .header => |s| if (on_action) (if (s == .staged) Hit.unstage_all else Hit.stage_all) else null,
        .entry => |e| if (on_action) (if (e.section == .staged) Hit{ .unstage = e.index } else Hit{ .stage = e.index }) else .{ .open = e.index },
    };
}

pub fn draw(self: *const GitPanel, git: *const Git, font: Font, focused: bool, show_caret: bool, has_project: bool) void {
    const r = self.rect;
    theme.clip(r);
    defer rl.endScissorMode();
    const ty0 = r.y + pad + (row_height - theme.font_size) / 2 - 4;

    const message: ?[]const u8 = if (!has_project)
        "Open a folder to see its Git changes"
    else switch (git.state) {
        .ok => null,
        .unknown => "Loading...",
        .not_a_repository => "This folder isn't a Git repository",
        .no_git => "Git isn't installed",
    };
    if (message) |m| {
        _ = font.drawFit(m, r.x + pad, ty0, r.x + r.width - pad, theme.popup_detail);
        return;
    }

    var branch_buf: [128]u8 = undefined;
    const branch = std.fmt.bufPrint(&branch_buf, "On branch {s}", .{git.branch}) catch "";
    _ = font.drawFit(branch, r.x + pad, ty0, r.x + r.width - pad, theme.popup_detail);

    self.message.draw(self.field_rect, font, "Commit message", focused, show_caret);
    const c = counts(git);
    const can_commit = c.staged > 0;
    const mouse = rl.getMousePosition();
    const hov = can_commit and rl.checkCollisionPointRec(mouse, self.commit_rect);
    rl.drawRectangleRounded(self.commit_rect, 0.2, 8, if (can_commit) (if (hov) theme.accentDim(0.8) else theme.accent) else theme.popup_border);
    var label_buf: [32]u8 = undefined;
    const label = if (can_commit) std.fmt.bufPrint(&label_buf, "Commit ({d})", .{c.staged}) catch "Commit" else "Nothing staged";
    const lw = @as(f32, @floatFromInt(label.len)) * font.cell_width;
    _ = font.drawFit(label, self.commit_rect.x + (self.commit_rect.width - lw) / 2, self.commit_rect.y + (self.commit_rect.height - theme.font_size) / 2, self.commit_rect.x + self.commit_rect.width, if (can_commit) theme.background else theme.popup_detail);

    if (git.entries.items.len == 0) {
        _ = font.drawFit("No changes", r.x + pad, self.listTop() + (row_height - theme.font_size) / 2, r.x + r.width - pad, theme.popup_detail);
        return;
    }

    const top = self.listTop();
    theme.clip(.{ .x = r.x, .y = top, .width = r.width, .height = r.y + r.height - top });
    var n: usize = 0;
    while (rowAtIndex(git, n)) |row| : (n += 1) {
        const y = top + @as(f32, @floatFromInt(n)) * row_height - self.scroll;
        if (y + row_height < top) continue;
        if (y > r.y + r.height) break;
        const ty = y + (row_height - theme.font_size) / 2;
        const row_hovered = mouse.y >= y and mouse.y < y + row_height and mouse.x >= r.x and mouse.x < r.x + r.width;
        if (row_hovered) rl.drawRectangleRec(.{ .x = r.x, .y = y, .width = r.width, .height = row_height }, theme.sidebar_hover);
        switch (row) {
            .header => |s| {
                var hbuf: [48]u8 = undefined;
                const title = std.fmt.bufPrint(&hbuf, "{s} ({d})", .{ if (s == .staged) "STAGED CHANGES" else "CHANGES", if (s == .staged) c.staged else c.changes }) catch "";
                _ = font.drawFit(title, r.x + pad, ty, r.x + r.width - pad - action_size - 20, theme.sidebar_header);
                if (row_hovered) drawAction(self.actionRect(y), s == .changes, mouse);
            },
            .entry => |e| {
                const entry = git.entries.items[e.index];
                const letter = if (e.section == .staged) entry.staged else entry.unstaged;
                const base = if (std.mem.lastIndexOfScalar(u8, entry.path, '/')) |i| i + 1 else 0;
                const status_x = r.x + r.width - pad - font.cell_width;
                const text_end = if (row_hovered) self.actionRect(y).x - 4 else status_x - 8;
                file_icon.draw(entry.path[base..], .{ .x = r.x + pad + 10 + file_icon.radius, .y = y + row_height / 2 });
                const x = font.drawFit(entry.path[base..], r.x + pad + 10 + file_icon.radius * 2 + 8, ty, text_end, theme.foreground);
                if (base > 0) _ = font.drawFit(entry.path[0 .. base - 1], x + font.cell_width, ty, text_end, theme.popup_detail);
                font.drawCodepoint(if (letter == '?') 'U' else letter, status_x, ty, statusColor(letter));
                if (row_hovered) drawAction(self.actionRect(y), e.section == .changes, mouse);
            },
        }
    }
}

/// "+" (stage) or "−" (unstage) button.
fn drawAction(b: rl.Rectangle, plus: bool, mouse: rl.Vector2) void {
    if (rl.checkCollisionPointRec(mouse, b)) rl.drawRectangleRounded(b, 0.3, 6, theme.tab_close_hover);
    const c: rl.Vector2 = .{ .x = b.x + b.width / 2, .y = b.y + b.height / 2 };
    rl.drawLineEx(.{ .x = c.x - 5, .y = c.y }, .{ .x = c.x + 5, .y = c.y }, 1.6, theme.foreground);
    if (plus) rl.drawLineEx(.{ .x = c.x, .y = c.y - 5 }, .{ .x = c.x, .y = c.y + 5 }, 1.6, theme.foreground);
}

fn statusColor(letter: u8) rl.Color {
    return switch (letter) {
        'M' => theme.git_modified,
        'A', '?' => theme.git_added,
        'D' => theme.git_deleted,
        'R', 'C' => theme.git_renamed,
        else => theme.popup_detail,
    };
}
