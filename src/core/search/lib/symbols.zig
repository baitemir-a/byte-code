//! Spotting a declaration without a language server: the shapes a name
//! takes where it is introduced, across the languages the editor
//! highlights. It's a guess from one line of text, not an understanding
//! of the code, so it errs towards missing a declaration rather than
//! calling every mention one.
const std = @import("std");
const text = @import("../../editing/lib/text.zig");

/// Words a name follows where it is declared. Qualifiers before them
/// (`pub`, `export`, `async`, `public static`) don't matter: only the
/// word right in front of the name is looked at.
const declarators = [_][]const u8{
    "const",  "var",    "let",      "fn",        "func",    "function",
    "def",    "class",  "struct",   "enum",      "union",   "interface",
    "type",   "trait",  "impl",     "namespace", "package", "module",
    "record", "object", "protocol", "extension", "typedef", "val",
};

/// Whether `line` declares the name at `line[start..end]`.
pub fn isDeclaration(line: []const u8, start: usize, end: usize) bool {
    if (start >= end or end > line.len) return false;
    const before = std.mem.trimEnd(u8, line[0..start], " \t");
    const after = std.mem.trimStart(u8, line[end..], " \t");

    // `const name`, `fn name`, `class name`: a word that introduces a name.
    const word = lastWord(before);
    for (declarators) |d| if (std.mem.eql(u8, word, d)) return true;

    // `name = ...` or `name := ...` starting a line, as Python and shell
    // scripts declare things. `name == ...` is a comparison, not one.
    if (before.len == 0) {
        if (std.mem.startsWith(u8, after, ":=")) return true;
        if (std.mem.startsWith(u8, after, "=") and !std.mem.startsWith(u8, after, "==")) return true;
    }

    // `name(...) {`: a function body opening, as C, Java and JavaScript
    // methods do. The name has to be the line's first call, so the test
    // in `if (ready(x)) {` isn't taken for a declaration.
    if (after.len > 0 and after[0] == '(' and std.mem.indexOfScalar(u8, before, '(') == null) {
        const code = std.mem.trimEnd(u8, line, " \t\r");
        if (std.mem.endsWith(u8, code, "{")) return true;
    }
    return false;
}

/// The word `s` ends with, empty unless it ends in word characters.
fn lastWord(s: []const u8) []const u8 {
    var i = s.len;
    while (i > 0 and text.isWordChar(s[i - 1])) i -= 1;
    return s[i..];
}

/// Whether `name` is something to look up at all: an identifier, not a
/// number or punctuation.
pub fn isName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| if (!text.isWordChar(c)) return false;
    return true;
}

test {
    _ = @import("../tests/symbols_test.zig");
}
