//! Smart editing on top of `Buffer`: auto-closing pairs, auto-indent and
//! pair-aware deletion.
const std = @import("std");
const Buffer = @import("Buffer.zig");
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

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn typeStr(b: *Buffer, s: []const u8) !void {
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| try typeCodepoint(b, cp);
}

test "auto-close pairs" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try typeStr(&b, "f(");
    try testing.expectEqualStrings("f()", b.items());
    try testing.expectEqual(@as(usize, 2), b.cursor);

    try typeStr(&b, "\"a");
    try testing.expectEqualStrings("f(\"a\")", b.items());
    try typeStr(&b, "\")"); // steps over both closers
    try testing.expectEqualStrings("f(\"a\")", b.items());
    try testing.expectEqual(b.items().len, b.cursor);

    try typeStr(&b, " don't");
    try testing.expectEqualStrings("f(\"a\") don't", b.items());

    try typeStr(&b, " [");
    try backspace(&b);
    try testing.expectEqualStrings("f(\"a\") don't ", b.items());
}

test "wrap selection" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("x = abc");
    b.moveTo(4, true);
    try typeStr(&b, "(");
    try testing.expectEqualStrings("x = (abc)", b.items());
    try testing.expectEqualStrings("abc", b.selectedText().?);
}

test "newline indents and splits brackets" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try typeStr(&b, "    if {");
    try newline(&b);
    try testing.expectEqualStrings("    if {\n        \n    }", b.items());
    try testing.expectEqual(@as(usize, 8), b.column(b.cursor));
}

test "undo groups typing and deleting" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try typeStr(&b, "hello world");
    try backspace(&b);
    try backspace(&b);
    try testing.expectEqualStrings("hello wor", b.items());

    try b.undo(); // both backspaces
    try testing.expectEqualStrings("hello world", b.items());
    try b.undo(); // " world"
    try testing.expectEqualStrings("hello", b.items());
    try b.redo();
    try testing.expectEqualStrings("hello world", b.items());
}

test "delete to line start" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();

    try b.insert("ab\n    cd");
    try deleteMotion(&b, .line_start);
    try testing.expectEqualStrings("ab\n", b.items());
    try deleteMotion(&b, .line_start);
    try testing.expectEqualStrings("ab", b.items());
}
