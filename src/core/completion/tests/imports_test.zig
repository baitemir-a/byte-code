//! Tests for imports.zig.
const std = @import("std");
const imports = @import("../lib/imports.zig");

const testing = std.testing;

fn expectTyped(language: anytype, line: []const u8, style: imports.Style, typed: []const u8) !void {
    const ctx = imports.context(language, line) orelse return error.NoContext;
    try testing.expectEqual(style, ctx.style);
    try testing.expectEqualStrings(typed, ctx.typed);
}

test "recognizes import strings" {
    try expectTyped(.typescript, "import { a } from './ut", .js, "./ut");
    try expectTyped(.typescript, "import \"", .js, "");
    try expectTyped(.typescript, "export * from \"@scope/pk", .js, "@scope/pk");
    try expectTyped(.jsx, "const x = await import('../", .js, "../");
    try expectTyped(.typescript, "const fs = require (\"f", .js, "f");
    try expectTyped(.zig, "const Buffer = @import(\"buffer/Bu", .zig, "buffer/Bu");
    try expectTyped(.zig, "const font = @embedFile(\"fonts/", .file, "fonts/");
    try expectTyped(.scss, "@use 'vars", .file, "vars");
    try expectTyped(.css, "  background: url(\"img/", .file, "img/");
    try expectTyped(.html, "<script src=\"js/", .file, "js/");
    try expectTyped(.c, "#include \"lib/", .file, "lib/");
}

test "ignores other strings" {
    try testing.expect(imports.context(.typescript, "const s = \"./a") == null);
    try testing.expect(imports.context(.typescript, "import x from './a' + '") == null);
    try testing.expect(imports.context(.typescript, "import x from './a'") == null);
    try testing.expect(imports.context(.typescript, "const fromage = '") == null);
    try testing.expect(imports.context(.html, "<a data-href=\"x") == null);
    try testing.expect(imports.context(.html, "<a href=\"https://ex") == null);
    try testing.expect(imports.context(.go, "import \"fmt") == null);
}

test "python modules" {
    try expectTyped(.python, "from pkg.mo", .python, "pkg.mo");
    try expectTyped(.python, "    import os, pkg.", .python, "pkg.");
    try expectTyped(.python, "from ..", .python, "..");
    try testing.expect(imports.context(.python, "from pkg import na") == null);
    try testing.expect(imports.context(.python, "x = 'from a") == null);

    const ctx = imports.context(.python, "from pkg.sub.mo").?;
    try testing.expectEqualStrings("pkg.sub.", ctx.dirPart());
    try testing.expectEqualStrings("mo", ctx.segment());
}

test "file labels" {
    try testing.expectEqualStrings("Button", imports.fileLabel(.js, "Button.tsx").?);
    try testing.expectEqualStrings("types", imports.fileLabel(.js, "types.d.ts").?);
    try testing.expectEqualStrings("app.css", imports.fileLabel(.js, "app.css").?);
    try testing.expectEqualStrings("main.zig", imports.fileLabel(.zig, "main.zig").?);
    try testing.expect(imports.fileLabel(.zig, "README.md") == null);
    try testing.expectEqualStrings("utils", imports.fileLabel(.python, "utils.py").?);
    try testing.expect(imports.fileLabel(.python, "__init__.py") == null);
}
