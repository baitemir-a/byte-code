//! Drawing the Git view: the commit box and button, and the staged and
//! changed files.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../theme/lib/theme.zig");
const anim = @import("../anim.zig");
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
    const can_commit = !busy and conflicts == 0 and (staged > 0 or syncing or git.operation != null);
    const hov = can_commit and rl.checkCollisionPointRec(mouse, self.commit_rect);
    rl.drawRectangleRounded(self.commit_rect, 0.2, 8, if (can_commit) (if (hov) theme.accentDim(0.8) else theme.accent) else theme.popup_border);
    var label_buf: [96]u8 = undefined;
    const label = if (git.operation) |op|
        GitPanel.continueLabel(op)
    else if (syncing)
        i18n.fill(&label_buf, t.sync_count, .{ git.behind, git.ahead })
    else if (staged > 0)
        i18n.fill(&label_buf, t.commit_count, .{staged})
    else
        t.nothing_staged;
    const lw = font.textWidth(label);
    const lx = self.commit_rect.x + (self.commit_rect.width - lw) / 2;
    _ = font.drawFit(label, lx, self.commit_rect.y + (self.commit_rect.height - theme.font_size) / 2, self.commit_rect.x + self.commit_rect.width, if (can_commit) theme.background else theme.popup_detail);
    if (self.busy) |*b| drawProgress(self, b, font, mouse);

    const top = self.listTop();
    const list_clip: rl.Rectangle = .{ .x = r.x, .y = top, .width = r.width, .height = r.y + r.height - top };
    theme.clip(list_clip);
    defer drawPrompt(self, font, prompt_focused, show_caret);
    // A section that just unfolded: its rows, and everything after them,
    // slide out from under its header.
    var moving = false;
    defer if (moving) {
        rl.endScissorMode();
        theme.clip(list_clip);
    };
    var n: usize = 0;
    while (self.rowAtIndex(git, n)) |row| : (n += 1) {
        var y = top + @as(f32, @floatFromInt(n)) * row_height - self.scroll;
        if (self.reveal) |v| if (v.moves(n)) {
            y += v.shift(row_height);
            if (!moving) {
                moving = true;
                const under = top + @as(f32, @floatFromInt(v.row + 1)) * row_height - self.scroll;
                const cut = @max(list_clip.y, under);
                theme.clip(.{ .x = list_clip.x, .y = cut, .width = list_clip.width, .height = @max(0, list_clip.y + list_clip.height - cut) });
            }
        };
        if (y + row_height < top) continue;
        if (y > r.y + r.height) break;
        const ty = y + (row_height - theme.font_size) / 2;
        const row_hovered = mouse.y >= y and mouse.y < y + row_height and mouse.x >= r.x and mouse.x < r.x + r.width;
        const hover_t = anim.fade(anim.hash("git_row", n), row_hovered, anim.hover_speed);
        if (hover_t > 0) rl.drawRectangleRec(.{ .x = r.x, .y = y, .width = r.width, .height = row_height }, anim.alpha(theme.sidebar_hover, hover_t));
        switch (row) {
            .commands_header => {
                const turn = anim.fade(anim.hash("git_section", 0), self.commands_open, anim.collapse_speed);
                anim.drawChevron(.{ .x = r.x + GitPanel.pad + 6, .y = y + row_height / 2 }, turn, 9, theme.sidebar_arrow);
                _ = font.drawFit(t.commands, r.x + GitPanel.pad + 18, ty, r.x + r.width - GitPanel.pad, theme.sidebar_header);
            },
            .command => |c| {
                // They wait while something runs.
                const color = if (busy) theme.popup_detail else theme.foreground;
                _ = font.drawFit(c.label(git), r.x + GitPanel.pad + 18, ty, r.x + r.width - GitPanel.pad, color);
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
                const turn = anim.fade(anim.hash("git_section", 1), self.history_open, anim.collapse_speed);
                anim.drawChevron(.{ .x = r.x + GitPanel.pad + 6, .y = y + row_height / 2 }, turn, 9, theme.sidebar_arrow);
                _ = font.drawFit(t.history, r.x + GitPanel.pad + 18, ty, r.x + r.width - GitPanel.pad, theme.sidebar_header);
            },
            .commit => |i| {
                drawCommit(self, git, font, i, y, now, row_hovered);
                if (row_hovered) drawAction(font, self.actionRect(y, 0), .undo_2, mouse);
            },
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
                file_icon.draw(entry.path[base..], .{ .x = r.x + GitPanel.pad + 10 + file_icon.size / 2, .y = y + row_height / 2 });
                const x = font.drawFit(entry.path[base..], r.x + GitPanel.pad + 10 + file_icon.size + 8, ty, text_end, theme.foreground);
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
fn drawCommit(self: *const GitPanel, git: *const Git, font: Font, index: u32, y: f32, now: i64, hovered: bool) void {
    const r = self.rect;
    const c = git.history.commits.items[index];
    const ty = y + (row_height - theme.font_size) / 2;
    const open = git.history.open == index;
    const turn = anim.fade(anim.hash("git_commit", index), open, anim.collapse_speed);
    anim.drawChevron(.{ .x = r.x + GitPanel.pad + 18, .y = y + row_height / 2 }, turn, 9, theme.sidebar_arrow);
    // Under the pointer, the revert button takes the age's place.
    var age_buf: [48]u8 = undefined;
    const age = ageText(&age_buf, now, c.time);
    const text_end = if (hovered) self.actionRect(y, 0).x - 4 else r.x + r.width - GitPanel.pad - font.textWidth(age) - 8;
    if (!hovered) _ = font.drawFit(age, text_end + 8, ty, r.x + r.width - GitPanel.pad, theme.popup_detail);
    var x = r.x + GitPanel.pad + 30;
    // Its tags first, in the accent color.
    if (c.tags.len > 0) {
        font.drawIcon(.tag, .{ .x = x + 6, .y = y + row_height / 2 }, .small, theme.accent);
        x = font.drawFit(c.tags, x + 16, ty, text_end, theme.accent) + font.cell_width;
    }
    _ = font.drawFit(c.subject, x, ty, text_end, theme.foreground);
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
    file_icon.draw(path[base..], .{ .x = x0 + file_icon.size / 2, .y = y + row_height / 2 });
    const x = font.drawFit(path[base..], x0 + file_icon.size + 8, ty, status_x - 8, theme.foreground);
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

/// What runs in the background: a spinner, what it is ("Pushing…"),
/// the last thing git said about how far it got, and a button to stop.
fn drawProgress(self: *const GitPanel, b: *const GitPanel.Busy, font: Font, mouse: rl.Vector2) void {
    const p = self.progressRect();
    const ty = p.y + (row_height - theme.font_size) / 2;
    drawSpinner(.{ .x = p.x + GitPanel.pad + 6, .y = p.y + row_height / 2 }, theme.accent);
    const stop = self.cancelRect();
    const x = font.drawFit(b.label, p.x + GitPanel.pad + 18, ty, stop.x - 6, theme.foreground);
    _ = font.drawFit(b.progressText(), x + font.cell_width, ty, stop.x - 6, theme.popup_detail);
    drawAction(font, stop, .x, mouse);
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
    // Drawn here, outside the view's clipping: the names of the stop
    // button and of a commit's revert button.
    if (self.busy != null and rl.checkCollisionPointRec(mouse, self.cancelRect())) {
        return search_controls.drawTooltip(font, self.cancelRect(), i18n.tr().common.cancel);
    }
    if (self.hitTest(git, font, mouse)) |hit| if (hit == .revert_commit) {
        return search_controls.drawTooltip(font, self.actionRect(self.rowTopAt(mouse), 0), i18n.tr().git.revert_commit);
    };
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
