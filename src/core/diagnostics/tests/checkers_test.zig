//! Tests for checkers.zig.
const std = @import("std");
const checkers = @import("../lib/checkers.zig");

const testing = std.testing;

test "reads compiler-style output" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const found = try checkers.parseLocated(arena.allocator(),
        \\<stdin>:1:12: error: expected ';' after declaration
        \\const a = 1
        \\           ^
        \\<stdin>:4:3: note: something to add
        \\<standard input>:7:2: expected '}', found 'EOF'
        \\
    );
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqual(@as(u32, 1), found[0].line);
    try testing.expectEqual(@as(u32, 12), found[0].col);
    try testing.expectEqualStrings("expected ';' after declaration", found[0].message);
    try testing.expectEqualStrings("expected '}', found 'EOF'", found[1].message);
}

test "reads tab-separated output" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const found = try checkers.parseTabbed(arena.allocator(), "1\t18\t1\t20\t'}' expected.\ngarbage\n3\t1\t0\t0\tinvalid syntax\n");
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqual(@as(u32, 20), found[0].end_col);
    try testing.expectEqualStrings("invalid syntax", found[1].message);
}

test "reads rustfmt output" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const found = try checkers.parseRustfmt(arena.allocator(),
        \\error: expected one of `;` or `}`, found `let`
        \\ --> <stdin>:3:5
        \\  |
        \\
    );
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(u32, 3), found[0].line);
    try testing.expectEqualStrings("expected one of `;` or `}`, found `let`", found[0].message);
}

test "runs zig ast-check when zig is installed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const env: checkers.Env = .{ .search_path = checkers.searchPath(alloc, testing.io, null) };
    const result = try checkers.run(alloc, testing.io, .zig, "a.zig", "const a = 1\n", env);
    switch (result) {
        .unavailable => return error.SkipZigTest,
        .found => |f| {
            try testing.expectEqual(@as(usize, 1), f.items.len);
            try testing.expectEqual(@as(u32, 1), f.items[0].line);
        },
    }
}

fn runTool(alloc: std.mem.Allocator, tool: checkers.Tool, path: []const u8, source: []const u8) !?[]const checkers.Found {
    const env: checkers.Env = .{ .search_path = checkers.searchPath(alloc, testing.io, null) };
    return switch (try checkers.run(alloc, testing.io, tool, path, source, env)) {
        .unavailable => null,
        .found => |f| f.items,
    };
}

test "runs TypeScript's parser when node and TypeScript are installed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const found = try runTool(arena.allocator(), .typescript, "/nowhere/App.tsx",
        \\const total = items.reduce((a, b) => a + , 0);
        \\const x = <div>{total</div>;
        \\let y: = 5;
        \\
    ) orelse return error.SkipZigTest;
    try testing.expect(found.len >= 3);
    try testing.expectEqual(@as(u32, 1), found[0].line);
    try testing.expectEqual(@as(u32, 42), found[0].col);
    try testing.expectEqualStrings("Expression expected.", found[0].message);
    try testing.expectEqual(@as(u32, 3), found[found.len - 1].line);

    const clean = (try runTool(arena.allocator(), .typescript, "/nowhere/a.ts", "export const a: number = 1;\n")).?;
    try testing.expectEqual(@as(usize, 0), clean.len);
}

test "runs Python's compiler when python is installed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const found = try runTool(arena.allocator(), .python, "a.py", "def f(:\n    pass\n") orelse return error.SkipZigTest;
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(u32, 1), found[0].line);
    try testing.expectEqual(@as(u32, 7), found[0].col);
}

test "Python names that are never defined" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const found = try runTool(arena.allocator(), .python, "a.py",
        \\import os
        \\hcgvh = fgh
        \\def f(a):
        \\    return [x for x in a] + os.sep + hcgvh
        \\printi(len(f))
        \\
    ) orelse return error.SkipZigTest;
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("'fgh' is not defined", found[0].message);
    try testing.expectEqual(@as(u32, 2), found[0].line);
    try testing.expectEqual(@as(u32, 9), found[0].col);
    try testing.expectEqual(@as(u32, 12), found[0].end_col);
    try testing.expectEqualStrings("'printi' is not defined", found[1].message);
}

test "TypeScript's service finds type errors, using the project's config" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    // Vite's layout: the settings are in a referenced config.
    try tmp.dir.writeFile(io, .{ .sub_path = "tsconfig.json", .data =
        \\{ "files": [], "references": [{ "path": "./tsconfig.app.json" }] }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "tsconfig.app.json", .data =
        \\{ "compilerOptions": { "strict": true, "noEmit": true }, "include": ["src"] }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/globals.d.ts", .data = "declare const APP_NAME: string;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.ts", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const file = try std.fs.path.join(testing.allocator, &.{ root, "src", "a.ts" });
    defer testing.allocator.free(file);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var server: checkers.Server = .init(testing.allocator);
    defer server.deinit(io);
    const env: checkers.Env = .{ .search_path = checkers.searchPath(alloc, io, null), .server = &server };

    const first = switch (try checkers.run(alloc, io, .typescript, file, "const n: number = \"x\";\nprinti(APP_NAME);\n", env)) {
        .unavailable => return error.SkipZigTest,
        .found => |f| f.items,
    };
    try testing.expectEqual(@as(usize, 2), first.len);
    try testing.expectEqualStrings("Type 'string' is not assignable to type 'number'.", first[0].message);
    try testing.expect(std.mem.startsWith(u8, first[1].message, "Cannot find name 'printi'."));
    try testing.expect(server.child != null);

    // The same service answers the next check, for the edited text.
    const second = (try checkers.run(alloc, io, .typescript, file, "export const ok = APP_NAME.length;\n", env)).found.items;
    try testing.expectEqual(@as(usize, 0), second.len);
}
