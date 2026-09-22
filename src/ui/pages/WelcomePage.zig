//! The welcome tab: how to get started, the folders opened before, and
//! the favorites among them — every row clickable. The keyboard shortcuts
//! live in the Help tab (Keymap and HelpPage).
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");
const WelcomePage_draw = @import("WelcomePage_draw.zig");
const i18n = @import("../../i18n/i18n.zig");

const WelcomePage = @This();

/// The "Start" rows.
pub const actions = [_]core.Command{ .open, .open_folder, .new_file, .open_settings, .open_help };

/// A "Start" row's text, in the chosen language.
pub fn actionLabel(command: core.Command) []const u8 {
    const t = i18n.tr().welcome;
    return switch (command) {
        .open => t.open_file,
        .open_folder => t.open_folder,
        .new_file => t.new_file,
        .open_settings => t.settings,
        .open_help => t.shortcuts,
        else => unreachable,
    };
}

pub const title = "byte code";
pub const content_cols = 56;
/// Rows a section lists at most; a short window fits fewer still.
pub const max_section_rows = 6;
pub const max_rows = 2 * max_section_rows;

/// A folder listed on the page: which entry of the project list it shows,
/// where its row is, and where the star that favorites it is.
pub const Row = struct {
    entry: usize,
    rect: rl.Rectangle,
    star: rl.Rectangle,
};

/// What a click on the page asks for.
pub const Hit = union(enum) {
    /// One of the "Start" rows.
    command: core.Command,
    /// Open this project (an index into the project list).
    open: usize,
    /// Make it a favorite, or stop.
    favorite: usize,
};

/// Clickable rows, in window coordinates; set by `layout`.
action_rects: [actions.len]rl.Rectangle = undefined,
hovered_action: ?usize = null,
/// The folders listed: the favorites first, `favorites` of them.
rows: [max_rows]Row = undefined,
row_count: usize = 0,
favorites: usize = 0,
hovered_row: ?usize = null,
hovered_star: ?usize = null,
/// Top-left of the content block, and where the folders start.
origin: rl.Vector2 = .{ .x = 0, .y = 0 },
projects_top: f32 = 0,
hint_y: f32 = 0,

// Drawing, in WelcomePage_draw.zig.
pub const draw = WelcomePage_draw.draw;

pub fn layout(self: *WelcomePage, area: rl.Rectangle, font: Font, projects: []const core.Projects.Entry) void {
    const w = content_cols * font.cell_width;
    self.origin = .{
        .x = area.x + @max(theme.padding * 2, (area.width - w) / 2),
        .y = area.y + @max(theme.padding * 2, area.height * 0.12),
    };
    for (&self.action_rects, 0..) |*r, i| {
        r.* = rowRect(self.origin.x, self.actionsTop() + rowY(i), w);
    }
    self.projects_top = self.actionsTop() + rowY(actions.len) + theme.line_height;
    self.layoutProjects(area, w, projects);

    const mouse = rl.getMousePosition();
    self.hovered_action = for (self.action_rects, 0..) |r, i| {
        if (rl.checkCollisionPointRec(mouse, r)) break i;
    } else null;
    self.hovered_row = for (self.rows[0..self.row_count], 0..) |row, i| {
        if (rl.checkCollisionPointRec(mouse, row.rect)) break i;
    } else null;
    self.hovered_star = for (self.rows[0..self.row_count], 0..) |row, i| {
        if (rl.checkCollisionPointRec(mouse, row.star)) break i;
    } else null;
}

/// Lays out the favorites, then the folders opened recently, as many of
/// each as the window has room for.
fn layoutProjects(self: *WelcomePage, area: rl.Rectangle, w: f32, projects: []const core.Projects.Entry) void {
    self.row_count = 0;
    self.favorites = 0;
    // What is left below the folders: the drop hint and a margin.
    const room = area.y + area.height - theme.line_height * 3 - self.projects_top;
    const fits: usize = @intFromFloat(@max(0, room / (theme.line_height + 6)));

    var y = self.projects_top;
    for ([_]bool{ true, false }) |favorites_pass| {
        var shown: usize = 0;
        var section_top = true;
        for (projects, 0..) |p, i| {
            if (p.favorite != favorites_pass) continue;
            if (shown >= max_section_rows or self.row_count >= fits or self.row_count >= max_rows) break;
            // Room for the section's heading, above its first row, and
            // for a gap between one section and the last one's rows.
            if (section_top) {
                if (self.row_count > 0) y += theme.line_height / 2;
                y += theme.line_height + 4;
                section_top = false;
            }
            const rect = rowRect(self.origin.x, y, w);
            self.rows[self.row_count] = .{
                .entry = i,
                .rect = rect,
                .star = .{ .x = rect.x, .y = rect.y, .width = theme.line_height + 6, .height = rect.height },
            };
            self.row_count += 1;
            shown += 1;
            y += theme.line_height + 6;
        }
        if (favorites_pass) self.favorites = self.row_count;
    }
    self.hint_y = if (self.row_count > 0) y + theme.line_height / 2 else self.projects_top;
}

/// What a click at `p` asks for, if anything.
pub fn hitTest(self: *const WelcomePage, p: rl.Vector2) ?Hit {
    for (self.action_rects, actions) |r, a| {
        if (rl.checkCollisionPointRec(p, r)) return .{ .command = a };
    }
    for (self.rows[0..self.row_count]) |row| {
        if (rl.checkCollisionPointRec(p, row.star)) return .{ .favorite = row.entry };
        if (rl.checkCollisionPointRec(p, row.rect)) return .{ .open = row.entry };
    }
    return null;
}

fn rowRect(x: f32, y: f32, w: f32) rl.Rectangle {
    return .{ .x = x - 8, .y = y, .width = w + 16, .height = theme.line_height + 4 };
}

pub fn rowY(i: usize) f32 {
    return @as(f32, @floatFromInt(i)) * (theme.line_height + 6);
}

pub fn actionsTop(self: *const WelcomePage) f32 {
    return self.origin.y + theme.font_size * 2.4 + theme.line_height * 3;
}
