//! Tests for config.zig.
const std = @import("std");
const token = @import("../lib/token.zig");
const config = @import("../lib/config.zig");

test "dotenv" {
    const expect = token.expectTokens;
    _ = try expect(config.DotenvLexer.init("export API_URL=https://x.io/${VERSION}/v1 # prod", .{}), "export API_URL=https://x.io/${VERSION}/v1 # prod", &.{
        "keyword:export", "property:API_URL", "punctuation:=", "string:https://x.io/", "constant:${VERSION}", "string:/v1", "comment:# prod",
    });
    _ = try expect(config.DotenvLexer.init("# comment", .{}), "# comment", &.{"comment:# comment"});
    const lx = try expect(config.DotenvLexer.init("KEY=\"line one", .{}), "KEY=\"line one", &.{ "property:KEY", "punctuation:=", "string:\"line one" });
    try std.testing.expectEqual(@as(u8, '"'), lx.state.quote);
    _ = try expect(config.DotenvLexer.init("two\"", lx.state), "two\"", &.{"string:two\""});
}

test "ignore files" {
    const expect = token.expectTokens;
    _ = try expect(config.IgnoreLexer.init("# deps"), "# deps", &.{"comment:# deps"});
    _ = try expect(config.IgnoreLexer.init("/node_modules/"), "/node_modules/", &.{ "punctuation:/", "plain:node_modules", "punctuation:/" });
    _ = try expect(config.IgnoreLexer.init("!**/*.log[0-9]"), "!**/*.log[0-9]", &.{
        "keyword:!", "keyword:**", "punctuation:/", "keyword:*", "plain:.log", "keyword:[0-9]",
    });
}
