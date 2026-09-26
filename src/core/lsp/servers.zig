//! Which language server serves which language, and how to start it. The
//! first one installed wins. JavaScript and TypeScript get the editor's
//! own small server (ts_server.js) on the project's TypeScript, so they
//! need nothing more than node.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Highlighter = @import("../syntax/Highlighter.zig");
const checkers = @import("../diagnostics/lib/checkers.zig");

pub const ts_server_script = @embedFile("ts_server.js");

pub const Server = enum {
    typescript,
    zls,
    gopls,
    rust_analyzer,
    pyright,
    basedpyright,
    pylsp,
    clangd,

    /// What to call it in messages: the program to install.
    pub fn name(self: Server) []const u8 {
        return switch (self) {
            .typescript => "TypeScript",
            .zls => "zls",
            .gopls => "gopls",
            .rust_analyzer => "rust-analyzer",
            .pyright => "pyright",
            .basedpyright => "basedpyright",
            .pylsp => "python-lsp-server",
            .clangd => "clangd",
        };
    }
};

pub fn serversFor(language: Highlighter.Language) []const Server {
    return switch (language) {
        .typescript, .jsx => &.{.typescript},
        .zig => &.{.zls},
        .go => &.{.gopls},
        .rust => &.{.rust_analyzer},
        .python => &.{ .pyright, .basedpyright, .pylsp },
        .c, .cpp, .objc => &.{.clangd},
        else => &.{},
    };
}

/// The protocol's name for the file's language.
pub fn languageId(language: Highlighter.Language, path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const js = std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".mjs") or std.mem.eql(u8, ext, ".cjs");
    return switch (language) {
        .typescript => if (js) "javascript" else "typescript",
        .jsx => if (std.mem.eql(u8, ext, ".jsx")) "javascriptreact" else "typescriptreact",
        .zig => "zig",
        .go => "go",
        .rust => "rust",
        .python => "python",
        .c => "c",
        .cpp => "cpp",
        .objc => "objective-c",
        else => "plaintext",
    };
}

pub const Found = struct {
    server: Server,
    argv: []const []const u8,
    /// Tells servers of the same kind apart: TypeScript's copy, or "".
    variant: []const u8 = "",
};

/// The first server for `language` that is installed, and how to start
/// it for the file at `path`. In `alloc`.
pub fn find(alloc: Allocator, io: Io, language: Highlighter.Language, path: []const u8, search_path: []const u8, home: []const u8) !?Found {
    const exe = checkers.findExe;
    for (serversFor(language)) |s| {
        const argv: []const []const u8 = switch (s) {
            .typescript => {
                const node = exe(alloc, io, search_path, "node") orelse continue;
                const ts = checkers.findTypeScript(alloc, io, path, home) orelse continue;
                return .{ .server = s, .argv = try alloc.dupe([]const u8, &.{ node, "-e", ts_server_script, ts }), .variant = ts };
            },
            .zls => &.{exe(alloc, io, search_path, "zls") orelse continue},
            .gopls => &.{exe(alloc, io, search_path, "gopls") orelse continue},
            .rust_analyzer => &.{exe(alloc, io, search_path, "rust-analyzer") orelse continue},
            .pyright => &.{ exe(alloc, io, search_path, "pyright-langserver") orelse continue, "--stdio" },
            .basedpyright => &.{ exe(alloc, io, search_path, "basedpyright-langserver") orelse continue, "--stdio" },
            .pylsp => &.{exe(alloc, io, search_path, "pylsp") orelse continue},
            .clangd => &.{exe(alloc, io, search_path, "clangd") orelse continue},
        };
        return .{ .server = s, .argv = try alloc.dupe([]const u8, argv) };
    }
    return null;
}

test {
    _ = @import("tests/servers_test.zig");
}
