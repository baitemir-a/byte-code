//! Drawing the welcome tab.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../theme/lib/theme.zig");
const Font = @import("../Font.zig");
const core = @import("core");
const WelcomePage = @import("WelcomePage.zig");

pub fn draw(self: *const WelcomePage, font: Font, projects: []const core.Projects.Entry) void {
    const x = self.origin.x;
    var y = self.origin.y;

    drawText(font, WelcomePage.title, x, y, Font.heading_size, theme.foreground);
    y += theme.font_size * 2.4 + 8;
    drawText(font, WelcomePage.subtitle, x, y, theme.font_size, theme.popup_detail);

    drawHeading(font, "Start", x, self.actionsTop() - theme.line_height - 4);
    for (WelcomePage.actions, self.action_rects, 0..) |a, r, i| {
        if (self.hovered_action == i) rl.drawRectangleRec(r, theme.tab_hover);
        drawText(font, a.label, x, textY(r), theme.font_size, theme.accent);
    }

    for (self.rows[0..self.row_count], 0..) |row, i| {
        // Each section's heading sits above its first row.
        const heading_y = row.rect.y - theme.line_height - 2;
        if (i == 0 and self.favorites > 0) drawHeading(font, WelcomePage.favorites_heading, x, heading_y);
        if (i == self.favorites) drawHeading(font, WelcomePage.recent_heading, x, heading_y);
        const entry = projects[row.entry];
        if (self.hovered_row == i) rl.drawRectangleRec(row.rect, theme.tab_hover);
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

    drawText(font, WelcomePage.drop_hint, x, self.hint_y, theme.font_size, theme.popup_detail);
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

fn drawText(font: Font, s: []const u8, x0: f32, y: f32, size: f32, color: rl.Color) void {
    const cw = font.cell_width * size / theme.font_size;
    var x = x0;
    for (s) |c| {
        if (c != ' ') font.drawCodepointSized(c, x, y, size, color);
        x += cw;
    }
}
