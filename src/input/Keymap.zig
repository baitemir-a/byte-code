//! Every keyboard shortcut the editor listens for: one action per line in
//! the Help tab, its default combination, and whatever the user changed it
//! to (kept in keybindings.json next to settings.json).
//!
//! A combination matches only when exactly its modifiers are held, so
//! Shift+Left selects without also moving the cursor and Cmd+Shift+F can
//! differ from Cmd+F.
const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const core = @import("core");
const i18n = @import("../i18n/i18n.zig");

const Keymap = @This();
const is_mac = builtin.os.tag == .macos;

// ------------------------------------------------------------- key combos

/// The modifier keys, as they physically are; left and right count the same.
pub const Mods = packed struct(u4) {
    shift: bool = false,
    ctrl: bool = false,
    /// Option on macOS.
    alt: bool = false,
    /// Command on macOS, the Windows key elsewhere.
    cmd: bool = false,

    /// The modifier this platform uses for app shortcuts (Save, Copy...).
    pub fn primary(self: Mods) bool {
        return if (is_mac) self.cmd else self.ctrl;
    }

    /// The modifier for word-wise moving and deleting.
    pub fn word(self: Mods) bool {
        return if (is_mac) self.alt else self.ctrl;
    }

    pub fn current() Mods {
        return .{
            .shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift),
            .ctrl = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control),
            .alt = rl.isKeyDown(.left_alt) or rl.isKeyDown(.right_alt),
            .cmd = rl.isKeyDown(.left_super) or rl.isKeyDown(.right_super),
        };
    }

    pub fn eql(self: Mods, other: Mods) bool {
        return @as(u4, @bitCast(self)) == @as(u4, @bitCast(other));
    }

    /// Any modifier that isn't Shift: those turn a letter into a shortcut
    /// instead of text.
    pub fn command(self: Mods) bool {
        return self.ctrl or self.alt or self.cmd;
    }

    pub fn none(self: Mods) bool {
        return @as(u4, @bitCast(self)) == 0;
    }
};

/// A key plus the modifiers held with it.
pub const Chord = struct {
    key: rl.KeyboardKey,
    mods: Mods = .{},

    pub fn eql(self: Chord, other: Chord) bool {
        return self.key == other.key and self.mods.eql(other.mods);
    }

    /// True while this combination is pressed (including key repeat).
    pub fn pressed(self: Chord) bool {
        if (!self.mods.eql(Mods.current())) return false;
        return rl.isKeyPressed(self.key) or rl.isKeyPressedRepeat(self.key);
    }

    /// Letters, digits and punctuation type text, so they only work as a
    /// shortcut with Ctrl, Option or Cmd. Arrows, Tab, F-keys and the rest
    /// are free.
    pub fn typesText(self: Chord) bool {
        return keyTypesText(self.key) and !self.mods.command();
    }

    /// "Cmd+Shift+S", into `buf` (48 bytes is always enough).
    pub fn write(self: Chord, buf: []u8) []const u8 {
        var w: usize = 0;
        const add = struct {
            fn f(b: []u8, at: *usize, s: []const u8) void {
                if (at.* + s.len > b.len) return;
                @memcpy(b[at.*..][0..s.len], s);
                at.* += s.len;
            }
        }.f;
        if (self.mods.cmd) add(buf, &w, if (is_mac) "Cmd+" else "Win+");
        if (self.mods.ctrl) add(buf, &w, "Ctrl+");
        if (self.mods.alt) add(buf, &w, if (is_mac) "Option+" else "Alt+");
        if (self.mods.shift) add(buf, &w, "Shift+");
        add(buf, &w, keyName(self.key) orelse "?");
        return buf[0..w];
    }

    /// The other way round: "Cmd+Shift+S". Modifier names from either
    /// platform are accepted, so a settings file can be carried over.
    pub fn parse(s: []const u8) ?Chord {
        var chord: Chord = .{ .key = .null };
        var rest = std.mem.trim(u8, s, " ");
        while (std.mem.indexOfScalar(u8, rest, '+')) |i| {
            // A bare "+" (as in Cmd++) is the key itself, not a separator.
            if (i == 0) break;
            const part = std.mem.trim(u8, rest[0..i], " ");
            if (eqlIgnoreCase(part, "cmd") or eqlIgnoreCase(part, "command") or
                eqlIgnoreCase(part, "super") or eqlIgnoreCase(part, "meta") or eqlIgnoreCase(part, "win"))
                chord.mods.cmd = true
            else if (eqlIgnoreCase(part, "ctrl") or eqlIgnoreCase(part, "control"))
                chord.mods.ctrl = true
            else if (eqlIgnoreCase(part, "alt") or eqlIgnoreCase(part, "option") or eqlIgnoreCase(part, "opt"))
                chord.mods.alt = true
            else if (eqlIgnoreCase(part, "shift"))
                chord.mods.shift = true
            else
                return null;
            rest = rest[i + 1 ..];
        }
        chord.key = keyFromName(std.mem.trim(u8, rest, " ")) orelse return null;
        return chord;
    }
};

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// ----------------------------------------------------------------- actions

/// What a shortcut does. The Help tab lists them in this order, grouped by
/// `Entry.group`.
pub const Action = enum {
    // Files
    open,
    open_folder,
    new_file,
    save,
    save_as,
    close_folder,
    open_settings,
    open_help,
    quick_open,
    // Tabs and views
    close_tab,
    next_tab,
    prev_tab,
    toggle_sidebar,
    toggle_terminal,
    show_explorer,
    show_search,
    show_git,
    toggle_word_wrap,
    zoom_in,
    zoom_out,
    zoom_reset,
    // Find
    find,
    find_replace,
    find_next,
    find_prev,
    toggle_match_case,
    toggle_whole_word,
    // Editing
    copy,
    cut,
    paste,
    undo,
    redo,
    select_all,
    clear_selection,
    complete,
    indent,
    newline,
    backspace,
    delete_forward,
    delete_word_left,
    delete_word_right,
    delete_line_start,
    delete_line_end,
    move_line_up,
    move_line_down,
    expand_selection,
    shrink_selection,
    // Cursor
    cursor_left,
    cursor_right,
    cursor_up,
    cursor_down,
    cursor_word_left,
    cursor_word_right,
    cursor_line_start,
    cursor_line_end,
    cursor_doc_start,
    cursor_doc_end,
    cursor_page_up,
    cursor_page_down,
    // Selection
    select_left,
    select_right,
    select_up,
    select_down,
    select_word_left,
    select_word_right,
    select_line_start,
    select_line_end,
    select_doc_start,
    select_doc_end,
    select_page_up,
    select_page_down,
};

pub const count = @typeInfo(Action).@"enum".fields.len;

pub const Group = enum {
    files,
    views,
    find,
    editing,
    cursor,
    selection,

    /// The Help tab's heading for it, in the chosen language.
    pub fn title(self: Group) []const u8 {
        return switch (self) {
            inline else => |g| @field(i18n.tr().shortcut_groups, @tagName(g)),
        };
    }
};

/// What the Help tab calls an action, in the chosen language.
pub fn label(action: Action) []const u8 {
    return switch (action) {
        inline else => |a| @field(i18n.tr().actions, @tagName(a)),
    };
}

pub const Entry = struct {
    action: Action,
    group: Group,
    /// What it's bound to out of the box; null for actions that start
    /// without a shortcut.
    default: ?Chord,
    /// Extra combinations that always work and can't be changed (keypad
    /// keys and the like).
    also: []const Chord = &.{},
};

/// Cmd+key on macOS, Ctrl+key elsewhere.
fn primary(key: rl.KeyboardKey, extra: Mods) Chord {
    var mods = extra;
    if (is_mac) mods.cmd = true else mods.ctrl = true;
    return .{ .key = key, .mods = mods };
}

/// Option+key on macOS, Ctrl+key elsewhere: word-wise editing.
fn word(key: rl.KeyboardKey, extra: Mods) Chord {
    var mods = extra;
    if (is_mac) mods.alt = true else mods.ctrl = true;
    return .{ .key = key, .mods = mods };
}

fn plain(key: rl.KeyboardKey) Chord {
    return .{ .key = key };
}

fn with(key: rl.KeyboardKey, mods: Mods) Chord {
    return .{ .key = key, .mods = mods };
}

const shift: Mods = .{ .shift = true };

pub const entries = [_]Entry{
    // ----------------------------------------------------------- files
    .{ .action = .open, .group = .files, .default = primary(.o, .{}) },
    .{ .action = .open_folder, .group = .files, .default = primary(.o, shift) },
    .{ .action = .new_file, .group = .files, .default = primary(.n, .{}) },
    .{ .action = .save, .group = .files, .default = primary(.s, .{}) },
    .{ .action = .save_as, .group = .files, .default = primary(.s, shift) },
    .{ .action = .close_folder, .group = .files, .default = primary(.k, .{}) },
    .{ .action = .open_settings, .group = .files, .default = primary(.comma, .{}) },
    .{ .action = .open_help, .group = .files, .default = null },
    .{ .action = .quick_open, .group = .files, .default = primary(.p, .{}) },
    // ----------------------------------------------------- tabs and views
    .{ .action = .close_tab, .group = .views, .default = primary(.w, .{}) },
    .{
        .action = .next_tab,
        .group = .views,
        .default = with(.tab, .{ .ctrl = true }),
        .also = &.{ with(.tab, .{ .alt = true }), primary(.right_bracket, shift) },
    },
    .{
        .action = .prev_tab,
        .group = .views,
        .default = with(.tab, .{ .ctrl = true, .shift = true }),
        .also = &.{ with(.tab, .{ .alt = true, .shift = true }), primary(.left_bracket, shift) },
    },
    .{ .action = .toggle_sidebar, .group = .views, .default = primary(.b, .{}) },
    .{
        .action = .toggle_terminal,
        .group = .views,
        .default = primary(.t, .{}),
        .also = &.{ primary(.j, .{}), with(.grave, .{ .ctrl = true }) },
    },
    .{ .action = .show_explorer, .group = .views, .default = primary(.e, shift) },
    .{ .action = .show_search, .group = .views, .default = primary(.f, shift) },
    .{ .action = .show_git, .group = .views, .default = primary(.g, .{}) },
    .{ .action = .toggle_word_wrap, .group = .views, .default = with(.z, .{ .alt = true }) },
    .{
        .action = .zoom_in,
        .group = .views,
        .default = primary(.equal, .{}),
        .also = &.{ primary(.equal, shift), primary(.kp_add, .{}) },
    },
    .{ .action = .zoom_out, .group = .views, .default = primary(.minus, .{}), .also = &.{primary(.kp_subtract, .{})} },
    .{ .action = .zoom_reset, .group = .views, .default = primary(.zero, .{}), .also = &.{primary(.kp_0, .{})} },
    // ------------------------------------------------------------- find
    .{ .action = .find, .group = .find, .default = primary(.f, .{}) },
    .{
        .action = .find_replace,
        .group = .find,
        .default = if (is_mac) with(.f, .{ .cmd = true, .alt = true }) else with(.h, .{ .ctrl = true }),
    },
    .{ .action = .find_next, .group = .find, .default = plain(.f3) },
    .{ .action = .find_prev, .group = .find, .default = with(.f3, shift) },
    .{
        .action = .toggle_match_case,
        .group = .find,
        .default = if (is_mac) with(.c, .{ .cmd = true, .alt = true }) else with(.c, .{ .alt = true }),
    },
    .{
        .action = .toggle_whole_word,
        .group = .find,
        .default = if (is_mac) with(.w, .{ .cmd = true, .alt = true }) else with(.w, .{ .alt = true }),
    },
    // ---------------------------------------------------------- editing
    .{ .action = .copy, .group = .editing, .default = primary(.c, .{}) },
    .{ .action = .cut, .group = .editing, .default = primary(.x, .{}) },
    .{ .action = .paste, .group = .editing, .default = primary(.v, .{}) },
    .{ .action = .undo, .group = .editing, .default = primary(.z, .{}) },
    .{
        .action = .redo,
        .group = .editing,
        .default = primary(.z, shift),
        .also = if (is_mac) &.{} else &.{with(.y, .{ .ctrl = true })},
    },
    .{ .action = .select_all, .group = .editing, .default = primary(.a, .{}) },
    .{ .action = .clear_selection, .group = .editing, .default = plain(.escape) },
    .{ .action = .complete, .group = .editing, .default = with(.space, .{ .ctrl = true }) },
    .{ .action = .indent, .group = .editing, .default = plain(.tab), .also = &.{with(.tab, shift)} },
    .{
        .action = .newline,
        .group = .editing,
        .default = plain(.enter),
        .also = &.{ with(.enter, shift), primary(.enter, .{}), plain(.kp_enter), with(.kp_enter, shift) },
    },
    .{ .action = .backspace, .group = .editing, .default = plain(.backspace), .also = &.{with(.backspace, shift)} },
    .{ .action = .delete_forward, .group = .editing, .default = plain(.delete), .also = &.{with(.delete, shift)} },
    .{ .action = .delete_word_left, .group = .editing, .default = word(.backspace, .{}) },
    .{ .action = .delete_word_right, .group = .editing, .default = word(.delete, .{}) },
    .{
        .action = .delete_line_start,
        .group = .editing,
        .default = if (is_mac) with(.backspace, .{ .cmd = true }) else with(.backspace, .{ .ctrl = true, .shift = true }),
    },
    .{
        .action = .delete_line_end,
        .group = .editing,
        .default = if (is_mac) with(.delete, .{ .cmd = true }) else with(.delete, .{ .ctrl = true, .shift = true }),
    },
    .{ .action = .move_line_up, .group = .editing, .default = with(.up, .{ .alt = true }) },
    .{ .action = .move_line_down, .group = .editing, .default = with(.down, .{ .alt = true }) },
    .{ .action = .expand_selection, .group = .editing, .default = with(.up, .{ .alt = true, .shift = true }) },
    .{ .action = .shrink_selection, .group = .editing, .default = with(.down, .{ .alt = true, .shift = true }) },
    // ----------------------------------------------------------- cursor
    .{ .action = .cursor_left, .group = .cursor, .default = plain(.left) },
    .{ .action = .cursor_right, .group = .cursor, .default = plain(.right) },
    .{ .action = .cursor_up, .group = .cursor, .default = plain(.up) },
    .{ .action = .cursor_down, .group = .cursor, .default = plain(.down) },
    .{ .action = .cursor_word_left, .group = .cursor, .default = word(.left, .{}) },
    .{ .action = .cursor_word_right, .group = .cursor, .default = word(.right, .{}) },
    .{
        .action = .cursor_line_start,
        .group = .cursor,
        .default = if (is_mac) with(.left, .{ .cmd = true }) else plain(.home),
        .also = if (is_mac) &.{plain(.home)} else &.{},
    },
    .{
        .action = .cursor_line_end,
        .group = .cursor,
        .default = if (is_mac) with(.right, .{ .cmd = true }) else plain(.end),
        .also = if (is_mac) &.{plain(.end)} else &.{},
    },
    .{ .action = .cursor_doc_start, .group = .cursor, .default = primary(.up, .{}), .also = &.{primary(.home, .{})} },
    .{ .action = .cursor_doc_end, .group = .cursor, .default = primary(.down, .{}), .also = &.{primary(.end, .{})} },
    .{ .action = .cursor_page_up, .group = .cursor, .default = plain(.page_up) },
    .{ .action = .cursor_page_down, .group = .cursor, .default = plain(.page_down) },
    // -------------------------------------------------------- selection
    .{ .action = .select_left, .group = .selection, .default = with(.left, shift) },
    .{ .action = .select_right, .group = .selection, .default = with(.right, shift) },
    .{ .action = .select_up, .group = .selection, .default = with(.up, shift) },
    .{ .action = .select_down, .group = .selection, .default = with(.down, shift) },
    .{ .action = .select_word_left, .group = .selection, .default = word(.left, shift) },
    .{ .action = .select_word_right, .group = .selection, .default = word(.right, shift) },
    .{
        .action = .select_line_start,
        .group = .selection,
        .default = if (is_mac) with(.left, .{ .cmd = true, .shift = true }) else with(.home, shift),
        .also = if (is_mac) &.{with(.home, shift)} else &.{},
    },
    .{
        .action = .select_line_end,
        .group = .selection,
        .default = if (is_mac) with(.right, .{ .cmd = true, .shift = true }) else with(.end, shift),
        .also = if (is_mac) &.{with(.end, shift)} else &.{},
    },
    .{ .action = .select_doc_start, .group = .selection, .default = primary(.up, shift), .also = &.{primary(.home, shift)} },
    .{ .action = .select_doc_end, .group = .selection, .default = primary(.down, shift), .also = &.{primary(.end, shift)} },
    .{ .action = .select_page_up, .group = .selection, .default = with(.page_up, shift) },
    .{ .action = .select_page_down, .group = .selection, .default = with(.page_down, shift) },
};

comptime {
    // Every action is listed exactly once, so the Help tab shows them all.
    var seen = [_]bool{false} ** count;
    for (entries) |e| {
        if (seen[@intFromEnum(e.action)]) @compileError("duplicate entry: " ++ @tagName(e.action));
        seen[@intFromEnum(e.action)] = true;
    }
    for (seen, 0..) |s, i| {
        if (!s) @compileError("action missing from entries: " ++ @tagName(@as(Action, @enumFromInt(i))));
    }
}

/// Where `action` sits in `entries`.
pub fn indexOf(action: Action) usize {
    const table = comptime blk: {
        var t: [count]usize = undefined;
        for (entries, 0..) |e, i| t[@intFromEnum(e.action)] = i;
        break :blk t;
    };
    return table[@intFromEnum(action)];
}

pub fn entryFor(action: Action) Entry {
    return entries[indexOf(action)];
}

/// The command an action runs. Movements come in a plain and a selecting
/// version of the same motion.
pub fn command(action: Action) core.Command {
    return switch (action) {
        .open => .open,
        .open_folder => .open_folder,
        .new_file => .new_file,
        .save => .save,
        .save_as => .save_as,
        .close_folder => .close_folder,
        .open_settings => .open_settings,
        .open_help => .open_help,
        .quick_open => .quick_open,
        .close_tab => .close_tab,
        .next_tab => .next_tab,
        .prev_tab => .prev_tab,
        .toggle_sidebar => .toggle_sidebar,
        .toggle_terminal => .toggle_terminal,
        .show_explorer => .show_explorer,
        .show_search => .show_search,
        .show_git => .show_git,
        .toggle_word_wrap => .toggle_word_wrap,
        .zoom_in => .zoom_in,
        .zoom_out => .zoom_out,
        .zoom_reset => .zoom_reset,
        .find => .find,
        .find_replace => .find_replace,
        .find_next => .find_next,
        .find_prev => .find_prev,
        .toggle_match_case => .toggle_match_case,
        .toggle_whole_word => .toggle_whole_word,
        .copy => .copy,
        .cut => .cut,
        .paste => .paste,
        .undo => .undo,
        .redo => .redo,
        .select_all => .select_all,
        .clear_selection => .clear_selection,
        .complete => .complete,
        .indent => .indent,
        .newline => .newline,
        .backspace => .backspace,
        .delete_forward => .delete_forward,
        .delete_word_left => .{ .delete = .word_left },
        .delete_word_right => .{ .delete = .word_right },
        .delete_line_start => .{ .delete = .line_start },
        .delete_line_end => .{ .delete = .line_end },
        .move_line_up => .move_line_up,
        .move_line_down => .move_line_down,
        .expand_selection => .expand_selection,
        .shrink_selection => .shrink_selection,
        .cursor_left => move(.char_left, false),
        .cursor_right => move(.char_right, false),
        .cursor_up => move(.line_up, false),
        .cursor_down => move(.line_down, false),
        .cursor_word_left => move(.word_left, false),
        .cursor_word_right => move(.word_right, false),
        .cursor_line_start => move(.line_start, false),
        .cursor_line_end => move(.line_end, false),
        .cursor_doc_start => move(.doc_start, false),
        .cursor_doc_end => move(.doc_end, false),
        .cursor_page_up => move(.page_up, false),
        .cursor_page_down => move(.page_down, false),
        .select_left => move(.char_left, true),
        .select_right => move(.char_right, true),
        .select_up => move(.line_up, true),
        .select_down => move(.line_down, true),
        .select_word_left => move(.word_left, true),
        .select_word_right => move(.word_right, true),
        .select_line_start => move(.line_start, true),
        .select_line_end => move(.line_end, true),
        .select_doc_start => move(.doc_start, true),
        .select_doc_end => move(.doc_end, true),
        .select_page_up => move(.page_up, true),
        .select_page_down => move(.page_down, true),
    };
}

fn move(motion: core.Motion, extend: bool) core.Command {
    return .{ .move = .{ .motion = motion, .extend = extend } };
}

// ------------------------------------------------------------- the keymap

/// What each action is bound to now; null means the user cleared it.
bound: [count]?Chord,

pub const default: Keymap = blk: {
    var km: Keymap = .{ .bound = undefined };
    for (entries) |e| km.bound[@intFromEnum(e.action)] = e.default;
    break :blk km;
};

pub fn chordFor(self: *const Keymap, action: Action) ?Chord {
    return self.bound[@intFromEnum(action)];
}

pub fn isDefault(self: *const Keymap, action: Action) bool {
    const now = self.chordFor(action);
    const original = entryFor(action).default;
    if (now == null or original == null) return (now == null) == (original == null);
    return now.?.eql(original.?);
}

/// The action `chord` is bound to, if any (ignoring `action` itself).
pub fn conflict(self: *const Keymap, chord: Chord, action: Action) ?Action {
    for (self.bound, 0..) |b, i| {
        const other: Action = @enumFromInt(i);
        if (other == action) continue;
        if (b) |c| if (c.eql(chord)) return other;
    }
    return null;
}

/// Binds `chord` to `action`, taking it away from whatever had it.
pub fn set(self: *Keymap, action: Action, chord: ?Chord) void {
    if (chord) |c| {
        for (&self.bound, 0..) |*b, i| {
            if (i == @intFromEnum(action)) continue;
            if (b.*) |other| if (other.eql(c)) {
                b.* = null;
            };
        }
    }
    self.bound[@intFromEnum(action)] = chord;
}

pub fn reset(self: *Keymap, action: Action) void {
    self.set(action, entryFor(action).default);
}

pub fn resetAll(self: *Keymap) void {
    self.* = default;
}

/// The combination of `action` held down right now, if any: the bound one
/// or one of its fixed extras. Key handling uses which one fired to tell a
/// shortcut apart from typing.
pub fn pressedChord(self: *const Keymap, action: Action) ?Chord {
    if (self.chordFor(action)) |c| {
        if (c.pressed()) return c;
    }
    for (entryFor(action).also) |c| {
        if (c.pressed()) return c;
    }
    return null;
}

// ---------------------------------------------------------------- storage

/// Reads keybindings.json. Anything missing, unknown or unparsable keeps
/// its default, so a hand-edited file can't leave the editor unusable.
pub fn load(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) Keymap {
    var km = default;
    const bytes = dir.readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch return km;
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return km;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |o| o,
        else => return km,
    };
    var it = object.iterator();
    while (it.next()) |field| {
        const action = std.meta.stringToEnum(Action, field.key_ptr.*) orelse continue;
        switch (field.value_ptr.*) {
            .null => km.bound[@intFromEnum(action)] = null,
            .string => |s| if (Chord.parse(s)) |c| {
                if (!c.typesText()) km.bound[@intFromEnum(action)] = c;
            },
            else => {},
        }
    }
    return km;
}

/// Writes the combinations that differ from the defaults; an empty file
/// (well, `{}`) means everything is stock.
pub fn save(self: *const Keymap, gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (entries) |e| {
        if (self.isDefault(e.action)) continue;
        try out.appendSlice(gpa, if (out.items.len == 0) "{\n" else ",\n");
        var buf: [48]u8 = undefined;
        if (self.chordFor(e.action)) |c| {
            try out.print(gpa, "  \"{s}\": \"{s}\"", .{ @tagName(e.action), c.write(&buf) });
        } else {
            try out.print(gpa, "  \"{s}\": null", .{@tagName(e.action)});
        }
    }
    try out.appendSlice(gpa, if (out.items.len == 0) "{}\n" else "\n}\n");

    if (std.fs.path.dirname(path)) |d| try dir.createDirPath(io, d);
    var file = try dir.createFileAtomic(io, path, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, out.items);
    try file.replace(io);
}

// -------------------------------------------------------------- key names

const NamedKey = struct { key: rl.KeyboardKey, name: []const u8 };

/// Keys that can be bound, with the name shown and stored for each.
pub const named_keys = [_]NamedKey{
    .{ .key = .a, .name = "A" },      .{ .key = .b, .name = "B" },
    .{ .key = .c, .name = "C" },      .{ .key = .d, .name = "D" },
    .{ .key = .e, .name = "E" },      .{ .key = .f, .name = "F" },
    .{ .key = .g, .name = "G" },      .{ .key = .h, .name = "H" },
    .{ .key = .i, .name = "I" },      .{ .key = .j, .name = "J" },
    .{ .key = .k, .name = "K" },      .{ .key = .l, .name = "L" },
    .{ .key = .m, .name = "M" },      .{ .key = .n, .name = "N" },
    .{ .key = .o, .name = "O" },      .{ .key = .p, .name = "P" },
    .{ .key = .q, .name = "Q" },      .{ .key = .r, .name = "R" },
    .{ .key = .s, .name = "S" },      .{ .key = .t, .name = "T" },
    .{ .key = .u, .name = "U" },      .{ .key = .v, .name = "V" },
    .{ .key = .w, .name = "W" },      .{ .key = .x, .name = "X" },
    .{ .key = .y, .name = "Y" },      .{ .key = .z, .name = "Z" },
    .{ .key = .zero, .name = "0" },   .{ .key = .one, .name = "1" },
    .{ .key = .two, .name = "2" },    .{ .key = .three, .name = "3" },
    .{ .key = .four, .name = "4" },   .{ .key = .five, .name = "5" },
    .{ .key = .six, .name = "6" },    .{ .key = .seven, .name = "7" },
    .{ .key = .eight, .name = "8" },  .{ .key = .nine, .name = "9" },
    .{ .key = .f1, .name = "F1" },    .{ .key = .f2, .name = "F2" },
    .{ .key = .f3, .name = "F3" },    .{ .key = .f4, .name = "F4" },
    .{ .key = .f5, .name = "F5" },    .{ .key = .f6, .name = "F6" },
    .{ .key = .f7, .name = "F7" },    .{ .key = .f8, .name = "F8" },
    .{ .key = .f9, .name = "F9" },    .{ .key = .f10, .name = "F10" },
    .{ .key = .f11, .name = "F11" },  .{ .key = .f12, .name = "F12" },
    .{ .key = .left, .name = "Left" },
    .{ .key = .right, .name = "Right" },
    .{ .key = .up, .name = "Up" },
    .{ .key = .down, .name = "Down" },
    .{ .key = .home, .name = "Home" },
    .{ .key = .end, .name = "End" },
    .{ .key = .page_up, .name = "PageUp" },
    .{ .key = .page_down, .name = "PageDown" },
    .{ .key = .tab, .name = "Tab" },
    .{ .key = .enter, .name = "Enter" },
    .{ .key = .escape, .name = "Esc" },
    .{ .key = .backspace, .name = "Backspace" },
    .{ .key = .delete, .name = "Delete" },
    .{ .key = .insert, .name = "Insert" },
    .{ .key = .space, .name = "Space" },
    .{ .key = .comma, .name = "," },
    .{ .key = .period, .name = "." },
    .{ .key = .slash, .name = "/" },
    .{ .key = .semicolon, .name = ";" },
    .{ .key = .minus, .name = "-" },
    .{ .key = .equal, .name = "=" },
    .{ .key = .left_bracket, .name = "[" },
    .{ .key = .right_bracket, .name = "]" },
    // Named rather than written out, so the file needs no JSON escaping.
    .{ .key = .backslash, .name = "Backslash" },
    .{ .key = .apostrophe, .name = "Quote" },
    .{ .key = .grave, .name = "Backtick" },
    .{ .key = .kp_0, .name = "Num0" },
    .{ .key = .kp_1, .name = "Num1" },
    .{ .key = .kp_2, .name = "Num2" },
    .{ .key = .kp_3, .name = "Num3" },
    .{ .key = .kp_4, .name = "Num4" },
    .{ .key = .kp_5, .name = "Num5" },
    .{ .key = .kp_6, .name = "Num6" },
    .{ .key = .kp_7, .name = "Num7" },
    .{ .key = .kp_8, .name = "Num8" },
    .{ .key = .kp_9, .name = "Num9" },
    .{ .key = .kp_add, .name = "Num+" },
    .{ .key = .kp_subtract, .name = "Num-" },
    .{ .key = .kp_multiply, .name = "Num*" },
    .{ .key = .kp_divide, .name = "Num/" },
    .{ .key = .kp_decimal, .name = "Num." },
    .{ .key = .kp_enter, .name = "NumEnter" },
};

pub fn keyName(key: rl.KeyboardKey) ?[]const u8 {
    for (named_keys) |k| {
        if (k.key == key) return k.name;
    }
    return null;
}

pub fn keyFromName(name: []const u8) ?rl.KeyboardKey {
    for (named_keys) |k| {
        if (eqlIgnoreCase(k.name, name)) return k.key;
    }
    return null;
}

/// Keys that would otherwise type a character.
fn keyTypesText(key: rl.KeyboardKey) bool {
    return switch (key) {
        .space, .apostrophe, .comma, .minus, .period, .slash, .semicolon, .equal,
        .left_bracket, .backslash, .right_bracket, .grave,
        => true,
        else => {
            const v = @intFromEnum(key);
            // Letters and digits.
            return (v >= @intFromEnum(rl.KeyboardKey.a) and v <= @intFromEnum(rl.KeyboardKey.z)) or
                (v >= @intFromEnum(rl.KeyboardKey.zero) and v <= @intFromEnum(rl.KeyboardKey.nine)) or
                (v >= @intFromEnum(rl.KeyboardKey.kp_0) and v <= @intFromEnum(rl.KeyboardKey.kp_equal));
        },
    };
}

/// Modifier keys themselves: pressing one doesn't finish a combination.
pub fn isModifier(key: rl.KeyboardKey) bool {
    return switch (key) {
        .left_shift, .right_shift, .left_control, .right_control, .left_alt, .right_alt, .left_super, .right_super => true,
        else => false,
    };
}

test {
    _ = @import("tests/Keymap_test.zig");
}
