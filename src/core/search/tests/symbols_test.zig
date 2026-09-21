//! Tests for symbols.zig.
const std = @import("std");
const symbols = @import("../lib/symbols.zig");

const testing = std.testing;

/// `isDeclaration` for the first occurrence of `name` in `line`.
fn declares(line: []const u8, name: []const u8) bool {
    const at = std.mem.indexOf(u8, line, name).?;
    return symbols.isDeclaration(line, at, at + name.len);
}

test "declaring words introduce a name" {
    try testing.expect(declares("pub fn openFile(self: *App) !void {", "openFile"));
    try testing.expect(declares("    const count = 0;", "count"));
    try testing.expect(declares("export default class Editor {", "Editor"));
    try testing.expect(declares("async function load(url) {", "load"));
    try testing.expect(declares("def render(self):", "render"));
    try testing.expect(declares("type Options = struct {", "Options"));
}

test "mentions of a name are not declarations" {
    try testing.expect(!declares("    try self.openFile(path);", "openFile"));
    try testing.expect(!declares("    return count + 1;", "count"));
    try testing.expect(!declares("    if (count == 0) return;", "count"));
    try testing.expect(!declares("    const total = count * 2;", "count"));
    // A member of something else, not a new name.
    try testing.expect(!declares("    self.count = 0;", "count"));
}

test "assignments and function bodies" {
    try testing.expect(declares("count = 0", "count"));
    try testing.expect(declares("root := loadTree()", "root"));
    try testing.expect(!declares("count == 0", "count"));
    // C-like: a name followed by its parameters and a body.
    try testing.expect(declares("int main(int argc, char **argv) {", "main"));
    try testing.expect(declares("public static void main(String[] args) {", "main"));
    // The same shape inside a condition is a call, not a declaration.
    try testing.expect(!declares("    if (ready(state)) {", "ready"));
}

test "names worth looking up" {
    try testing.expect(symbols.isName("openFile"));
    try testing.expect(symbols.isName("_x1"));
    try testing.expect(!symbols.isName(""));
    try testing.expect(!symbols.isName("42"));
    try testing.expect(!symbols.isName("a.b"));
}
