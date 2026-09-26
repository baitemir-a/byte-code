//! Cmd+/: comments the lines the cursor or selection is on out, or back
//! in if they all are. Languages without line comments (HTML, CSS) wrap
//! the lines in a block comment instead.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const lines = @import("lines.zig");
const Highlighter = @import("../../syntax/Highlighter.zig");
const generic = @import("../../syntax/lib/generic.zig");

const Range = Buffer.Range;
const Edit = lines.Edit;

/// How a language writes comments.
pub const Style = struct {
    line: ?[]const u8 = null,
    block: ?[2][]const u8 = null,
};

pub fn styleFor(language: Highlighter.Language) Style {
    const c: Style = .{ .line = "//", .block = .{ "/*", "*/" } };
    const markup: Style = .{ .block = .{ "<!--", "-->" } };
    const hash: Style = .{ .line = "#" };
    return switch (language) {
        .plain, .diff => .{},
        .typescript, .jsx, .json, .scss, .go, .rust => c,
        .zig => .{ .line = "//" },
        .css => .{ .block = .{ "/*", "*/" } },
        .html, .xml, .markdown => markup,
        .python, .toml, .yaml, .yarn_lock, .dotenv, .ignore => hash,
        else => {
            const d = language.genericDialect() orelse return .{};
            const spec = generic.language(d).spec;
            return .{
                .line = if (spec.line_comments.len > 0) spec.line_comments[0] else null,
                .block = if (spec.block_comments.len > 0) spec.block_comments[0] else null,
            };
        },
    };
}

/// Comments the lines out or in. See `lines` for `skip` and the result.
pub fn toggle(buf: *Buffer, style: Style, skip: ?Range) !Range {
    const block = lines.selectedLines(buf);
    if (skip) |r| if (block.start <= r.end and block.end >= r.start) return r;
    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(buf.gpa);
    var space: std.ArrayList(u8) = .empty;
    defer space.deinit(buf.gpa);
    if (style.line) |prefix| {
        try lineEdits(buf, block, prefix, &edits, &space);
    } else if (style.block) |pair| {
        try blockEdits(buf, block, pair, &edits, &space);
    } else return block;

    var d: isize = 0;
    for (edits.items) |e| d += @as(isize, @intCast(e.insert.len)) - @as(isize, @intCast(e.remove));
    try lines.applyEdits(buf, edits.items);
    return .{ .start = block.start, .end = @intCast(@as(isize, @intCast(block.end)) + d) };
}

/// `prefix` after each line's indentation. Taken off again when every
/// line that isn't blank starts with it; otherwise added to each, in the
/// column of the least indented one, so they line up.
fn lineEdits(buf: *Buffer, block: Range, prefix: []const u8, edits: *std.ArrayList(Edit), space: *std.ArrayList(u8)) !void {
    const b = buf.items();
    const gpa = buf.gpa;
    var all_commented = true;
    var any_text = false;
    var min_indent: usize = std.math.maxInt(usize);
    var s = block.start;
    while (true) {
        const e = buf.lineEnd(s);
        const indent = indentOf(b[s..e]);
        if (s + indent < e) {
            any_text = true;
            min_indent = @min(min_indent, indent);
            if (!std.mem.startsWith(u8, b[s + indent .. e], prefix)) all_commented = false;
        }
        if (e >= block.end) break;
        s = e + 1;
    }
    const uncomment = any_text and all_commented;
    if (!any_text) min_indent = 0;
    try space.appendSlice(gpa, prefix);
    try space.append(gpa, ' ');
    s = block.start;
    while (true) {
        const e = buf.lineEnd(s);
        const indent = indentOf(b[s..e]);
        const blank = s + indent == e;
        if (uncomment) {
            if (!blank) {
                const at = s + indent + prefix.len;
                const n = prefix.len + @as(usize, if (at < e and b[at] == ' ') 1 else 0);
                try edits.append(gpa, .{ .pos = s + indent, .remove = n });
            }
        } else if (!blank or !any_text) {
            try edits.append(gpa, .{ .pos = s + @min(min_indent, indent), .insert = space.items });
        }
        if (e >= block.end) break;
        s = e + 1;
    }
}

/// `open` before the lines' text and `close` after it, or both taken off
/// when they are there already.
fn blockEdits(buf: *Buffer, block: Range, pair: [2][]const u8, edits: *std.ArrayList(Edit), space: *std.ArrayList(u8)) !void {
    const b = buf.items();
    const gpa = buf.gpa;
    var start = block.start;
    while (start < block.end and (b[start] == ' ' or b[start] == '\t' or b[start] == '\n')) start += 1;
    var end = block.end;
    while (end > start and std.ascii.isWhitespace(b[end - 1])) end -= 1;
    const inner = b[start..end];
    const open = pair[0];
    const close = pair[1];
    if (inner.len >= open.len + close.len and std.mem.startsWith(u8, inner, open) and std.mem.endsWith(u8, inner, close)) {
        const a = start + open.len;
        const z = end - close.len;
        const open_n = open.len + @as(usize, if (a < z and b[a] == ' ') 1 else 0);
        const close_n = close.len + @as(usize, if (z > a + open_n - open.len and b[z - 1] == ' ') 1 else 0);
        try edits.append(gpa, .{ .pos = start, .remove = open_n });
        try edits.append(gpa, .{ .pos = end - close_n, .remove = close_n });
        return;
    }
    // Both halves live in `space`: "open " then " close".
    try space.appendSlice(gpa, open);
    try space.append(gpa, ' ');
    try space.append(gpa, ' ');
    try space.appendSlice(gpa, close);
    try edits.append(gpa, .{ .pos = start, .insert = space.items[0 .. open.len + 1] });
    try edits.append(gpa, .{ .pos = end, .insert = space.items[open.len + 1 ..] });
}

fn indentOf(line: []const u8) usize {
    return std.mem.indexOfNone(u8, line, " \t") orelse line.len;
}

test {
    _ = @import("../tests/comment_test.zig");
}
