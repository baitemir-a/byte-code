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

test "signature help" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sig = results.signature(try parse(a,
        \\{"signatures": [{"label": "add(a: number, b: number): number", "parameters": [{"label": "a: number"}, {"label": [15, 24]}]}], "activeSignature": 0, "activeParameter": 1}
    )).?;
    try testing.expectEqualStrings("b: number", sig.label[sig.param_start..sig.param_end]);
    const first = results.signature(try parse(a,
        \\{"signatures": [{"label": "f(x, y)", "parameters": [{"label": "x"}, {"label": "y"}], "activeParameter": 0}]}
    )).?;
    try testing.expectEqualStrings("x", first.label[first.param_start..first.param_end]);
    try testing.expect(results.signature(try parse(a, "{\"signatures\": []}")) == null);
}

test "document symbols, nested and flat, without locals" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try results.documentSymbols(a, try parse(a,
        \\[{"name": "Editor", "kind": 5, "range": {"start": {"line": 0, "character": 0}, "end": {"line": 9, "character": 1}}, "selectionRange": {"start": {"line": 0, "character": 6}, "end": {"line": 0, "character": 12}},
        \\  "children": [{"name": "open", "kind": 6, "range": {"start": {"line": 2, "character": 2}, "end": {"line": 4, "character": 3}},
        \\    "children": [{"name": "local", "kind": 13, "range": {"start": {"line": 3, "character": 4}, "end": {"line": 3, "character": 9}}}]}]},
        \\ {"name": "main", "kind": 12, "location": {"uri": "file:///x", "range": {"start": {"line": 11, "character": 0}, "end": {"line": 11, "character": 4}}}}]
    ));
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqualStrings("Editor", list[0].name);
    try testing.expectEqual(@as(u32, 6), list[0].start.character);
    try testing.expectEqualStrings("method", list[1].kind);
    try testing.expectEqual(@as(u8, 1), list[1].depth);
    try testing.expectEqualStrings("main", list[2].name);
}

test "workspace symbols" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try results.workspaceSymbols(a, try parse(a,
        \\[{"name": "Point", "kind": 23, "containerName": "geo", "location": {"uri": "file:///p/geo.zig", "range": {"start": {"line": 4, "character": 4}, "end": {"line": 4, "character": 9}}}},
        \\ {"name": "run", "kind": 12, "location": {"uri": "file:///p/main.go"}}]
    ));
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("/p/geo.zig", list[0].path.?);
    try testing.expectEqualStrings("geo", list[0].container);
    try testing.expectEqual(@as(u32, 0), list[1].start.line);
}
