//! Editor core: text, cursor, editing and undo. No rendering or platform
//! code lives here, so everything is unit-testable with `zig build test`.

pub const Buffer = @import("Buffer.zig");
pub const Document = @import("Document.zig");
pub const Search = @import("Search.zig");
pub const FileTree = @import("FileTree.zig");
pub const TerminalScreen = @import("terminal/Screen.zig");
pub const Settings = @import("Settings.zig");
pub const FileSearch = @import("FileSearch.zig");
pub const ProjectSearch = @import("ProjectSearch.zig");
pub const Git = @import("Git.zig");
pub const History = @import("History.zig");
pub const text = @import("text.zig");
pub const motion = @import("motion.zig");
pub const edit = @import("edit.zig");
pub const command = @import("command.zig");
pub const syntax = @import("syntax/syntax.zig");
pub const Completion = @import("completion/Completion.zig");

pub const Command = command.Command;
pub const Motion = motion.Motion;

test {
    @import("std").testing.refAllDecls(@This());
}
