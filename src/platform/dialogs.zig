//! Native dialogs, shown by running the OS's own tools: `osascript` on
//! macOS, `zenity` on Linux. Each call blocks until the user answers.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Error = error{DialogUnavailable} || Allocator.Error;

pub const Choice = enum { save, discard, cancel };

/// Asks for a file to open. Returns its path (caller frees), or null if cancelled.
pub fn openFile(gpa: Allocator, io: Io, start_dir: ?[]const u8) Error!?[]u8 {
    return switch (builtin.os.tag) {
        .macos => if (start_dir) |d|
            appleScript(gpa, io, &.{"POSIX path of (choose file with prompt \"Open\" default location (POSIX file (item 1 of argv)))"}, &.{d})
        else
            appleScript(gpa, io, &.{"POSIX path of (choose file with prompt \"Open\")"}, &.{}),
        .linux => zenity(gpa, io, &.{ "--file-selection", "--title=Open" }, start_dir, null),
        else => error.DialogUnavailable,
    };
}

/// Asks for a folder. Returns its path (caller frees), or null if cancelled.
pub fn openFolder(gpa: Allocator, io: Io, start_dir: ?[]const u8) Error!?[]u8 {
    return switch (builtin.os.tag) {
        .macos => if (start_dir) |d|
            appleScript(gpa, io, &.{"POSIX path of (choose folder with prompt \"Open Folder\" default location (POSIX file (item 1 of argv)))"}, &.{d})
        else
            appleScript(gpa, io, &.{"POSIX path of (choose folder with prompt \"Open Folder\")"}, &.{}),
        .linux => zenity(gpa, io, &.{ "--file-selection", "--directory", "--title=Open Folder" }, start_dir, null),
        else => error.DialogUnavailable,
    };
}

/// Asks where to save. Returns the path (caller frees), or null if cancelled.
/// The dialog itself confirms overwriting an existing file.
pub fn saveFile(gpa: Allocator, io: Io, default_name: []const u8, start_dir: ?[]const u8) Error!?[]u8 {
    return switch (builtin.os.tag) {
        .macos => if (start_dir) |d|
            appleScript(gpa, io, &.{"POSIX path of (choose file name with prompt \"Save As\" default name (item 1 of argv) default location (POSIX file (item 2 of argv)))"}, &.{ default_name, d })
        else
            appleScript(gpa, io, &.{"POSIX path of (choose file name with prompt \"Save As\" default name (item 1 of argv))"}, &.{default_name}),
        .linux => zenity(gpa, io, &.{ "--file-selection", "--save", "--confirm-overwrite", "--title=Save As" }, start_dir, default_name),
        else => error.DialogUnavailable,
    };
}

/// "Save changes to <name>?" with Save / Don't Save / Cancel.
pub fn askSaveChanges(gpa: Allocator, io: Io, name: []const u8) Error!Choice {
    const answer = switch (builtin.os.tag) {
        .macos => try appleScript(gpa, io, &.{
            "set r to display dialog (\"Do you want to save the changes you made to \" & item 1 of argv & \"?\") " ++
                "buttons {\"Don't Save\", \"Cancel\", \"Save\"} default button \"Save\" cancel button \"Cancel\" with icon caution",
            "button returned of r",
        }, &.{name}),
        .linux => blk: {
            const text = try std.fmt.allocPrint(gpa, "--text=Save changes to {s}?", .{name});
            defer gpa.free(text);
            // OK = Save; the extra button prints its label; anything else is Cancel.
            const r = try runTool(gpa, io, &.{ "zenity", "--question", text, "--ok-label=Save", "--cancel-label=Cancel", "--extra-button=Don't Save" });
            if (r.ok) {
                gpa.free(r.stdout);
                return .save;
            }
            break :blk @as(?[]u8, r.stdout);
        },
        else => return error.DialogUnavailable,
    } orelse return .cancel;
    defer gpa.free(answer);
    if (std.mem.eql(u8, answer, "Save")) return .save;
    if (std.mem.eql(u8, answer, "Don't Save")) return .discard;
    return .cancel;
}

/// A warning with Cancel and an `ok_label` button. Returns true if the user
/// chose `ok_label`.
pub fn confirm(gpa: Allocator, io: Io, message: []const u8, detail: []const u8, ok_label: []const u8) Error!bool {
    const answer = switch (builtin.os.tag) {
        .macos => try appleScript(gpa, io, &.{
            "set r to display alert (item 1 of argv) message (item 2 of argv) as warning " ++
                "buttons {\"Cancel\", item 3 of argv} default button (item 3 of argv) cancel button \"Cancel\"",
            "button returned of r",
        }, &.{ message, detail, ok_label }),
        .linux => blk: {
            const text = try std.fmt.allocPrint(gpa, "--text={s}\n\n{s}", .{ message, detail });
            defer gpa.free(text);
            const ok = try std.fmt.allocPrint(gpa, "--ok-label={s}", .{ok_label});
            defer gpa.free(ok);
            break :blk try zenity(gpa, io, &.{ "--question", "--icon=dialog-warning", text, ok }, null, null);
        },
        else => return error.DialogUnavailable,
    } orelse return false;
    gpa.free(answer);
    return true;
}

/// Moves a file or folder to the system trash, where it can be restored.
/// macOS asks Finder (which supports "Put Back"), falling back to moving it
/// into ~/.Trash; Linux uses `gio trash`.
pub fn moveToTrash(gpa: Allocator, io: Io, path: []const u8) error{ TrashUnavailable, OutOfMemory }!void {
    switch (builtin.os.tag) {
        .macos => {
            const finder = appleScript(gpa, io, &.{
                "tell application \"Finder\" to delete (POSIX file (item 1 of argv) as alias)",
                "\"\"",
            }, &.{path}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.DialogUnavailable => null,
            };
            if (finder) |out| return gpa.free(out);
            return moveIntoHomeTrash(gpa, io, path);
        },
        .linux => {
            const r = runTool(gpa, io, &.{ "gio", "trash", path }) catch return error.TrashUnavailable;
            gpa.free(r.stdout);
            if (!r.ok) return error.TrashUnavailable;
        },
        else => return error.TrashUnavailable,
    }
}

/// Renames into ~/.Trash, adding " 2", " 3"... if the name is taken there.
fn moveIntoHomeTrash(gpa: Allocator, io: Io, path: []const u8) error{ TrashUnavailable, OutOfMemory }!void {
    const home = std.mem.span(std.c.getenv("HOME") orelse return error.TrashUnavailable);
    const name = std.fs.path.basename(path);
    const cwd = Io.Dir.cwd();
    var n: usize = 1;
    while (n < 100) : (n += 1) {
        const dest = if (n == 1)
            try std.fmt.allocPrint(gpa, "{s}/.Trash/{s}", .{ home, name })
        else
            try std.fmt.allocPrint(gpa, "{s}/.Trash/{s} {d}", .{ home, name, n });
        defer gpa.free(dest);
        if (cwd.statFile(io, dest, .{ .follow_symlinks = false })) |_| continue else |_| {}
        cwd.rename(path, cwd, dest, io) catch return error.TrashUnavailable;
        return;
    }
    return error.TrashUnavailable;
}

/// Shows an error message. Failures to show it are ignored.
pub fn showError(gpa: Allocator, io: Io, title: []const u8, message: []const u8) void {
    const out = switch (builtin.os.tag) {
        .macos => appleScript(gpa, io, &.{"display alert (item 1 of argv) message (item 2 of argv) as critical"}, &.{ title, message }),
        .linux => blk: {
            const text = std.fmt.allocPrint(gpa, "--text={s}\n\n{s}", .{ title, message }) catch return;
            defer gpa.free(text);
            break :blk zenity(gpa, io, &.{ "--error", text }, null, null);
        },
        else => return,
    } catch return;
    if (out) |o| gpa.free(o);
}

// ---------------------------------------------------------------- helpers

/// Runs AppleScript `lines` inside `on run argv`, passing `args` as argv, so
/// user text (file names) is never spliced into the script itself.
fn appleScript(gpa: Allocator, io: Io, comptime lines: []const []const u8, args: []const []const u8) Error!?[]u8 {
    const script = comptime blk: {
        var s: []const []const u8 = &.{ "-e", "on run argv" };
        for (lines[0 .. lines.len - 1]) |l| s = s ++ &[_][]const u8{ "-e", l };
        s = s ++ &[_][]const u8{ "-e", "return " ++ lines[lines.len - 1], "-e", "end run" };
        break :blk s;
    };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "osascript");
    try argv.appendSlice(gpa, script);
    try argv.appendSlice(gpa, args);
    return okOutput(gpa, try runTool(gpa, io, argv.items));
}

fn zenity(gpa: Allocator, io: Io, flags: []const []const u8, start_dir: ?[]const u8, file_name: ?[]const u8) Error!?[]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "zenity");
    try argv.appendSlice(gpa, flags);
    var filename_arg: ?[]u8 = null;
    defer if (filename_arg) |f| gpa.free(f);
    if (start_dir != null or file_name != null) {
        filename_arg = try std.fmt.allocPrint(gpa, "--filename={s}/{s}", .{ start_dir orelse ".", file_name orelse "" });
        try argv.append(gpa, filename_arg.?);
    }
    return okOutput(gpa, try runTool(gpa, io, argv.items));
}

const ToolResult = struct { ok: bool, stdout: []u8 };

/// Runs a tool and returns whether it exited with 0, plus its trimmed stdout
/// (caller frees).
fn runTool(gpa: Allocator, io: Io, argv: []const []const u8) Error!ToolResult {
    const r = std.process.run(gpa, io, .{ .argv = argv }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.DialogUnavailable, // e.g. zenity not installed
    };
    defer gpa.free(r.stdout);
    gpa.free(r.stderr);
    const ok = switch (r.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{ .ok = ok, .stdout = try gpa.dupe(u8, std.mem.trimEnd(u8, r.stdout, "\r\n")) };
}

/// Stdout of a successful run, or null if the user cancelled.
fn okOutput(gpa: Allocator, r: ToolResult) ?[]u8 {
    if (r.ok) return r.stdout;
    gpa.free(r.stdout);
    return null;
}
