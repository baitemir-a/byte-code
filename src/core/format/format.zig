//! Formatting a file with its language's own formatter: Prettier (for
//! JS/TS, JSON, CSS, HTML, Markdown, YAML — the project's own copy, else
//! a global one), `zig fmt`, gofmt, rustfmt, Black or Ruff, clang-format.
//! Each reads the text on stdin and writes it formatted to stdout, so
//! unsaved edits are formatted too.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Highlighter = @import("../syntax/Highlighter.zig");
const checkers = @import("../diagnostics/lib/checkers.zig");

pub const Formatter = enum {
    prettier,
    zig,
    gofmt,
    rustfmt,
    black,
    ruff,
    clang_format,

    /// Its name, for messages.
    pub fn name(self: Formatter) []const u8 {
        return switch (self) {
            .prettier => "Prettier",
            .zig => "zig fmt",
            .gofmt => "gofmt",
            .rustfmt => "rustfmt",
            .black => "Black",
            .ruff => "Ruff",
            .clang_format => "clang-format",
        };
    }
};

/// The formatters for a language, the preferred one first.
pub fn formattersFor(language: Highlighter.Language) []const Formatter {
    return switch (language) {
        .typescript, .jsx, .json, .css, .scss, .html, .markdown, .yaml, .graphql => &.{.prettier},
        .zig => &.{.zig},
        .go => &.{.gofmt},
        .rust => &.{.rustfmt},
        .python => &.{ .black, .ruff },
        .c, .cpp, .objc => &.{.clang_format},
        else => &.{},
    };
}

pub const Result = union(enum) {
    /// No formatter for the language is installed.
    unavailable,
    /// It ran and refused, usually over a syntax error: what it said.
    failed: struct { formatter: Formatter, message: []const u8 },
    /// The text, formatted.
    formatted: []const u8,
};

/// Formats `source`, the text of the file at `path` (absolute, or just a
/// name for an untitled file: its extension still tells Prettier the
/// language). Programs are looked for in `search_path` (see
/// `checkers.searchPath`). Everything is allocated in `alloc`.
pub fn run(alloc: Allocator, io: Io, language: Highlighter.Language, path: []const u8, source: []const u8, search_path: []const u8) !Result {
    for (formattersFor(language)) |f| {
        const argv = try command(alloc, io, f, path, search_path) orelse continue;
        const dir = if (std.fs.path.isAbsolute(path)) std.fs.path.dirname(path) else null;
        const out = try runFilter(alloc, io, argv, source, dir) orelse continue;
        if (out.ok) return .{ .formatted = out.stdout };
        const message = std.mem.trim(u8, if (out.stderr.len > 0) out.stderr else out.stdout, " \t\r\n");
        return .{ .failed = .{ .formatter = f, .message = message } };
    }
    return .unavailable;
}

/// How to run `f` on stdin, or null when it isn't installed.
fn command(alloc: Allocator, io: Io, f: Formatter, path: []const u8, search_path: []const u8) !?[]const []const u8 {
    const find = checkers.findExe;
    return switch (f) {
        .prettier => {
            // Through node, which a Dock-started app can't count on finding
            // from Prettier's own `#!/usr/bin/env node`.
            const node = find(alloc, io, search_path, "node") orelse return null;
            const script = findPrettier(alloc, io, path, search_path) orelse return null;
            return try alloc.dupe([]const u8, &.{ node, script, "--stdin-filepath", path });
        },
        .zig => {
            const zig = find(alloc, io, search_path, "zig") orelse return null;
            if (std.mem.endsWith(u8, path, ".zon")) return try alloc.dupe([]const u8, &.{ zig, "fmt", "--stdin", "--zon" });
            return try alloc.dupe([]const u8, &.{ zig, "fmt", "--stdin" });
        },
        .gofmt => try alloc.dupe([]const u8, &.{find(alloc, io, search_path, "gofmt") orelse return null}),
        .rustfmt => try alloc.dupe([]const u8, &.{ find(alloc, io, search_path, "rustfmt") orelse return null, "--edition", "2021", "--emit", "stdout" }),
        .black => try alloc.dupe([]const u8, &.{ find(alloc, io, search_path, "black") orelse return null, "-q", "--stdin-filename", path, "-" }),
        .ruff => try alloc.dupe([]const u8, &.{ find(alloc, io, search_path, "ruff") orelse return null, "format", "--stdin-filename", path, "-" }),
        .clang_format => {
            const exe = find(alloc, io, search_path, "clang-format") orelse return null;
            return try alloc.dupe([]const u8, &.{ exe, try std.mem.concat(alloc, u8, &.{ "--assume-filename=", path }) });
        },
    };
}

/// Prettier's script: the project's own (in a node_modules up from the
/// file), else the one a global `prettier` command runs.
fn findPrettier(alloc: Allocator, io: Io, path: []const u8, search_path: []const u8) ?[]const u8 {
    const scripts = [_][]const u8{ "node_modules/prettier/bin/prettier.cjs", "node_modules/prettier/bin-prettier.js" };
    if (std.fs.path.isAbsolute(path)) {
        var up: ?[]const u8 = std.fs.path.dirname(path);
        while (up) |d| : (up = std.fs.path.dirname(d)) {
            for (scripts) |s| {
                const full = std.fs.path.join(alloc, &.{ d, s }) catch return null;
                if (isFile(io, full)) return full;
            }
        }
    }
    return checkers.findExe(alloc, io, search_path, "prettier");
}

fn isFile(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

const Output = struct { ok: bool, stdout: []const u8, stderr: []const u8 };

/// Runs `argv` (in `dir`, if given) with `source` on stdin; what it wrote
/// and whether it exited with 0. Null if it couldn't be started.
fn runFilter(alloc: Allocator, io: Io, argv: []const []const u8, source: []const u8, dir: ?[]const u8) !?Output {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (dir) |d| .{ .path = d } else .inherit,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return null;
    defer child.kill(io);

    // Formatters read all of their input before writing anything, so it
    // can go in before the output is read.
    child.stdin.?.writeStreamingAll(io, source) catch {};
    child.stdin.?.close(io);
    child.stdin = null;

    var buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var reader: Io.File.MultiReader = undefined;
    reader.init(alloc, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    while (reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => return null,
    }
    const term = child.wait(io) catch return null;
    const stdout = try reader.toOwnedSlice(0);
    const stderr = try reader.toOwnedSlice(1);
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{ .ok = ok, .stdout = stdout, .stderr = stderr };
}

/// The smallest change that turns `old` into `new`: the bytes of `old`
/// between their common start and end, and what replaces them. Replacing
/// only that keeps the cursor, folds and undo history of the rest.
pub const Change = struct { start: usize, end: usize, text: []const u8 };

pub fn change(old: []const u8, new: []const u8) ?Change {
    if (std.mem.eql(u8, old, new)) return null;
    var p: usize = 0;
    const n = @min(old.len, new.len);
    while (p < n and old[p] == new[p]) p += 1;
    var s: usize = 0;
    while (s < n - p and old[old.len - 1 - s] == new[new.len - 1 - s]) s += 1;
    return .{ .start = p, .end = old.len - s, .text = new[p .. new.len - s] };
}

test {
    _ = @import("tests/format_test.zig");
}
