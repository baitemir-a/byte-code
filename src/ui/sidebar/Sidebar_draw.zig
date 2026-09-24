//! Drawing the sidebar: the view strip, the file tree with its header
//! buttons and name box, the scrollbar and the drag label.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");
const file_icon = @import("../widgets/lib/file_icon.zig");
const Icons = @import("../Icons.zig");
const core = @import("core");
const Sidebar = @import("Sidebar.zig");
const i18n = @import("../../i18n/i18n.zig");
const GitPanel = @import("GitPanel.zig");

/// The round badge on the Git tab's icon.
const badge_font: f32 = Font.small_size;
const badge_size: f32 = badge_font + 4;

const FileTree = core.FileTree;
const row_height = theme.line_height;

pub fn drawScrollbar(self: *const Sidebar) void {
    const thumb = self.scrollbarThumb() orelse return;
    const active = self.scrollbar_drag != null or self.onScrollbar(rl.getMousePosition());
    rl.drawRectangleRounded(thumb, 1, 6, theme.copy(if (active) theme.scrollbar_thumb_hover else theme.scrollbar_thumb));
}

pub fn draw(self: *const Sidebar, tree: ?*const FileTree, current_path: ?[]const u8, font: Font, show_caret: bool, git: *const core.Git) void {
    if (self.rect.width == 0) return;
    const r = self.rect;
    rl.drawRectangleRec(r, theme.sidebar_background);
    rl.drawRectangleRec(.{ .x = r.width - 1, .y = 0, .width = 1, .height = r.height }, theme.sidebar_border);
    drawViewStrip(self, font);
    drawGitBadge(font, git);
    if (self.view == .explorer) drawExplorer(self, tree.?, current_path, font, show_caret);

    // The resize edge lights up while hovered or dragged.
    if (self.resizing or self.onEdge(rl.getMousePosition())) {
        rl.drawRectangleRec(.{ .x = r.width - 3, .y = 0, .width = 2, .height = r.height }, theme.accent);
    }
}

/// How many changes are waiting, on the Git tab's icon: it is the one
/// thing worth seeing while another view is showing.
fn drawGitBadge(font: Font, git: *const core.Git) void {
    const badge = GitPanel.tabBadge(git) orelse return;
    const tab = Sidebar.viewTabRect(.git);
    var digits: [12]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{@min(badge.count, 99)}) catch return;
    const text_w = font.textWidthAt(text, badge_font);
    const w = @max(badge_size, text_w + 6);
    // Over the icon's top-right corner, and never off the top edge.
    const box: rl.Rectangle = .{
        .x = tab.x + tab.width / 2 + 2,
        .y = @max(tab.y + 2, tab.y + tab.height / 2 - badge_size - 1),
        .width = w,
        .height = badge_size,
    };
    rl.drawRectangleRounded(box, 0.5, 8, theme.copy(badge.color));
    const x = box.x + (box.width - text_w) / 2;
    _ = font.drawFitSized(text, x, box.y + (badge_size - badge_font) / 2, box.x + box.width, badge_font, theme.background);
}

/// What the badge stands for, broken down: a row per counter that isn't
/// zero, each in its own color. It shows while the pointer is over the
/// Git tab or over the tooltip itself, so a row can be clicked.
pub const BadgeTooltip = struct {
    box: rl.Rectangle,
    /// Room for the count of each row.
    counts: f32,
    rows: [GitPanel.badge_count]GitPanel.Badge,
    len: usize,

    const pad: f32 = 10;
    const gap: f32 = 8;

    pub fn list(self: *const BadgeTooltip) []const GitPanel.Badge {
        return self.rows[0..self.len];
    }

    pub fn rowRect(self: *const BadgeTooltip, index: usize) rl.Rectangle {
        return .{
            .x = self.box.x,
            .y = self.box.y + pad / 2 + @as(f32, @floatFromInt(index)) * theme.line_height,
            .width = self.box.width,
            .height = theme.line_height,
        };
    }

    /// The counter under a point, for a click.
    pub fn rowAt(self: *const BadgeTooltip, p: rl.Vector2) ?GitPanel.Badge {
        for (self.list(), 0..) |badge, i| {
            if (rl.checkCollisionPointRec(p, self.rowRect(i))) return badge;
        }
        return null;
    }
};

/// The tooltip as it stands, or null when there is nothing to show or
/// the pointer is elsewhere.
pub fn gitBadgeTooltip(font: Font, git: *const core.Git, pointer: rl.Vector2) ?BadgeTooltip {
    var tip: BadgeTooltip = .{ .box = std.mem.zeroes(rl.Rectangle), .counts = badge_size, .rows = undefined, .len = 0 };
    const active = GitPanel.activeBadges(git, &tip.rows);
    tip.len = active.len;
    if (active.len == 0) return null;

    // Wide enough for the longest label, and for the widest count.
    var label_w: f32 = 0;
    var digits: [12]u8 = undefined;
    for (active) |badge| {
        label_w = @max(label_w, font.textWidth(badge.label()));
        const text = std.fmt.bufPrint(&digits, "{d}", .{GitPanel.badgeCount(git, badge)}) catch continue;
        tip.counts = @max(tip.counts, font.textWidthAt(text, badge_font) + 6);
    }
    const pad = BadgeTooltip.pad;
    const tab = Sidebar.viewTabRect(.git);
    const window_width = @as(f32, @floatFromInt(rl.getScreenWidth())) / theme.zoom;
    const width = pad * 2 + tip.counts + BadgeTooltip.gap + label_w;
    tip.box = .{
        .x = @min(tab.x, @max(4, window_width - width - 4)),
        .y = tab.y + tab.height + 4,
        .width = width,
        .height = pad + @as(f32, @floatFromInt(active.len)) * theme.line_height,
    };
    // The pointer can travel from the tab into the tooltip to click a row.
    const reach: rl.Rectangle = .{ .x = tip.box.x, .y = tab.y, .width = @max(tab.width, tip.box.width), .height = tip.box.y + tip.box.height - tab.y };
    const over = rl.checkCollisionPointRec(pointer, tab) or rl.checkCollisionPointRec(pointer, reach);
    return if (over) tip else null;
}

pub fn drawGitBadgeTooltip(font: Font, git: *const core.Git) void {
    const mouse = rl.getMousePosition();
    const tip = gitBadgeTooltip(font, git, mouse) orelse return;
    const box = tip.box;
    rl.drawRectangleRec(.{ .x = box.x + 2, .y = box.y + 3, .width = box.width, .height = box.height }, theme.popup_shadow);
    rl.drawRectangleRec(box, theme.popup_background);
    rl.drawRectangleLinesEx(box, 1, theme.popup_border);
    var digits: [12]u8 = undefined;
    for (tip.list(), 0..) |badge, i| {
        const row = tip.rowRect(i);
        // The row under the pointer lights up: clicking it goes there.
        if (rl.checkCollisionPointRec(mouse, row)) rl.drawRectangleRec(row, theme.sidebar_hover);
        const text = std.fmt.bufPrint(&digits, "{d}", .{GitPanel.badgeCount(git, badge)}) catch continue;
        const pill: rl.Rectangle = .{
            .x = row.x + BadgeTooltip.pad,
            .y = row.y + (row.height - badge_size) / 2,
            .width = tip.counts,
            .height = badge_size,
        };
        rl.drawRectangleRounded(pill, 0.5, 8, theme.copy(badge.color()));
        const text_x = pill.x + (pill.width - font.textWidthAt(text, badge_font)) / 2;
        _ = font.drawFitSized(text, text_x, pill.y + (badge_size - badge_font) / 2, pill.x + pill.width, badge_font, theme.background);
        const ty = row.y + (row.height - theme.font_size) / 2;
        _ = font.drawFit(badge.label(), pill.x + pill.width + BadgeTooltip.gap, ty, box.x + box.width - BadgeTooltip.pad, theme.foreground);
    }
}

/// The view tabs: Explorer, Search, Git, as icons. The current one is in
/// the accent color with a line under it.
pub fn drawViewStrip(self: *const Sidebar, font: Font) void {
    const mouse = rl.getMousePosition();
    inline for (@typeInfo(Sidebar.View).@"enum".fields) |f| {
        const v: Sidebar.View = @enumFromInt(f.value);
        const tab = Sidebar.viewTabRect(v);
        const active = self.view == v;
        const hovered = rl.checkCollisionPointRec(mouse, tab);
        const color = theme.copy(if (active) theme.accent else if (hovered) theme.foreground else theme.sidebar_arrow);
        const c: rl.Vector2 = .{ .x = tab.x + tab.width / 2, .y = tab.y + tab.height / 2 };
        const icon: Icons.Icon = switch (v) {
            .explorer => .files,
            .search => .search,
            .git => .git_branch,
        };
        font.drawIcon(icon, c, .large, color);
        if (active) rl.drawRectangleRec(.{ .x = tab.x + 8, .y = tab.y + tab.height - 2, .width = tab.width - 16, .height = 2 }, theme.accent);
    }

    // Help, open folder, and settings.
    for ([_]usize{ 2, 1, 0 }) |slot| {
        if (!self.stripButtonVisible(slot)) continue;
        const b = self.stripButtonRect(slot);
        const hovered = rl.checkCollisionPointRec(mouse, b);
        const color = theme.copy(if (hovered) theme.foreground else theme.sidebar_arrow);
        const c: rl.Vector2 = .{ .x = b.x + b.width / 2, .y = b.y + b.height / 2 };
        if (hovered) rl.drawRectangleRounded(.{ .x = b.x + 3, .y = b.y + 4, .width = b.width - 6, .height = b.height - 8 }, 0.3, 6, theme.sidebar_hover);
        const icon: Icons.Icon = switch (slot) {
            0 => .settings,
            1 => .folder_open,
            else => .circle_question_mark,
        };
        font.drawIcon(icon, c, .large, color);
    }
    rl.drawRectangleRec(.{ .x = 0, .y = Sidebar.strip_height - 1, .width = self.rect.width - 1, .height = 1 }, theme.sidebar_border);
}

pub fn drawExplorer(self: *const Sidebar, t: *const FileTree, current_path: ?[]const u8, font: Font, show_caret: bool) void {
    const r = self.rect;

    // Clip long names at the sidebar's edge (and below the view strip).
    theme.clip(.{ .x = 0, .y = Sidebar.strip_height, .width = r.width - 1, .height = r.height - Sidebar.strip_height });
    defer rl.endScissorMode();

    const text_dy = (row_height - theme.font_size) / 2;
    // Visible rows only. Clamped, so a stale scroll (e.g. rows just
    // collapsed) can never make an empty or backwards range.
    const total = self.rowCount(t);
    const first = @min(total, @as(usize, @intFromFloat(@max(0, self.scroll) / row_height)));
    const count: usize = @intFromFloat(r.height / row_height + 2);
    for (first..@min(first + count, total)) |row| {
        const top = Sidebar.listTop() + @as(f32, @floatFromInt(row)) * row_height - self.scroll;
        const index = self.nodeAtRow(t, row) orelse {
            drawInput(self, t, row, font, show_caret);
            continue;
        };
        const n = t.node(index);

        const is_current = if (current_path) |p| std.mem.eql(u8, p, n.path) else false;
        const hovered = if (self.hovered) |h| h == .node and h.node == index else false;
        const is_drop = self.drop_target == index;
        const bg: ?rl.Color = if (is_drop) theme.accentDim(0.25) else if (is_current) theme.accentDim(0.35) else if (hovered) theme.sidebar_hover else null;
        const row_rect: rl.Rectangle = .{ .x = 0, .y = top, .width = r.width - 1, .height = row_height };
        if (bg) |c| rl.drawRectangleRec(row_rect, theme.copy(c));
        if (is_drop) rl.drawRectangleLinesEx(row_rect, 1, theme.accent);

        const x = Sidebar.pad + @as(f32, @floatFromInt(n.depth)) * Sidebar.indent;
        const mid = top + row_height / 2;
        // Folders get their arrow, files a colored dot for their language.
        if (n.is_dir) drawArrow(font, x, mid, n.expanded) else file_icon.draw(n.name, .{ .x = x + Sidebar.arrow_size / 2, .y = mid });
        const color = if (n.is_dir) theme.sidebar_folder else theme.foreground;
        // Long names end in "…" before the scrollbar.
        _ = font.drawFit(n.name, x + Sidebar.arrow_size + 6, top + text_dy, r.width - Sidebar.scrollbar_grab - 2, color);
    }

    // Dropping into the project folder itself: outline the whole list.
    if (self.drop_target == 0) {
        rl.drawRectangleLinesEx(.{ .x = 1, .y = Sidebar.listTop(), .width = r.width - 3, .height = r.height - Sidebar.listTop() - 1 }, 1, theme.accent);
    }

    drawScrollbar(
        self,
    );

    // Header over rows scrolled beneath it: folder name and the buttons.
    rl.drawRectangleRec(.{ .x = 0, .y = Sidebar.strip_height, .width = r.width - 1, .height = Sidebar.header_height }, theme.sidebar_background);
    const buttons_left = self.buttonRect(.file).x - 6;
    _ = font.drawFit(t.root().name, Sidebar.pad, Sidebar.strip_height + (Sidebar.header_height - theme.font_size) / 2, buttons_left, theme.sidebar_header);
    for ([_]FileTree.EntryKind{ .file, .folder }) |kind| {
        const b = self.buttonRect(kind);
        const hovered = if (self.hovered) |h| h == .new_button and h.new_button == kind else false;
        rl.drawRectangleRec(b, theme.sidebar_background); // cover a long folder name
        if (hovered) rl.drawRectangleRec(b, theme.sidebar_hover);
        headerIcon(font, b, if (kind == .file) .file_plus else .folder_plus, hovered);
    }
    const c = self.collapseRect();
    rl.drawRectangleRec(c, theme.sidebar_background);
    const collapse_hovered = if (self.hovered) |h| h == .collapse_button else false;
    if (collapse_hovered) rl.drawRectangleRec(c, theme.sidebar_hover);
    headerIcon(font, c, .copy_minus, collapse_hovered);
}

/// A header button's icon: New File, New Folder, Collapse All.
fn headerIcon(font: Font, b: rl.Rectangle, icon: Icons.Icon, hovered: bool) void {
    const color = theme.copy(if (hovered) theme.foreground else theme.sidebar_arrow);
    font.drawIcon(icon, .{ .x = b.x + b.width / 2, .y = b.y + b.height / 2 }, .medium, color);
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

pub fn drawInput(self: *const Sidebar, tree: *const FileTree, row: usize, font: Font, show_caret: bool) void {
    const r = self.inputRect(tree, row);
    const kind = self.input.?.kind;
    // A folder arrow or file dot in front, like the other rows.
    const mid = r.y + r.height / 2;
    if (kind == .folder) drawArrow(font, r.x - Sidebar.arrow_size - 4, mid, false) else rl.drawCircleV(.{ .x = r.x - Sidebar.arrow_size / 2 - 4, .y = mid }, 2, theme.sidebar_arrow);
    self.name.draw(r, font, if (kind == .folder) i18n.tr().sidebar.folder_name else i18n.tr().sidebar.file_name, true, show_caret);
}

/// A chevron: right for a collapsed folder, down for an expanded one,
/// centered in the `arrow_size` column at `x`.
pub fn drawArrow(font: Font, x: f32, mid: f32, expanded: bool) void {
    font.drawIcon(if (expanded) .chevron_down else .chevron_right, .{ .x = x + Sidebar.arrow_size / 2, .y = mid }, .medium, theme.sidebar_arrow);
}
