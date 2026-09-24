//! The sidebar's Git view: the branch with counters for the changes it
//! carries, a commit message box, and the changed files: staged ones (−
//! to unstage) and the rest (+ to stage, ↺ to throw the changes away).
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");
const TextField = @import("../widgets/TextField.zig");
const file_icon = @import("../widgets/lib/file_icon.zig");
const GitPanel_draw = @import("GitPanel_draw.zig");
const i18n = @import("../../i18n/i18n.zig");

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
    /// Fold the list of commands open or shut, or run one of them.
    toggle_commands,
    command: Command,
    /// The box a command's question is typed in.
    prompt,
};

/// The counters beside the branch: how much there is of each kind.
pub const Badge = enum {
    /// Changes in the work tree, waiting to be staged.
    unstaged,
    /// Changes already staged, waiting for a commit.
    staged,
    /// Commits this branch has that its upstream doesn't.
    to_push,
    /// And the other way round: what the last fetch found waiting.
    to_pull,
    /// Files a merge left half-done.
    conflicts,

    pub fn color(self: Badge) rl.Color {
        return switch (self) {
            .unstaged => theme.diff_modified,
            .staged => theme.git_modified,
            .to_push => theme.diff_added,
            .to_pull => theme.git_pull,
            .conflicts => theme.diff_deleted,
        };
    }

    pub fn label(self: Badge) []const u8 {
        const t = i18n.tr().git;
        return switch (self) {
            .unstaged => t.badge_unstaged,
            .staged => t.badge_staged,
            .to_push => t.badge_to_push,
            .to_pull => t.badge_to_pull,
            .conflicts => t.badge_conflicts,
        };
    }
};

pub const badge_count = std.enums.values(Badge).len;

/// The list a counter stands for, so clicking it can scroll there.
pub fn badgeSection(badge: Badge) ?Section {
    return switch (badge) {
        .unstaged => .changes,
        .staged => .staged,
        .conflicts => .conflicts,
        .to_push, .to_pull => null,
    };
}

/// Puts a section's header at the top of the list.
pub fn scrollToSection(self: *GitPanel, git: *const Git, section: Section) void {
    var n: usize = 0;
    while (self.rowAtIndex(git, n)) |row| : (n += 1) {
        if (row == .header and row.header == section) {
            self.scroll = @as(f32, @floatFromInt(n)) * row_height;
            return;
        }
    }
}

/// The counters that aren't zero, in order. `out` holds the answer.
pub fn activeBadges(git: *const Git, out: *[badge_count]Badge) []const Badge {
    if (git.state != .ok) return &.{};
    var n: usize = 0;
    for (std.enums.values(Badge)) |badge| {
        if (badgeCount(git, badge) == 0) continue;
        out[n] = badge;
        n += 1;
    }
    return out[0..n];
}

/// The badge on the Git tab's icon, for when another view is showing:
/// one counter in its own color, or, when several kinds are waiting,
/// their total in the accent color (the tooltip breaks it down).
pub fn tabBadge(git: *const Git) ?struct { count: u32, color: rl.Color } {
    var buf: [badge_count]Badge = undefined;
    const active = activeBadges(git, &buf);
    if (active.len == 0) return null;
    if (active.len == 1) return .{ .count = badgeCount(git, active[0]), .color = active[0].color() };
    var total: u32 = 0;
    for (active) |badge| total += badgeCount(git, badge);
    return .{ .count = total, .color = theme.accent };
}

pub const badge_height: f32 = theme.font_size + 4;
const badge_gap: f32 = 5;

/// What each counter stands at; a zero isn't shown at all.
pub fn badgeCount(git: *const Git, badge: Badge) u32 {
    var n: u32 = 0;
    for (git.entries.items) |e| {
        if (e.isConflict()) {
            n += @intFromBool(badge == .conflicts);
            continue;
        }
        switch (badge) {
            .unstaged => n += @intFromBool(e.isUnstaged()),
            .staged => n += @intFromBool(e.isStaged()),
            else => {},
        }
    }
    return switch (badge) {
        .to_push => git.ahead,
        .to_pull => git.behind,
        else => n,
    };
}

/// The counters, right to left along the branch line, skipping the empty
/// ones. `f` is called with each one and where it goes.
pub fn eachBadge(self: *const GitPanel, git: *const Git, font: Font, context: anytype, f: fn (@TypeOf(context), Badge, rl.Rectangle) void) void {
    var right = self.rect.x + self.rect.width - pad;
    const y = self.rect.y + pad + (row_height - badge_height) / 2;
    // Last first, so they read in the order of the enum from the left.
    var i = std.enums.values(Badge).len;
    while (i > 0) {
        i -= 1;
        const badge = std.enums.values(Badge)[i];
        const n = badgeCount(git, badge);
        if (n == 0) continue;
        var digits: [12]u8 = undefined;
        const text = std.fmt.bufPrint(&digits, "{d}", .{n}) catch continue;
        const w = font.textWidth(text) + 10;
        right -= w;
        f(context, badge, .{ .x = right, .y = y, .width = w, .height = badge_height });
        right -= badge_gap;
    }
}

/// The counter under the pointer, if it is over one.
pub fn badgeAt(self: *const GitPanel, git: *const Git, font: Font, p: rl.Vector2) ?Badge {
    const Found = struct {
        point: rl.Vector2,
        badge: ?Badge = null,
        fn check(state: *@This(), badge: Badge, r: rl.Rectangle) void {
            if (rl.checkCollisionPointRec(state.point, r)) state.badge = badge;
        }
    };
    var found: Found = .{ .point = p };
    self.eachBadge(git, font, &found, Found.check);
    return found.badge;
}

/// Where the branch name has to stop: before the counters.
pub fn branchEnd(self: *const GitPanel, git: *const Git, font: Font) f32 {
    const Edge = struct {
        x: f32,
        fn check(state: *@This(), _: Badge, r: rl.Rectangle) void {
            state.x = @min(state.x, r.x);
        }
    };
    var edge: Edge = .{ .x = self.rect.x + self.rect.width - pad };
    self.eachBadge(git, font, &edge, Edge.check);
    return edge.x - 8;
}

/// The commands the list offers, under a header that folds them away.
pub const Command = enum {
    push,
    pull,
    commit_push,
    commit_sync,
    fetch,
    clone,
    checkout,
    create_branch,
    create_branch_from,
    stash,
    stash_pop,

    pub fn label(self: Command) []const u8 {
        const t = i18n.tr().git;
        return switch (self) {
            .push => t.push,
            .pull => t.pull,
            .commit_push => t.commit_push,
            .commit_sync => t.commit_sync,
            .fetch => t.fetch,
            .clone => t.clone,
            .checkout => t.checkout,
            .create_branch => t.create_branch,
            .create_branch_from => t.create_branch_from,
            .stash => t.stash,
            .stash_pop => t.stash_pop,
        };
    }
};

/// What the box above the list is asking for, when a command needs
/// something typed before it can run.
pub const Prompt = enum {
    clone,
    create_branch,
    /// The base is in `prompt_base`.
    create_branch_from,

    pub fn placeholder(self: Prompt, buf: []u8, base: []const u8) []const u8 {
        const t = i18n.tr().git;
        return switch (self) {
            .clone => t.clone_url,
            .create_branch => t.branch_name,
            .create_branch_from => i18n.fill(buf, t.branch_from_name, .{base}),
        };
    }
};

/// A row of the list: the commands, then the files.
const Row = union(enum) {
    commands_header,
    command: Command,
    header: Section,
    entry: struct { index: u32, section: Section },
};
/// The lists the files are split into. A file a merge left half-done is
/// in neither of the others: it has to be sorted out first.
pub const Section = enum { conflicts, staged, changes };

/// Whether an entry belongs in a section.
fn inSection(e: Git.Entry, section: Section) bool {
    if (e.isConflict()) return section == .conflicts;
    return switch (section) {
        .conflicts => false,
        .staged => e.isStaged(),
        .changes => e.isUnstaged(),
    };
}

message: TextField,
/// The commands are folded away until asked for.
commands_open: bool = false,
/// What a command is waiting to be told, and the box it is typed in.
prompt: ?Prompt = null,
prompt_field: TextField,
prompt_base: [64]u8 = undefined,
prompt_base_len: usize = 0,
rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
field_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
commit_rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
scroll: f32 = 0,
max_scroll: f32 = 0,
/// A push, pull or fetch is running; `from` is the command row that
/// started it (null for the commit button), which shows the spinner.
busy: ?struct { from: ?Command } = null,

// Drawing, in GitPanel_draw.zig.
pub const draw = GitPanel_draw.draw;
pub const drawBadgeTooltip = GitPanel_draw.drawBadgeTooltip;

pub fn init(gpa: std.mem.Allocator) GitPanel {
    return .{ .message = .init(gpa), .prompt_field = .init(gpa) };
}

pub fn deinit(self: *GitPanel) void {
    self.message.deinit();
    self.prompt_field.deinit();
}

/// Asks for what a command needs; `base` is what a branch starts from.
pub fn ask(self: *GitPanel, prompt: Prompt, base: []const u8) !void {
    self.prompt = prompt;
    self.prompt_base_len = @min(base.len, self.prompt_base.len);
    @memcpy(self.prompt_base[0..self.prompt_base_len], base[0..self.prompt_base_len]);
    try self.prompt_field.setText("");
}

pub fn cancelPrompt(self: *GitPanel) void {
    self.prompt = null;
}

pub fn promptBase(self: *const GitPanel) []const u8 {
    return self.prompt_base[0..self.prompt_base_len];
}

/// The box a command's question is typed in, over the top of the list.
pub fn promptRect(self: *const GitPanel) rl.Rectangle {
    return .{ .x = self.rect.x + pad, .y = self.listTop() + 4, .width = self.rect.width - 2 * pad, .height = theme.line_height + 8 };
}

/// Whether the button commits or syncs: with nothing staged, but commits
/// to send or take in, it offers to sync instead.
pub fn syncing(git: *const Git) bool {
    return count(git, .staged) == 0 and (git.ahead > 0 or git.behind > 0);
}

/// How many files each list holds.
pub fn count(git: *const Git, section: Section) usize {
    var n: usize = 0;
    for (git.entries.items) |e| n += @intFromBool(inSection(e, section));
    return n;
}

/// Row `n` of the list: the commands, folded or not, then the files
/// (headers only for non-empty sections).
pub fn rowAtIndex(self: *const GitPanel, git: *const Git, n: usize) ?Row {
    if (n == 0) return .commands_header;
    var i = n - 1;
    if (self.commands_open) {
        const commands = std.enums.values(Command);
        if (i < commands.len) return .{ .command = commands[i] };
        i -= commands.len;
    }
    for (std.enums.values(Section)) |section| {
        if (count(git, section) == 0) continue;
        if (i == 0) return .{ .header = section };
        i -= 1;
        for (git.entries.items, 0..) |e, idx| {
            if (!inSection(e, section)) continue;
            if (i == 0) return .{ .entry = .{ .index = @intCast(idx), .section = section } };
            i -= 1;
        }
    }
    return null;
}

fn rowCount(self: *const GitPanel, git: *const Git) usize {
    var n: usize = 1 + if (self.commands_open) std.enums.values(Command).len else 0;
    for (std.enums.values(Section)) |section| {
        const c = count(git, section);
        n += c + @intFromBool(c > 0);
    }
    return n;
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
    const content = @as(f32, @floatFromInt(self.rowCount(git))) * row_height;
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
    if (self.prompt != null and rl.checkCollisionPointRec(p, self.promptRect())) return .prompt;
    if (p.y < self.listTop()) return null;
    const n: usize = @intFromFloat((p.y - self.listTop() + self.scroll) / row_height);
    const row = self.rowAtIndex(git, n) orelse return null;
    const y = self.listTop() + @as(f32, @floatFromInt(n)) * row_height - self.scroll;
    const on_action = rl.checkCollisionPointRec(p, self.actionRect(y, 0));
    const on_discard = rl.checkCollisionPointRec(p, self.actionRect(y, 1));
    return switch (row) {
        .commands_header => Hit.toggle_commands,
        .command => |c| Hit{ .command = c },
        .header => |s| switch (s) {
            // A half-done merge is sorted out file by file.
            .conflicts => null,
            .staged => if (on_action) Hit.unstage_all else null,
            .changes => if (on_action)
                Hit.stage_all
            else if (on_discard and canDiscardAll(git))
                Hit.discard_all
            else
                null,
        },
        .entry => |e| if (on_action)
            (if (e.section == .staged) Hit{ .unstage = e.index } else Hit{ .stage = e.index })
        else if (on_discard and e.section == .changes and canDiscard(git.entries.items[e.index]))
            Hit{ .discard = e.index }
        else
            .{ .open = .{ .index = e.index, .staged = e.section == .staged } },
    };
}
