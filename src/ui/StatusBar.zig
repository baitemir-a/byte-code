//! The bar along the bottom of the window: the branch and how far it is
//! from its remote on the left, then who last touched the line the cursor
//! is on (author, how long ago, the commit and its message), and where the
//! cursor is at the right end. Hovering the blame shows the commit's exact
//! date and time; the branch picks another one and the counters beside it
//! push and pull.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("theme/lib/theme.zig");
const Font = @import("Font.zig");
const Icons = @import("Icons.zig");

const StatusBar = @This();

pub const height: f32 = theme.line_height + 8;
const pad: f32 = 12;
/// Space around the "·" between the parts.
const gap: f32 = 8;
/// Space around an icon and between it and what it labels.
const icon_gap: f32 = 6;

/// What git says about the line the cursor is on. The strings are made
/// fresh each frame by the caller.
pub const Blame = struct {
    author: []const u8,
    /// How long ago, in the interface's language ("3 d ago").
    age: []const u8,
    /// The short commit hash, empty for a line that isn't committed yet.
    hash: []const u8,
    summary: []const u8,
    /// The date and time the popup shows.
    exact: []const u8,
};

/// Git's side of the bar, as it stands this frame.
pub const Branch = struct {
    name: []const u8,
    /// Commits this branch has that its upstream doesn't, and the other
    /// way round.
    ahead: u32,
    behind: u32,
    /// Without a remote branch there is nothing to compare with: the
    /// counter offers to publish this one instead.
    has_upstream: bool,
    /// A push, pull or fetch is running: the counters can't be clicked.
    busy: bool,
};

/// What the branch and its counters answer to.
pub const Hit = enum { branch, sync };

rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
/// The branch's name and its counters ("2↓ 1↑"), made by `layout` and
/// kept until the frame is drawn. Empty outside a repository.
name_buf: [96]u8 = undefined,
name_len: usize = 0,
counts_buf: [24]u8 = undefined,
counts_len: usize = 0,
branch_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
sync_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
sync_busy: bool = false,

/// The bar sits across the bottom; everything else is laid out above it.
/// The branch takes the left end, so the blame starts after it.
pub fn layout(self: *StatusBar, window: rl.Vector2, font: Font, git: ?Branch) void {
    self.rect = .{ .x = 0, .y = window.y - height, .width = window.x, .height = height };
    self.name_len = 0;
    self.counts_len = 0;
    self.branch_rect = std.mem.zeroes(rl.Rectangle);
    self.sync_rect = std.mem.zeroes(rl.Rectangle);
    const b = git orelse return;
    self.sync_busy = b.busy;

    const name = b.name[0..@min(b.name.len, self.name_buf.len)];
    @memcpy(self.name_buf[0..name.len], name);
    self.name_len = name.len;
    // "2↓ 1↑", either half on its own, or "↑" for a branch with no remote
    // yet, which the counter publishes.
    var buf: [24]u8 = undefined;
    const text: []const u8 = if (!b.has_upstream)
        "↑"
    else if (b.behind > 0 and b.ahead > 0)
        std.fmt.bufPrint(&buf, "{d}↓ {d}↑", .{ b.behind, b.ahead }) catch ""
    else if (b.behind > 0)
        std.fmt.bufPrint(&buf, "{d}↓", .{b.behind}) catch ""
    else if (b.ahead > 0)
        std.fmt.bufPrint(&buf, "{d}↑", .{b.ahead}) catch ""
    else
        "";
    self.counts_len = @min(text.len, self.counts_buf.len);
    @memcpy(self.counts_buf[0..self.counts_len], text[0..self.counts_len]);

    const icon = Icons.Size.small.px();
    self.branch_rect = .{
        .x = self.rect.x + pad,
        .y = self.rect.y,
        .width = icon + icon_gap + font.textWidth(self.branch()),
        .height = height,
    };
    self.sync_rect = .{
        .x = self.branch_rect.x + self.branch_rect.width + gap + icon_gap,
        .y = self.rect.y,
        .width = icon + (if (self.counts_len > 0) icon_gap + font.textWidth(self.counts()) else 0),
        .height = height,
    };
}

pub fn branch(self: *const StatusBar) []const u8 {
    return self.name_buf[0..self.name_len];
}

fn counts(self: *const StatusBar) []const u8 {
    return self.counts_buf[0..self.counts_len];
}

pub fn contains(self: *const StatusBar, p: rl.Vector2) bool {
    return rl.checkCollisionPointRec(p, self.rect);
}

/// The branch or its counters under a point, for the cursor and clicks.
pub fn hit(self: *const StatusBar, p: rl.Vector2) ?Hit {
    if (self.name_len == 0) return null;
    if (rl.checkCollisionPointRec(p, self.branch_rect)) return .branch;
    if (rl.checkCollisionPointRec(p, self.sync_rect)) return .sync;
    return null;
}

pub fn draw(self: *const StatusBar, font: Font, blame: ?Blame, position: []const u8) void {
    const r = self.rect;
    rl.drawRectangleRec(r, theme.tab_bar_background);
    rl.drawRectangleRec(.{ .x = r.x, .y = r.y, .width = r.width, .height = 1 }, theme.sidebar_border);
    const y = r.y + (height - theme.font_size) / 2;

    // Where the cursor is, at the right end.
    const position_w = font.textWidth(position);
    const right = r.x + r.width - pad;
    _ = font.drawFit(position, right - position_w, y, right, theme.popup_detail);

    const text_left = drawBranch(self, font, y);
    const b = blame orelse return;
    const end = right - position_w - 2 * gap;
    var x = text_left;
    x = font.drawFit(b.author, x, y, end, theme.foreground);
    x = separator(font, x, y, end);
    x = font.drawFit(b.age, x, y, end, theme.popup_detail);
    if (b.hash.len > 0) {
        x = separator(font, x, y, end);
        x = font.drawFit(b.hash, x, y, end, theme.git_renamed);
    }
    if (b.summary.len > 0) {
        x = separator(font, x, y, end);
        x = font.drawFit(b.summary, x, y, end, theme.popup_detail);
    }
    // The date hangs off the blame text: everything up to where it ends.
    const over_text: rl.Rectangle = .{ .x = text_left, .y = r.y, .width = @max(0, @min(x, end) - text_left), .height = height };
    if (rl.checkCollisionPointRec(rl.getMousePosition(), over_text)) drawPopup(font, r, b.exact);
}

/// The branch at the left end, with the counter that pushes and pulls
/// beside it. Returns where the rest of the bar can start.
fn drawBranch(self: *const StatusBar, font: Font, y: f32) f32 {
    if (self.name_len == 0) return self.rect.x + pad;
    const mouse = rl.getMousePosition();
    const mid = self.rect.y + height / 2;
    const half = Icons.Size.small.px() / 2;

    const on_branch = rl.checkCollisionPointRec(mouse, self.branch_rect);
    const branch_color = theme.copy(if (on_branch) theme.foreground else theme.popup_detail);
    font.drawIcon(.git_branch, .{ .x = self.branch_rect.x + half, .y = mid }, .small, branch_color);
    const name_x = self.branch_rect.x + 2 * half + icon_gap;
    _ = font.drawFit(self.branch(), name_x, y, self.branch_rect.x + self.branch_rect.width, branch_color);

    // Nothing to send or take in, and no remote yet: the counter is still
    // there to push to one.
    const on_sync = rl.checkCollisionPointRec(mouse, self.sync_rect);
    const sync_color = theme.copy(if (self.sync_busy)
        theme.popup_border
    else if (on_sync)
        theme.foreground
    else if (self.counts_len > 0)
        theme.accent
    else
        theme.popup_detail);
    font.drawIcon(.refresh_cw, .{ .x = self.sync_rect.x + half, .y = mid }, .small, sync_color);
    if (self.counts_len > 0) {
        _ = font.drawFit(self.counts(), self.sync_rect.x + 2 * half + icon_gap, y, self.sync_rect.x + self.sync_rect.width, sync_color);
    }
    return self.sync_rect.x + self.sync_rect.width + 2 * gap;
}

fn separator(font: Font, x: f32, y: f32, end: f32) f32 {
    if (x + gap >= end) return x;
    font.drawCodepoint('·', x + gap, y, theme.popup_border);
    return x + 2 * gap + font.cell_width;
}

/// The commit's exact date and time, in a box that sits on top of the
/// bar so it doesn't cover what the bar says.
fn drawPopup(font: Font, bar: rl.Rectangle, text: []const u8) void {
    if (text.len == 0) return;
    const window_width = @as(f32, @floatFromInt(rl.getScreenWidth())) / theme.zoom;
    const w = font.textWidth(text) + 16;
    const x = std.math.clamp(rl.getMousePosition().x - w / 2, 4, @max(4, window_width - w - 4));
    const r: rl.Rectangle = .{ .x = x, .y = bar.y - theme.line_height - 6, .width = w, .height = theme.line_height };
    rl.drawRectangleRec(.{ .x = r.x + 2, .y = r.y + 3, .width = r.width, .height = r.height }, theme.popup_shadow);
    rl.drawRectangleRec(r, theme.popup_background);
    rl.drawRectangleLinesEx(r, 1, theme.popup_border);
    _ = font.drawFit(text, r.x + 8, r.y + (theme.line_height - theme.font_size) / 2, r.x + r.width - 4, theme.foreground);
}
