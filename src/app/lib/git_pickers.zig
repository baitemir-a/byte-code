//! The Git view's lists to pick from, at the top of the editor: the
//! branches (to check out, start a branch from, or merge; each row can
//! also be merged, renamed or deleted), and the stashes (to bring back,
//! apply or drop).
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const App = @import("../App.zig");
const Picker = @import("../../ui/Picker.zig");
const i18n = @import("../../i18n/i18n.zig");
const clipboard = @import("clipboard.zig");

pub const Mode = enum { checkout, branch_from, merge, stash };

/// Lists the branches for `mode` (one of the branch ones). While
/// checking out, each row also offers to merge, rename or delete it.
pub fn openBranchPicker(self: *App, mode: Mode) !void {
    const project = if (self.project) |*p| p else return;
    const out = try core.Git.readBranches(self.gpa, self.io, project.root().path) orelse return;
    defer self.gpa.free(out);
    try self.git_refs.parseBranches(out);
    // Merging needs another branch than the one checked out.
    if (mode == .merge) for (self.git_refs.branches.items, 0..) |b, i| if (b.current) {
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
    try self.git_refs.parseStashes(out);
    const t = i18n.tr().git;
    try self.picker.open(t.pick_stash, &.{ .apply, .drop }, &.{ t.action_apply, t.action_drop });
    for (self.git_refs.stashes.items) |s| try self.picker.add(.{ .label = s.message, .detail = s.ref });
    try finishOpening(self, .stash);
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
    switch (cmd) {
        .newline => if (p.selectedItem()) |i| try choose(self, i, null),
        .clear_selection => p.close(),
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
}

/// The mouse while a list is open: a row or one of its buttons is picked,
/// a click elsewhere closes it. Returns whether the mouse was taken.
pub fn pickerMouse(self: *App, point: rl.Vector2, pressed: bool) !bool {
    const hit = self.picker.hitTest(point);
    if (hit != null) self.wanted_cursor = .pointing_hand;
    if (!pressed) return self.picker.contains(point);
    if (hit) |h| {
        try choose(self, h.item, h.action);
        return true;
    }
    if (!self.picker.contains(point)) self.picker.close();
    return true;
}

/// A row was picked (`action` null), or one of its buttons.
fn choose(self: *App, item: u32, action: ?Picker.Action) !void {
    const project = if (self.project) |*p| p else return;
    const root = project.root().path;
    // Closed first: what follows may ask something in a dialog.
    self.picker.close();
    if (self.picker_mode == .stash) {
        const s = self.git_refs.stashes.items[item];
        const a = action orelse return stashAction(self, root, s.ref, .pop);
        return switch (a) {
            .apply => stashAction(self, root, s.ref, .apply),
            .drop => dropStash(self, root, s),
            else => {},
        };
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
        .stash => unreachable,
    }
}

/// Moves onto a branch: a remote's gets a local one that follows it.
/// The files it changes are read again.
fn checkout(self: *App, root: []const u8, b: core.GitRefs.Branch) !void {
    const result = if (b.remote) self.git.checkoutRemote(self.io, root, b.name) else self.git.checkout(self.io, root, b.name);
    self.gitAction(result);
    try self.refreshProject();
    try self.reloadUnchangedTabs();
}

/// Merges a branch into the one checked out. When it stops at a conflict
/// that isn't an error to report: the conflicts show in the Git view.
fn mergeBranch(self: *App, root: []const u8, name: []const u8) !void {
    self.git.merge(self.io, root, name) catch |err| {
        try self.git.refresh(self.io, root);
        if (!self.git.merging) self.gitAction(err);
    };
    self.gitChanged();
    self.showView(.git);
    try self.refreshProject();
    try self.reloadUnchangedTabs();
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
