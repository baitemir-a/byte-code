//! Reading what servers answer: hover text, suggestions, quick fixes and
//! the problems they report.
const std = @import("std");
const Allocator = std.mem.Allocator;
const edits = @import("edits.zig");
const protocol = @import("protocol.zig");

const Value = std.json.Value;

/// Hover contents as plain text: code fences dropped, sections separated
/// by a blank line. Null when there's nothing to show.
pub fn hoverText(alloc: Allocator, result: Value) !?[]const u8 {
    const contents = get(result, "contents") orelse return null;
    var out: std.ArrayList(u8) = .empty;
    try addContents(alloc, &out, contents);
    const text = std.mem.trim(u8, out.items, " \t\r\n");
    return if (text.len == 0) null else text;
}

fn addContents(alloc: Allocator, out: *std.ArrayList(u8), v: Value) !void {
    switch (v) {
        .string => |s| try addMarkdown(alloc, out, s),
        .array => |a| for (a.items) |x| try addContents(alloc, out, x),
        .object => if (str(get(v, "value"))) |s| try addMarkdown(alloc, out, s),
        else => {},
    }
}

fn addMarkdown(alloc: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    if (std.mem.trim(u8, s, " \t\r\n").len == 0) return;
    if (out.items.len > 0) try out.appendSlice(alloc, "\n\n");
    var it = std.mem.splitScalar(u8, s, '\n');
    var first = true;
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```")) continue;
        // A rule between sections is just a gap.
        if (std.mem.eql(u8, std.mem.trim(u8, line, " "), "---")) continue;
        if (!first) try out.append(alloc, '\n');
        first = false;
        // Markdown escapes (`\_`, `\*`) read better without the backslash.
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            if (line[i] == '\\' and i + 1 < line.len and std.ascii.isPunctuation(line[i + 1])) i += 1;
            try out.append(alloc, line[i]);
        }
    }
}

pub const Kind = enum { keyword, type, function, variable, member, file, folder, module };

pub const Suggestion = struct {
    label: []const u8,
    kind: Kind,
    /// What goes in when it's picked.
    insert: []const u8,
    /// Where the server ranks it (lower first).
    sort: []const u8,
    /// Shown dimmed beside it: the module an auto-import comes from.
    detail: []const u8,
    /// The item as sent, for resolving it and for its extra edits (the
    /// import) once picked.
    raw: Value,
};

/// The suggestions of a completion answer.
pub fn suggestions(alloc: Allocator, result: Value) ![]Suggestion {
    const list = if (result == .array) result else get(result, "items") orelse return &.{};
    if (list != .array) return &.{};
    var out: std.ArrayList(Suggestion) = .empty;
    for (list.array.items) |item| {
        const label = str(get(item, "label")) orelse continue;
        const kind: i64 = if (get(item, "kind")) |k| (if (k == .integer) k.integer else 0) else 0;
        const insert = if (get(item, "textEdit")) |te| str(get(te, "newText")) orelse label else str(get(item, "insertText")) orelse label;
        // A snippet we asked not to get: its first line, without tab stops.
        const plain = std.mem.sliceTo(insert, '$');
        try out.append(alloc, .{
            .label = std.mem.trim(u8, label, " "),
            .kind = kindOf(kind),
            .insert = if (plain.len > 0) plain else label,
            .sort = str(get(item, "sortText")) orelse label,
            .detail = if (get(item, "labelDetails")) |ld| str(get(ld, "description")) orelse "" else "",
            .raw = item,
        });
    }
    return out.items;
}

/// LSP's CompletionItemKind numbers.
fn kindOf(k: i64) Kind {
    return switch (k) {
        2, 3, 4 => .function,
        5, 10, 20 => .member,
        7, 8, 13, 22, 25 => .type,
        9 => .module,
        14 => .keyword,
        17 => .file,
        19 => .folder,
        else => .variable,
    };
}

/// A place in a file, as a definition answer names it.
pub const Location = struct {
    path: []const u8,
    start: protocol.Position,
    end: protocol.Position,
};

/// The places of a `textDocument/definition` answer: a Location, a list
/// of them, or of LocationLinks.
pub fn locations(alloc: Allocator, result: Value) ![]Location {
    var out: std.ArrayList(Location) = .empty;
    switch (result) {
        .array => |a| for (a.items) |x| if (try location(alloc, x)) |l| try out.append(alloc, l),
        .object => if (try location(alloc, result)) |l| try out.append(alloc, l),
        else => {},
    }
    return out.items;
}

fn location(alloc: Allocator, v: Value) !?Location {
    // A LocationLink points at the name itself with its selection range.
    const uri = str(get(v, "uri")) orelse str(get(v, "targetUri")) orelse return null;
    const range_value = get(v, "range") orelse get(v, "targetSelectionRange") orelse get(v, "targetRange") orelse return null;
    const range = edits.parseRange(range_value) orelse return null;
    const path = try protocol.pathFromUri(alloc, uri) orelse return null;
    return .{ .path = path, .start = range[0], .end = range[1] };
}

/// A quick fix (or other action) offered for a place in the text.
pub const Action = struct {
    title: []const u8,
    /// The changes it makes, when the server sent them along.
    edit: ?Value,
    /// A command for the server to run instead (or as well).
    command: ?Value,
    /// The action as sent, for asking the server to fill in its edit.
    raw: Value,
    preferred: bool,
};

pub fn actions(alloc: Allocator, result: Value) ![]Action {
    if (result != .array) return &.{};
    var out: std.ArrayList(Action) = .empty;
    for (result.array.items) |a| if (action(a)) |x| try out.append(alloc, x);
    // The ones the server prefers first.
    std.mem.sort(Action, out.items, {}, struct {
        fn f(_: void, x: Action, y: Action) bool {
            return x.preferred and !y.preferred;
        }
    }.f);
    return out.items;
}

pub const Problem = struct {
    start: protocol.Position,
    end: protocol.Position,
    message: []const u8,
    /// 1 error, 2 warning, 3 information, 4 hint.
    severity: i64,
    /// The diagnostic as sent, to give back when asking for fixes.
    raw: Value,
};

pub const Published = struct {
    path: []const u8,
    version: ?i64,
    problems: []Problem,
};

/// One action (a Command, or a CodeAction), e.g. as `codeAction/resolve`
/// answers.
pub fn action(a: Value) ?Action {
    const title = str(get(a, "title")) orelse return null;
    // A bare Command has a string `command`; a CodeAction may carry one.
    const bare = if (get(a, "command")) |c| c == .string else false;
    return .{
        .title = title,
        .edit = if (bare) null else get(a, "edit"),
        .command = if (bare) a else get(a, "command"),
        .raw = a,
        .preferred = if (get(a, "isPreferred")) |p| p == .bool and p.bool else false,
    };
}

/// A `textDocument/publishDiagnostics` notification.
pub fn published(alloc: Allocator, params: Value) !?Published {
    const uri = str(get(params, "uri")) orelse return null;
    const path = try protocol.pathFromUri(alloc, uri) orelse return null;
    const version: ?i64 = if (get(params, "version")) |v| (if (v == .integer) v.integer else null) else null;
    var out: std.ArrayList(Problem) = .empty;
    if (get(params, "diagnostics")) |list| if (list == .array) for (list.array.items) |d| {
        const range = edits.parseRange(get(d, "range") orelse continue) orelse continue;
        try out.append(alloc, .{
            .start = range[0],
            .end = range[1],
            .message = str(get(d, "message")) orelse "",
            .severity = if (get(d, "severity")) |s| (if (s == .integer) s.integer else 1) else 1,
            .raw = d,
        });
    };
    return .{ .path = path, .version = version, .problems = out.items };
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
    _ = @import("tests/results_test.zig");
}
