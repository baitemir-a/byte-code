//! The project sidebar: the opened folder's file tree, on the left. Its
//! header has "new file" and "new folder" buttons; creating either shows a
//! name box as a row in the tree, at the top of the target folder. Renaming
//! shows the name box in place of the renamed row.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("theme.zig");
const Font = @import("Font.zig");
const TextField = @import("TextField.zig");
const file_icon = @import("file_icon.zig");

const FileTree = core.FileTree;
const Sidebar = @This();

const row_height = theme.line_height;
const indent: f32 = 14;
const pad: f32 = 10;
const arrow_size: f32 = 8;
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

/// Height of that strip of view tabs.
pub const strip_height: f32 = 34;
const view_tab_width: f32 = 40;

/// What's under the mouse.
pub const Hit = union(enum) {
    /// A view tab in the top strip.
    view_tab: View,
    /// The Search or Git view's area (they handle the mouse themselves).
    panel,
    /// Buttons at the right of the strip.
    open_folder_button,
    settings_button,
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
fn rowCount(self: *const Sidebar, tree: *const FileTree) usize {
    const extra = if (self.input) |in| in.renaming == null else false;
    return tree.rows.items.len + @intFromBool(extra);
}

/// The node shown at a display row, or null for the name box.
fn nodeAtRow(self: *const Sidebar, tree: *const FileTree, row: usize) ?u32 {
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
const header_height: f32 = row_height + 10;

/// Top of the first row, below the view strip and the folder-name header.
fn listTop() f32 {
    return strip_height + header_height;
}

/// Where the Search and Git views draw: below the view strip.
pub fn contentRect(self: *const Sidebar) rl.Rectangle {
    return .{ .x = 0, .y = strip_height, .width = self.rect.width - 1, .height = self.rect.height - strip_height };
}

/// The strip's buttons at its right end: settings last, open-folder before it.
fn stripButtonRect(self: *const Sidebar, slot: usize) rl.Rectangle {
    const w: f32 = 32;
    return .{ .x = self.rect.width - 8 - @as(f32, @floatFromInt(slot + 1)) * w, .y = 0, .width = w, .height = strip_height };
}

fn viewTabRect(view: View) rl.Rectangle {
    return .{ .x = 6 + @as(f32, @floatFromInt(@intFromEnum(view))) * view_tab_width, .y = 0, .width = view_tab_width, .height = strip_height };
}

/// Header buttons, right to left: collapse all, new folder, new file.
fn headerButton(self: *const Sidebar, slot: usize) rl.Rectangle {
    const right = self.rect.width - 8 - @as(f32, @floatFromInt(slot)) * (button_size + 2);
    return .{ .x = right - button_size, .y = strip_height + (header_height - button_size) / 2, .width = button_size, .height = button_size };
}

fn buttonRect(self: *const Sidebar, kind: FileTree.EntryKind) rl.Rectangle {
    return self.headerButton(if (kind == .folder) 1 else 2);
}

fn collapseRect(self: *const Sidebar) rl.Rectangle {
    return self.headerButton(0);
}

fn inputRect(self: *const Sidebar, tree: *const FileTree, row: usize) rl.Rectangle {
    const in = self.input.?;
    const depth: f32 = if (in.renaming) |node|
        @floatFromInt(tree.node(node).depth)
    else if (in.folder == 0) 0 else @floatFromInt(tree.node(in.folder).depth + 1);
    const x = pad + depth * indent + arrow_size + 2;
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
        if (rl.checkCollisionPointRec(p, self.stripButtonRect(0))) return .settings_button;
        if (rl.checkCollisionPointRec(p, self.stripButtonRect(1))) return .open_folder_button;
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
const scrollbar_grab: f32 = 12;

/// The strip along the right edge of the list.
fn scrollbarTrack(self: *const Sidebar) rl.Rectangle {
    return .{ .x = self.rect.width - scrollbar_width - 3, .y = listTop() + 2, .width = scrollbar_width, .height = @max(0, self.rect.height - listTop() - 4) };
}

/// The draggable part, sized by how much of the list is visible; null
/// when everything fits.
fn scrollbarThumb(self: *const Sidebar) ?rl.Rectangle {
    if (self.max_scroll <= 0) return null;
    const track = self.scrollbarTrack();
    const content = track.height + self.max_scroll;
    const h = @max(24, track.height * track.height / content);
    return .{ .x = track.x, .y = track.y + (track.height - h) * (self.scroll / self.max_scroll), .width = track.width, .height = h };
}

fn onScrollbar(self: *const Sidebar, p: rl.Vector2) bool {
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

fn drawScrollbar(self: *const Sidebar) void {
    const thumb = self.scrollbarThumb() orelse return;
    const active = self.scrollbar_drag != null or self.onScrollbar(rl.getMousePosition());
    rl.drawRectangleRounded(thumb, 1, 6, if (active) theme.scrollbar_thumb_hover else theme.scrollbar_thumb);
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

// ------------------------------------------------------------------- draw

pub fn draw(self: *const Sidebar, tree: ?*const FileTree, current_path: ?[]const u8, font: Font, show_caret: bool) void {
    if (self.rect.width == 0) return;
    const r = self.rect;
    rl.drawRectangleRec(r, theme.sidebar_background);
    rl.drawRectangleRec(.{ .x = r.width - 1, .y = 0, .width = 1, .height = r.height }, theme.sidebar_border);
    self.drawViewStrip();
    if (self.view == .explorer) self.drawExplorer(tree.?, current_path, font, show_caret);

    // The resize edge lights up while hovered or dragged.
    if (self.resizing or self.onEdge(rl.getMousePosition())) {
        rl.drawRectangleRec(.{ .x = r.width - 3, .y = 0, .width = 2, .height = r.height }, theme.accent);
    }
}

/// The view tabs: Explorer, Search, Git, as icons. The current one is in
/// the accent color with a line under it.
fn drawViewStrip(self: *const Sidebar) void {
    const mouse = rl.getMousePosition();
    inline for (@typeInfo(View).@"enum".fields) |f| {
        const v: View = @enumFromInt(f.value);
        const tab = viewTabRect(v);
        const active = self.view == v;
        const hovered = rl.checkCollisionPointRec(mouse, tab);
        const color = if (active) theme.accent else if (hovered) theme.foreground else theme.sidebar_arrow;
        const c: rl.Vector2 = .{ .x = tab.x + tab.width / 2, .y = tab.y + tab.height / 2 };
        switch (v) {
            .explorer => {
                // Two stacked pages.
                rl.drawRectangleLinesEx(.{ .x = c.x - 3, .y = c.y - 8, .width = 10, .height = 13 }, 1.3, color);
                rl.drawRectangleRec(.{ .x = c.x - 7, .y = c.y - 4, .width = 10, .height = 13 }, theme.sidebar_background);
                rl.drawRectangleLinesEx(.{ .x = c.x - 7, .y = c.y - 4, .width = 10, .height = 13 }, 1.3, color);
            },
            .search => {
                // A magnifying glass.
                rl.drawCircleLinesV(.{ .x = c.x - 2, .y = c.y - 2 }, 6, color);
                rl.drawCircleLinesV(.{ .x = c.x - 2, .y = c.y - 2 }, 5.4, color);
                rl.drawLineEx(.{ .x = c.x + 2.5, .y = c.y + 2.5 }, .{ .x = c.x + 7, .y = c.y + 7 }, 2, color);
            },
            .git => {
                // A branch: a trunk with a side branch joining it.
                rl.drawLineEx(.{ .x = c.x - 4, .y = c.y - 6 }, .{ .x = c.x - 4, .y = c.y + 6 }, 1.5, color);
                rl.drawLineEx(.{ .x = c.x + 4, .y = c.y - 3 }, .{ .x = c.x - 4, .y = c.y + 3 }, 1.5, color);
                rl.drawCircleV(.{ .x = c.x - 4, .y = c.y - 7 }, 2.3, color);
                rl.drawCircleV(.{ .x = c.x - 4, .y = c.y + 7 }, 2.3, color);
                rl.drawCircleV(.{ .x = c.x + 4, .y = c.y - 4 }, 2.3, color);
            },
        }
        if (active) rl.drawRectangleRec(.{ .x = tab.x + 8, .y = tab.y + tab.height - 2, .width = tab.width - 16, .height = 2 }, theme.accent);
    }

    // Open folder, and settings.
    for ([_]usize{ 1, 0 }) |slot| {
        const b = self.stripButtonRect(slot);
        const hovered = rl.checkCollisionPointRec(mouse, b);
        const color = if (hovered) theme.foreground else theme.sidebar_arrow;
        const c: rl.Vector2 = .{ .x = b.x + b.width / 2, .y = b.y + b.height / 2 };
        if (hovered) rl.drawRectangleRounded(.{ .x = b.x + 3, .y = b.y + 4, .width = b.width - 6, .height = b.height - 8 }, 0.3, 6, theme.sidebar_hover);
        if (slot == 0) drawGear(c, color) else drawOpenFolder(c, color);
    }
    rl.drawRectangleRec(.{ .x = 0, .y = strip_height - 1, .width = self.rect.width - 1, .height = 1 }, theme.sidebar_border);
}

/// A gear: a ring with teeth and a hole.
fn drawGear(c: rl.Vector2, color: rl.Color) void {
    for (0..8) |i| {
        const a = @as(f32, @floatFromInt(i)) * std.math.pi / 4;
        const dir: rl.Vector2 = .{ .x = @cos(a), .y = @sin(a) };
        rl.drawLineEx(.{ .x = c.x + dir.x * 5, .y = c.y + dir.y * 5 }, .{ .x = c.x + dir.x * 8, .y = c.y + dir.y * 8 }, 2.4, color);
    }
    rl.drawCircleV(c, 6, color);
    rl.drawCircleV(c, 2.5, theme.sidebar_background);
}

/// A folder with a plus.
fn drawOpenFolder(c: rl.Vector2, color: rl.Color) void {
    rl.drawRectangleLinesEx(.{ .x = c.x - 8, .y = c.y - 4, .width = 14, .height = 10 }, 1.3, color);
    rl.drawRectangleRec(.{ .x = c.x - 8, .y = c.y - 6, .width = 6, .height = 3 }, color);
    rl.drawRectangleRec(.{ .x = c.x + 1, .y = c.y + 1, .width = 9, .height = 9 }, theme.sidebar_background);
    rl.drawLineEx(.{ .x = c.x + 2, .y = c.y + 5.5 }, .{ .x = c.x + 9, .y = c.y + 5.5 }, 1.5, theme.foreground);
    rl.drawLineEx(.{ .x = c.x + 5.5, .y = c.y + 2 }, .{ .x = c.x + 5.5, .y = c.y + 9 }, 1.5, theme.foreground);
}

fn drawExplorer(self: *const Sidebar, t: *const FileTree, current_path: ?[]const u8, font: Font, show_caret: bool) void {
    const r = self.rect;

    // Clip long names at the sidebar's edge (and below the view strip).
    theme.clip(.{ .x = 0, .y = strip_height, .width = r.width - 1, .height = r.height - strip_height });
    defer rl.endScissorMode();

    const text_dy = (row_height - theme.font_size) / 2;
    // Visible rows only. Clamped, so a stale scroll (e.g. rows just
    // collapsed) can never make an empty or backwards range.
    const total = self.rowCount(t);
    const first = @min(total, @as(usize, @intFromFloat(@max(0, self.scroll) / row_height)));
    const count: usize = @intFromFloat(r.height / row_height + 2);
    for (first..@min(first + count, total)) |row| {
        const top = listTop() + @as(f32, @floatFromInt(row)) * row_height - self.scroll;
        const index = self.nodeAtRow(t, row) orelse {
            self.drawInput(t, row, font, show_caret);
            continue;
        };
        const n = t.node(index);

        const is_current = if (current_path) |p| std.mem.eql(u8, p, n.path) else false;
        const hovered = if (self.hovered) |h| h == .node and h.node == index else false;
        const is_drop = self.drop_target == index;
        const bg: ?rl.Color = if (is_drop) theme.accentDim(0.25) else if (is_current) theme.accentDim(0.35) else if (hovered) theme.sidebar_hover else null;
        const row_rect: rl.Rectangle = .{ .x = 0, .y = top, .width = r.width - 1, .height = row_height };
        if (bg) |c| rl.drawRectangleRec(row_rect, c);
        if (is_drop) rl.drawRectangleLinesEx(row_rect, 1, theme.accent);

        const x = pad + @as(f32, @floatFromInt(n.depth)) * indent;
        const mid = top + row_height / 2;
        // Folders get their arrow, files a colored dot for their language.
        if (n.is_dir) drawArrow(x, mid, n.expanded) else file_icon.draw(n.name, .{ .x = x + arrow_size / 2, .y = mid });
        const color = if (n.is_dir) theme.sidebar_folder else theme.foreground;
        // Long names end in "…" before the scrollbar.
        _ = font.drawFit(n.name, x + arrow_size + 6, top + text_dy, r.width - scrollbar_grab - 2, color);
    }

    // Dropping into the project folder itself: outline the whole list.
    if (self.drop_target == 0) {
        rl.drawRectangleLinesEx(.{ .x = 1, .y = listTop(), .width = r.width - 3, .height = r.height - listTop() - 1 }, 1, theme.accent);
    }

    self.drawScrollbar();

    // Header over rows scrolled beneath it: folder name and the buttons.
    rl.drawRectangleRec(.{ .x = 0, .y = strip_height, .width = r.width - 1, .height = header_height }, theme.sidebar_background);
    const buttons_left = self.buttonRect(.file).x - 6;
    _ = font.drawFit(t.root().name, pad, strip_height + (header_height - theme.font_size) / 2, buttons_left, theme.sidebar_header);
    for ([_]FileTree.EntryKind{ .file, .folder }) |kind| {
        const b = self.buttonRect(kind);
        const hovered = if (self.hovered) |h| h == .new_button and h.new_button == kind else false;
        rl.drawRectangleRec(b, theme.sidebar_background); // cover a long folder name
        if (hovered) rl.drawRectangleRec(b, theme.sidebar_hover);
        drawNewIcon(b, kind);
    }
    const c = self.collapseRect();
    rl.drawRectangleRec(c, theme.sidebar_background);
    if (self.hovered) |h| if (h == .collapse_button) rl.drawRectangleRec(c, theme.sidebar_hover);
    drawCollapseIcon(c);
}

/// "Collapse all": two stacked squares, the front one with a minus.
fn drawCollapseIcon(b: rl.Rectangle) void {
    const col = theme.sidebar_arrow;
    const x = b.x + 5;
    const y = b.y + 5;
    // The back square shows only its top and right edges.
    rl.drawRectangleRec(.{ .x = x + 3, .y = y, .width = 10, .height = 1.2 }, col);
    rl.drawRectangleRec(.{ .x = x + 12, .y = y, .width = 1.2, .height = 10 }, col);
    const front: rl.Rectangle = .{ .x = x, .y = y + 3, .width = 10, .height = 10 };
    rl.drawRectangleLinesEx(front, 1.2, col);
    rl.drawRectangleRec(.{ .x = front.x + 2.5, .y = front.y + front.height / 2 - 0.6, .width = 5, .height = 1.2 }, theme.foreground);
}

/// The dragged entry's name next to the cursor. Drawn last, over
/// everything, since it can leave the sidebar.
pub fn drawDragLabel(self: *const Sidebar, font: Font) void {
    const label = self.drag_label orelse return;
    const m = rl.getMousePosition();
    const cols: f32 = @floatFromInt(@min(label.len, 40));
    const box: rl.Rectangle = .{ .x = m.x + 14, .y = m.y + 10, .width = cols * font.cell_width + 16, .height = row_height };
    rl.drawRectangleRec(.{ .x = box.x + 2, .y = box.y + 3, .width = box.width, .height = box.height }, theme.popup_shadow);
    rl.drawRectangleRec(box, theme.popup_background);
    rl.drawRectangleLinesEx(box, 1, theme.popup_border);
    _ = font.drawFit(label, box.x + 8, box.y + (row_height - theme.font_size) / 2, box.x + box.width - 8 + 0.5, theme.foreground);
}

fn drawInput(self: *const Sidebar, tree: *const FileTree, row: usize, font: Font, show_caret: bool) void {
    const r = self.inputRect(tree, row);
    const kind = self.input.?.kind;
    // A folder arrow or file dot in front, like the other rows.
    const mid = r.y + r.height / 2;
    if (kind == .folder) drawArrow(r.x - arrow_size - 4, mid, false) else rl.drawCircleV(.{ .x = r.x - arrow_size / 2 - 4, .y = mid }, 2, theme.sidebar_arrow);
    self.name.draw(r, font, if (kind == .folder) "folder name" else "file name", true, show_caret);
}

/// A page (new file) or folder outline with a small plus.
fn drawNewIcon(b: rl.Rectangle, kind: FileTree.EntryKind) void {
    const c = theme.sidebar_arrow;
    const x = b.x + 4;
    const y = b.y + 4;
    switch (kind) {
        .file => {
            rl.drawRectangleLinesEx(.{ .x = x + 1, .y = y, .width = 10, .height = 13 }, 1.2, c);
        },
        .folder => {
            rl.drawRectangleLinesEx(.{ .x = x - 1, .y = y + 3, .width = 13, .height = 10 }, 1.2, c);
            rl.drawRectangleRec(.{ .x = x - 1, .y = y + 1, .width = 6, .height = 3 }, c);
        },
    }
    // The plus, on a cut-out in the bottom-right corner.
    const px = b.x + b.width - 6;
    const py = b.y + b.height - 6;
    rl.drawRectangleRec(.{ .x = px - 5, .y = py - 5, .width = 10, .height = 10 }, theme.sidebar_background);
    rl.drawLineEx(.{ .x = px - 3.5, .y = py }, .{ .x = px + 3.5, .y = py }, 1.5, theme.foreground);
    rl.drawLineEx(.{ .x = px, .y = py - 3.5 }, .{ .x = px, .y = py + 3.5 }, 1.5, theme.foreground);
}

/// ▸ for a collapsed folder, ▾ for an expanded one. Vertices go
/// counter-clockwise, as raylib requires.
fn drawArrow(x: f32, mid: f32, expanded: bool) void {
    const s = arrow_size;
    if (expanded) {
        rl.drawTriangle(.{ .x = x, .y = mid - s / 3 }, .{ .x = x + s / 2, .y = mid + s / 3 }, .{ .x = x + s, .y = mid - s / 3 }, theme.sidebar_arrow);
    } else {
        rl.drawTriangle(.{ .x = x + s / 4, .y = mid - s / 2 }, .{ .x = x + s / 4, .y = mid + s / 2 }, .{ .x = x + s * 0.85, .y = mid }, theme.sidebar_arrow);
    }
}

