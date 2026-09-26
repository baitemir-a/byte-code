//! The Git view's lists to pick from, at the top of the editor: the
//! branches (to check out, start a branch from, merge, rebase onto,
//! cherry-pick from or compare with; while checking out each row can
//! also be merged, renamed or deleted), another branch's commits (to
//! cherry-pick), the files two branches differ in, the stashes (to bring
//! back, apply or drop) and the tags (to delete).
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const App = @import("../App.zig");
const Picker = @import("../../ui/Picker.zig");
const i18n = @import("../../i18n/i18n.zig");
const clipboard = @import("clipboard.zig");
const git_commands = @import("git_commands.zig");
const palette = @import("palette.zig");

pub const Mode = enum {
    checkout,
    branch_from,
    merge,
    rebase,
    /// Cherry-picking: the branch, then one of its commits.
    cherry_branch,
    cherry_commit,
    /// Comparing: the branch, then one of the files it differs in.
    compare,
    compare_file,
    stash,
    delete_tag,
    /// Not git's: the lists in palette.zig.
    command,
    go_to_line,
    symbol,
    workspace_symbol,
    problems,
};

/// Lists the branches for `mode` (one of the branch ones). While
/// checking out, each row also offers to merge, rename or delete it.
pub fn openBranchPicker(self: *App, mode: Mode) !void {
    const project = if (self.project) |*p| p else return;
    const out = try core.Git.readBranches(self.gpa, self.io, project.root().path) orelse return;
    defer self.gpa.free(out);
    self.git_refs.clear();
    try self.git_refs.parseBranches(out);
    // Only checking out and starting a branch have a use for the one
    // checked out; the rest need another one.
    if (mode != .checkout and mode != .branch_from) for (self.git_refs.branches.items, 0..) |b, i| if (b.current) {
        _ = self.git_refs.branches.orderedRemove(i);
        break;
    };

    const t = i18n.tr().git;
    const all = comptime [_]Picker.Action{ .merge, .rename, .delete };
    const actions: []const Picker.Action = if (mode == .checkout) &all else &.{};
    const labels: []const []const u8 = if (mode == .checkout) &.{ t.action_merge, t.action_rename, t.action_delete } else &.{};
    try self.picker.open(switch (mode) {
        .checkout => t.pick_branch,
        .branch_from => t.pick_branch_from,
        .rebase => t.pick_rebase,
        .cherry_branch => t.pick_cherry_branch,
        .compare => t.pick_compare,
        else => t.pick_merge,
    }, actions, labels);
    for (self.git_refs.branches.items) |b| {
        // Merging it into itself, or deleting the branch that's checked
        // out, isn't on offer; nor is renaming or deleting the remote's.
        var without: std.EnumSet(Picker.Action) = .initEmpty();
        if (b.current) {
            without.insert(.merge);
            without.insert(.delete);
        }
        if (b.remote) {
            without.insert(.rename);
            without.insert(.delete);
        }
        try self.picker.add(.{ .label = b.name, .detail = if (b.remote) t.remote else "", .current = b.current, .without = without });
    }
    try finishOpening(self, mode);
}

/// Lists the stashes, newest first: Enter brings one back (and drops it),
/// the buttons apply one (keeping it) or drop it.
pub fn openStashPicker(self: *App) !void {
    const project = if (self.project) |*p| p else return;
    const out = try core.Git.readStashes(self.gpa, self.io, project.root().path) orelse return;
    defer self.gpa.free(out);
    self.git_refs.clear();
    try self.git_refs.parseStashes(out);
    const t = i18n.tr().git;
    try self.picker.open(t.pick_stash, &.{ .apply, .drop }, &.{ t.action_apply, t.action_drop });
    for (self.git_refs.stashes.items) |s| try self.picker.add(.{ .label = s.message, .detail = s.ref });
    try finishOpening(self, .stash);
}

/// The commits `branch` has that the branch checked out doesn't, newest
/// first: Enter copies one here.
fn openCommitPicker(self: *App, root: []const u8, branch: []const u8) !void {
    const out = try core.Git.readCommitsNotHere(self.gpa, self.io, root, branch) orelse return;
    defer self.gpa.free(out);
    self.git_refs.clear();
    try self.git_refs.parseCommits(out);
    try self.picker.open(i18n.tr().git.pick_cherry_commit, &.{}, &.{});
    for (self.git_refs.commits.items) |c| {
        var detail: [96]u8 = undefined;
        const d = std.fmt.bufPrint(&detail, "{s}  {s}", .{ c.shortHash(), c.author }) catch c.shortHash();
        try self.picker.add(.{ .label = c.subject, .detail = d });
    }
    try finishOpening(self, .cherry_commit);
}

/// The files the branch checked out and `branch` differ in: Enter shows
/// how one differs.
fn openComparePicker(self: *App, root: []const u8, branch: []const u8) !void {
    const out = try core.Git.readChangedFiles(self.gpa, self.io, root, "HEAD", branch) orelse return;
    defer self.gpa.free(out);
    self.git_refs.clear();
    try self.git_refs.parseFiles(out);
    try self.picker.open(i18n.tr().git.pick_compare_file, &.{}, &.{});
    for (self.git_refs.files.items) |f| try self.picker.add(.{ .label = f.path, .detail = &.{f.status} });
    try finishOpening(self, .compare_file);
}

/// The tags, newest first: Enter deletes one (after asking).
pub fn openTagPicker(self: *App) !void {
    const project = if (self.project) |*p| p else return;
    const out = try core.Git.readTags(self.gpa, self.io, project.root().path) orelse return;
    defer self.gpa.free(out);
    self.git_refs.clear();
    try self.git_refs.parseTags(out);
    try self.picker.open(i18n.tr().git.pick_tag_delete, &.{}, &.{});
    for (self.git_refs.tags.items) |tag| try self.picker.add(.{ .label = tag.name, .detail = tag.subject });
    try finishOpening(self, .delete_tag);
}

fn finishOpening(self: *App, mode: Mode) !void {
    self.picker_mode = mode;
    try self.picker.filter();
    self.quick_open.close();
    self.completion.close();
    self.side_focus = .none;
    self.terminal_focused = false;
}

/// Keys while a list is open: type to narrow it down, arrows to choose,
/// Enter to pick, Esc to close.
pub fn pickerKey(self: *App, cmd: core.Command) !void {
    const p = &self.picker;
    const own = palette.isOwn(self);
    switch (cmd) {
        .newline => if (own) try palette.choose(self, p.selectedItem()) else if (p.selectedItem()) |i| try choose(self, i, null),
        .clear_selection => if (own) palette.cancel(self) else p.close(),
        .move => |m| switch (m.motion) {
            .line_up => p.moveSelection(-1),
            .line_down => p.moveSelection(1),
            .page_up => p.moveSelection(-Picker.max_rows),
            .page_down => p.moveSelection(Picker.max_rows),
            else => _ = try p.query.handle(cmd),
        },
        .copy, .cut => try clipboard.copyOrCut(self.gpa, &p.query.buffer, cmd == .cut),
        .paste => if (clipboard.getClipboard()) |s| {
            try p.query.paste(s);
            try p.filter();
        },
        else => if (try p.query.handle(cmd)) try p.filter(),
    }
    if (own and p.is_open) try palette.preview(self);
}

/// The mouse while a list is open: a row or one of its buttons is picked,
/// a click elsewhere closes it. Returns whether the mouse was taken.
pub fn pickerMouse(self: *App, point: rl.Vector2, pressed: bool) !bool {
    const hit = self.picker.hitTest(point);
    if (hit != null) self.wanted_cursor = .pointing_hand;
    if (!pressed) return self.picker.contains(point);
    const own = palette.isOwn(self);
    if (hit) |h| {
        if (own) try palette.choose(self, h.item) else try choose(self, h.item, h.action);
        return true;
    }
    if (!self.picker.contains(point)) {
        if (own) palette.cancel(self) else self.picker.close();
    }
    return true;
}

/// A row was picked (`action` null), or one of its buttons.
fn choose(self: *App, item: u32, action: ?Picker.Action) !void {
    const project = if (self.project) |*p| p else return;
    const root = project.root().path;
    // Closed first: what follows may ask something in a dialog.
    self.picker.close();
    switch (self.picker_mode) {
        .stash => {
            const s = self.git_refs.stashes.items[item];
            const a = action orelse return stashAction(self, root, s.ref, .pop);
            return switch (a) {
                .apply => stashAction(self, root, s.ref, .apply),
                .drop => dropStash(self, root, s),
                else => {},
            };
        },
        .cherry_commit => {
            const hash = try self.gpa.dupe(u8, self.git_refs.commits.items[item].hash);
            defer self.gpa.free(hash);
            return git_commands.stoppable(self, root, self.git.cherryPick(self.io, root, hash));
        },
        .compare_file => {
            const file = self.git_refs.files.items[item];
            var label_buf: [160]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "HEAD..{s}", .{self.picker_rev.items}) catch self.picker_rev.items;
            return self.openRevDiff("HEAD", self.picker_rev.items, file, label);
        },
        .delete_tag => return deleteTag(self, root, self.git_refs.tags.items[item].name),
        else => {},
    }
    const b = self.git_refs.branches.items[item];
    switch (self.picker_mode) {
        .checkout => if (action) |a| switch (a) {
            .merge => try mergeBranch(self, root, b.name),
            .rename => try renameBranch(self, root, b.name),
            .delete => try deleteBranch(self, root, b.name),
            else => {},
        } else if (!b.current) try checkout(self, root, b),
        // The new branch's name is typed in the Git view's box.
        .branch_from => {
            self.showView(.git);
            try self.git_panel.ask(.create_branch_from, b.name);
            self.side_focus = .git_prompt;
        },
        .merge => try mergeBranch(self, root, b.name),
        .rebase => {
            const onto = try self.gpa.dupe(u8, b.name);
            defer self.gpa.free(onto);
            try git_commands.stoppable(self, root, self.git.rebase(self.io, root, onto));
        },
        // The branch is remembered: the next list is made from it.
        .cherry_branch, .compare => {
            self.picker_rev.clearRetainingCapacity();
            try self.picker_rev.appendSlice(self.gpa, b.name);
            if (self.picker_mode == .compare) {
                try openComparePicker(self, root, self.picker_rev.items);
            } else {
                try openCommitPicker(self, root, self.picker_rev.items);
            }
        },
        .stash, .cherry_commit, .compare_file, .delete_tag, .command, .go_to_line, .symbol, .workspace_symbol, .problems => unreachable,
    }
}

fn deleteTag(self: *App, root: []const u8, name: []const u8) !void {
    const t = i18n.tr().git;
    const question = try i18n.fillAlloc(self.gpa, t.delete_tag_question, .{name});
    defer self.gpa.free(question);
    if (!self.confirm(question, t.delete_tag_detail, t.action_delete)) return;
    self.gitAction(self.git.deleteTag(self.io, root, name));
}

/// Moves onto a branch: a remote's gets a local one that follows it.
/// The files it changes are read again.
fn checkout(self: *App, root: []const u8, b: core.GitRefs.Branch) !void {
    const result = if (b.remote) self.git.checkoutRemote(self.io, root, b.name) else self.git.checkout(self.io, root, b.name);
    self.gitAction(result);
    try self.refreshProject();
    try self.reloadUnchangedTabs();
}

/// Merges a branch into the one checked out; it may stop at a conflict.
fn mergeBranch(self: *App, root: []const u8, name: []const u8) !void {
    const branch = try self.gpa.dupe(u8, name);
    defer self.gpa.free(branch);
    try git_commands.stoppable(self, root, self.git.merge(self.io, root, branch));
}

fn renameBranch(self: *App, root: []const u8, old: []const u8) !void {
    const t = i18n.tr().git;
    const title = try i18n.fillAlloc(self.gpa, t.rename_title, .{old});
    defer self.gpa.free(title);
    const new = try self.askText(title, t.new_name, false) orelse return;
    defer self.gpa.free(new);
    const name = std.mem.trim(u8, new, " \t");
    if (name.len == 0 or std.mem.eql(u8, name, old)) return;
    self.gitAction(self.git.renameBranch(self.io, root, old, name));
}

/// Deletes a branch after asking. One that isn't merged anywhere is
/// asked about again: its commits would be lost.
fn deleteBranch(self: *App, root: []const u8, name: []const u8) !void {
    const t = i18n.tr().git;
    const question = try i18n.fillAlloc(self.gpa, t.delete_branch_question, .{name});
    defer self.gpa.free(question);
    if (!self.confirm(question, t.delete_branch_detail, t.action_delete)) return;
    self.git.deleteBranch(self.io, root, name, false) catch |err| {
        if (std.mem.indexOf(u8, self.git.last_error.items, "not fully merged") == null) return self.gitAction(err);
        const unmerged = try i18n.fillAlloc(self.gpa, t.unmerged_question, .{name});
        defer self.gpa.free(unmerged);
        if (!self.confirm(unmerged, t.unmerged_detail, t.action_delete)) return;
        return self.gitAction(self.git.deleteBranch(self.io, root, name, true));
    };
    self.gitChanged();
}

const StashAction = enum { pop, apply };

/// Brings a stash's changes back; the files they touch are read again.
fn stashAction(self: *App, root: []const u8, ref: []const u8, what: StashAction) !void {
    self.gitAction(switch (what) {
        .pop => self.git.stashPopAt(self.io, root, ref),
        .apply => self.git.stashApply(self.io, root, ref),
    });
    try self.refreshProject();
    try self.reloadUnchangedTabs();
}

fn dropStash(self: *App, root: []const u8, s: core.GitRefs.Stash) !void {
    const t = i18n.tr().git;
    const question = try i18n.fillAlloc(self.gpa, t.drop_stash_question, .{s.ref});
    defer self.gpa.free(question);
    if (!self.confirm(question, t.drop_stash_detail, t.action_drop)) return;
    self.gitAction(self.git.stashDrop(self.io, root, s.ref));
}

/// "Stash": asks for a message to find the changes by later (it can be
/// left empty), then puts them aside.
pub fn stashWithMessage(self: *App, root: []const u8) !void {
    const t = i18n.tr().git;
    const message = try self.askText(t.stash_title, t.stash_message, false) orelse return;
    defer self.gpa.free(message);
    self.gitAction(self.git.stash(self.io, root, std.mem.trim(u8, message, " \t")));
    try self.refreshProject();
    try self.reloadUnchangedTabs();
}
