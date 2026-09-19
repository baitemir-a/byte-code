//! Tests for Highlighter.zig.
const std = @import("std");
const Buffer = @import("../../buffer/Buffer.zig");
const token = @import("../lib/token.zig");
const js = @import("../lib/js.zig");
const Highlighter = @import("../Highlighter.zig");

test "states follow the buffer" {
    const gpa = std.testing.allocator;
    var buf = Buffer.init(gpa);
    defer buf.deinit();
    var hl = Highlighter.init(.typescript);
    defer hl.deinit(gpa);

    try buf.insert("a /*\nb\n*/ c");
    try hl.update(gpa, &buf);
    try std.testing.expectEqual(js.State.Mode.code, hl.line_states.items[0].js.mode);
    try std.testing.expectEqual(js.State.Mode.block_comment, hl.line_states.items[1].js.mode);
    try std.testing.expectEqual(js.State.Mode.block_comment, hl.line_states.items[2].js.mode);

    var t = hl.tokens(1, "b");
    try std.testing.expectEqual(token.Kind.comment, t.next().?.kind);

    // Switching language rebuilds even though the text didn't change.
    hl.language = .html;
    try hl.update(gpa, &buf);
    try std.testing.expect(hl.line_states.items[1] == .html);
}

test "language from path" {
    try std.testing.expectEqual(Highlighter.Language.typescript, Highlighter.Language.fromPath("src/app.TSX"));
    try std.testing.expectEqual(Highlighter.Language.scss, Highlighter.Language.fromPath("styles/main.sass"));
    try std.testing.expectEqual(Highlighter.Language.xml, Highlighter.Language.fromPath("icon.svg"));
    try std.testing.expectEqual(Highlighter.Language.markdown, Highlighter.Language.fromPath("README.md"));
    try std.testing.expectEqual(Highlighter.Language.plain, Highlighter.Language.fromPath("notes.txt"));
    try std.testing.expectEqual(Highlighter.Language.plain, Highlighter.Language.fromPath("Makefile"));
    try std.testing.expectEqual(Highlighter.Language.python, Highlighter.Language.fromPath("app/main.py"));
    try std.testing.expectEqual(Highlighter.Language.dotenv, Highlighter.Language.fromPath("/p/.env"));
    try std.testing.expectEqual(Highlighter.Language.dotenv, Highlighter.Language.fromPath(".env.local"));
    try std.testing.expectEqual(Highlighter.Language.ignore, Highlighter.Language.fromPath("repo/.gitignore"));
    try std.testing.expectEqual(Highlighter.Language.yarn_lock, Highlighter.Language.fromPath("web/yarn.lock"));
    try std.testing.expectEqual(Highlighter.Language.toml, Highlighter.Language.fromPath("Cargo.lock"));
    try std.testing.expectEqual(Highlighter.Language.json, Highlighter.Language.fromPath("composer.lock"));
    try std.testing.expectEqual(Highlighter.Language.yaml, Highlighter.Language.fromPath("ci.yml"));
    try std.testing.expectEqual(Highlighter.Language.go, Highlighter.Language.fromPath("cmd/main.go"));
    try std.testing.expectEqual(Highlighter.Language.rust, Highlighter.Language.fromPath("src/lib.rs"));
    try std.testing.expectEqual(Highlighter.Language.zig, Highlighter.Language.fromPath("build.zig.zon"));
}

test "unknown .lock files are recognized by content" {
    try std.testing.expectEqual(Highlighter.Language.json, Highlighter.Language.detect("x.lock", "{\n  \"a\": 1\n}"));
    try std.testing.expectEqual(Highlighter.Language.toml, Highlighter.Language.detect("x.lock", "# gen\n[[package]]\nname = \"a\""));
    try std.testing.expectEqual(Highlighter.Language.yaml, Highlighter.Language.detect("x.lock", "PODS:\n  - A (1.0)"));
    try std.testing.expectEqual(Highlighter.Language.plain, Highlighter.Language.detect("notes.txt", "{"));
}
