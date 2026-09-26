//! Folding: which lines a block's first line can hide. A line that opens
//! a bracket it doesn't close hides the lines up to the one with the
//! closing bracket (which stays, like the first). Otherwise it hides the
//! lines after it that are indented further, as in Python or YAML.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const Highlighter = @import("../../syntax/Highlighter.zig");
const brackets = @import("brackets.zig");
const text = @import("text.zig");

const Range = Buffer.Range;

/// What a fold on the line starting at `start` (line number `index`)
/// hides: from the start of the next line to the end of the last hidden
/// one (its newline stays). Null when there is nothing to hide.
pub fn region(buf: *const Buffer, hl: *const Highlighter, start: usize, index: usize) ?Range {
    const b = buf.items();
    const end = buf.lineEnd(start);
    if (end >= b.len) return null;
    if (brackets.unclosedOpener(hl, index, b[start..end])) |o| {
        if (brackets.findClose(buf, hl, start + o, index)) |close| {
            const close_line = buf.lineStart(close);
            if (close_line <= end + 1) return null;
            return .{ .start = end + 1, .end = close_line - 1 };
        }
    }
    return indentRegion(b, start, end);
}

/// Whether the line could be folded, without looking further than the
/// next line with text: for the marks in the gutter.
pub fn foldable(buf: *const Buffer, hl: *const Highlighter, start: usize, index: usize) bool {
    const b = buf.items();
    const end = buf.lineEnd(start);
    if (end >= b.len) return false;
    const line = b[start..end];
    if (isBlank(line)) return false;
    if (brackets.unclosedOpener(hl, index, line) != null) return true;
    const base = indentWidth(line);
    var s = end + 1;
    while (true) {
        const e = std.mem.indexOfScalarPos(u8, b, s, '\n') orelse b.len;
        const l = b[s..e];
        if (!isBlank(l)) return indentWidth(l) > base;
        if (e >= b.len) return false;
        s = e + 1;
    }
}

fn indentRegion(b: []const u8, start: usize, end: usize) ?Range {
    const line = b[start..end];
    if (isBlank(line)) return null;
    const base = indentWidth(line);
    var last: ?usize = null;
    var s = end + 1;
    while (true) {
        const e = std.mem.indexOfScalarPos(u8, b, s, '\n') orelse b.len;
        const l = b[s..e];
        if (!isBlank(l)) {
            if (indentWidth(l) <= base) break;
            last = e;
        }
        if (e >= b.len) break;
        s = e + 1;
    }
    return .{ .start = end + 1, .end = last orelse return null };
}

/// The lines the buffer's folds hide, as sorted byte ranges that don't
/// touch, into `out`. Folds that no longer hide anything (their block
/// was edited away) are dropped from the buffer.
pub fn hiddenRanges(buf: *Buffer, hl: *const Highlighter, out: *std.ArrayList(Range)) !void {
    out.clearRetainingCapacity();
    const b = buf.items();
    var index: usize = 0;
    var counted: usize = 0;
    var i: usize = 0;
    while (i < buf.folds.items.len) {
        const start = buf.folds.items[i];
        if (start > b.len or (start > 0 and b[start - 1] != '\n')) {
            _ = buf.unfold(start);
            continue;
        }
        index += std.mem.count(u8, b[counted..start], "\n");
        counted = start;
        const r = region(buf, hl, start, index) orelse {
            _ = buf.unfold(start);
            continue;
        };
        i += 1;
        if (out.items.len > 0) {
            const last = &out.items[out.items.len - 1];
            if (r.start <= last.end + 1) {
                last.end = @max(last.end, r.end);
                continue;
            }
        }
        try out.append(buf.gpa, r);
    }
}

/// Whether `pos` is on a hidden line.
pub fn isHidden(hidden: []const Range, pos: usize) bool {
    for (hidden) |r| {
        if (pos < r.start) return false;
        if (pos <= r.end) return true;
    }
    return false;
}

fn isBlank(line: []const u8) bool {
    return std.mem.indexOfNone(u8, line, " \t\r") == null;
}

fn indentWidth(line: []const u8) usize {
    const n = std.mem.indexOfNone(u8, line, " \t") orelse line.len;
    return text.visualColumn(line[0..n]);
}

test {
    _ = @import("../tests/fold_test.zig");
}
