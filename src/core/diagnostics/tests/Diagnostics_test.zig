//! Tests for Diagnostics.zig.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const Highlighter = @import("../../syntax/Highlighter.zig");
const Diagnostics = @import("../Diagnostics.zig");

const testing = std.testing;

fn check(language: Highlighter.Language, content: []const u8, files: ?Diagnostics.Files) !Diagnostics {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();
    try buf.insert(content);
    var hl: Highlighter = .init(language);
    defer hl.deinit(testing.allocator);
    var d: Diagnostics = .init(testing.allocator);
    errdefer d.deinit();
    try d.update(testing.allocator, &buf, &hl, .{ .files = files });
    return d;
}

fn expectKinds(d: *const Diagnostics, kinds: []const Diagnostics.Kind) !void {
    var got: std.ArrayList(Diagnostics.Kind) = .empty;
    defer got.deinit(testing.allocator);
    for (d.items.items) |it| try got.append(testing.allocator, it.kind);
    try testing.expectEqualSlices(Diagnostics.Kind, kinds, got.items);
}

test "balanced code has no problems" {
    const sources = .{
        .{ Highlighter.Language.typescript, "function f(a) {\n  return [a, { b: `x ${a} )` }];\n}\n// (\nconst s = \"(\";\nconst r = /\\(/;\n" },
        .{ Highlighter.Language.jsx, "const x = <div className=\"a\">Don't ( panic {count}</div>;\n" },
        .{ Highlighter.Language.rust, "fn f<'a>(x: &'a str) -> char { '(' }\n" },
        .{ Highlighter.Language.python, "def f():\n    \"\"\"Docs (\n    go on\"\"\"\n    return f'{x}'\n" },
        .{ Highlighter.Language.zig, "const s =\n    \\\\ multi (\n;\nconst c = '[';\n" },
        .{ Highlighter.Language.markdown, "Just text (with a paren\n" },
    };
    inline for (sources) |s| {
        var d = try check(s[0], s[1], null);
        defer d.deinit();
        testing.expectEqual(@as(usize, 0), d.items.items.len) catch |err| {
            std.debug.print("{s}: {any}\n", .{ @tagName(s[0]), d.items.items });
            return err;
        };
    }
}

test "unpaired brackets" {
    {
        var d = try check(.typescript, "foo(a, { b }\n}\n", null);
        defer d.deinit();
        // The `}` comes where the `(` needed its `)`.
        try expectKinds(&d, &.{.mismatched});
        try testing.expectEqual(@as(usize, 13), d.items.items[0].start);
        try testing.expectEqual(@as(u8, ')'), d.items.items[0].a);
    }
    {
        var d = try check(.typescript, "function f() {\n  g(1];\n}\n", null);
        defer d.deinit();
        try expectKinds(&d, &.{.mismatched});
        try testing.expectEqual(@as(u8, ')'), d.items.items[0].a);
        try testing.expectEqual(@as(u8, ']'), d.items.items[0].b);
    }
    {
        var d = try check(.typescript, "if (a) {\n  b();\n", null);
        defer d.deinit();
        try expectKinds(&d, &.{.unclosed});
        try testing.expectEqual(@as(usize, 7), d.items.items[0].start);
    }
}

test "strings left open" {
    var d = try check(.typescript, "const a = \"abc;\nconst b = 'x\\'';\nconst c = \"ok\\\\\";\n", null);
    defer d.deinit();
    try expectKinds(&d, &.{.unterminated_string});
    try testing.expectEqual(@as(usize, 10), d.items.items[0].start);
}

test "missing imports" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/lib");
    try tmp.dir.createDirPath(io, "src/shared/ui");
    try tmp.dir.createDirPath(io, "node_modules/react");
    try tmp.dir.createDirPath(io, "node_modules/@types/lodash");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.ts", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/utils.ts", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/lib/index.tsx", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/shared/ui/Card.tsx", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const file = try std.fs.path.join(testing.allocator, &.{ root, "src", "main.ts" });
    defer testing.allocator.free(file);

    var d = try check(.typescript,
        \\import { a } from './utils';
        \\import { b } from './utils.js';
        \\import lib from './lib';
        \\import Card from '@/shared/ui/Card';
        \\import React from 'react';
        \\import _ from 'lodash/fp';
        \\import fs from 'node:fs';
        \\import path from 'path';
        \\import icon from './icon.svg?raw';
        \\import { gone } from './gone';
        \\import Nope from '@/shared/Nope';
        \\import vue from 'vue';
        \\
    , .{ .io = io, .path = file, .root = root });
    defer d.deinit();
    try expectKinds(&d, &.{ .missing_import, .missing_import, .missing_import, .missing_import });
    try testing.expectEqualStrings("./icon.svg", d.items.items[0].path);
    try testing.expectEqualStrings("./gone", d.items.items[1].path);
    try testing.expectEqualStrings("@/shared/Nope", d.items.items[2].path);
    try testing.expectEqualStrings("vue", d.items.items[3].path);
}

test "json syntax" {
    {
        var d = try check(.json, "{\n  \"a\": 1,\n  \"b\": [1, 2\n}\n", null);
        defer d.deinit();
        try expectKinds(&d, &.{.invalid_json});
        try testing.expectEqual(@as(usize, 25), d.items.items[0].start); // the `}`
    }
    {
        var d = try check(.json, "{ \"a\": 1 }\n", null);
        defer d.deinit();
        try expectKinds(&d, &.{});
    }
    {
        // tsconfig.json may have comments and trailing commas.
        var d = try check(.json, "{\n  // note\n  \"a\": [1, 2,],\n}\n", .{ .io = testing.io, .path = "/p/tsconfig.json" });
        defer d.deinit();
        try expectKinds(&d, &.{});
    }
}

test "parser errors replace the bracket checks" {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();
    try buf.insert("function f( {\n  return 1 +;\n}\nlet é = ;\n");
    var hl: Highlighter = .init(.typescript);
    defer hl.deinit(testing.allocator);
    var d: Diagnostics = .init(testing.allocator);
    defer d.deinit();
    try d.update(testing.allocator, &buf, &hl, .{});
    try testing.expect(d.items.items.len > 0);
    try testing.expect(d.items.items[0].kind == .mismatched or d.items.items[0].kind == .unclosed);

    const found = [_]Diagnostics.checkers.Found{
        .{ .line = 2, .col = 13, .end_line = 2, .end_col = 14, .message = "Expression expected." },
        .{ .line = 4, .col = 9, .message = "Expression expected." },
        .{ .line = 1, .col = 12, .message = "',' expected." },
    };
    try d.setSyntax(&buf, buf.version, &found, true);
    try expectKinds(&d, &.{ .syntax, .syntax, .syntax });
    try testing.expectEqual(@as(usize, 11), d.items.items[0].start);
    try testing.expectEqual(@as(usize, 26), d.items.items[1].start);
    // Line 4 has a two-byte `é`: character 9 is byte 9 of the line.
    try testing.expectEqual(@as(usize, 30 + 9), d.items.items[2].start);
    try testing.expectEqualStrings("Expression expected.", d.items.items[2].message);

    // Results for an older version of the text aren't shown.
    try buf.insert(" ");
    try d.update(testing.allocator, &buf, &hl, .{ .structural = false });
    try d.setSyntax(&buf, buf.version - 1, &found, true);
    try expectKinds(&d, &.{});
}
