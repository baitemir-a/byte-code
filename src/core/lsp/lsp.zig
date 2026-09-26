//! Language servers: the protocol, a client for one server, the edits
//! they send, and which server serves which language.
pub const protocol = @import("protocol.zig");
pub const Client = @import("Client.zig");
pub const edits = @import("edits.zig");
pub const results = @import("results.zig");
pub const servers = @import("servers.zig");

test {
    _ = protocol;
    _ = edits;
    _ = results;
    _ = servers;
    _ = @import("tests/Client_test.zig");
}
