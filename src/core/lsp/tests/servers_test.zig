//! Tests for servers.zig.
const std = @import("std");
const servers = @import("../servers.zig");

const testing = std.testing;

test "servers and language ids" {
    try testing.expectEqual(servers.Server.zls, servers.serversFor(.zig)[0]);
    try testing.expectEqual(@as(usize, 0), servers.serversFor(.markdown).len);
    try testing.expectEqualStrings("typescriptreact", servers.languageId(.jsx, "/a/b.tsx"));
    try testing.expectEqualStrings("javascript", servers.languageId(.typescript, "/a/b.mjs"));
}
