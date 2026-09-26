//! Text edits a server asks for (a rename, a quick fix): which files, and
//! what to replace in each.
const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const Buffer = @import("../buffer/Buffer.zig");
const lines = @import("../editing/lib/lines.zig");

const Value = std.json.Value;

pub const TextEdit = struct {
    start: protocol.Position,
    end: protocol.Position,
    text: []const u8,
};

pub const FileEdit = struct {
    path: []const u8,
    edits: []const TextEdit,
};

/// The files and edits of a `WorkspaceEdit`, in `alloc`. Creating,
/// renaming and deleting files are left out.
pub fn parseWorkspaceEdit(alloc: Allocator, edit: Value) ![]FileEdit {
    var out: std.ArrayList(FileEdit) = .empty;
    if (edit != .object) return out.items;
    if (edit.object.get("documentChanges")) |changes| if (changes == .array) {
        for (changes.array.items) |c| {
            const doc = get(c, "textDocument") orelse continue;
            const uri = str(get(doc, "uri")) orelse continue;
            const path = try protocol.pathFromUri(alloc, uri) orelse continue;
            try out.append(alloc, .{ .path = path, .edits = try parseEdits(alloc, get(c, "edits") orelse continue) });
        }
        return out.items;
    };
    if (edit.object.get("changes")) |changes| if (changes == .object) {
        var it = changes.object.iterator();
        while (it.next()) |e| {
            const path = try protocol.pathFromUri(alloc, e.key_ptr.*) orelse continue;
            try out.append(alloc, .{ .path = path, .edits = try parseEdits(alloc, e.value_ptr.*) });
        }
    };
    return out.items;
}

pub fn parseEdits(alloc: Allocator, list: Value) ![]TextEdit {
    var out: std.ArrayList(TextEdit) = .empty;
    if (list != .array) return out.items;
    for (list.array.items) |e| {
        const range = parseRange(get(e, "range") orelse continue) orelse continue;
        try out.append(alloc, .{ .start = range[0], .end = range[1], .text = str(get(e, "newText")) orelse "" });
    }
    return out.items;
}

pub fn parseRange(v: Value) ?[2]protocol.Position {
    return .{ parsePosition(get(v, "start") orelse return null) orelse return null, parsePosition(get(v, "end") orelse return null) orelse return null };
}

pub fn parsePosition(v: Value) ?protocol.Position {
    const line = get(v, "line") orelse return null;
    const ch = get(v, "character") orelse return null;
    if (line != .integer or ch != .integer or line.integer < 0 or ch.integer < 0) return null;
    return .{ .line = @intCast(line.integer), .character = @intCast(ch.integer) };
}

/// The edits as byte ranges of `text`, in order (the protocol lets them
/// come in any order).
pub fn toByteEdits(alloc: Allocator, text: []const u8, list: []const TextEdit) ![]lines.Edit {
    var ls = try protocol.Lines.init(alloc, text);
    defer ls.deinit(alloc);
    const out = try alloc.alloc(lines.Edit, list.len);
    for (list, out) |e, *o| {
        const a = ls.offset(e.start);
        const b = @max(a, ls.offset(e.end));
        o.* = .{ .pos = a, .remove = b - a, .insert = e.text };
    }
    std.mem.sort(lines.Edit, out, {}, struct {
        fn f(_: void, x: lines.Edit, y: lines.Edit) bool {
            return x.pos < y.pos;
        }
    }.f);
    // Overlapping edits would break the others: keep the first.
    var n: usize = 0;
    for (out) |e| {
        if (n > 0 and e.pos < out[n - 1].pos + out[n - 1].remove) continue;
        out[n] = e;
        n += 1;
    }
    return out[0..n];
}

/// Makes the edits in a buffer, as one undo step.
pub fn applyToBuffer(alloc: Allocator, buf: *Buffer, list: []const TextEdit) !void {
    const byte_edits = try toByteEdits(alloc, buf.items(), list);
    if (byte_edits.len == 0) return;
    buf.history.seal();
    try lines.applyEdits(buf, byte_edits);
    buf.history.seal();
}

/// `text` with the edits made (for a file that isn't open).
pub fn applyToText(alloc: Allocator, text: []const u8, list: []const TextEdit) ![]u8 {
    const byte_edits = try toByteEdits(alloc, text, list);
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    for (byte_edits) |e| {
        try out.appendSlice(alloc, text[at..e.pos]);
        try out.appendSlice(alloc, e.insert);
        at = e.pos + e.remove;
    }
    try out.appendSlice(alloc, text[at..]);
    return out.items;
}

fn get(v: Value, name: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(name);
}

fn str(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

test {
    _ = @import("tests/edits_test.zig");
}
