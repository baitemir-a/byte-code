//! The app's own text in each language of `Settings.Language`: one table
//! of `Strings` per language, in lang/<code>.zig. Every field of `Strings`
//! is required, so a language missing a string doesn't compile.
//!
//! Text with values in it is a template: `{1}`, `{2}`... stand for the
//! values in order, and a language may put them in any order (see `fill`).
const std = @import("std");
const core = @import("core");
const Keymap = @import("../input/Keymap.zig");

pub const Language = core.Settings.Language;

pub const Strings = struct {
    /// Words used in several places.
    common: struct {
        reset: []const u8,
        open: []const u8,
        cancel: []const u8,
        ok: []const u8,
        replace: []const u8,
        replace_all: []const u8,
        /// Above the path of settings.json / keybindings.json.
        saved_to: []const u8,
    },
    /// Names of the tabs that aren't files.
    tabs: struct {
        welcome: []const u8,
        settings: []const u8,
        help: []const u8,
    },
    welcome: struct {
        subtitle: []const u8,
        start: []const u8,
        open_file: []const u8,
        open_folder: []const u8,
        new_file: []const u8,
        settings: []const u8,
        shortcuts: []const u8,
        favorites: []const u8,
        recent: []const u8,
        drop_hint: []const u8,
    },
    settings: struct {
        title: []const u8,
        language: []const u8,
        language_hint: []const u8,
        theme: []const u8,
        theme_hint: []const u8,
        dark: []const u8,
        light: []const u8,
        accent: []const u8,
        accent_hint: []const u8,
        autosave: []const u8,
        autosave_hint: []const u8,
        /// "after [−] 1.00 s [+]": the auto-save delay.
        autosave_after: []const u8,
        /// "{1} s": seconds.
        seconds: []const u8,
        zoom: []const u8,
        minimap: []const u8,
        minimap_hint: []const u8,
        word_wrap: []const u8,
        /// {1}: its shortcut.
        word_wrap_hint: []const u8,
        new_window: []const u8,
        new_window_hint: []const u8,
        confirm_discard: []const u8,
        confirm_discard_hint: []const u8,
        shortcuts: []const u8,
        shortcuts_hint: []const u8,
    },
    /// The Help tab: the keyboard shortcuts.
    help: struct {
        title: []const u8,
        hint: []const u8,
        press_keys: []const u8,
        reset_all: []const u8,
        /// Before a shortcut's other combinations: "or Cmd+J".
        @"or": []const u8,
        /// {1}: `modifiers_mac` or `modifiers_other`.
        needs_modifier: []const u8,
        modifiers_mac: []const u8,
        modifiers_other: []const u8,
        /// {1}: the action that lost its shortcut.
        taken_from: []const u8,
    },
    /// Headings of the Help tab's sections.
    shortcut_groups: std.enums.EnumFieldStruct(Keymap.Group, []const u8, null),
    /// Every action a shortcut can run.
    actions: std.enums.EnumFieldStruct(Keymap.Action, []const u8, null),
    sidebar: struct {
        file_name: []const u8,
        folder_name: []const u8,
        new_file: []const u8,
        new_folder: []const u8,
        rename: []const u8,
        delete: []const u8,
    },
    /// The Search view (search in the project).
    search: struct {
        placeholder: []const u8,
        replace_placeholder: []const u8,
        open_folder_first: []const u8,
        no_results: []const u8,
        /// {1}: matches (may end in "+"), {2}: files.
        results: []const u8,
        /// Tooltips of the replace buttons on a file and on a match.
        replace_in_file: []const u8,
        replace_match: []const u8,
    },
    git: struct {
        open_folder_first: []const u8,
        loading: []const u8,
        not_a_repository: []const u8,
        not_installed: []const u8,
        /// {1}: the branch.
        on_branch: []const u8,
        message_placeholder: []const u8,
        /// {1}: how many changes are staged.
        commit_count: []const u8,
        commit: []const u8,
        nothing_staged: []const u8,
        no_changes: []const u8,
        staged_changes: []const u8,
        changes: []const u8,
        /// The list of files a half-done merge left behind.
        conflicts_section: []const u8,
        /// The list of git commands, and what each of them does.
        commands: []const u8,
        push: []const u8,
        pull: []const u8,
        commit_push: []const u8,
        commit_sync: []const u8,
        fetch: []const u8,
        clone: []const u8,
        checkout: []const u8,
        create_branch: []const u8,
        create_branch_from: []const u8,
        stash: []const u8,
        stash_pop: []const u8,
        /// The commit button when there is nothing to commit but the
        /// branch and its remote have drifted apart. {1}: to pull,
        /// {2}: to push.
        sync_count: []const u8,
        /// What the box asks for, for the commands that need it.
        clone_url: []const u8,
        branch_name: []const u8,
        /// {1}: what the new branch starts from.
        branch_from_name: []const u8,
        /// What the counters beside the branch stand for.
        badge_unstaged: []const u8,
        badge_staged: []const u8,
        badge_to_push: []const u8,
        badge_to_pull: []const u8,
        badge_conflicts: []const u8,
        /// What the tab showing a file's changes is called, after the file
        /// name: "App.zig (changes)" and "App.zig (staged)".
        changes_tab: []const u8,
        staged_tab: []const u8,
        /// Before throwing changes away: the question, the line under it,
        /// and the button that goes through with it.
        discard_all_question: []const u8,
        /// {1}: the file's name.
        discard_question: []const u8,
        /// The same for a file git doesn't know, which can only be
        /// thrown away by deleting it.
        delete_question: []const u8,
        delete_detail: []const u8,
        discard_detail: []const u8,
        /// Used instead when new files go with the changes.
        discard_all_detail: []const u8,
        discard: []const u8,
        /// The button that goes ahead and stops asking.
        discard_always: []const u8,
        /// The list of the branch's commits.
        history: []const u8,
        no_commits: []const u8,
        amend: []const u8,
        undo_commit: []const u8,
        abort_merge: []const u8,
        commit_merge: []const u8,
        /// Before rewriting a commit the remote already has.
        amend_pushed_question: []const u8,
        undo_pushed_question: []const u8,
        pushed_detail: []const u8,
        /// Before calling a half-done merge off.
        abort_merge_question: []const u8,
        abort_merge_detail: []const u8,
        /// Marking a file resolved while it still has markers. {1}: its name.
        still_conflicted_question: []const u8,
        still_conflicted_detail: []const u8,
        mark_resolved: []const u8,
        /// The buttons over a conflict in the editor.
        accept_current: []const u8,
        accept_incoming: []const u8,
        accept_both: []const u8,
        /// Above git's own question ("Password for ...").
        credentials_title: []const u8,
    },
    /// The bar along the bottom: what git says about the line the cursor
    /// is on, and where the cursor is.
    status: struct {
        /// {1}: how many of them ago.
        just_now: []const u8,
        minutes: []const u8,
        hours: []const u8,
        days: []const u8,
        months: []const u8,
        years: []const u8,
        /// A line that isn't in any commit yet.
        uncommitted: []const u8,
        /// {1}: the line, {2}: the column.
        line_column: []const u8,
    },
    /// The find bar in the editor.
    find: struct {
        placeholder: []const u8,
        replace_placeholder: []const u8,
        no_results: []const u8,
        /// {1}: which match, {2}: how many.
        n_of_m: []const u8,
        /// {1}: how many.
        found: []const u8,
        /// {1}: its shortcut.
        replace_tooltip: []const u8,
        match_case_tooltip: []const u8,
        whole_word_tooltip: []const u8,
    },
    /// Go to File.
    quick_open: struct {
        placeholder: []const u8,
        open_folder_first: []const u8,
        no_matches: []const u8,
    },
    /// The terminal panel's header. (What the terminal itself prints stays
    /// in English: its screen can't lay out wide characters yet.)
    terminal: struct {
        title: []const u8,
    },
    /// The Ctrl+click menu of places a name is used.
    refs: struct {
        /// {1}: how many.
        all_uses: []const u8,
        /// {1}: the line number.
        line: []const u8,
    },
    /// Titles of error messages: "Couldn't ...".
    errors: struct {
        open_file: []const u8,
        open_folder: []const u8,
        save_file: []const u8,
        save_projects: []const u8,
        save_shortcuts: []const u8,
        save_settings: []const u8,
        autosave_failed: []const u8,
        new_window: []const u8,
        list_files: []const u8,
        replace_in_file: []const u8,
        create_file: []const u8,
        create_folder: []const u8,
        rename: []const u8,
        move: []const u8,
        delete: []const u8,
        git_failed: []const u8,
        nothing_to_commit: []const u8,
        nothing_to_commit_detail: []const u8,
        message_needed: []const u8,
        message_needed_detail: []const u8,
    },
    /// Why something failed, under an error's title.
    reasons: struct {
        not_utf8: []const u8,
        too_big: []const u8,
        permission_denied: []const u8,
        is_dir: []const u8,
        not_found: []const u8,
        disk_full: []const u8,
        already_exists: []const u8,
        invalid_name: []const u8,
    },
    /// The system's dialogs.
    dialogs: struct {
        open: []const u8,
        open_folder: []const u8,
        save_as: []const u8,
        /// {1}: the file's name.
        save_changes: []const u8,
        save: []const u8,
        dont_save: []const u8,
        /// {1}: the file or folder's name.
        delete_question: []const u8,
        delete_folder_detail: []const u8,
        delete_file_detail: []const u8,
        move_to_trash: []const u8,
        cant_trash_detail: []const u8,
        delete_permanently: []const u8,
        /// {1}: matches (may end in "+"), {2}: files.
        replace_question: []const u8,
        replace_detail: []const u8,
    },
};

const tables = std.enums.EnumArray(Language, *const Strings).init(.{
    .en = &@import("lang/en.zig").strings,
    .ru = &@import("lang/ru.zig").strings,
    .de = &@import("lang/de.zig").strings,
    .ky = &@import("lang/ky.zig").strings,
    .tr = &@import("lang/tr.zig").strings,
    .es = &@import("lang/es.zig").strings,
    .zh = &@import("lang/zh.zig").strings,
    .ja = &@import("lang/ja.zig").strings,
    .fr = &@import("lang/fr.zig").strings,
    .it = &@import("lang/it.zig").strings,
    .pt = &@import("lang/pt.zig").strings,
    .ko = &@import("lang/ko.zig").strings,
});

var current_language: Language = .en;
var current: *const Strings = tables.get(.en);

/// The text in the language chosen in Settings.
pub fn tr() *const Strings {
    return current;
}

pub fn language() Language {
    return current_language;
}

pub fn setLanguage(lang: Language) void {
    current_language = lang;
    current = tables.get(lang);
}

pub fn stringsFor(lang: Language) *const Strings {
    return tables.get(lang);
}

/// Every string of `s`, for going through all the text of a language
/// (e.g. collecting the characters its font needs).
pub fn forEachString(s: *const Strings, context: anytype, comptime f: fn (@TypeOf(context), []const u8) void) void {
    inline for (@typeInfo(Strings).@"struct".fields) |group| {
        const g = &@field(s, group.name);
        inline for (@typeInfo(@TypeOf(g.*)).@"struct".fields) |field| f(context, @field(g, field.name));
    }
}

/// Fills in a template: `{1}` is the first of `args`, `{2}` the second...
/// Numbers are written in decimal, strings as they are. The result is cut
/// short if `buf` is too small.
pub fn fill(buf: []u8, template: []const u8, args: anytype) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var i: usize = 0;
    while (i < template.len) {
        if (placeholder(template, i)) |n| {
            inline for (args, 0..) |arg, k| {
                if (k == n) writeArg(&w, arg) catch return w.buffered();
            }
            i += 3;
            continue;
        }
        w.writeByte(template[i]) catch break;
        i += 1;
    }
    return w.buffered();
}

/// Like `fill`, into memory the caller frees.
pub fn fillAlloc(gpa: std.mem.Allocator, template: []const u8, args: anytype) std.mem.Allocator.Error![]u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();
    var i: usize = 0;
    // The writer only fails when it can't grow.
    while (i < template.len) {
        if (placeholder(template, i)) |n| {
            inline for (args, 0..) |arg, k| {
                if (k == n) writeArg(&w.writer, arg) catch return error.OutOfMemory;
            }
            i += 3;
            continue;
        }
        w.writer.writeByte(template[i]) catch return error.OutOfMemory;
        i += 1;
    }
    return w.toOwnedSlice();
}

/// The value index of a `{1}`...`{9}` at `i`.
fn placeholder(template: []const u8, i: usize) ?usize {
    if (i + 2 >= template.len or template[i] != '{' or template[i + 2] != '}') return null;
    const d = template[i + 1];
    return if (d >= '1' and d <= '9') d - '1' else null;
}

fn writeArg(w: *std.Io.Writer, arg: anytype) !void {
    switch (@typeInfo(@TypeOf(arg))) {
        .int, .comptime_int => try w.print("{d}", .{arg}),
        else => try w.writeAll(arg),
    }
}

test "fill" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("3 of 7", fill(&buf, "{1} of {2}", .{ 3, 7 }));
    try std.testing.expectEqualStrings("7中3", fill(&buf, "{2}中{1}", .{ 3, 7 }));
    try std.testing.expectEqualStrings("On main", fill(&buf, "On {1}", .{"main"}));
    try std.testing.expectEqualStrings("{x} {}", fill(&buf, "{x} {}", .{}));
    var small: [4]u8 = undefined;
    try std.testing.expectEqualStrings("1234", fill(&small, "{1}", .{123456}));
}

/// The `{n}` placeholders in `s`, as a bit set.
fn placeholders(s: []const u8) u9 {
    var set: u9 = 0;
    for (0..s.len) |i| if (placeholder(s, i)) |n| {
        set |= @as(u9, 1) << @intCast(n);
    };
    return set;
}

test "every language has every string, with the same placeholders as English" {
    const en = stringsFor(.en);
    for (std.enums.values(Language)) |lang| {
        const s = stringsFor(lang);
        inline for (@typeInfo(Strings).@"struct".fields) |group| {
            inline for (@typeInfo(@FieldType(Strings, group.name)).@"struct".fields) |field| {
                const want = @field(@field(en, group.name), field.name);
                const got = @field(@field(s, group.name), field.name);
                if (got.len == 0 or placeholders(want) != placeholders(got)) {
                    std.debug.print("{s}: {s}.{s} = \"{s}\"\n", .{ @tagName(lang), group.name, field.name, got });
                    return error.TestUnexpectedResult;
                }
                try std.testing.expect(std.unicode.utf8ValidateSlice(got));
            }
        }
    }
}
