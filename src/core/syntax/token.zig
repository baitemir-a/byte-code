//! What a highlighter produces: kinds of tokens and their byte spans.
const std = @import("std");

pub const Kind = enum {
    plain,
    keyword,
    /// Built-in values: true, false, null, undefined, this, ...; CSS values.
    constant,
    type,
    function,
    number,
    string,
    regex,
    comment,
    punctuation,
    /// HTML/XML tag names, CSS element selectors.
    tag,
    /// HTML/XML attribute names.
    attribute,
    /// CSS properties, JSON keys.
    property,
    /// Markdown headings.
    heading,
    /// Markdown *emphasis* and **strong** text.
    emphasis,
    /// Markdown link text.
    link,
    /// Markdown inline code and code blocks without a known language.
    code,
};

/// A token within one line; `start`/`end` are byte offsets into that line.
pub const Span = struct {
    start: usize,
    end: usize,
    kind: Kind,
};

/// Test helper: the lexer's non-whitespace tokens of `line`, rendered as
/// "kind:text", must equal `expected`. Returns the lexer for state checks.
pub fn expectTokens(lexer: anytype, line: []const u8, expected: []const []const u8) !@TypeOf(lexer) {
    const testing = std.testing;
    var lx = lexer;
    var got: std.ArrayList([]const u8) = .empty;
    defer {
        for (got.items) |s| testing.allocator.free(s);
        got.deinit(testing.allocator);
    }
    var prev_end: usize = 0;
    while (lx.next()) |t| {
        // Tokens must tile the line in order.
        try testing.expectEqual(prev_end, t.start);
        prev_end = t.end;
        const s = line[t.start..t.end];
        if (std.mem.trim(u8, s, " \t").len == 0) continue;
        try got.append(testing.allocator, try std.fmt.allocPrint(testing.allocator, "{t}:{s}", .{ t.kind, s }));
    }
    try testing.expectEqual(line.len, prev_end);
    errdefer {
        std.debug.print("\ngot:\n", .{});
        for (got.items) |g| std.debug.print("  {s}\n", .{g});
    }
    try testing.expectEqual(expected.len, got.items.len);
    for (expected, got.items) |e, g| try testing.expectEqualStrings(e, g);
    return lx;
}
