//! Identifiers used in the document, rebuilt whenever the buffer changes.
//! Strings and comments are skipped thanks to the syntax highlighter.
const std = @import("std");
const Buffer = @import("../Buffer.zig");
const Highlighter = @import("../syntax/Highlighter.zig");
const js = @import("../syntax/js.zig");

const Index = @This();

pub const Word = struct {
    count: u32 = 0,
    /// Seen as `x.word` / on its own.
    as_member: bool = false,
    as_name: bool = false,
    /// Seen followed by `(`.
    called: bool = false,
    /// Starts with an uppercase letter or was lexed as a type.
    is_type: bool = false,
};

arena: std.heap.ArenaAllocator,
words: std.StringArrayHashMapUnmanaged(Word) = .empty,
version: ?u64 = null,

pub fn init(gpa: std.mem.Allocator) Index {
    return .{ .arena = .init(gpa) };
}

pub fn deinit(self: *Index) void {
    self.arena.deinit();
}

pub fn update(self: *Index, gpa: std.mem.Allocator, buf: *const Buffer, hl: *Highlighter) !void {
    if (self.version == buf.version) return;
    try hl.update(gpa, buf);

    _ = self.arena.reset(.retain_capacity);
    self.words = .empty;
    const alloc = self.arena.allocator();

    var lines = std.mem.splitScalar(u8, buf.items(), '\n');
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        var tokens = hl.tokens(index, line);
        while (tokens.next()) |span| {
            switch (span.kind) {
                // Code, strings, comments and keywords (offered separately) aren't names.
                .comment, .string, .regex, .number, .punctuation, .keyword, .code => continue,
                else => {},
            }
            // A plain-text span may hold many words; split it.
            var i = span.start;
            while (i < span.end) {
                if (!js.isIdentStart(line[i])) {
                    i += 1;
                    continue;
                }
                const start = i;
                while (i < span.end and js.isIdentChar(line[i])) i += 1;
                try self.add(alloc, line, start, i, span.kind == .type);
            }
        }
    }
    self.version = buf.version;
}

fn add(self: *Index, alloc: std.mem.Allocator, line: []const u8, start: usize, end: usize, lexed_type: bool) !void {
    const word = line[start..end];
    if (word.len < 2) return;
    const gop = try self.words.getOrPut(alloc, word);
    if (!gop.found_existing) {
        gop.key_ptr.* = try alloc.dupe(u8, word);
        gop.value_ptr.* = .{};
    }
    const w = gop.value_ptr;
    w.count += 1;
    if (start > 0 and line[start - 1] == '.') w.as_member = true else w.as_name = true;
    const rest = std.mem.trimStart(u8, line[end..], " \t");
    if (rest.len > 0 and rest[0] == '(') w.called = true;
    if (lexed_type or std.ascii.isUpper(word[0])) w.is_type = true;
}

test "collects identifiers outside strings and comments" {
    const gpa = std.testing.allocator;
    var buf = Buffer.init(gpa);
    defer buf.deinit();
    var hl = Highlighter.init(.typescript);
    defer hl.deinit(gpa);
    var idx = Index.init(gpa);
    defer idx.deinit();

    try buf.insert("const userName = getUser(); // ignored\nuserName.first = \"not me\"");
    try idx.update(gpa, &buf, &hl);

    try std.testing.expectEqual(@as(u32, 2), idx.words.get("userName").?.count);
    try std.testing.expect(idx.words.get("getUser").?.called);
    try std.testing.expect(idx.words.get("first").?.as_member);
    try std.testing.expect(idx.words.get("ignored") == null);
    try std.testing.expect(idx.words.get("me") == null);
}
