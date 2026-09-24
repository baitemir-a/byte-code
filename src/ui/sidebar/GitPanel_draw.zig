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

/// `now` (seconds since the epoch) is what the history's ages count from.
pub fn draw(self: *const GitPanel, git: *const Git, font: Font, focused: bool, prompt_focused: bool, show_caret: bool, has_project: bool, now: i64) void {
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
    // The name picks another branch: it shows it can be clicked.
    const mouse = rl.getMousePosition();
    const on_branch = rl.checkCollisionPointRec(mouse, self.branchRect(git, font));
    const branch_end = font.drawFit(branch, r.x + GitPanel.pad, ty0, self.branchEnd(git, font), theme.copy(if (on_branch) theme.foreground else theme.popup_detail));
    if (on_branch) rl.drawRectangleRec(.{ .x = r.x + GitPanel.pad, .y = ty0 + theme.font_size + 1, .width = branch_end - r.x - GitPanel.pad, .height = 1 }, theme.foreground);
    self.eachBadge(git, font, Counter{ .font = font, .git = git }, Counter.draw);

    self.message.draw(self.field_rect, font, t.message_placeholder, focused, show_caret);
    const staged = GitPanel.count(git, .staged);
    const syncing = GitPanel.syncing(git);
    const conflicts = GitPanel.count(git, .conflicts);
    // git refuses a commit while a merge is half-done, and says so; once
    // it is sorted out, the merge can be committed even with nothing
    // staged.
    const busy = self.busy != null;
    const can_commit = !busy and conflicts == 0 and (staged > 0 or syncing or git.merging);
    const hov = can_commit and rl.checkCollisionPointRec(mouse, self.commit_rect);
    rl.drawRectangleRounded(self.commit_rect, 0.2, 8, if (can_commit) (if (hov) theme.accentDim(0.8) else theme.accent) else theme.popup_border);
    var label_buf: [96]u8 = undefined;
    const label = if (git.merging)
        t.commit_merge
    else if (syncing)
        i18n.fill(&label_buf, t.sync_count, .{ git.behind, git.ahead })
    else if (staged > 0)
        i18n.fill(&label_buf, t.commit_count, .{staged})
    else
        t.nothing_staged;
    const lw = font.textWidth(label);
    const lx = self.commit_rect.x + (self.commit_rect.width - lw) / 2;
    _ = font.drawFit(label, lx, self.commit_rect.y + (self.commit_rect.height - theme.font_size) / 2, self.commit_rect.x + self.commit_rect.width, if (can_commit) theme.background else theme.popup_detail);
    // The button itself started what is running: it spins beside its label.
    if (self.busy) |b| if (b.from == null) {
        drawSpinner(.{ .x = lx - 12, .y = self.commit_rect.y + self.commit_rect.height / 2 }, theme.popup_detail);
    };

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
                _ = font.drawFit(t.commands, r.x + GitPanel.pad + 18, ty, r.x + r.width - GitPanel.pad - 16, theme.sidebar_header);
                // Folded away, the running command spins here instead.
                if (self.busy) |b| if (b.from != null and !self.commands_open) {
                    drawSpinner(spinnerAt(r, y), theme.sidebar_header);
                };
            },
            .command => |c| {
                const running = if (self.busy) |b| b.from == c else false;
                // The others wait until it is done.
                const color = if (busy and !running) theme.popup_detail else theme.foreground;
                _ = font.drawFit(c.label(), r.x + GitPanel.pad + 18, ty, r.x + r.width - GitPanel.pad - 16, color);
                if (running) drawSpinner(spinnerAt(r, y), theme.accent);
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
            .history_header => {
                const icon: Icons.Icon = if (self.history_open) .chevron_down else .chevron_right;
                font.drawIcon(icon, .{ .x = r.x + GitPanel.pad + 6, .y = y + row_height / 2 }, .small, theme.sidebar_arrow);
                _ = font.drawFit(t.history, r.x + GitPanel.pad + 18, ty, r.x + r.width - GitPanel.pad, theme.sidebar_header);
            },
            .commit => |i| drawCommit(self, git, font, i, y, now),
            .commit_file => |i| {
                const f = git.history.files.items[i];
                drawFile(font, f.path, f.status, r.x + GitPanel.pad + 30, ty, y, r.x + r.width - GitPanel.pad, false);
            },
            .no_changes, .no_commits => {
                const text = if (row == .no_changes) t.no_changes else t.no_commits;
                _ = font.drawFit(text, r.x + GitPanel.pad + 18, ty, r.x + r.width - GitPanel.pad, theme.popup_detail);
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
                    drawAction(font, self.actionRect(y, 0), if (e.section == .staged) .minus else .plus, mouse);
                    if (buttons > 1) drawAction(font, self.actionRect(y, 1), .undo_2, mouse);
                }
            },
        }
    }
}

/// A commit in the history: its first line, and how long ago it was made.
/// The open one points down at its files.
fn drawCommit(self: *const GitPanel, git: *const Git, font: Font, index: u32, y: f32, now: i64) void {
    const r = self.rect;
    const c = git.history.commits.items[index];
    const ty = y + (row_height - theme.font_size) / 2;
    const open = git.history.open == index;
    font.drawIcon(if (open) .chevron_down else .chevron_right, .{ .x = r.x + GitPanel.pad + 18, .y = y + row_height / 2 }, .small, theme.sidebar_arrow);
    var age_buf: [48]u8 = undefined;
    const age = ageText(&age_buf, now, c.time);
    const age_x = r.x + r.width - GitPanel.pad - font.textWidth(age);
    _ = font.drawFit(age, age_x, ty, r.x + r.width - GitPanel.pad, theme.popup_detail);
    _ = font.drawFit(c.subject, r.x + GitPanel.pad + 30, ty, age_x - 8, theme.foreground);
}

/// "3 d ago", in the words the bar at the bottom uses.
fn ageText(buf: []u8, now: i64, time: i64) []const u8 {
    const s = i18n.tr().status;
    const ago = core.Blame.age(now, time);
    const unit = switch (ago.unit) {
        .just_now => return s.just_now,
        .minutes => s.minutes,
        .hours => s.hours,
        .days => s.days,
        .months => s.months,
        .years => s.years,
    };
    return i18n.fill(buf, unit, .{ago.count});
}

/// A file row: its icon and name, the folder it is in, and its status
/// letter at the right end, before `right`.
fn drawFile(font: Font, path: []const u8, letter: u8, x0: f32, ty: f32, y: f32, right: f32, conflict: bool) void {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0;
    const status_x = right - font.cell_width;
    file_icon.draw(path[base..], .{ .x = x0 + file_icon.radius, .y = y + row_height / 2 });
    const x = font.drawFit(path[base..], x0 + file_icon.radius * 2 + 8, ty, status_x - 8, theme.foreground);
    if (base > 0) _ = font.drawFit(path[0 .. base - 1], x + font.cell_width, ty, status_x - 8, theme.popup_detail);
    font.drawCodepoint(if (letter == '?') 'U' else letter, status_x, ty, theme.copy(if (conflict) theme.diff_deleted else statusColor(letter)));
}

/// What a command is waiting to be told, in a box over the list.
fn drawPrompt(self: *const GitPanel, font: Font, focused: bool, show_caret: bool) void {
    const prompt = self.prompt orelse return;
    const box = self.promptRect();
    var buf: [128]u8 = undefined;
    rl.drawRectangleRec(.{ .x = box.x - GitPanel.pad, .y = box.y - 4, .width = box.width + 2 * GitPanel.pad, .height = box.height + 8 }, theme.sidebar_background);
    self.prompt_field.draw(box, font, prompt.placeholder(&buf, self.promptBase()), focused, show_caret);
}

/// Where a row's spinner goes: at its right end.
fn spinnerAt(r: rl.Rectangle, y: f32) rl.Vector2 {
    return .{ .x = r.x + r.width - GitPanel.pad - 8, .y = y + row_height / 2 };
}

/// Something is running: an arc going round, a turn a second.
fn drawSpinner(center: rl.Vector2, color: rl.Color) void {
    const start: f32 = @floatCast(@mod(rl.getTime() * 360, 360));
    rl.drawRing(center, 4, 6, start, start + 270, 24, color);
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
