//! Tests for Completion.zig.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const Highlighter = @import("../../syntax/Highlighter.zig");
const Completion = @import("../Completion.zig");

const testing = std.testing;

const Fixture = struct {
    buf: Buffer,
    hl: Highlighter,
    c: Completion,

    fn init(content: []const u8) !*Fixture {
        const f = try testing.allocator.create(Fixture);
        f.* = .{ .buf = .init(testing.allocator), .hl = .init(.typescript), .c = .init(testing.allocator) };
        try f.buf.insert(content);
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.c.deinit();
        f.hl.deinit(testing.allocator);
        f.buf.deinit();
        testing.allocator.destroy(f);
    }

    fn has(f: *Fixture, label: []const u8) bool {
        for (f.c.items.items) |it| if (std.mem.eql(u8, it.label, label)) return true;
        return false;
    }
};

test "suggests document words first, then keywords" {
    const f = try Fixture.init("let counter = 1;\nco");
    defer f.deinit();
    try f.c.refresh(&f.buf, &f.hl, false, null);
    try testing.expect(f.c.is_open);
    try testing.expectEqualStrings("counter", f.c.items.items[0].label);
    try testing.expect(f.has("const"));
    try testing.expect(!f.has("co")); // the word being typed
}

test "members after a dot" {
    const f = try Fixture.init("console.");
    defer f.deinit();
    try f.c.refresh(&f.buf, &f.hl, false, null);
    try testing.expect(f.c.is_open);
    try testing.expectEqualStrings("log", f.c.items.items[0].label);
    try testing.expect(!f.has("const"));
}

test "accept replaces the word" {
    const f = try Fixture.init("const value = 1;\nva");
    defer f.deinit();
    try f.c.refresh(&f.buf, &f.hl, false, null);
    try testing.expectEqualStrings("value", f.c.selectedItem().?.label);
    try f.c.accept(&f.buf);
    try testing.expectEqualStrings("const value = 1;\nvalue", f.buf.items());
    try testing.expect(!f.c.is_open);
}

test "stays closed in strings, comments and numbers" {
    inline for (.{ "const s = \"co", "// co", "x = 12" }) |src| {
        const f = try Fixture.init(src);
        defer f.deinit();
        try f.c.refresh(&f.buf, &f.hl, false, null);
        try testing.expect(!f.c.is_open);
    }
}

test "opens after a closed string" {
    const f = try Fixture.init("let counter = \"a\" + co");
    defer f.deinit();
    try f.c.refresh(&f.buf, &f.hl, false, null);
    try testing.expect(f.c.is_open);
}

/// A project in a temporary folder, with the edited file at `src/main.ts`.
const Project = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    file: []u8,

    fn init() !Project {
        const io = testing.io;
        var tmp = testing.tmpDir(.{});
        try tmp.dir.createDirPath(io, "src/components");
        try tmp.dir.createDirPath(io, "node_modules/react");
        try tmp.dir.createDirPath(io, "node_modules/@scope/pkg");
        try tmp.dir.writeFile(io, .{ .sub_path = "src/main.ts", .data = "" });
        try tmp.dir.writeFile(io, .{ .sub_path = "src/utils.ts", .data = "" });
        try tmp.dir.writeFile(io, .{ .sub_path = "src/app.css", .data = "" });
        try tmp.dir.writeFile(io, .{ .sub_path = "src/components/Button.tsx", .data = "" });
        const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
        const file = try std.fs.path.join(testing.allocator, &.{ root, "src", "main.ts" });
        return .{ .tmp = tmp, .root = root, .file = file };
    }

    fn deinit(p: *Project) void {
        testing.allocator.free(p.file);
        testing.allocator.free(p.root);
        p.tmp.cleanup();
    }

    fn files(p: *const Project) Completion.Files {
        return .{ .io = testing.io, .path = p.file, .root = p.root };
    }
};

test "suggests files in a relative import" {
    var p = try Project.init();
    defer p.deinit();
    const f = try Fixture.init("import { x } from './");
    defer f.deinit();
    try f.c.refresh(&f.buf, &f.hl, false, p.files());
    try testing.expect(f.c.is_open);
    try testing.expectEqualStrings("components/", f.c.items.items[0].label);
    try testing.expect(f.has("utils"));
    try testing.expect(f.has("app.css"));
    try testing.expect(!f.has("main")); // the file itself

    // Accepting a folder goes on into it.
    try f.c.accept(&f.buf);
    try testing.expect(f.c.reopen);
    try testing.expectEqualStrings("import { x } from './components/", f.buf.items());
    try f.c.refresh(&f.buf, &f.hl, false, p.files());
    try testing.expectEqualStrings("Button", f.c.items.items[0].label);
    try f.c.accept(&f.buf);
    try testing.expectEqualStrings("import { x } from './components/Button", f.buf.items());
}

test "replaces the rest of a path segment" {
    var p = try Project.init();
    defer p.deinit();
    const f = try Fixture.init("import { x } from './ut';");
    defer f.deinit();
    f.buf.moveTo(23, false);
    try f.c.refresh(&f.buf, &f.hl, false, p.files());
    try testing.expectEqualStrings("utils", f.c.selectedItem().?.label);
    try f.c.accept(&f.buf);
    try testing.expectEqualStrings("import { x } from './utils';", f.buf.items());
}

test "suggests packages from node_modules" {
    var p = try Project.init();
    defer p.deinit();
    const f = try Fixture.init("import React from 're");
    defer f.deinit();
    try f.c.refresh(&f.buf, &f.hl, false, p.files());
    try testing.expectEqualStrings("react", f.c.items.items[0].label);
    try testing.expectEqual(Completion.ItemKind.module, f.c.items.items[0].kind);

    const g = try Fixture.init("import x from '@scope/");
    defer g.deinit();
    try g.c.refresh(&g.buf, &g.hl, false, p.files());
    try testing.expectEqualStrings("pkg", g.c.items.items[0].label);
}

test "no files in ordinary strings or without a file" {
    var p = try Project.init();
    defer p.deinit();
    const f = try Fixture.init("const s = './");
    defer f.deinit();
    try f.c.refresh(&f.buf, &f.hl, false, p.files());
    try testing.expect(!f.c.is_open);

    const g = try Fixture.init("import x from './");
    defer g.deinit();
    try g.c.refresh(&g.buf, &g.hl, false, null);
    try testing.expect(!g.c.is_open);
}

test "follows a tsconfig path alias" {
    var p = try Project.init();
    defer p.deinit();
    const io = testing.io;
    try p.tmp.dir.createDirPath(io, "src/shared/ui");
    try p.tmp.dir.writeFile(io, .{ .sub_path = "src/shared/ui/Card.tsx", .data = "" });
    try p.tmp.dir.writeFile(io, .{ .sub_path = "tsconfig.json", .data =
        \\{ "compilerOptions": { "paths": { "@/*": ["./src/*"] } } }
    });

    const f = try Fixture.init("import { Card } from '@");
    defer f.deinit();
    try f.c.refresh(&f.buf, &f.hl, false, p.files());
    try testing.expectEqualStrings("@/", f.c.items.items[0].label);
    try f.c.accept(&f.buf);
    try f.c.refresh(&f.buf, &f.hl, false, p.files());
    try testing.expect(f.has("shared/"));

    const g = try Fixture.init("import { Card } from '@/shared/ui/");
    defer g.deinit();
    try g.c.refresh(&g.buf, &g.hl, false, p.files());
    try testing.expectEqualStrings("Card", g.c.items.items[0].label);
}

test "@/ means src/ without a tsconfig" {
    var p = try Project.init();
    defer p.deinit();
    const f = try Fixture.init("import x from '@/comp");
    defer f.deinit();
    try f.c.refresh(&f.buf, &f.hl, false, p.files());
    try testing.expectEqualStrings("components/", f.c.items.items[0].label);
}
