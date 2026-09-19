//! Syntax highlighting.

pub const Highlighter = @import("Highlighter.zig");
pub const Language = Highlighter.Language;
pub const js = @import("lib/js.zig");
pub const json = @import("lib/json.zig");
pub const css = @import("lib/css.zig");
pub const html = @import("lib/html.zig");
pub const markdown = @import("lib/markdown.zig");
pub const python = @import("lib/python.zig");
pub const toml = @import("lib/toml.zig");
pub const yaml = @import("lib/yaml.zig");
pub const config = @import("lib/config.zig");
pub const clike = @import("lib/clike.zig");
pub const Kind = @import("lib/token.zig").Kind;
pub const Span = @import("lib/token.zig").Span;

test {
    @import("std").testing.refAllDecls(@This());
}
