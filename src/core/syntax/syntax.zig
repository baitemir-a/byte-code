//! Syntax highlighting.

pub const Highlighter = @import("Highlighter.zig");
pub const Language = Highlighter.Language;
pub const js = @import("js.zig");
pub const json = @import("json.zig");
pub const css = @import("css.zig");
pub const html = @import("html.zig");
pub const markdown = @import("markdown.zig");
pub const python = @import("python.zig");
pub const toml = @import("toml.zig");
pub const yaml = @import("yaml.zig");
pub const config = @import("config.zig");
pub const clike = @import("clike.zig");
pub const Kind = @import("token.zig").Kind;
pub const Span = @import("token.zig").Span;

test {
    @import("std").testing.refAllDecls(@This());
}
