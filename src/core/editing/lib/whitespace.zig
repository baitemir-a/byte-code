//! Tidying the text as it's saved: blanks at the ends of lines taken off,
//! and a newline at the end of the file.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const lines = @import("lines.zig");

pub const Options = struct {
    trim_trailing: bool = true,
    final_newline: bool = true,
};

/// Makes the changes as one undo step; the cursors stay on their text.
/// Does nothing (and records nothing) when the text is tidy already.
pub fn tidy(buf: *Buffer, opts: Options) !void {
    var edits: std.ArrayList(lines.Edit) = .empty;
    defer edits.deinit(buf.gpa);
    const b = buf.items();
    if (opts.trim_trailing) {
        var start: usize = 0;
        while (true) {
            const end = std.mem.indexOfScalarPos(u8, b, start, '\n') orelse b.len;
            var e = end;
            // A "\r" before the newline stays: that's a line ending.
            if (e > start and b[e - 1] == '\r') e -= 1;
            var s = e;
            while (s > start and (b[s - 1] == ' ' or b[s - 1] == '\t')) s -= 1;
            if (s < e) try edits.append(buf.gpa, .{ .pos = s, .remove = e - s });
            if (end == b.len) break;
            start = end + 1;
        }
    }
    if (opts.final_newline and b.len > 0 and b[b.len - 1] != '\n') {
        try edits.append(buf.gpa, .{ .pos = b.len, .insert = "\n" });
    }
    if (edits.items.len == 0) return;
    // The cursor at the very end stays before the newline added there.
    const at_end = buf.cursor == b.len;
    try lines.applyEdits(buf, edits.items);
    if (at_end and opts.final_newline and buf.cursor == buf.items().len and buf.cursor > 0) buf.cursor -= 1;
}

test {
    _ = @import("../tests/whitespace_test.zig");
}
