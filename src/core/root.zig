//! Editor core: text, cursor, editing and undo. No rendering or platform
//! code lives here, so everything is unit-testable with `zig build test`.

pub const Buffer = @import("buffer/Buffer.zig");
pub const Document = @import("Document.zig");
pub const Search = @import("search/Search.zig");
pub const find = @import("search/lib/find.zig");
pub const symbols = @import("search/lib/symbols.zig");
pub const scope = @import("editing/lib/scope.zig");
pub const wrap = @import("editing/lib/wrap.zig");
pub const FileTree = @import("project/FileTree.zig");
pub const Projects = @import("project/Projects.zig");
pub const TerminalScreen = @import("terminal/Screen.zig");
pub const Settings = @import("Settings.zig");
pub const FileSearch = @import("search/FileSearch.zig");
pub const ProjectSearch = @import("search/ProjectSearch.zig");
pub const Git = @import("project/Git.zig");
pub const History = @import("buffer/History.zig");
pub const text = @import("editing/lib/text.zig");
pub const motion = @import("editing/lib/motion.zig");
pub const edit = @import("editing/lib/edit.zig");
pub const command = @import("editing/lib/command.zig");
pub const syntax = @import("syntax/syntax.zig");
pub const Completion = @import("completion/Completion.zig");

pub const Command = command.Command;
pub const Motion = motion.Motion;

test {
    @import("std").testing.refAllDecls(@This());
}
