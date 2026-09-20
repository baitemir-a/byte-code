//! Drawing the sidebar: the view strip, the file tree with its header
//! buttons and name box, the scrollbar and the drag label.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");
const file_icon = @import("../widgets/lib/file_icon.zig");
const core = @import("core");
const Sidebar = @import("Sidebar.zig");

const FileTree = core.FileTree;
const row_height = theme.line_height;

pub fn drawScrollbar(self: *const Sidebar) void {
    const thumb = self.scrollbarThumb() orelse return;
    const active = self.scrollbar_drag != null or self.onScrollbar(rl.getMousePosition());
    rl.drawRectangleRounded(thumb, 1, 6, theme.copy(if (active) theme.scrollbar_thumb_hover else theme.scrollbar_thumb));
}

pub fn draw(self: *const Sidebar, tree: ?*const FileTree, current_path: ?[]const u8, font: Font, show_caret: bool) void {
    if (self.rect.width == 0) return;
    const r = self.rect;
    rl.drawRectangleRec(r, theme.sidebar_background);
    rl.drawRectangleRec(.{ .x = r.width - 1, .y = 0, .width = 1, .height = r.height }, theme.sidebar_border);
    drawViewStrip(
        self,
    );
    if (self.view == .explorer) drawExplorer(self, tree.?, current_path, font, show_caret);

    // The resize edge lights up while hovered or dragged.
    if (self.resizing or self.onEdge(rl.getMousePosition())) {
        rl.drawRectangleRec(.{ .x = r.width - 3, .y = 0, .width = 2, .height = r.height }, theme.accent);
    }
}

/// The view tabs: Explorer, Search, Git, as icons. The current one is in
/// the accent color with a line under it.
pub fn drawViewStrip(self: *const Sidebar) void {
    const mouse = rl.getMousePosition();
    inline for (@typeInfo(Sidebar.View).@"enum".fields) |f| {
        const v: Sidebar.View = @enumFromInt(f.value);
        const tab = Sidebar.viewTabRect(v);
        const active = self.view == v;
        const hovered = rl.checkCollisionPointRec(mouse, tab);
        const color = theme.copy(if (active) theme.accent else if (hovered) theme.foreground else theme.sidebar_arrow);
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
        const color = theme.copy(if (hovered) theme.foreground else theme.sidebar_arrow);
        const c: rl.Vector2 = .{ .x = b.x + b.width / 2, .y = b.y + b.height / 2 };
        if (hovered) rl.drawRectangleRounded(.{ .x = b.x + 3, .y = b.y + 4, .width = b.width - 6, .height = b.height - 8 }, 0.3, 6, theme.sidebar_hover);
        if (slot == 0) drawGear(c, color) else drawOpenFolder(c, color);
    }
    rl.drawRectangleRec(.{ .x = 0, .y = Sidebar.strip_height - 1, .width = self.rect.width - 1, .height = 1 }, theme.sidebar_border);
}

/// A gear: a ring with teeth and a hole.
pub fn drawGear(c: rl.Vector2, color: rl.Color) void {
    for (0..8) |i| {
        const a = @as(f32, @floatFromInt(i)) * std.math.pi / 4;
        const dir: rl.Vector2 = .{ .x = @cos(a), .y = @sin(a) };
        rl.drawLineEx(.{ .x = c.x + dir.x * 5, .y = c.y + dir.y * 5 }, .{ .x = c.x + dir.x * 8, .y = c.y + dir.y * 8 }, 2.4, color);
    }
    rl.drawCircleV(c, 6, color);
    rl.drawCircleV(c, 2.5, theme.sidebar_background);
}

/// A folder with a plus.
pub fn drawOpenFolder(c: rl.Vector2, color: rl.Color) void {
    rl.drawRectangleLinesEx(.{ .x = c.x - 8, .y = c.y - 4, .width = 14, .height = 10 }, 1.3, color);
    rl.drawRectangleRec(.{ .x = c.x - 8, .y = c.y - 6, .width = 6, .height = 3 }, color);
    rl.drawRectangleRec(.{ .x = c.x + 1, .y = c.y + 1, .width = 9, .height = 9 }, theme.sidebar_background);
    rl.drawLineEx(.{ .x = c.x + 2, .y = c.y + 5.5 }, .{ .x = c.x + 9, .y = c.y + 5.5 }, 1.5, theme.foreground);
    rl.drawLineEx(.{ .x = c.x + 5.5, .y = c.y + 2 }, .{ .x = c.x + 5.5, .y = c.y + 9 }, 1.5, theme.foreground);
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
        if (n.is_dir) drawArrow(x, mid, n.expanded) else file_icon.draw(n.name, .{ .x = x + Sidebar.arrow_size / 2, .y = mid });
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
        drawNewIcon(b, kind);
    }
    const c = self.collapseRect();
    rl.drawRectangleRec(c, theme.sidebar_background);
    if (self.hovered) |h| if (h == .collapse_button) rl.drawRectangleRec(c, theme.sidebar_hover);
    drawCollapseIcon(c);
}

/// "Collapse all": two stacked squares, the front one with a minus.
pub fn drawCollapseIcon(b: rl.Rectangle) void {
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

pub fn drawInput(self: *const Sidebar, tree: *const FileTree, row: usize, font: Font, show_caret: bool) void {
    const r = self.inputRect(tree, row);
    const kind = self.input.?.kind;
    // A folder arrow or file dot in front, like the other rows.
    const mid = r.y + r.height / 2;
    if (kind == .folder) drawArrow(r.x - Sidebar.arrow_size - 4, mid, false) else rl.drawCircleV(.{ .x = r.x - Sidebar.arrow_size / 2 - 4, .y = mid }, 2, theme.sidebar_arrow);
    self.name.draw(r, font, if (kind == .folder) "folder name" else "file name", true, show_caret);
}

/// A page (new file) or folder outline with a small plus.
pub fn drawNewIcon(b: rl.Rectangle, kind: FileTree.EntryKind) void {
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
pub fn drawArrow(x: f32, mid: f32, expanded: bool) void {
    const s = Sidebar.arrow_size;
    if (expanded) {
        rl.drawTriangle(.{ .x = x, .y = mid - s / 3 }, .{ .x = x + s / 2, .y = mid + s / 3 }, .{ .x = x + s, .y = mid - s / 3 }, theme.sidebar_arrow);
    } else {
        rl.drawTriangle(.{ .x = x + s / 4, .y = mid - s / 2 }, .{ .x = x + s / 4, .y = mid + s / 2 }, .{ .x = x + s * 0.85, .y = mid }, theme.sidebar_arrow);
    }
}
