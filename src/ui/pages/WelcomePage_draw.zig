//! Drawing the welcome tab.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../theme/lib/theme.zig");
const anim = @import("../anim.zig");
const Font = @import("../Font.zig");
const core = @import("core");
const WelcomePage = @import("WelcomePage.zig");
const i18n = @import("../../i18n/i18n.zig");

pub fn draw(self: *const WelcomePage, font: Font, projects: []const core.Projects.Entry) void {
    theme.clip(self.area);
    defer drawScrollbar(self);
    defer rl.endScissorMode();

    const x = self.origin.x;
    var y = self.origin.y;

    drawText(font, WelcomePage.title, x, y, Font.heading_size, theme.foreground);
    y += theme.font_size * 2.4 + 8;
    const t = i18n.tr().welcome;
    drawText(font, t.subtitle, x, y, theme.font_size, theme.popup_detail);

    drawHeading(font, t.start, x, self.actionsTop() - theme.line_height - 4);
    for (WelcomePage.actions, self.action_rects, 0..) |a, r, i| {
        const t_action = anim.fade(anim.hash("welcome_action", i), self.hovered_action == i, anim.hover_speed);
        if (t_action > 0) rl.drawRectangleRec(r, anim.alpha(theme.tab_hover, t_action));
        drawText(font, WelcomePage.actionLabel(a), x, textY(r), theme.font_size, theme.accent);
    }

    for (self.rows[0..self.row_count], 0..) |row, i| {
        // Each section's heading sits above its first row.
        const heading_y = row.rect.y - theme.line_height - 2;
        if (i == 0 and self.favorites > 0) drawHeading(font, t.favorites, x, heading_y);
        if (i == self.favorites) drawHeading(font, t.recent, x, heading_y);
        const entry = projects[row.entry];
        const t_row = anim.fade(anim.hash("welcome_row", row.entry), self.hovered_row == i, anim.hover_speed);
        if (t_row > 0) rl.drawRectangleRec(row.rect, anim.alpha(theme.tab_hover, t_row));
        drawStar(
            .{ .x = row.star.x + row.star.width / 2, .y = row.star.y + row.star.height / 2 },
            entry.favorite,
            entry.favorite or self.hovered_star == i or self.hovered_row == i,
        );
        // The folder's name, then the path it is at, dimmed.
        const name = std.fs.path.basename(entry.path);
        const text_x = row.star.x + row.star.width;
        const y_text = textY(row.rect);
        const after = font.drawFit(name, text_x, y_text, row.rect.x + row.rect.width, theme.accent);
        const right = row.rect.x + row.rect.width - 8;
        if (after + 2 * font.cell_width < right) {
            _ = font.drawFit(entry.path, after + 2 * font.cell_width, y_text, right, theme.popup_detail);
        }
    }

    drawText(font, t.drop_hint, x, self.hint_y, theme.font_size, theme.popup_detail);
}

/// A thin bar on the right edge showing how far down the page we are.
fn drawScrollbar(self: *const WelcomePage) void {
    if (self.max_scroll <= 0) return;
    const h = self.area.height;
    const visible = h / (h + self.max_scroll);
    const thumb_h = @max(40, h * visible);
    const t = self.scroll / self.max_scroll;
    rl.drawRectangleRounded(.{
        .x = self.area.x + self.area.width - 8,
        .y = self.area.y + t * (h - thumb_h),
        .width = 4,
        .height = thumb_h,
    }, 1, 6, theme.scrollbar_thumb);
}

fn drawHeading(font: Font, s: []const u8, x: f32, y: f32) void {
    drawText(font, s, x, y, theme.font_size, theme.welcome_heading);
}

/// Middle of a row, for text of the usual size.
fn textY(r: rl.Rectangle) f32 {
    return r.y + (r.height - theme.font_size) / 2;
}

/// The favorite mark: a five-pointed star, filled once the folder is one.
fn drawStar(c: rl.Vector2, filled: bool, lit: bool) void {
    const color = theme.copy(if (filled) theme.accent else if (lit) theme.foreground else theme.popup_detail);
    const outer: f32 = 7;
    const inner: f32 = 3;
    var points: [11]rl.Vector2 = undefined;
    for (0..10) |i| {
        const r = if (i % 2 == 0) outer else inner;
        // Start at the top point: a tenth of a turn per step.
        const angle = -std.math.pi / 2.0 + @as(f32, @floatFromInt(i)) * std.math.pi / 5.0;
        points[i] = .{ .x = c.x + r * @cos(angle), .y = c.y + r * @sin(angle) };
    }
    points[10] = points[0];
    if (filled) {
        // A fan from the middle: every point is visible from there.
        for (0..10) |i| rl.drawTriangle(c, points[i + 1], points[i], color);
    } else {
        for (0..10) |i| rl.drawLineEx(points[i], points[i + 1], 1.2, color);
    }
}

fn drawText(font: Font, s: []const u8, x: f32, y: f32, size: f32, color: rl.Color) void {
    _ = font.drawText(s, x, y, size, color);
}
