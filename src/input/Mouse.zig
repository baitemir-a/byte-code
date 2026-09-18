//! Mouse input for the text area: click to place the cursor, drag or
//! shift+click to select, wheel to scroll.
const rl = @import("raylib");
const core = @import("core");
const View = @import("../ui/View.zig");

const Mouse = @This();

/// A left-button drag that started in the text (not on a popup).
dragging: bool = false,

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
        buf.moveTo(view.posAt(buf, point), shift);
        return true;
    }
    if (self.dragging) {
        const pos = view.posAt(buf, point);
        if (pos != buf.cursor) {
            buf.moveTo(pos, true);
            return true;
        }
    }
    return false;
}
