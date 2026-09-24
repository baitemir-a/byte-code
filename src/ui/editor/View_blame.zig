//! Who last changed the line the cursor is on, dimmed at the end of that
//! line (Settings can turn it off): "Ada, 3 d ago • Fix the parser".
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const theme = @import("../theme/lib/theme.zig");
const View = @import("View.zig");

/// Space left between the line's text and the blame.
const gap_cols = 4;

pub fn draw(view: View, buf: *const core.Buffer, text: []const u8) void {
    const end = buf.lineEnd(buf.cursor);
    const p = view.screenPos(buf, end);
    if (p.y + theme.line_height < view.area.y or p.y > view.bottom()) return;
    const x = @max(p.x, view.gutterRight()) + gap_cols * view.font.cell_width;
    const right = view.right() - view.font.cell_width;
    // A long line leaves no room: then it isn't shown at all.
    if (right - x < view.font.cell_width * 12) return;
    const color = theme.popup_detail;
    _ = view.font.drawFit(text, x, p.y + (theme.line_height - theme.font_size) / 2, right, .{ .r = color.r, .g = color.g, .b = color.b, .a = 170 });
}
