//! The project sidebar: the opened folder's file tree, on the left. Its
//! header has "new file" and "new folder" buttons; creating either shows a
//! name box as a row in the tree, at the top of the target folder. Renaming
//! shows the name box in place of the renamed row.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");
const TextField = @import("../widgets/TextField.zig");
const file_icon = @import("../widgets/lib/file_icon.zig");
const Sidebar_draw = @import("Sidebar_draw.zig");

const FileTree = core.FileTree;
const Sidebar = @This();

const row_height = theme.line_height;
pub const indent: f32 = 14;
pub const pad: f32 = 10;
pub const arrow_size: f32 = 8;
/// From a row's arrow column to its name: room for the 16-wide file icons
/// centered on that column.
pub const name_gap: f32 = 10;
const button_size: f32 = 22;

/// A new file or folder being named, in folder node `folder` — or, with
/// `renaming`, a new name for that existing node.
pub const Input = struct {
    folder: u32,
    kind: FileTree.EntryKind,
    renaming: ?u32 = null,
};

/// What the sidebar shows, picked with the strip of tabs at its top.
pub const View = enum { explorer, search, git };

/// The buttons that follow the view tabs in the strip (see `strip_buttons`).
pub const StripButton = enum { terminal, open_folder, help, settings };

/// Height of that strip of view tabs.
pub const strip_height: f32 = 34;
/// Tabs and buttons share one slot width, so the strip reads as one row.
const strip_item_width: f32 = 32;
/// Left edge of the tabs, and the break between them and the buttons.
const strip_pad: f32 = 4;
const strip_gap: f32 = 6;

/// What's under the mouse.
pub const Hit = union(enum) {
    /// A view tab in the top strip.≠≠
    view_tab: View,
    /// The Search or Git view's area (they handle the mouse themselves).
    panel,
    /// A button after the tabs in the strip.
    strip_button: StripButton,
    /// A tree node, by index into `FileTree.nodes`.
    node: u32,
    input,
    new_button: FileTree.EntryKind,
    collapse_button,
    /// Empty space below the rows.
    empty,
};

/// Hidden with Cmd+B; only shown while a folder is open.
visible: bool = true,
view: View = .explorer,
/// Pixels scrolled down the list of rows; kept within [0, max_scroll].
scroll: f32 = 0,
/// How far the list can scroll; set by `layout`.
max_scroll: f32 = 0,
/// Area of the sidebar; zero width when hidden. Set by `layout`.
rect: rl.Rectangle = std.mem.zeroes(rl.Rectangle),
/// What's under the mouse, for hover highlighting.
hovered: ?Hit = null,
/// The Git tab's tooltip is showing. It only opens from that tab, so the
/// room it takes is free for the buttons under it until then.
git_tip_open: bool = false,
/// Display row to scroll into view at the next layout.
pending_reveal: ?usize = null,
/// Width asked for (dragging the right edge); the actual width is limited
/// by the window. Kept in Settings.
preferred_width: f32 = theme.sidebar_width,
/// The right edge is being dragged.
resizing: bool = false,
/// Dragging the scrollbar thumb, grabbed this far below its top.
scrollbar_drag: ?f32 = null,
input: ?Input = null,
/// The name box's text.
name: TextField,
/// While dragging an entry: the folder it would be dropped into (0 = the
/// project folder), and the dragged name shown at the cursor.
drop_target: ?u32 = null,
drag_label: ?[]const u8 = null,

// Drawing, in Sidebar_draw.zig.
pub const draw = Sidebar_draw.draw;
pub const drawDragLabel = Sidebar_draw.drawDragLabel;
pub const drawGitBadgeTooltip = Sidebar_draw.drawGitBadgeTooltip;
pub const gitBadgeTooltip = Sidebar_draw.gitBadgeTooltip;
pub const updateGitBadgeTooltip = Sidebar_draw.updateGitBadgeTooltip;

pub fn init(gpa: std.mem.Allocator) Sidebar {
    return .{ .name = .init(gpa) };
}

pub fn deinit(self: *Sidebar) void {
    self.name.deinit();
}

/// Back to the top, with no name box (e.g. when another folder opens).
pub fn reset(self: *Sidebar) void {
    self.scroll = 0;
    self.pending_reveal = null;
    self.input = null;
}

pub const min_width: f32 = 140;

/// The right edge, which drags to resize (a few units either side of it).
pub fn onEdge(self: *const Sidebar, p: rl.Vector2) bool {
    return self.rect.width > 0 and @abs(p.x - self.rect.width) <= 4 and p.y >= 0 and p.y <= self.rect.height;
}

/// Width taken from the window (0 when hidden).
pub fn width(self: *const Sidebar) f32 {
    return self.rect.width;
}

/// Shows the name box for a new entry in `folder` (which must be expanded).
pub fn startInput(self: *Sidebar, tree: *const FileTree, folder: u32, kind: FileTree.EntryKind) !void {
    self.input = .{ .folder = folder, .kind = kind };
    try self.name.setText("");
    self.visible = true;
    self.pending_reveal = self.inputRow(tree);
}

/// Shows the name box over `node`'s row, filled with its name and the part
/// before the extension selected.
pub fn startRename(self: *Sidebar, tree: *const FileTree, node: u32) !void {
    const n = tree.node(node);
    self.input = .{ .folder = n.parent, .kind = if (n.is_dir) .folder else .file, .renaming = node };
    try self.name.setText(n.name);
    const stem = if (n.is_dir) n.name.len else std.mem.lastIndexOfScalar(u8, n.name, '.') orelse n.name.len;
    self.name.buffer.moveTo(0, false);
    self.name.buffer.moveTo(if (stem == 0) n.name.len else stem, true); // ".env": select all
    self.visible = true;
    self.pending_reveal = self.inputRow(tree);
}

pub fn cancelInput(self: *Sidebar) void {
    self.input = null;
}

// ------------------------------------------------------------------- rows

/// Display row of the name box: the renamed node's row, or first inside the
/// target folder.
fn inputRow(self: *const Sidebar, tree: *const FileTree) ?usize {
    const in = self.input orelse return null;
    if (in.renaming) |node| return std.mem.indexOfScalar(u32, tree.rows.items, node);
    if (in.folder == 0) return 0;
    const row = std.mem.indexOfScalar(u32, tree.rows.items, in.folder) orelse return 0;
    return row + 1;
}

/// Tree rows, plus the name box when it's an extra row (not renaming).
pub fn rowCount(self: *const Sidebar, tree: *const FileTree) usize {
    const extra = if (self.input) |in| in.renaming == null else false;
    return tree.rows.items.len + @intFromBool(extra);
}

/// The node shown at a display row, or null for the name box.
pub fn nodeAtRow(self: *const Sidebar, tree: *const FileTree, row: usize) ?u32 {
    const input_row = self.inputRow(tree);
    if (input_row == row) return null;
    const renaming = self.input != null and self.input.?.renaming != null;
    const tree_row = if (!renaming and input_row != null and row > input_row.?) row - 1 else row;
    return tree.rows.items[tree_row];
}

/// Scrolls so the tree row `row` is visible (applied at the next layout).
pub fn revealRow(self: *Sidebar, row: usize) void {
    self.pending_reveal = row;
}

/// The explorer's header (project name and buttons) sits below the strip.
pub const header_height: f32 = row_height + 10;

/// Top of the first row, below the view strip and the folder-name header.
pub fn listTop() f32 {
    return strip_height + header_height;
}

/// Where the Search and Git views draw: below the view strip.
pub fn contentRect(self: *const Sidebar) rl.Rectangle {
    return .{ .x = 0, .y = strip_height, .width = self.rect.width - 1, .height = self.rect.height - strip_height };
}

/// The buttons, left to right, in the order they follow the view tabs.
pub const strip_buttons = [_]StripButton{ .terminal, .open_folder, .help, .settings };

/// Dropped from the strip's right end as the sidebar narrows, least useful
/// first, rather than drawing buttons on top of each other.
const strip_drop_order = [_]StripButton{ .help, .open_folder, .terminal, .settings };

/// Where the buttons start: after the last view tab.
fn stripButtonsLeft() f32 {
    return viewTabRect(.git).x + strip_item_width + strip_gap;
}

/// A button's place in the strip: the slots after the tabs, skipping the
/// ones a narrow sidebar has no room for.
pub fn stripButtonRect(self: *const Sidebar, button: StripButton) rl.Rectangle {
    var slot: f32 = 0;
    for (strip_buttons) |other| {
        if (other == button) break;
        if (self.stripButtonVisible(other)) slot += 1;
    }
    return .{ .x = stripButtonsLeft() + slot * strip_item_width, .y = 0, .width = strip_item_width, .height = strip_height };
}

pub fn stripButtonVisible(self: *const Sidebar, button: StripButton) bool {
    const room = self.rect.width - strip_pad - stripButtonsLeft();
    const fits: usize = @intFromFloat(@max(0, @floor(room / strip_item_width)));
    const dropped = strip_buttons.len -| fits;
    for (strip_drop_order[0..dropped]) |d| {
        if (d == button) return false;
    }
    return true;
}

pub fn viewTabRect(view: View) rl.Rectangle {
    return .{ .x = strip_pad + @as(f32, @floatFromInt(@intFromEnum(view))) * strip_item_width, .y = 0, .width = strip_item_width, .height = strip_height };
}

/// Header buttons, right to left: collapse all, new folder, new file.
fn headerButton(self: *const Sidebar, slot: usize) rl.Rectangle {
    const right = self.rect.width - 8 - @as(f32, @floatFromInt(slot)) * (button_size + 2);
    return .{ .x = right - button_size, .y = strip_height + (header_height - button_size) / 2, .width = button_size, .height = button_size };
}

pub fn buttonRect(self: *const Sidebar, kind: FileTree.EntryKind) rl.Rectangle {
    return self.headerButton(if (kind == .folder) 1 else 2);
}

pub fn collapseRect(self: *const Sidebar) rl.Rectangle {
    return self.headerButton(0);
}

pub fn inputRect(self: *const Sidebar, tree: *const FileTree, row: usize) rl.Rectangle {
    const in = self.input.?;
    const depth: f32 = if (in.renaming) |node|
        @floatFromInt(tree.node(node).depth)
    else if (in.folder == 0) 0 else @floatFromInt(tree.node(in.folder).depth + 1);
    const x = pad + depth * indent + arrow_size + name_gap - 4;
    const top = listTop() + @as(f32, @floatFromInt(row)) * row_height - self.scroll;
    return .{ .x = x, .y = top + 1, .width = @max(40, self.rect.width - x - 6), .height = row_height - 2 };
}

// ----------------------------------------------------------------- layout

pub fn layout(self: *Sidebar, tree: ?*const FileTree, size: rl.Vector2, font: Font) void {
    const shown = self.visible and tree != null;
    // At least 140 wide, and always leaving 300 for the editor.
    const w = std.math.clamp(self.preferred_width, min_width, @max(min_width, size.x - 300));
    self.rect = .{ .x = 0, .y = 0, .width = if (shown) w else 0, .height = size.y };
    if (!shown) return;
    const t = tree.?;

    if (self.pending_reveal) |row| {
        self.pending_reveal = null;
        const top = @as(f32, @floatFromInt(row)) * row_height;
        const view_h = self.rect.height - listTop();
        if (top < self.scroll) self.scroll = top;
        if (top + row_height > self.scroll + view_h) self.scroll = top + row_height - view_h;
    }

    // Keep the scroll within the list.
    const content = @as(f32, @floatFromInt(self.rowCount(t))) * row_height;
    self.max_scroll = @max(0, content - (size.y - listTop()));
    self.scroll = std.math.clamp(self.scroll, 0, self.max_scroll);

    if (self.inputRow(t)) |row| self.name.layout(self.inputRect(t, row).width, font);
    const mouse = rl.getMousePosition();
    self.hovered = if (self.contains(mouse)) self.hitTest(t, mouse) else null;
}

pub fn contains(self: *const Sidebar, p: rl.Vector2) bool {
    return self.rect.width > 0 and rl.checkCollisionPointRec(p, self.rect);
}

/// Scrolls by mouse-wheel ticks. Clamped right away: drawing can happen
/// before the next `layout`.
pub fn scrollBy(self: *Sidebar, wheel_y: f32) void {
    self.scroll = std.math.clamp(self.scroll - wheel_y * row_height * 3, 0, self.max_scroll);
}

pub fn hitTest(self: *const Sidebar, tree: *const FileTree, p: rl.Vector2) ?Hit {
    if (!self.contains(p)) return null;
    if (p.y < strip_height) {
        inline for (@typeInfo(View).@"enum".fields) |f| {
            const v: View = @enumFromInt(f.value);
            if (rl.checkCollisionPointRec(p, viewTabRect(v))) return .{ .view_tab = v };
        }
        for (strip_buttons) |b| {
            if (self.stripButtonVisible(b) and rl.checkCollisionPointRec(p, self.stripButtonRect(b))) return .{ .strip_button = b };
        }
        return null;
    }
    if (self.view != .explorer) return .panel;
    if (p.y < listTop()) {
        for ([_]FileTree.EntryKind{ .file, .folder }) |kind| {
            if (rl.checkCollisionPointRec(p, self.buttonRect(kind))) return .{ .new_button = kind };
        }
        if (rl.checkCollisionPointRec(p, self.collapseRect())) return .collapse_button;
        return null;
    }
    const row: usize = @intFromFloat((p.y - listTop() + self.scroll) / row_height);
    if (row >= self.rowCount(tree)) return .empty;
    return if (self.nodeAtRow(tree, row)) |n| .{ .node = n } else .input;
}

/// While dragging near the top or bottom edge, scrolls the list.
// -------------------------------------------------------------- scrollbar

const scrollbar_width: f32 = 6;
/// The grab area is wider than the thin bar, so it's easy to hit.
pub const scrollbar_grab: f32 = 12;

/// The strip along the right edge of the list.
fn scrollbarTrack(self: *const Sidebar) rl.Rectangle {
    return .{ .x = self.rect.width - scrollbar_width - 3, .y = listTop() + 2, .width = scrollbar_width, .height = @max(0, self.rect.height - listTop() - 4) };
}

/// The draggable part, sized by how much of the list is visible; null
/// when everything fits.
pub fn scrollbarThumb(self: *const Sidebar) ?rl.Rectangle {
    if (self.max_scroll <= 0) return null;
    const track = self.scrollbarTrack();
    const content = track.height + self.max_scroll;
    const h = @max(24, track.height * track.height / content);
    return .{ .x = track.x, .y = track.y + (track.height - h) * (self.scroll / self.max_scroll), .width = track.width, .height = h };
}

pub fn onScrollbar(self: *const Sidebar, p: rl.Vector2) bool {
    const t = self.scrollbarTrack();
    return self.scrollbarThumb() != null and p.x >= self.rect.width - scrollbar_grab and p.x < self.rect.width and p.y >= t.y and p.y <= t.y + t.height;
}

/// Mouse on the scrollbar: drag the thumb, or click the track to jump
/// there. Returns true while it has the mouse.
pub fn handleScrollbar(self: *Sidebar, p: rl.Vector2, pressed: bool) bool {
    if (self.view != .explorer) return false;
    const thumb = self.scrollbarThumb() orelse {
        self.scrollbar_drag = null;
        return false;
    };
    if (pressed and self.onScrollbar(p)) {
        // On the thumb: keep the grab point; on the track: center it there.
        self.scrollbar_drag = if (p.y >= thumb.y and p.y <= thumb.y + thumb.height) p.y - thumb.y else thumb.height / 2;
    }
    const grab = self.scrollbar_drag orelse return false;
    if (!rl.isMouseButtonDown(.left)) {
        self.scrollbar_drag = null;
        return pressed;
    }
    const track = self.scrollbarTrack();
    const t = (p.y - grab - track.y) / @max(1, track.height - thumb.height);
    self.scroll = std.math.clamp(t, 0, 1) * self.max_scroll;
    return true;
}

pub fn autoScroll(self: *Sidebar, p: rl.Vector2) void {
    const edge = row_height;
    if (p.y < listTop() + edge) self.scroll = @max(0, self.scroll - 6);
    if (p.y > self.rect.height - edge) self.scroll = @min(self.max_scroll, self.scroll + 6);
}

/// Places the name box's cursor at a click.
pub fn clickInput(self: *Sidebar, tree: *const FileTree, p: rl.Vector2, font: Font) void {
    const row = self.inputRow(tree) orelse return;
    const r = self.inputRect(tree, row);
    self.name.buffer.moveTo(self.name.posAtX(r, font, p.x), false);
}
