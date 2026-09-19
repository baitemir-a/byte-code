//! Drawing the Git view: the commit box and button, and the staged and
//! changed files.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");
const file_icon = @import("../widgets/lib/file_icon.zig");
const core = @import("core");
const GitPanel = @import("GitPanel.zig");

const Git = core.Git;
const row_height = theme.line_height;

pub fn draw(self: *const GitPanel, git: *const Git, font: Font, focused: bool, show_caret: bool, has_project: bool) void {
    const r = self.rect;
    theme.clip(r);
    defer rl.endScissorMode();
    const ty0 = r.y + GitPanel.pad + (row_height - theme.font_size) / 2 - 4;

    const message: ?[]const u8 = if (!has_project)
        "Open a folder to see its Git changes"
    else switch (git.state) {
        .ok => null,
        .unknown => "Loading...",
        .not_a_repository => "This folder isn't a Git repository",
        .no_git => "Git isn't installed",
    };
    if (message) |m| {
        _ = font.drawFit(m, r.x + GitPanel.pad, ty0, r.x + r.width - GitPanel.pad, theme.popup_detail);
        return;
    }

    var branch_buf: [128]u8 = undefined;
    const branch = std.fmt.bufPrint(&branch_buf, "On branch {s}", .{git.branch}) catch "";
    _ = font.drawFit(branch, r.x + GitPanel.pad, ty0, r.x + r.width - GitPanel.pad, theme.popup_detail);

    self.message.draw(self.field_rect, font, "Commit message", focused, show_caret);
    const c = GitPanel.counts(git);
    const can_commit = c.staged > 0;
    const mouse = rl.getMousePosition();
    const hov = can_commit and rl.checkCollisionPointRec(mouse, self.commit_rect);
    rl.drawRectangleRounded(self.commit_rect, 0.2, 8, if (can_commit) (if (hov) theme.accentDim(0.8) else theme.accent) else theme.popup_border);
    var label_buf: [32]u8 = undefined;
    const label = if (can_commit) std.fmt.bufPrint(&label_buf, "Commit ({d})", .{c.staged}) catch "Commit" else "Nothing staged";
    const lw = @as(f32, @floatFromInt(label.len)) * font.cell_width;
    _ = font.drawFit(label, self.commit_rect.x + (self.commit_rect.width - lw) / 2, self.commit_rect.y + (self.commit_rect.height - theme.font_size) / 2, self.commit_rect.x + self.commit_rect.width, if (can_commit) theme.background else theme.popup_detail);

    if (git.entries.items.len == 0) {
        _ = font.drawFit("No changes", r.x + GitPanel.pad, self.listTop() + (row_height - theme.font_size) / 2, r.x + r.width - GitPanel.pad, theme.popup_detail);
        return;
    }

    const top = self.listTop();
    theme.clip(.{ .x = r.x, .y = top, .width = r.width, .height = r.y + r.height - top });
    var n: usize = 0;
    while (GitPanel.rowAtIndex(git, n)) |row| : (n += 1) {
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
                _ = font.drawFit(title, r.x + GitPanel.pad, ty, r.x + r.width - GitPanel.pad - GitPanel.action_size - 20, theme.sidebar_header);
                if (row_hovered) drawAction(self.actionRect(y), s == .changes, mouse);
            },
            .entry => |e| {
                const entry = git.entries.items[e.index];
                const letter = if (e.section == .staged) entry.staged else entry.unstaged;
                const base = if (std.mem.lastIndexOfScalar(u8, entry.path, '/')) |i| i + 1 else 0;
                const status_x = r.x + r.width - GitPanel.pad - font.cell_width;
                const text_end = if (row_hovered) self.actionRect(y).x - 4 else status_x - 8;
                file_icon.draw(entry.path[base..], .{ .x = r.x + GitPanel.pad + 10 + file_icon.radius, .y = y + row_height / 2 });
                const x = font.drawFit(entry.path[base..], r.x + GitPanel.pad + 10 + file_icon.radius * 2 + 8, ty, text_end, theme.foreground);
                if (base > 0) _ = font.drawFit(entry.path[0 .. base - 1], x + font.cell_width, ty, text_end, theme.popup_detail);
                font.drawCodepoint(if (letter == '?') 'U' else letter, status_x, ty, statusColor(letter));
                if (row_hovered) drawAction(self.actionRect(y), e.section == .changes, mouse);
            },
        }
    }
}

/// "+" (stage) or "−" (unstage) button.
pub fn drawAction(b: rl.Rectangle, plus: bool, mouse: rl.Vector2) void {
    if (rl.checkCollisionPointRec(mouse, b)) rl.drawRectangleRounded(b, 0.3, 6, theme.tab_close_hover);
    const c: rl.Vector2 = .{ .x = b.x + b.width / 2, .y = b.y + b.height / 2 };
    rl.drawLineEx(.{ .x = c.x - 5, .y = c.y }, .{ .x = c.x + 5, .y = c.y }, 1.6, theme.foreground);
    if (plus) rl.drawLineEx(.{ .x = c.x, .y = c.y - 5 }, .{ .x = c.x, .y = c.y + 5 }, 1.6, theme.foreground);
}

pub fn statusColor(letter: u8) rl.Color {
    return switch (letter) {
        'M' => theme.git_modified,
        'A', '?' => theme.git_added,
        'D' => theme.git_deleted,
        'R', 'C' => theme.git_renamed,
        else => theme.popup_detail,
    };
}
