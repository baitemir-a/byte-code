//! Path aliases from the nearest tsconfig.json / jsconfig.json: the
//! `compilerOptions.paths` that map `@/*` to `./src/*`, plus `baseUrl`.
//! Follows relative `extends` and `references` (Vite puts its options in
//! tsconfig.app.json). The files are JSON with comments and trailing commas.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Alias = struct {
    /// The key before its `*`, e.g. `@/`; the whole key when there's no `*`.
    prefix: []const u8,
    /// Whether the key ends in `*`, so anything can follow the prefix.
    wildcard: bool,
    /// Absolute folder the first target points at, before its `*`.
    target: []const u8,
};

pub const Config = struct {
    aliases: []const Alias = &.{},
    /// Absolute `baseUrl`, where bare imports also resolve.
    base_url: ?[]const u8 = null,
};

const names = [_][]const u8{ "tsconfig.json", "jsconfig.json" };

/// The config that applies to files in `dir`: the first one found going up.
/// Everything is allocated in `alloc` (an arena).
pub fn load(alloc: Allocator, io: Io, dir: []const u8) Config {
    var up: ?[]const u8 = dir;
    while (up) |d| : (up = std.fs.path.dirname(d)) {
        for (names) |name| {
            const path = std.fs.path.join(alloc, &.{ d, name }) catch return .{};
            var aliases: std.ArrayList(Alias) = .empty;
            var config: Config = .{};
            if (!readFile(alloc, io, path, &aliases, &config, 0)) continue;
            config.aliases = aliases.items;
            return config;
        }
    }
    return .{};
}

/// Adds the aliases of the config at `path` (then of the ones it extends
/// or references). Returns false if the file can't be read.
fn readFile(alloc: Allocator, io: Io, path: []const u8, aliases: *std.ArrayList(Alias), config: *Config, depth: u8) bool {
    if (depth > 4) return false;
    const text = Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return false;
    const json = std.json.parseFromSliceLeaky(std.json.Value, alloc, stripJsonc(alloc, text) catch return true, .{}) catch return true;
    if (json != .object) return true;
    const here = std.fs.path.dirname(path) orelse "/";

    if (json.object.get("compilerOptions")) |opts| if (opts == .object) {
        const base_url = if (opts.object.get("baseUrl")) |b| if (b == .string) b.string else null else null;
        const base = std.fs.path.resolve(alloc, &.{ here, base_url orelse "." }) catch return true;
        if (base_url != null and config.base_url == null) config.base_url = base;
        if (opts.object.get("paths")) |paths| if (paths == .object) {
            var it = paths.object.iterator();
            while (it.next()) |e| addAlias(alloc, aliases, base, e.key_ptr.*, e.value_ptr.*) catch {};
        };
    };

    // Options from what this one builds on come after its own.
    var more: std.ArrayList([]const u8) = .empty;
    if (json.object.get("extends")) |ext| switch (ext) {
        .string => |s| more.append(alloc, s) catch {},
        .array => |a| for (a.items) |v| if (v == .string) more.append(alloc, v.string) catch {},
        else => {},
    };
    if (json.object.get("references")) |refs| if (refs == .array) for (refs.array.items) |r| {
        if (r != .object) continue;
        const p = r.object.get("path") orelse continue;
        if (p == .string) more.append(alloc, p.string) catch {};
    };
    for (more.items) |m| {
        // Package configs (`@tsconfig/node20`) don't declare project paths.
        if (!std.mem.startsWith(u8, m, ".")) continue;
        var target = std.fs.path.resolve(alloc, &.{ here, m }) catch continue;
        // A reference may name a folder holding a tsconfig.json.
        if (!std.mem.endsWith(u8, target, ".json")) target = std.fs.path.join(alloc, &.{ target, "tsconfig.json" }) catch continue;
        _ = readFile(alloc, io, target, aliases, config, depth + 1);
    }
    return true;
}

fn addAlias(alloc: Allocator, aliases: *std.ArrayList(Alias), base: []const u8, key: []const u8, targets: std.json.Value) !void {
    if (targets != .array or targets.array.items.len == 0) return;
    const first = targets.array.items[0];
    if (first != .string) return;
    const star = std.mem.indexOfScalar(u8, key, '*');
    const target_star = std.mem.indexOfScalar(u8, first.string, '*') orelse first.string.len;
    const target_dir = first.string[0..target_star];
    try aliases.append(alloc, .{
        .prefix = if (star) |s| key[0..s] else key,
        .wildcard = star != null,
        .target = try std.fs.path.resolve(alloc, &.{ base, target_dir }),
    });
}

/// JSON with the comments and trailing commas tsconfig allows blanked out.
/// Everything else keeps its place, so offsets into it are offsets into
/// the original.
pub fn stripJsonc(alloc: Allocator, text: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, text);
    var i: usize = 0;
    // Where the last comma outside strings is, while only blanks follow it.
    var comma: ?usize = null;
    while (i < out.len) {
        const c = out[i];
        if (c == '"') {
            comma = null;
            i += 1;
            while (i < out.len and out[i] != '"' and out[i] != '\n') : (i += 1) {
                if (out[i] == '\\') i += 1;
            }
            i = @min(i + 1, out.len);
        } else if (c == '/' and i + 1 < out.len and out[i + 1] == '/') {
            while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
        } else if (c == '/' and i + 1 < out.len and out[i + 1] == '*') {
            const end = if (std.mem.indexOfPos(u8, out, i + 2, "*/")) |e| e + 2 else out.len;
            for (out[i..end]) |*b| if (b.* != '\n') {
                b.* = ' ';
            };
            i = end;
        } else {
            if (c == '}' or c == ']') {
                if (comma) |at| out[at] = ' ';
            }
            if (c == ',') comma = i else if (!std.ascii.isWhitespace(c)) comma = null;
            i += 1;
        }
    }
    return out;
}

test {
    _ = @import("../tests/tsconfig_test.zig");
}
