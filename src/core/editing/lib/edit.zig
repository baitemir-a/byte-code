//! Smart editing on top of `Buffer`: auto-closing pairs, auto-indent and
//! pair-aware deletion.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const text = @import("text.zig");
const motion = @import("motion.zig");

/// Types one character, auto-closing brackets and quotes.
pub fn typeCodepoint(buf: *Buffer, cp: u21) !void {
    var enc: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &enc) catch return;
    const ch = enc[0..len];

    if (buf.selection()) |s| {
        if (len == 1) if (text.closerFor(ch[0])) |close| return wrapSelection(buf, s, ch[0], close);
        return buf.replace(s.start, s.end, ch, len, .typing);
    }

    if (len == 1) {
        const c = ch[0];
        const next = buf.byteAt(buf.cursor);
        // Typing the closer that's already next to the cursor steps over it.
        if (text.isCloser(c) and next == c) return buf.moveTo(buf.cursor + 1, false);
        if (text.closerFor(c)) |close| if (shouldAutoClose(buf, c)) {
            return buf.replace(buf.cursor, buf.cursor, &.{ c, close }, 1, .other);
        };
    }
    try buf.replace(buf.cursor, buf.cursor, ch, len, .typing);
}

fn shouldAutoClose(buf: *const Buffer, opener: u8) bool {
    // Only before whitespace, a closer or punctuation that ends an expression.
    if (buf.byteAt(buf.cursor)) |next| {
        if (!(text.isSpace(next) or text.isCloser(next) or next == ',' or next == ';')) return false;
    }
    // A quote right after a letter is an apostrophe: don't.
    if (text.isQuote(opener)) if (buf.byteBefore(buf.cursor)) |prev| return !text.isWordChar(prev);
    return true;
}

/// Surrounds the selection with a pair, keeping the inner text selected.
fn wrapSelection(buf: *Buffer, s: Buffer.Range, open: u8, close: u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(buf.gpa);
    try out.append(buf.gpa, open);
    try out.appendSlice(buf.gpa, buf.items()[s.start..s.end]);
    try out.append(buf.gpa, close);
    try buf.replace(s.start, s.end, out.items, out.items.len - 1, .other);
    buf.anchor = s.start + 1;
}

/// Enter: keeps the current indentation, indents after an opening bracket,
/// and splits an empty pair like `{}` onto three lines.
pub fn newline(buf: *Buffer) !void {
    const s = buf.selectionOrCursor();
    const line_start = buf.lineStart(s.start);
    var indent_end = line_start;
    while (indent_end < s.start and text.isSpace(buf.items()[indent_end])) indent_end += 1;
    const line_indent = buf.items()[line_start..indent_end];

    const prev = buf.byteBefore(s.start);
    const opens = prev != null and text.isOpenBracket(prev.?);
    const splits = opens and buf.byteAt(s.end) == text.closerFor(prev.?);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(buf.gpa);
    try out.append(buf.gpa, '\n');
    try out.appendSlice(buf.gpa, line_indent);
    if (opens) try out.appendSlice(buf.gpa, buf.indent);
    const cursor_offset = out.items.len;
    if (splits) {
        try out.append(buf.gpa, '\n');
        try out.appendSlice(buf.gpa, line_indent);
    }
    try buf.replace(s.start, s.end, out.items, cursor_offset, .other);
}

pub fn indent(buf: *Buffer) !void {
    try buf.insert(buf.indent);
}

pub fn backspace(buf: *Buffer) !void {
    if (buf.selection()) |s| return buf.deleteRange(s);
    const pos = buf.cursor;
    if (pos == 0) return;
    // Deleting the opener of an empty pair removes both halves.
    if (text.closerFor(buf.items()[pos - 1])) |close| if (buf.byteAt(pos) == close) {
        return buf.replace(pos - 1, pos + 1, "", 0, .deleting);
    };
    try buf.replace(buf.prevPos(pos), pos, "", 0, .deleting);
}

pub fn deleteForward(buf: *Buffer) !void {
    if (buf.selection()) |s| return buf.deleteRange(s);
    if (buf.cursor >= buf.items().len) return;
    try buf.replace(buf.cursor, buf.nextPos(buf.cursor), "", 0, .deleting);
}

/// Deletes the selection, or from the cursor to where `m` would land.
pub fn deleteMotion(buf: *Buffer, m: motion.Motion) !void {
    if (buf.selection()) |s| return buf.deleteRange(s);
    const to = switch (m) {
        // Unlike the Home motion this ignores indentation, and at column 0
        // joins with the previous line.
        .line_start => if (buf.cursor == buf.lineStart(buf.cursor)) buf.cursor -| 1 else buf.lineStart(buf.cursor),
        else => motion.target(buf, m),
    };
    try buf.deleteRange(.{ .start = @min(to, buf.cursor), .end = @max(to, buf.cursor) });
}

/// Option+Up / Down: swaps the cursor's lines (all the selected ones) with
/// the line above or below, keeping the cursor and selection on them.
/// Returns where those lines are now. With several cursors, `skip` is the
/// block the previous cursor moved: a cursor inside it came along already.
pub fn moveLines(buf: *Buffer, up: bool, skip: ?Buffer.Range) !Buffer.Range {
    const b = buf.items();
    const sel = buf.selectionOrCursor();
    const first = buf.lineStart(sel.start);
    // A selection ending at the start of a line doesn't include that line.
    const ends_at_line_start = sel.end > sel.start and sel.end == buf.lineStart(sel.end);
    const last = buf.lineEnd(if (ends_at_line_start) sel.end - 1 else sel.end);
    if (skip) |r| if (first <= r.end and last >= r.start) return r;
    const unmoved: Buffer.Range = .{ .start = first, .end = last };
    if (if (up) first == 0 else last == b.len) return unmoved;

    // That selection end is on the next line, which stays: pull it back to
    // the block's end for the swap, and put it after the newline again.
    const end_is_cursor = buf.cursor == sel.end;
    if (ends_at_line_start) setEnd(buf, end_is_cursor, last);

    var moved: Buffer.Range = undefined;
    if (up) {
        const above = buf.lineStart(first - 1);
        try buf.swapRanges(above, first - 1, first, last);
        moved = .{ .start = above, .end = above + (last - first) };
    } else {
        const below_end = buf.lineEnd(last + 1);
        try buf.swapRanges(first, last, last + 1, below_end);
        moved = .{ .start = first + (below_end - last), .end = below_end };
    }
    if (ends_at_line_start and buf.byteAt(moved.end) == '\n') setEnd(buf, end_is_cursor, moved.end + 1);
    return moved;
}

fn setEnd(buf: *Buffer, is_cursor: bool, pos: usize) void {
    if (is_cursor) buf.cursor = pos else buf.anchor = pos;
}

test {
    _ = @import("../tests/edit_test.zig");
}
