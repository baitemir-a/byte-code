//! The client against a real server: the editor's own TypeScript one, when
//! node and TypeScript are on this machine (skipped otherwise).
const std = @import("std");
const Client = @import("../Client.zig");
const servers = @import("../servers.zig");
const results = @import("../results.zig");
const edits = @import("../edits.zig");
const protocol = @import("../protocol.zig");
const checkers = @import("../../diagnostics/lib/checkers.zig");

const testing = std.testing;

/// Polls until `pred` accepts something that came in (or 30 s pass).
fn waitFor(client: *Client, arena: std.mem.Allocator, io: std.Io, ctx: anytype, comptime pred: fn (@TypeOf(ctx), Client.Incoming) bool) !Client.Incoming {
    for (0..600) |_| {
        for (try client.poll(arena)) |m| if (pred(ctx, m)) return m;
        if (client.isDead()) return error.ServerDied;
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    return error.Timeout;
}

fn isDiagnostics(_: void, m: Client.Incoming) bool {
    return m == .notification and std.mem.eql(u8, m.notification.method, "textDocument/publishDiagnostics");
}

fn isResponse(id: i64, m: Client.Incoming) bool {
    return m == .response and m.response.id == id;
}

test "the TypeScript server answers" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const text =
        \\export function add(a: number, b: number) { return a + b; }
        \\const n: string = add(1, 2);
        \\readFileSync("x");
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = text });
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const path = try std.fs.path.join(arena, &.{ root, "a.ts" });
    const found = try servers.find(arena, io, .typescript, path, checkers.searchPath(arena, io, null), "") orelse return error.SkipZigTest;

    const client = try Client.start(testing.allocator, io, found.argv, root);
    defer client.destroy();
    try client.sync(path, "typescript", text, 1);

    // The type error on line 2 and the unknown name on line 3.
    const d = try waitFor(client, arena, io, {}, isDiagnostics);
    const p = (try results.published(arena, d.notification.params)).?;
    try testing.expectEqualStrings(path, p.path);
    try testing.expectEqual(@as(usize, 2), p.problems.len);
    try testing.expectEqual(@as(u32, 1), p.problems[0].start.line);
    try testing.expect(client.caps.hover and client.caps.rename and client.caps.code_action);

    const uri = try protocol.uriFromPath(arena, path);
    const on_add = protocol.toPosition(text, std.mem.indexOf(u8, text, "add(1").?);

    const hover_id = try client.request("textDocument/hover", .{ .textDocument = .{ .uri = uri }, .position = on_add });
    const hover = try waitFor(client, arena, io, hover_id, isResponse);
    const shown = (try results.hoverText(arena, hover.response.result)).?;
    try testing.expect(std.mem.indexOf(u8, shown, "function add(a: number, b: number): number") != null);

    // From the use on line 2 to the declaration on line 1.
    try testing.expect(client.caps.definition);
    const def_id = try client.request("textDocument/definition", .{ .textDocument = .{ .uri = uri }, .position = on_add });
    const def = try waitFor(client, arena, io, def_id, isResponse);
    const places = try results.locations(arena, def.response.result);
    try testing.expectEqual(@as(usize, 1), places.len);
    try testing.expectEqualStrings(path, places[0].path);
    try testing.expectEqual(protocol.Position{ .line = 0, .character = 16 }, places[0].start);

    const at_end = protocol.toPosition(text, std.mem.indexOf(u8, text, "add(1").? + 1);
    const completion_id = try client.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = at_end });
    const completion = try waitFor(client, arena, io, completion_id, isResponse);
    const labels = try results.suggestions(arena, completion.response.result);
    var has_add = false;
    for (labels) |s| if (std.mem.eql(u8, s.label, "add")) {
        has_add = true;
    };
    try testing.expect(has_add);

    const rename_id = try client.request("textDocument/rename", .{ .textDocument = .{ .uri = uri }, .position = on_add, .newName = "sum" });
    const rename = try waitFor(client, arena, io, rename_id, isResponse);
    const files = try edits.parseWorkspaceEdit(arena, rename.response.result);
    try testing.expectEqual(@as(usize, 1), files.len);
    const renamed = try edits.applyToText(arena, text, files[0].edits);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, renamed, "sum("));

    // A fix for the name `readFileSync`: importing it from "fs".
    const line3 = protocol.toPosition(text, std.mem.indexOf(u8, text, "readFileSync").?);
    const fix_id = try client.request("textDocument/codeAction", .{
        .textDocument = .{ .uri = uri },
        .range = .{ .start = line3, .end = line3 },
        .context = .{ .diagnostics = .{} },
    });
    const fix = try waitFor(client, arena, io, fix_id, isResponse);
    const actions = try results.actions(arena, fix.response.result);
    try testing.expect(actions.len > 0);
}

test "TypeScript suggests other modules' exports, with their import" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "util.ts", .data = "export function formatDate(d: Date) { return d.toISOString(); }\n" });
    const text = "const x = 1;\nforma\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "main.ts", .data = text });
    try tmp.dir.writeFile(io, .{ .sub_path = "tsconfig.json", .data = "{\"compilerOptions\": {\"strict\": true}}" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const path = try std.fs.path.join(arena, &.{ root, "main.ts" });
    const found = try servers.find(arena, io, .typescript, path, checkers.searchPath(arena, io, null), "") orelse return error.SkipZigTest;

    const client = try Client.start(testing.allocator, io, found.argv, root);
    defer client.destroy();
    try client.sync(path, "typescript", text, 1);
    const uri = try protocol.uriFromPath(arena, path);
    const after = protocol.toPosition(text, std.mem.indexOf(u8, text, "forma").? + 5);
    const id = try client.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = after });
    const answer = try waitFor(client, arena, io, id, isResponse);
    try testing.expect(client.caps.completion_resolve);
    const list = try results.suggestions(arena, answer.response.result);
    const item = for (list) |s| {
        if (std.mem.eql(u8, s.label, "formatDate")) break s;
    } else return error.NotSuggested;
    try testing.expectEqualStrings("./util", item.detail);

    const resolve_id = try client.request("completionItem/resolve", item.raw);
    const resolved = try waitFor(client, arena, io, resolve_id, isResponse);
    const extra = try edits.parseEdits(arena, Client.field(resolved.response.result, "additionalTextEdits").?);
    const with_import = try edits.applyToText(arena, text, extra);
    try testing.expect(std.mem.startsWith(u8, with_import, "import { formatDate } from \"./util\";\n"));
}
