//! Native dialogs, shown by running the OS's own tools: `osascript` on
//! macOS, `zenity` on Linux; on Windows, the Win32 API directly (see
//! `win32`). Each call blocks until the user answers.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const i18n = @import("../../i18n/i18n.zig");

pub const Error = error{DialogUnavailable} || Allocator.Error;

pub const Choice = enum { save, discard, cancel };

/// The answer to `confirmRemember`: go ahead, go ahead and stop asking,
/// or do nothing.
pub const Confirmation = enum { cancel, ok, ok_always };

/// Asks for a file to open. Returns its path (caller frees), or null if cancelled.
pub fn openFile(gpa: Allocator, io: Io, start_dir: ?[]const u8) Error!?[]u8 {
    const title = i18n.tr().dialogs.open;
    return switch (builtin.os.tag) {
        .macos => if (start_dir) |d|
            appleScript(gpa, io, &.{"POSIX path of (choose file with prompt (item 1 of argv) default location (POSIX file (item 2 of argv)))"}, &.{ title, d })
        else
            appleScript(gpa, io, &.{"POSIX path of (choose file with prompt (item 1 of argv))"}, &.{title}),
        .linux => zenityTitled(gpa, io, &.{"--file-selection"}, title, start_dir, null),
        .windows => win32.fileDialog(gpa, .open_file, title, start_dir, null),
        else => error.DialogUnavailable,
    };
}

/// Asks for a folder. Returns its path (caller frees), or null if cancelled.
pub fn openFolder(gpa: Allocator, io: Io, start_dir: ?[]const u8) Error!?[]u8 {
    const title = i18n.tr().dialogs.open_folder;
    return switch (builtin.os.tag) {
        .macos => if (start_dir) |d|
            appleScript(gpa, io, &.{"POSIX path of (choose folder with prompt (item 1 of argv) default location (POSIX file (item 2 of argv)))"}, &.{ title, d })
        else
            appleScript(gpa, io, &.{"POSIX path of (choose folder with prompt (item 1 of argv))"}, &.{title}),
        .linux => zenityTitled(gpa, io, &.{ "--file-selection", "--directory" }, title, start_dir, null),
        .windows => win32.fileDialog(gpa, .open_folder, title, start_dir, null),
        else => error.DialogUnavailable,
    };
}

/// Asks where to save. Returns the path (caller frees), or null if cancelled.
/// The dialog itself confirms overwriting an existing file.
pub fn saveFile(gpa: Allocator, io: Io, default_name: []const u8, start_dir: ?[]const u8) Error!?[]u8 {
    const title = i18n.tr().dialogs.save_as;
    return switch (builtin.os.tag) {
        .macos => if (start_dir) |d|
            appleScript(gpa, io, &.{"POSIX path of (choose file name with prompt (item 1 of argv) default name (item 2 of argv) default location (POSIX file (item 3 of argv)))"}, &.{ title, default_name, d })
        else
            appleScript(gpa, io, &.{"POSIX path of (choose file name with prompt (item 1 of argv) default name (item 2 of argv))"}, &.{ title, default_name }),
        .linux => zenityTitled(gpa, io, &.{ "--file-selection", "--save", "--confirm-overwrite" }, title, start_dir, default_name),
        .windows => win32.fileDialog(gpa, .save_file, title, start_dir, default_name),
        else => error.DialogUnavailable,
    };
}

/// "Save changes to <name>?" with Save / Don't Save / Cancel.
pub fn askSaveChanges(gpa: Allocator, io: Io, name: []const u8) Error!Choice {
    const t = i18n.tr();
    const question = try i18n.fillAlloc(gpa, t.dialogs.save_changes, .{name});
    defer gpa.free(question);
    const answer = switch (builtin.os.tag) {
        .macos => try appleScript(gpa, io, &.{
            "set r to display dialog (item 1 of argv) " ++
                "buttons {item 2 of argv, item 3 of argv, item 4 of argv} default button (item 4 of argv) cancel button (item 3 of argv) with icon caution",
            "button returned of r",
        }, &.{ question, t.dialogs.dont_save, t.common.cancel, t.dialogs.save }),
        .linux => blk: {
            const text = try std.fmt.allocPrint(gpa, "--text={s}", .{question});
            defer gpa.free(text);
            const ok = try std.fmt.allocPrint(gpa, "--ok-label={s}", .{t.dialogs.save});
            defer gpa.free(ok);
            const cancel = try std.fmt.allocPrint(gpa, "--cancel-label={s}", .{t.common.cancel});
            defer gpa.free(cancel);
            const extra = try std.fmt.allocPrint(gpa, "--extra-button={s}", .{t.dialogs.dont_save});
            defer gpa.free(extra);
            // OK = Save; the extra button prints its label; anything else is Cancel.
            const r = try runTool(gpa, io, &.{ "zenity", "--question", text, ok, cancel, extra });
            if (r.ok) {
                gpa.free(r.stdout);
                return .save;
            }
            break :blk @as(?[]u8, r.stdout);
        },
        // A plain message box can't relabel its buttons: Yes / No / Cancel.
        .windows => return switch (try win32.messageBox(gpa, "byte-code", question, win32.MB_YESNOCANCEL | win32.MB_ICONWARNING)) {
            win32.IDYES => .save,
            win32.IDNO => .discard,
            else => .cancel,
        },
        else => return error.DialogUnavailable,
    } orelse return .cancel;
    defer gpa.free(answer);
    if (std.mem.eql(u8, answer, t.dialogs.save)) return .save;
    if (std.mem.eql(u8, answer, t.dialogs.dont_save)) return .discard;
    return .cancel;
}

/// A warning with Cancel and an `ok_label` button. Returns true if the user
/// chose `ok_label`.
pub fn confirm(gpa: Allocator, io: Io, message: []const u8, detail: []const u8, ok_label: []const u8) Error!bool {
    const cancel = i18n.tr().common.cancel;
    const answer = switch (builtin.os.tag) {
        .macos => try appleScript(gpa, io, &.{
            "set r to display alert (item 1 of argv) message (item 2 of argv) as warning " ++
                "buttons {item 4 of argv, item 3 of argv} default button (item 3 of argv) cancel button (item 4 of argv)",
            "button returned of r",
        }, &.{ message, detail, ok_label, cancel }),
        .linux => blk: {
            const text = try std.fmt.allocPrint(gpa, "--text={s}\n\n{s}", .{ message, detail });
            defer gpa.free(text);
            const ok = try std.fmt.allocPrint(gpa, "--ok-label={s}", .{ok_label});
            defer gpa.free(ok);
            const cancel_arg = try std.fmt.allocPrint(gpa, "--cancel-label={s}", .{cancel});
            defer gpa.free(cancel_arg);
            break :blk try zenity(gpa, io, &.{ "--question", "--icon=dialog-warning", text, ok, cancel_arg }, null, null);
        },
        // OK stands in for `ok_label`, which a message box can't show.
        .windows => {
            const text = try std.fmt.allocPrint(gpa, "{s}\n\n{s}", .{ message, detail });
            defer gpa.free(text);
            return try win32.messageBox(gpa, ok_label, text, win32.MB_OKCANCEL | win32.MB_ICONWARNING) == win32.IDOK;
        },
        else => return error.DialogUnavailable,
    } orelse return false;
    gpa.free(answer);
    return true;
}

/// The same warning as `confirm`, with a third button that goes ahead and
/// says not to ask again (there is no room for a checkbox in a system
/// dialog, so it is a button).
pub fn confirmRemember(gpa: Allocator, io: Io, message: []const u8, detail: []const u8, ok_label: []const u8, always_label: []const u8) Error!Confirmation {
    const cancel = i18n.tr().common.cancel;
    const answer = switch (builtin.os.tag) {
        .macos => try appleScript(gpa, io, &.{
            "set r to display alert (item 1 of argv) message (item 2 of argv) as warning " ++
                "buttons {item 4 of argv, item 5 of argv, item 3 of argv} default button (item 3 of argv) cancel button (item 4 of argv)",
            "button returned of r",
        }, &.{ message, detail, ok_label, cancel, always_label }),
        .linux => blk: {
            const text = try std.fmt.allocPrint(gpa, "--text={s}\n\n{s}", .{ message, detail });
            defer gpa.free(text);
            const ok = try std.fmt.allocPrint(gpa, "--ok-label={s}", .{ok_label});
            defer gpa.free(ok);
            const cancel_arg = try std.fmt.allocPrint(gpa, "--cancel-label={s}", .{cancel});
            defer gpa.free(cancel_arg);
            const extra = try std.fmt.allocPrint(gpa, "--extra-button={s}", .{always_label});
            defer gpa.free(extra);
            // OK answers straight away; the extra button prints its label.
            const r = try runTool(gpa, io, &.{ "zenity", "--question", "--icon=dialog-warning", text, ok, cancel_arg, extra });
            if (r.ok) {
                gpa.free(r.stdout);
                return .ok;
            }
            break :blk @as(?[]u8, r.stdout);
        },
        // A message box can't relabel its buttons: Yes goes ahead, No goes
        // ahead and stops asking.
        .windows => {
            const text = try std.fmt.allocPrint(gpa, "{s}\n\n{s}\n\n{s}", .{ message, detail, always_label });
            defer gpa.free(text);
            return switch (try win32.messageBox(gpa, ok_label, text, win32.MB_YESNOCANCEL | win32.MB_ICONWARNING)) {
                win32.IDYES => .ok,
                win32.IDNO => .ok_always,
                else => .cancel,
            };
        },
        else => return error.DialogUnavailable,
    } orelse return .cancel;
    defer gpa.free(answer);
    if (std.mem.eql(u8, std.mem.trim(u8, answer, " \n"), always_label)) return .ok_always;
    if (std.mem.eql(u8, std.mem.trim(u8, answer, " \n"), ok_label)) return .ok;
    return .cancel;
}

/// A zenity dialog with a window title.
fn zenityTitled(gpa: Allocator, io: Io, flags: []const []const u8, title: []const u8, start_dir: ?[]const u8, file_name: ?[]const u8) Error!?[]u8 {
    const title_arg = try std.fmt.allocPrint(gpa, "--title={s}", .{title});
    defer gpa.free(title_arg);
    var args: [8][]const u8 = undefined;
    @memcpy(args[0..flags.len], flags);
    args[flags.len] = title_arg;
    return zenity(gpa, io, args[0 .. flags.len + 1], start_dir, file_name);
}

/// Moves a file or folder to the system trash, where it can be restored.
/// macOS asks Finder (which supports "Put Back"), falling back to moving it
/// into ~/.Trash; Linux uses `gio trash`; Windows, the Recycle Bin.
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
        .windows => return win32.recycle(gpa, path),
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
        .windows => {
            _ = win32.messageBox(gpa, title, message, win32.MB_OK | win32.MB_ICONERROR) catch {};
            return;
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

// ---------------------------------------------------------------- Windows

/// Win32 has the dialogs built in, so no tools are run: the common file
/// dialog (COM's IFileDialog) and plain message boxes, owned by the
/// editor's window so they stay on top of it.
const win32 = struct {
    const windows = std.os.windows;
    const HWND = windows.HWND;
    const GUID = windows.GUID;
    const HRESULT = c_long;
    const WCHAR = u16;

    const Kind = enum { open_file, open_folder, save_file };

    fn fileDialog(gpa: Allocator, kind: Kind, title: []const u8, start_dir: ?[]const u8, file_name: ?[]const u8) Error!?[]u8 {
        // The dialog needs COM in a single-threaded apartment. S_FALSE means
        // it already was; either way it's balanced below.
        const init = CoInitializeEx(null, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
        if (init < 0 and init != RPC_E_CHANGED_MODE) return error.DialogUnavailable;
        defer if (init >= 0) CoUninitialize();

        const clsid = if (kind == .save_file) &CLSID_FileSaveDialog else &CLSID_FileOpenDialog;
        var dialog: *IFileDialog = undefined;
        if (CoCreateInstance(clsid, null, CLSCTX_INPROC_SERVER, &IID_IFileDialog, @ptrCast(&dialog)) < 0) return error.DialogUnavailable;
        defer _ = dialog.vtable.Release(dialog);

        var options: u32 = 0;
        _ = dialog.vtable.GetOptions(dialog, &options);
        options |= FOS_FORCEFILESYSTEM | @as(u32, switch (kind) {
            .open_file => FOS_FILEMUSTEXIST,
            .open_folder => FOS_PICKFOLDERS,
            .save_file => FOS_OVERWRITEPROMPT,
        });
        _ = dialog.vtable.SetOptions(dialog, options);

        const wide_title = try wide(gpa, title);
        defer gpa.free(wide_title);
        _ = dialog.vtable.SetTitle(dialog, wide_title);
        if (file_name) |n| {
            const w = try wide(gpa, n);
            defer gpa.free(w);
            _ = dialog.vtable.SetFileName(dialog, w);
        }
        // An unusable start folder just means the dialog picks its own.
        if (start_dir) |d| {
            const w = try wide(gpa, d);
            defer gpa.free(w);
            std.mem.replaceScalar(WCHAR, w, '/', '\\');
            var folder: *IShellItem = undefined;
            if (SHCreateItemFromParsingName(w, null, &IID_IShellItem, @ptrCast(&folder)) >= 0) {
                _ = dialog.vtable.SetFolder(dialog, folder);
                _ = folder.vtable.Release(folder);
            }
        }

        const shown = dialog.vtable.Show(dialog, GetActiveWindow());
        if (shown == HRESULT_ERROR_CANCELLED) return null;
        if (shown < 0) return error.DialogUnavailable;

        var item: *IShellItem = undefined;
        if (dialog.vtable.GetResult(dialog, &item) < 0) return error.DialogUnavailable;
        defer _ = item.vtable.Release(item);
        var path: [*:0]WCHAR = undefined;
        if (item.vtable.GetDisplayName(item, SIGDN_FILESYSPATH, &path) < 0) return error.DialogUnavailable;
        defer CoTaskMemFree(path);
        return try std.unicode.wtf16LeToWtf8Alloc(gpa, std.mem.span(path));
    }

    /// Shows a message box and returns the ID of the button pressed.
    fn messageBox(gpa: Allocator, title: []const u8, text: []const u8, flags: c_uint) Error!c_int {
        const wide_title = try wide(gpa, title);
        defer gpa.free(wide_title);
        const wide_text = try wide(gpa, text);
        defer gpa.free(wide_text);
        const id = MessageBoxW(GetActiveWindow(), wide_text, wide_title, flags);
        if (id == 0) return error.DialogUnavailable;
        return id;
    }

    fn recycle(gpa: Allocator, path: []const u8) error{ TrashUnavailable, OutOfMemory }!void {
        // pFrom is a list of paths, each ended by a NUL, the list by another.
        const w = std.unicode.wtf8ToWtf16LeAlloc(gpa, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.TrashUnavailable,
        };
        defer gpa.free(w);
        const from = try gpa.alloc(WCHAR, w.len + 2);
        defer gpa.free(from);
        @memcpy(from[0..w.len], w);
        std.mem.replaceScalar(WCHAR, from[0..w.len], '/', '\\');
        from[w.len] = 0;
        from[w.len + 1] = 0;
        var op: SHFILEOPSTRUCTW = .{
            .hwnd = GetActiveWindow(),
            .wFunc = FO_DELETE,
            .pFrom = @ptrCast(from.ptr),
            .fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI,
        };
        if (SHFileOperationW(&op) != 0 or op.fAnyOperationsAborted.toBool()) return error.TrashUnavailable;
    }

    fn wide(gpa: Allocator, s: []const u8) Error![:0]WCHAR {
        return std.unicode.wtf8ToWtf16LeAllocZ(gpa, s) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidWtf8 => return error.DialogUnavailable,
        };
    }

    const MB_OK = 0x0;
    const MB_OKCANCEL = 0x1;
    const MB_YESNOCANCEL = 0x3;
    const MB_ICONERROR = 0x10;
    const MB_ICONWARNING = 0x30;
    const IDOK = 1;
    const IDYES = 6;
    const IDNO = 7;

    const COINIT_APARTMENTTHREADED = 0x2;
    const COINIT_DISABLE_OLE1DDE = 0x4;
    const CLSCTX_INPROC_SERVER = 0x1;
    const RPC_E_CHANGED_MODE: HRESULT = @bitCast(@as(u32, 0x80010106));
    const HRESULT_ERROR_CANCELLED: HRESULT = @bitCast(@as(u32, 0x800704C7));

    const FOS_OVERWRITEPROMPT = 0x2;
    const FOS_PICKFOLDERS = 0x20;
    const FOS_FORCEFILESYSTEM = 0x40;
    const FOS_FILEMUSTEXIST = 0x1000;
    const SIGDN_FILESYSPATH: c_int = @bitCast(@as(u32, 0x80058000));

    const FO_DELETE = 0x3;
    const FOF_SILENT = 0x4;
    const FOF_NOCONFIRMATION = 0x10;
    const FOF_ALLOWUNDO = 0x40;
    const FOF_NOERRORUI = 0x400;

    const CLSID_FileOpenDialog = GUID.parse("{DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7}");
    const CLSID_FileSaveDialog = GUID.parse("{C0B4E2F3-BA21-4773-8DBA-335EC946EB8B}");
    const IID_IFileDialog = GUID.parse("{42F85136-DB7E-439C-85F1-E4075D135FC8}");
    const IID_IShellItem = GUID.parse("{43826D1E-E718-42EE-BC55-A1E261C37BFE}");

    const SHFILEOPSTRUCTW = extern struct {
        hwnd: ?HWND,
        wFunc: c_uint,
        pFrom: [*:0]const WCHAR,
        pTo: ?[*:0]const WCHAR = null,
        fFlags: u16,
        fAnyOperationsAborted: windows.BOOL = .FALSE,
        hNameMappings: ?*anyopaque = null,
        lpszProgressTitle: ?[*:0]const WCHAR = null,
    };

    /// COM interfaces as vtables, in declaration order. Only the methods
    /// used here are typed; the rest just hold their place.
    const Slot = *const anyopaque;

    const IShellItem = extern struct {
        vtable: *const extern struct {
            QueryInterface: Slot,
            AddRef: Slot,
            Release: *const fn (*IShellItem) callconv(.winapi) u32,
            BindToHandler: Slot,
            GetParent: Slot,
            GetDisplayName: *const fn (*IShellItem, c_int, *[*:0]WCHAR) callconv(.winapi) HRESULT,
            GetAttributes: Slot,
            Compare: Slot,
        },
    };

    const IFileDialog = extern struct {
        vtable: *const extern struct {
            // IUnknown
            QueryInterface: Slot,
            AddRef: Slot,
            Release: *const fn (*IFileDialog) callconv(.winapi) u32,
            // IModalWindow
            Show: *const fn (*IFileDialog, ?HWND) callconv(.winapi) HRESULT,
            // IFileDialog
            SetFileTypes: Slot,
            SetFileTypeIndex: Slot,
            GetFileTypeIndex: Slot,
            Advise: Slot,
            Unadvise: Slot,
            SetOptions: *const fn (*IFileDialog, u32) callconv(.winapi) HRESULT,
            GetOptions: *const fn (*IFileDialog, *u32) callconv(.winapi) HRESULT,
            SetDefaultFolder: Slot,
            SetFolder: *const fn (*IFileDialog, *IShellItem) callconv(.winapi) HRESULT,
            GetFolder: Slot,
            GetCurrentSelection: Slot,
            SetFileName: *const fn (*IFileDialog, [*:0]const WCHAR) callconv(.winapi) HRESULT,
            GetFileName: Slot,
            SetTitle: *const fn (*IFileDialog, [*:0]const WCHAR) callconv(.winapi) HRESULT,
            SetOkButtonLabel: Slot,
            SetFileNameLabel: Slot,
            GetResult: *const fn (*IFileDialog, **IShellItem) callconv(.winapi) HRESULT,
            AddPlace: Slot,
            SetDefaultExtension: Slot,
            Close: Slot,
            SetClientGuid: Slot,
            ClearClientData: Slot,
            SetFilter: Slot,
        },
    };

    extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, coinit: u32) callconv(.winapi) HRESULT;
    extern "ole32" fn CoUninitialize() callconv(.winapi) void;
    extern "ole32" fn CoCreateInstance(clsid: *const GUID, outer: ?*anyopaque, context: u32, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;
    extern "ole32" fn CoTaskMemFree(p: ?*anyopaque) callconv(.winapi) void;
    extern "shell32" fn SHCreateItemFromParsingName(path: [*:0]const WCHAR, bind: ?*anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;
    extern "shell32" fn SHFileOperationW(op: *SHFILEOPSTRUCTW) callconv(.winapi) c_int;
    extern "user32" fn GetActiveWindow() callconv(.winapi) ?HWND;
    extern "user32" fn MessageBoxW(owner: ?HWND, text: [*:0]const WCHAR, caption: [*:0]const WCHAR, flags: c_uint) callconv(.winapi) c_int;
};
