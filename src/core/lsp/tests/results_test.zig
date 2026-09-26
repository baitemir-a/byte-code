//! Tests for results.zig.
const std = @import("std");
const results = @import("../results.zig");

const testing = std.testing;

fn parse(arena: std.mem.Allocator, json: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
}

test "hover text without the markdown" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try results.hoverText(a, try parse(a,
        \\{"contents": {"kind": "markdown", "value": "```ts\nconst x: number\n```\n---\nThe \\_count."}}
    ));
    try testing.expectEqualStrings("const x: number\nThe _count.", text.?);
    const old = try results.hoverText(a, try parse(a,
        \\{"contents": [{"language": "go", "value": "func f()"}, "does f"]}
    ));
    try testing.expectEqualStrings("func f()\n\ndoes f", old.?);
    try testing.expect(try results.hoverText(a, try parse(a, "{\"contents\": \"\"}")) == null);
}

test "suggestions" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try results.suggestions(a, try parse(a,
        \\{"isIncomplete": false, "items": [{"label": "len", "kind": 3}, {"label": "Point", "kind": 22, "textEdit": {"newText": "Point"}}, {"label": "fmt", "kind": 9, "insertText": "fmt.Println($1)"}]}
    ));
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqual(results.Kind.function, list[0].kind);
    try testing.expectEqual(results.Kind.type, list[1].kind);
    try testing.expectEqualStrings("fmt.Println(", list[2].insert);
}

test "code actions, preferred first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try results.actions(a, try parse(a,
        \\[{"title": "Run", "command": "x.run"}, {"title": "Add import", "isPreferred": true, "edit": {"changes": {}}}]
    ));
    try testing.expectEqualStrings("Add import", list[0].title);
    try testing.expect(list[0].edit != null);
    try testing.expect(list[1].command != null and list[1].edit == null);
}

test "published problems" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = (try results.published(a, try parse(a,
        \\{"uri": "file:///x/a.zig", "version": 4, "diagnostics": [{"range": {"start": {"line": 1, "character": 2}, "end": {"line": 1, "character": 5}}, "message": "bad", "severity": 2}]}
    ))).?;
    try testing.expectEqualStrings("/x/a.zig", p.path);
    try testing.expectEqual(@as(?i64, 4), p.version);
    try testing.expectEqual(@as(i64, 2), p.problems[0].severity);
}

test "definition places, as locations or links" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try results.locations(a, try parse(a,
        \\{"uri": "file:///p/a.go", "range": {"start": {"line": 3, "character": 5}, "end": {"line": 3, "character": 8}}}
    ));
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqualStrings("/p/a.go", one[0].path);
    try testing.expectEqual(@as(u32, 3), one[0].start.line);
    const links = try results.locations(a, try parse(a,
        \\[{"targetUri": "file:///p/b.rs", "targetRange": {"start": {"line": 1, "character": 0}, "end": {"line": 9, "character": 1}}, "targetSelectionRange": {"start": {"line": 1, "character": 7}, "end": {"line": 1, "character": 10}}}]
    ));
    try testing.expectEqual(@as(u32, 7), links[0].start.character);
    try testing.expectEqual(@as(usize, 0), (try results.locations(a, .null)).len);
}
