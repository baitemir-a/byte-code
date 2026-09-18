//! Fuzzy matching: does a candidate contain the query's characters in order,
//! and how good a match is it?
const std = @import("std");

pub const Match = struct {
    score: i32,
    /// Bit i set = candidate byte i matched (first 64 bytes only).
    positions: u64,
};

/// Case-insensitive subsequence match. Rewards prefixes, exact case,
/// consecutive runs and word starts (`getUser` matches `gU` well).
pub fn match(candidate: []const u8, query: []const u8) ?Match {
    if (query.len == 0) return .{ .score = 0, .positions = 0 };
    if (query.len > candidate.len) return null;

    var score: i32 = 0;
    var positions: u64 = 0;
    var qi: usize = 0;
    var prev: ?usize = null;
    for (candidate, 0..) |c, i| {
        if (qi == query.len) break;
        const q = query[qi];
        if (std.ascii.toLower(c) != std.ascii.toLower(q)) continue;

        var s: i32 = 1;
        if (c == q) s += 1;
        if (i == 0) s += 8 else if (isWordStart(candidate, i)) s += 5;
        if (prev != null and prev.? + 1 == i) s += 4;
        score += s;
        if (i < 64) positions |= @as(u64, 1) << @intCast(i);
        prev = i;
        qi += 1;
    }
    if (qi < query.len) return null;

    if (std.ascii.startsWithIgnoreCase(candidate, query)) score += 20;
    if (std.mem.startsWith(u8, candidate, query)) score += 10;
    return .{ .score = score, .positions = positions };
}

/// Start of a "word" inside an identifier: after `_`/`$`, or a camelCase hump.
fn isWordStart(s: []const u8, i: usize) bool {
    const p = s[i - 1];
    const c = s[i];
    return p == '_' or p == '$' or (std.ascii.isLower(p) and std.ascii.isUpper(c));
}

test "subsequence and ranking" {
    try std.testing.expect(match("console", "cns") != null);
    try std.testing.expect(match("console", "cx") == null);
    // Word starts count: "gebi" hits get-Element-By-Id humps.
    try std.testing.expect(match("getElementById", "gebi").?.score > match("gxexbxix", "gebi").?.score);
    // Prefix beats a scattered match.
    try std.testing.expect(match("map", "ma").?.score > match("Math", "mh").?.score);
    try std.testing.expectEqual(@as(u64, 0b101), match("abc", "ac").?.positions);
}
