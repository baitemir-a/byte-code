//! Tests for GitRefs.zig.
const std = @import("std");
const GitRefs = @import("../GitRefs.zig");

test "parses branches and stashes" {
    var refs = GitRefs.init(std.testing.allocator);
    defer refs.deinit();
    try refs.parseBranches("refs/heads/dev\x1f*\nrefs/heads/main\x1f \nrefs/remotes/origin/HEAD\x1f \nrefs/remotes/origin/main\x1f \nrefs/tags/v1\x1f \n");
    const b = refs.branches.items;
    try std.testing.expectEqual(@as(usize, 3), b.len);
    try std.testing.expectEqualStrings("dev", b[0].name);
    try std.testing.expect(b[0].current and !b[0].remote);
    try std.testing.expect(!b[1].current);
    try std.testing.expectEqualStrings("origin/main", b[2].name);
    try std.testing.expect(b[2].remote);
    try std.testing.expectEqualStrings("main", GitRefs.localName(b[2].name));

    try refs.parseStashes("stash@{0}\x1f1700000000\x1fOn dev: half-done menu\nstash@{1}\x1f1600000000\x1fWIP on main: abc123 first\n");
    const s = refs.stashes.items;
    try std.testing.expectEqual(@as(usize, 2), s.len);
    try std.testing.expectEqualStrings("stash@{0}", s[0].ref);
    try std.testing.expectEqualStrings("On dev: half-done menu", s[0].message);
    try std.testing.expectEqual(@as(i64, 1600000000), s[1].time);
}
