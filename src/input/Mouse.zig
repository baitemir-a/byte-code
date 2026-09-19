//! Mouse input for the text area: click to place the cursor, drag or
//! shift+click to select, Option+click (Alt+click) to add another cursor,
//! Option+Shift+click (or drag) for a cursor on each line in a column,
//! wheel to scroll.
const rl = @import("raylib");
const core = @import("core");
const View = @import("../ui/editor/View.zig");

const Mouse = @This();

/// A left-button drag that started in the text (not on a popup).
dragging: bool = false,
/// The drag is for a cursor just added with Option+click: it selects
/// without removing the other cursors.
adding: bool = false,
/// Option+Shift: where the column selection started (line, column).
column_from: ?struct { line: usize, col: usize } = null,

/// Applies this frame's mouse input. `captured` means something drawn on
/// top (e.g. the completion popup) took the click; `wheel` whether the
/// wheel scrolls the text. Returns true if the cursor moved.
pub fn update(self: *Mouse, view: *View, buf: *core.Buffer, captured: bool, wheel: bool) bool {
    if (wheel) view.scrollBy(rl.getMouseWheelMoveV());
    if (!rl.isMouseButtonDown(.left)) self.dragging = false;
    if (captured) return false;

    const point = rl.getMousePosition();
    if (rl.isMouseButtonPressed(.left)) {
        self.dragging = true;
        const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
        const alt = rl.isKeyDown(.left_alt) or rl.isKeyDown(.right_alt);
        self.adding = alt and !shift;
        self.column_from = null;
        if (alt and shift) {
            // From the cursor's line to the click's, in the clicked column.
            self.column_from = .{ .line = buf.lineIndex(buf.cursor), .col = view.lineColAt(buf, point).col };
            self.selectColumns(view, buf, point);
        } else if (self.adding) {
            buf.toggleCursor(view.posAt(buf, point)) catch {};
        } else {
            buf.moveTo(view.posAt(buf, point), shift);
        }
        return true;
    }
    if (self.dragging and self.column_from != null) {
        self.selectColumns(view, buf, point);
        return true;
    }
    if (self.dragging) {
        const pos = view.posAt(buf, point);
        if (pos != buf.cursor) {
            if (self.adding) buf.moveHead(pos, true) else buf.moveTo(pos, true);
            return true;
        }
    }
    return false;
}

/// Cursors from the column selection's start to the mouse: a click puts
/// them all in the clicked column; dragging sideways selects a box.
fn selectColumns(self: *const Mouse, view: *const View, buf: *core.Buffer, point: rl.Vector2) void {
    const from = self.column_from.?;
    const to = view.lineColAt(buf, point);
    buf.selectColumns(from.line, from.col, to.line, to.col) catch {};
}
