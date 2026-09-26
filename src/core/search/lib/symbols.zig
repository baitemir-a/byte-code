//! Spotting a declaration without a language server: the shapes a name
//! takes where it is introduced, across the languages the editor
//! highlights. It's a guess from one line of text, not an understanding
//! of the code, so it errs towards missing a declaration rather than
//! calling every mention one.
const std = @import("std");
const text = @import("../../editing/lib/text.zig");
const Highlighter = @import("../../syntax/Highlighter.zig");

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

// ------------------------------------------------------------- outline

/// A name declared in a file, for "go to symbol": where the name is and
/// the word that declared it ("fn", "class"...), or "#" for a heading.
pub const Symbol = struct {
    start: usize,
    end: usize,
    line: u32,
    kind: []const u8,
};

/// Declarators whose names count only at the top of the file (not
/// indented): elsewhere they are mostly local variables.
const top_level_only = [_][]const u8{ "const", "var", "let", "val", "type" };

/// Words a call-like line can start with that don't declare anything:
/// `if (x) {` isn't a method called `if`.
const not_methods = [_][]const u8{
    "if",     "for",    "while",  "switch", "catch",  "return", "with",    "elif",   "else",
    "do",     "try",    "new",    "await",  "typeof", "sizeof", "foreach", "using",  "lock",
    "match",  "when",   "until",  "unless", "defer",  "go",     "assert",  "print",  "yield",
    "delete", "throw",  "case",   "and",    "or",     "not",    "in",      "is",     "super",
    "this",   "select", "loop",   "fixed",  "sync",   "errdefer",
};

/// The declarations in `bytes`, in order, into `out`. `hl` must be up to
/// date with the text: names in strings and comments don't count.
pub fn outline(gpa: std.mem.Allocator, bytes: []const u8, hl: *const Highlighter, out: *std.ArrayList(Symbol)) !void {
    out.clearRetainingCapacity();
    var start: usize = 0;
    var index: u32 = 0;
    while (true) : (index += 1) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        const line = bytes[start..end];
        const found = switch (hl.language) {
            .markdown => heading(line),
            .css, .scss => selector(line),
            else => declaration(hl, index, line),
        };
        if (found) |f| try out.append(gpa, .{ .start = start + f.start, .end = start + f.end, .line = index, .kind = f.kind });
        if (end == bytes.len) break;
        start = end + 1;
    }
}

const Found = struct { start: usize, end: usize, kind: []const u8 };

fn heading(line: []const u8) ?Found {
    if (line.len == 0 or line[0] != '#') return null;
    var i = std.mem.indexOfNone(u8, line, "#") orelse return null;
    if (line[i] != ' ') return null;
    i = std.mem.indexOfNonePos(u8, line, i, " ") orelse return null;
    const e = std.mem.trimEnd(u8, line, " \t#").len;
    if (e <= i) return null;
    return .{ .start = i, .end = e, .kind = "#" };
}

fn selector(line: []const u8) ?Found {
    if (line.len == 0 or line[0] == ' ' or line[0] == '\t') return null;
    const code = std.mem.trimEnd(u8, line, " \t\r");
    if (!std.mem.endsWith(u8, code, "{")) return null;
    const e = std.mem.trimEnd(u8, code[0 .. code.len - 1], " \t").len;
    if (e == 0) return null;
    return .{ .start = 0, .end = e, .kind = "{}" };
}

/// A word of code on a line.
const Word = struct { start: usize, end: usize };

fn declaration(hl: *const Highlighter, index: u32, line: []const u8) ?Found {
    // The words outside strings and comments.
    var words: [32]Word = undefined;
    var n: usize = 0;
    var code_end: usize = 0;
    var tokens = hl.tokens(index, line);
    while (tokens.next()) |span| {
        switch (span.kind) {
            .string, .regex, .comment => continue,
            else => {},
        }
        if (std.mem.trim(u8, line[span.start..span.end], " \t\r").len > 0) code_end = span.end;
        var i = span.start;
        while (i < span.end and n < words.len) {
            if (!text.isWordChar(line[i])) {
                i += 1;
                continue;
            }
            const s = i;
            while (i < span.end and text.isWordChar(line[i])) i += 1;
            // A word split over two tokens is one word.
            if (n > 0 and words[n - 1].end == s) {
                words[n - 1].end = i;
            } else {
                words[n] = .{ .start = s, .end = i };
                n += 1;
            }
        }
    }
    const indented = line.len > 0 and (line[0] == ' ' or line[0] == '\t');

    // `fn name`, `class Name`, `const name` (at the top).
    for (words[0..n], 0..) |w, k| {
        const word = line[w.start..w.end];
        const d = for (declarators) |x| {
            if (std.mem.eql(u8, word, x)) break x;
        } else continue;
        if (indented and contains(&top_level_only, d)) return null;
        var rest = std.mem.trimStart(u8, line[w.end..], " \t");
        var at = line.len - rest.len;
        // Go's methods: `func (r *T) Name(`.
        if (std.mem.eql(u8, d, "func") and rest.len > 0 and rest[0] == '(') {
            const close = std.mem.indexOfScalarPos(u8, line, at, ')') orelse return null;
            rest = std.mem.trimStart(u8, line[close + 1 ..], " \t");
            at = line.len - rest.len;
        }
        // The name is the word right there.
        const name = for (words[k + 1 .. n]) |x| {
            if (x.start == at) break x;
        } else return null;
        if (!isName(line[name.start..name.end])) return null;
        return .{ .start = name.start, .end = name.end, .kind = d };
    }

    // `name(...) {`: a method, as in JavaScript classes, Java and C#.
    if (n == 0 or code_end == 0 or line[code_end - 1] != '{') return null;
    for (words[0..n]) |w| {
        const word = line[w.start..w.end];
        const after = std.mem.trimStart(u8, line[w.end..], " \t");
        if (after.len == 0 or after[0] != '(') continue;
        // Only modifiers (`public static async`) may come before it.
        for (line[0..w.start]) |c| if (!(text.isWordChar(c) or c == ' ' or c == '\t')) return null;
        if (contains(&not_methods, word) or !isName(word)) return null;
        return .{ .start = w.start, .end = w.end, .kind = "()" };
    }
    return null;
}

fn contains(list: []const []const u8, word: []const u8) bool {
    for (list) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

test {
    _ = @import("../tests/symbols_test.zig");
}
