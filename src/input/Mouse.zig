//! Mouse input for the text area: click to place the cursor, double-click
//! to select the word, triple-click the line, drag or shift+click to
//! select, Option+click (Alt+click) to add another cursor, Option+Shift+
//! click (or drag) for a cursor on each line in a column, wheel to scroll.
const rl = @import("raylib");
const core = @import("core");
const View = @import("../ui/editor/View.zig");

const Mouse = @This();

/// Two clicks count as one double-click within this many seconds.
const double_click_time = 0.4;
/// ...and within this many pixels of each other.
const double_click_slop = 5;

/// What a click (and the drag after it) selects.
const Unit = enum { char, word, line };

/// A left-button drag that started in the text (not on a popup).
dragging: bool = false,
/// The drag is for a cursor just added with Option+click: it selects
/// without removing the other cursors.
adding: bool = false,
/// Option+Shift: where the column selection started (line, column).
column_from: ?struct { line: usize, col: usize } = null,
/// When and where the last click was, to spot double- and triple-clicks.
last_click: f64 = 0,
last_point: rl.Vector2 = .{ .x = 0, .y = 0 },
/// Clicks in the current run: 1 normal, 2 double, 3 triple.
clicks: u8 = 0,
/// What the current drag selects, and the word or line it started on.
unit: Unit = .char,
origin: core.Buffer.Range = .{ .start = 0, .end = 0 },

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
        self.unit = .char;
        // Option+click adds cursors (clicking twice removes one again),
        // so it never counts towards a double-click.
        if (alt) self.clicks = 0 else self.countClick(point);
        if (alt and shift) {
            // From the cursor's line to the click's, in the clicked column.
            self.column_from = .{ .line = buf.lineIndex(buf.cursor), .col = view.lineColAt(buf, point).col };
            self.selectColumns(view, buf, point);
        } else if (self.clicks >= 2) {
            // Double-click takes the word, triple-click the whole line.
            self.unit = if (self.clicks == 2) .word else .line;
            self.origin = unitAt(buf, view.posAt(buf, point), self.unit);
            buf.moveTo(self.origin.start, false);
            buf.moveTo(self.origin.end, true);
        } else if (self.adding) {
            buf.toggleCursor(view.posAt(buf, point)) catch {};
        } else {
            buf.moveTo(view.posAt(buf, point), shift);
        }
        return true;
    }
    // Dragging past the top or bottom edge scrolls, so the selection can
    // reach text off screen.
    if (self.dragging) view.dragScroll(point);
    if (self.dragging and self.column_from != null) {
        self.selectColumns(view, buf, point);
        return true;
    }
    if (self.dragging and self.unit != .char) return self.dragUnits(view, buf, point);
    if (self.dragging) {
        const pos = view.posAt(buf, point);
        if (pos != buf.cursor) {
            if (self.adding) buf.moveHead(pos, true) else buf.moveTo(pos, true);
            return true;
        }
    }
    return false;
}

/// Counts this click as part of a double- or triple-click run: soon
/// enough after the last one, and close enough to it. A fourth click
/// starts over at one.
fn countClick(self: *Mouse, point: rl.Vector2) void {
    const now = rl.getTime();
    const dx = point.x - self.last_point.x;
    const dy = point.y - self.last_point.y;
    const near = @abs(dx) <= double_click_slop and @abs(dy) <= double_click_slop;
    self.clicks = if (self.clicks > 0 and self.clicks < 3 and near and now - self.last_click <= double_click_time)
        self.clicks + 1
    else
        1;
    self.last_click = now;
    self.last_point = point;
}

/// Dragging after a double- or triple-click: the selection grows a whole
/// word or line at a time, always covering the one it started on.
fn dragUnits(self: *const Mouse, view: *const View, buf: *core.Buffer, point: rl.Vector2) bool {
    const r = unitAt(buf, view.posAt(buf, point), self.unit);
    const before = r.start < self.origin.start;
    const anchor = if (before) self.origin.end else self.origin.start;
    const head = if (before) r.start else @max(r.end, self.origin.end);
    if (buf.cursor == head and buf.anchor == anchor) return false;
    buf.moveTo(anchor, false);
    buf.moveTo(head, true);
    return true;
}

/// The word or line around `pos`, as a double- or triple-click selects it.
fn unitAt(buf: *const core.Buffer, pos: usize, unit: Unit) core.Buffer.Range {
    return switch (unit) {
        .char => .{ .start = pos, .end = pos },
        .word => core.motion.wordRange(buf.items(), pos),
        .line => core.motion.lineRange(buf.items(), pos),
    };
}

/// Cursors from the column selection's start to the mouse: a click puts
/// them all in the clicked column; dragging sideways selects a box.
fn selectColumns(self: *const Mouse, view: *const View, buf: *core.Buffer, point: rl.Vector2) void {
    const from = self.column_from.?;
    const to = view.lineColAt(buf, point);
    buf.selectColumns(from.line, from.col, to.line, to.col) catch {};
}
