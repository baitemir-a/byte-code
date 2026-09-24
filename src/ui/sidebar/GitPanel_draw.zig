//! Drawing the Git view: the commit box and button, and the staged and
//! changed files.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");
const file_icon = @import("../widgets/lib/file_icon.zig");
const Icons = @import("../Icons.zig");
const search_controls = @import("../widgets/lib/search_controls.zig");
const core = @import("core");
const GitPanel = @import("GitPanel.zig");
const i18n = @import("../../i18n/i18n.zig");

const Git = core.Git;
const row_height = theme.line_height;

pub fn draw(self: *const GitPanel, git: *const Git, font: Font, focused: bool, prompt_focused: bool, show_caret: bool, has_project: bool) void {
    const r = self.rect;
    theme.clip(r);
    defer rl.endScissorMode();
    const ty0 = r.y + GitPanel.pad + (row_height - theme.font_size) / 2 - 4;

    const t = i18n.tr().git;
    const message: ?[]const u8 = if (!has_project)
        t.open_folder_first
    else switch (git.state) {
        .ok => null,
        .unknown => t.loading,
        .not_a_repository => t.not_a_repository,
        .no_git => t.not_installed,
    };
    if (message) |m| {
        _ = font.drawFit(m, r.x + GitPanel.pad, ty0, r.x + r.width - GitPanel.pad, theme.popup_detail);
        return;
    }

    var branch_buf: [192]u8 = undefined;
    const branch = i18n.fill(&branch_buf, t.on_branch, .{git.branch});
    _ = font.drawFit(branch, r.x + GitPanel.pad, ty0, self.branchEnd(git, font), theme.popup_detail);
    self.eachBadge(git, font, Counter{ .font = font, .git = git }, Counter.draw);

    self.message.draw(self.field_rect, font, t.message_placeholder, focused, show_caret);
    const staged = GitPanel.count(git, .staged);
    const syncing = GitPanel.syncing(git);
    // git refuses a commit while a merge is half-done, and says so.
    const can_commit = staged > 0 or syncing;
    const mouse = rl.getMousePosition();
    const hov = can_commit and rl.checkCollisionPointRec(mouse, self.commit_rect);
    rl.drawRectangleRounded(self.commit_rect, 0.2, 8, if (can_commit) (if (hov) theme.accentDim(0.8) else theme.accent) else theme.popup_border);
    var label_buf: [96]u8 = undefined;
    const label = if (syncing)
        i18n.fill(&label_buf, t.sync_count, .{ git.behind, git.ahead })
    else if (staged > 0)
        i18n.fill(&label_buf, t.commit_count, .{staged})
    else
        t.nothing_staged;
    const lw = font.textWidth(label);
    _ = font.drawFit(label, self.commit_rect.x + (self.commit_rect.width - lw) / 2, self.commit_rect.y + (self.commit_rect.height - theme.font_size) / 2, self.commit_rect.x + self.commit_rect.width, if (can_commit) theme.background else theme.popup_detail);

    const top = self.listTop();
    theme.clip(.{ .x = r.x, .y = top, .width = r.width, .height = r.y + r.height - top });
    defer drawPrompt(self, font, prompt_focused, show_caret);
    var n: usize = 0;
    while (self.rowAtIndex(git, n)) |row| : (n += 1) {
        const y = top + @as(f32, @floatFromInt(n)) * row_height - self.scroll;
        if (y + row_height < top) continue;
        if (y > r.y + r.height) break;
        const ty = y + (row_height - theme.font_size) / 2;
        const row_hovered = mouse.y >= y and mouse.y < y + row_height and mouse.x >= r.x and mouse.x < r.x + r.width;
        if (row_hovered) rl.drawRectangleRec(.{ .x = r.x, .y = y, .width = r.width, .height = row_height }, theme.sidebar_hover);
        switch (row) {
            .commands_header => {
                const icon: Icons.Icon = if (self.commands_open) .chevron_down else .chevron_right;
                font.drawIcon(icon, .{ .x = r.x + GitPanel.pad + 6, .y = y + row_height / 2 }, .small, theme.sidebar_arrow);
                _ = font.drawFit(t.commands, r.x + GitPanel.pad + 18, ty, r.x + r.width - GitPanel.pad, theme.sidebar_header);
            },
            .command => |c| {
                _ = font.drawFit(c.label(), r.x + GitPanel.pad + 18, ty, r.x + r.width - GitPanel.pad, theme.foreground);
            },
            .header => |s| {
                var hbuf: [128]u8 = undefined;
                const name = switch (s) {
                    .conflicts => t.conflicts_section,
                    .staged => t.staged_changes,
                    .changes => t.changes,
                };
                const title = std.fmt.bufPrint(&hbuf, "{s} ({d})", .{ name, GitPanel.count(git, s) }) catch "";
                // The changes can also all be thrown away at once; a
                // half-done merge is sorted out file by file.
                const discard_all = s == .changes and GitPanel.canDiscardAll(git);
                const buttons: usize = if (discard_all) 2 else 1;
                const color = if (s == .conflicts) theme.diff_deleted else theme.sidebar_header;
                _ = font.drawFit(title, r.x + GitPanel.pad, ty, self.actionRect(y, buttons - 1).x - 8, theme.copy(color));
                if (row_hovered and s != .conflicts) {
                    drawAction(font, self.actionRect(y, 0), if (s == .changes) .plus else .minus, mouse);
                    if (discard_all) drawAction(font, self.actionRect(y, 1), .undo_2, mouse);
                }
            },
            .entry => |e| {
                const entry = git.entries.items[e.index];
                const letter = if (e.section == .staged) entry.staged else entry.unstaged;
                const conflict = e.section == .conflicts;
                const base = if (std.mem.lastIndexOfScalar(u8, entry.path, '/')) |i| i + 1 else 0;
                const status_x = r.x + r.width - GitPanel.pad - font.cell_width;
                const buttons: usize = if (e.section == .changes and GitPanel.canDiscard(entry)) 2 else 1;
                const text_end = if (row_hovered) self.actionRect(y, buttons - 1).x - 4 else status_x - 8;
                file_icon.draw(entry.path[base..], .{ .x = r.x + GitPanel.pad + 10 + file_icon.radius, .y = y + row_height / 2 });
                const x = font.drawFit(entry.path[base..], r.x + GitPanel.pad + 10 + file_icon.radius * 2 + 8, ty, text_end, theme.foreground);
                if (base > 0) _ = font.drawFit(entry.path[0 .. base - 1], x + font.cell_width, ty, text_end, theme.popup_detail);
                font.drawCodepoint(if (letter == '?') 'U' else letter, status_x, ty, theme.copy(if (conflict) theme.diff_deleted else statusColor(letter)));
                if (row_hovered) {
                    drawAction(font, self.actionRect(y, 0), if (e.section == .changes) .plus else .minus, mouse);
                    if (buttons > 1) drawAction(font, self.actionRect(y, 1), .undo_2, mouse);
                }
            },
        }
    }
    // Nothing in the lists: say so where they would start.
    if (git.entries.items.len == 0) {
        const y = top + @as(f32, @floatFromInt(n)) * row_height - self.scroll;
        _ = font.drawFit(t.no_changes, r.x + GitPanel.pad, y + (row_height - theme.font_size) / 2, r.x + r.width - GitPanel.pad, theme.popup_detail);
    }
}

/// What a command is waiting to be told, in a box over the list.
fn drawPrompt(self: *const GitPanel, font: Font, focused: bool, show_caret: bool) void {
    const prompt = self.prompt orelse return;
    const box = self.promptRect();
    var buf: [128]u8 = undefined;
    rl.drawRectangleRec(.{ .x = box.x - GitPanel.pad, .y = box.y - 4, .width = box.width + 2 * GitPanel.pad, .height = box.height + 8 }, theme.sidebar_background);
    self.prompt_field.draw(box, font, prompt.placeholder(&buf, self.promptBase()), focused, show_caret);
}

/// A counter beside the branch: how many changes of its kind there are,
/// in its own color.
const Counter = struct {
    font: Font,
    git: *const Git,

    fn draw(self: Counter, badge: GitPanel.Badge, r: rl.Rectangle) void {
        var digits: [12]u8 = undefined;
        const text = std.fmt.bufPrint(&digits, "{d}", .{GitPanel.badgeCount(self.git, badge)}) catch return;
        rl.drawRectangleRounded(r, 0.4, 8, theme.copy(badge.color()));
        const x = r.x + (r.width - self.font.textWidth(text)) / 2;
        _ = self.font.drawFit(text, x, r.y + (r.height - theme.font_size) / 2, r.x + r.width, theme.background);
    }
};

/// The name of the counter under the pointer.
pub fn drawBadgeTooltip(self: *const GitPanel, git: *const Git, font: Font) void {
    const mouse = rl.getMousePosition();
    const badge = self.badgeAt(git, font, mouse) orelse return;
    const Anchor = struct {
        want: GitPanel.Badge,
        font: Font,
        rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
        fn take(state: *@This(), badge_at: GitPanel.Badge, r: rl.Rectangle) void {
            if (badge_at == state.want) state.rect = r;
        }
    };
    var anchor: Anchor = .{ .want = badge, .font = font };
    self.eachBadge(git, font, &anchor, Anchor.take);
    search_controls.drawTooltip(font, anchor.rect, badge.label());
}

/// One of a row's buttons: "+" (stage), "−" (unstage) or "↺" (throw the
/// changes away).
pub fn drawAction(font: Font, b: rl.Rectangle, icon: Icons.Icon, mouse: rl.Vector2) void {
    if (rl.checkCollisionPointRec(mouse, b)) rl.drawRectangleRounded(b, 0.3, 6, theme.tab_close_hover);
    const c: rl.Vector2 = .{ .x = b.x + b.width / 2, .y = b.y + b.height / 2 };
    font.drawIcon(icon, c, .small, theme.foreground);
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
