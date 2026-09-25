//! Recognizes an import path being typed: the string in `from "./ut`,
//! `require("`, `@import("`, `@import "`, `src="`, `#include "`, or the
//! dotted module after Python's `from` / `import`. Works on the line's text
//! up to the cursor; the caller checks the highlighter to rule out comments.
const std = @import("std");
const Highlighter = @import("../../syntax/Highlighter.zig");
const js = @import("../../syntax/lib/js.zig");

const Language = Highlighter.Language;

pub const Style = enum {
    /// A JS/TS module: relative paths, or packages in node_modules.
    js,
    /// Zig's `@import`: .zig/.zon files next to this one, or `std`.
    zig,
    /// Any file relative to this one (`@embedFile`, CSS, HTML, `#include`).
    file,
    /// Python's dotted module path, not in a string.
    python,
};

pub const Context = struct {
    style: Style,
    /// Offset in the line where the typed path starts (after the quote).
    start: usize,
    /// The path typed so far, up to the cursor.
    typed: []const u8,
    /// Offset in the line of the quote or the Python keyword, for the
    /// highlighter check.
    anchor: usize,

    /// The folder part of the path, up to and including the last separator.
    pub fn dirPart(self: Context) []const u8 {
        const sep: u8 = if (self.style == .python) '.' else '/';
        const i = std.mem.lastIndexOfScalar(u8, self.typed, sep) orelse return "";
        return self.typed[0 .. i + 1];
    }

    /// The name being typed after the last separator.
    pub fn segment(self: Context) []const u8 {
        return self.typed[self.dirPart().len..];
    }
};

/// The import path the cursor is in, given the line up to the cursor.
pub fn context(language: Language, before: []const u8) ?Context {
    if (language == .python) return pythonContext(before);
    const quote = openString(before) orelse return null;
    const lead = std.mem.trimEnd(u8, before[0..quote], " \t");
    const style: Style = switch (language) {
        .typescript, .jsx => if (endsWithWord(lead, "from") or endsWithWord(lead, "import") or
            endsWithCall(lead, "import") or endsWithCall(lead, "require")) .js else return null,
        .zig => if (std.mem.endsWith(u8, lead, "@import(")) .zig else if (std.mem.endsWith(u8, lead, "@embedFile(")) .file else return null,
        .css, .scss => if (endsWithWord(lead, "@import") or endsWithWord(lead, "@use") or
            endsWithWord(lead, "@forward") or std.mem.endsWith(u8, lead, "url(")) .file else return null,
        .html, .xml => if (endsWithAttr(lead, "src") or endsWithAttr(lead, "href")) .file else return null,
        .c, .cpp, .objc => if (std.mem.eql(u8, std.mem.trim(u8, lead, " \t"), "#include") or
            std.mem.eql(u8, std.mem.trim(u8, lead, " \t"), "#import")) .file else return null,
        else => return null,
    };
    const typed = before[quote + 1 ..];
    // A URL or a template placeholder isn't a local path.
    if (std.mem.indexOf(u8, typed, "://") != null or std.mem.indexOfScalar(u8, typed, '$') != null) return null;
    return .{ .style = style, .start = quote + 1, .typed = typed, .anchor = quote };
}

/// `from pkg.mo` / `import os, pkg.mo`: the dotted name at the end.
fn pythonContext(before: []const u8) ?Context {
    const indent = before.len - std.mem.trimStart(u8, before, " \t").len;
    const stmt = before[indent..];
    const kw_len: usize = if (std.mem.startsWith(u8, stmt, "from ")) 5 else if (std.mem.startsWith(u8, stmt, "import ")) 7 else return null;
    const rest = stmt[kw_len..];
    var start = indent + kw_len;
    if (kw_len == 5) {
        // `from x import y` names things inside x, not modules.
        for (rest) |c| if (!isDotted(c) and c != ' ' and c != '\t') return null;
        if (std.mem.indexOfAny(u8, std.mem.trim(u8, rest, " \t"), " \t") != null) return null;
    } else {
        for (rest) |c| if (!isDotted(c) and c != ' ' and c != '\t' and c != ',') return null;
        if (std.mem.lastIndexOfScalar(u8, rest, ',')) |i| start += i + 1;
    }
    while (start < before.len and (before[start] == ' ' or before[start] == '\t')) start += 1;
    const typed = before[start..];
    // `import os sys`: a space inside means the name has ended.
    if (std.mem.indexOfAny(u8, typed, " \t") != null) return null;
    return .{ .style = .python, .start = start, .typed = typed, .anchor = indent };
}

fn isDotted(c: u8) bool {
    return c == '.' or js.isIdentChar(c);
}

/// Position of the quote of a string still open at the end of `line`.
fn openString(line: []const u8) ?usize {
    var open: ?usize = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (open) |o| {
            if (c == '\\') i += 1 else if (c == line[o]) open = null;
        } else if (c == '"' or c == '\'' or c == '`') open = i;
    }
    return open;
}

fn endsWithWord(s: []const u8, word: []const u8) bool {
    if (!std.mem.endsWith(u8, s, word)) return false;
    const i = s.len - word.len;
    return i == 0 or !js.isIdentChar(s[i - 1]);
}

/// `name(` with optional spaces before the parenthesis.
fn endsWithCall(s: []const u8, name: []const u8) bool {
    if (s.len == 0 or s[s.len - 1] != '(') return false;
    return endsWithWord(std.mem.trimEnd(u8, s[0 .. s.len - 1], " \t"), name);
}

/// `name=` with optional spaces around the `=`.
fn endsWithAttr(s: []const u8, name: []const u8) bool {
    if (s.len == 0 or s[s.len - 1] != '=') return false;
    const n = std.mem.trimEnd(u8, s[0 .. s.len - 1], " \t");
    return endsWithWord(n, name) and n.len > name.len and std.ascii.isWhitespace(n[n.len - name.len - 1]);
}

/// The name to show for a file in this style, or null to leave it out.
/// JS modules drop their extension, as bundlers and TypeScript resolve it.
pub fn fileLabel(style: Style, name: []const u8) ?[]const u8 {
    switch (style) {
        .js => {
            inline for (.{ ".d.ts", ".tsx", ".ts", ".jsx", ".js" }) |ext| {
                if (std.mem.endsWith(u8, name, ext) and name.len > ext.len) return name[0 .. name.len - ext.len];
            }
            return name;
        },
        .zig => return if (std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".zon")) name else null,
        .file => return name,
        .python => {
            if (std.mem.eql(u8, name, "__init__.py")) return null;
            inline for (.{ ".py", ".pyi" }) |ext| {
                if (std.mem.endsWith(u8, name, ext)) {
                    const stem = name[0 .. name.len - ext.len];
                    return if (isIdentifier(stem)) stem else null;
                }
            }
            return null;
        },
    }
}

/// Whether a folder is worth offering in this style.
pub fn folderShown(style: Style, name: []const u8) bool {
    if (std.mem.eql(u8, name, "node_modules") and style != .file) return false;
    if (style == .python) return isIdentifier(name) and !std.mem.eql(u8, name, "__pycache__");
    return true;
}

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0 or !js.isIdentStart(s[0])) return false;
    for (s) |c| if (!js.isIdentChar(c) or c == '$') return false;
    return true;
}

test {
    _ = @import("../tests/imports_test.zig");
}
