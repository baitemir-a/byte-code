//! Ctrl+click (Cmd+click on macOS) on a name in the text: go to where it
//! is declared, or, clicking the declaration itself, list where it is
//! used. Without a language server the declaration is recognised by the
//! shape of its line (see core/search/lib/symbols.zig), and the uses come
//! from a whole-word search of the project — the same search the sidebar's
//! Search view shows, so the whole list is one click away.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const ContextMenu = @import("../../ui/sidebar/ContextMenu.zig");
const App = @import("../App.zig");

/// Uses kept for the menu; far more than it can list, but "All uses"
/// hands the rest to the Search view anyway.
const max_refs = 500;
/// Whole word, and case as typed: what a name means.
const symbol_options: core.find.Options = .{ .match_case = true, .whole_word = true };

/// Ctrl+click in the text. Returns false when there is no name under the
/// mouse, so the click can go on to place the cursor as usual.
pub fn symbolClick(self: *App, point: rl.Vector2) !bool {
    const buf = self.buf();
    const word = core.motion.wordRange(buf.items(), self.view.posAt(buf, point));
    const name = buf.items()[word.start..word.end];
    if (!core.symbols.isName(name)) return false;

    // Select it, so it's plain which name was clicked.
    buf.moveTo(word.start, false);
    buf.moveTo(word.end, true);
    self.reveal_cursor = true;
    self.completion.close();
    self.find.focus = .editor;

    const line_start = buf.lineStart(word.start);
    const line = buf.items()[line_start..buf.lineEnd(word.start)];
    const on_declaration = core.symbols.isDeclaration(line, word.start - line_start, word.end - line_start);

    try findUses(self, name);
    // From a use, go straight to the declaration; from the declaration
    // (or with none to be found), show where the name is used.
    if (!on_declaration) if (declaration(self, name)) |ref| {
        try self.openRef(ref);
        return true;
    };
    openRefsMenu(self, point);
    return true;
}

/// Opens the file a use is in (if it isn't the current one) and selects it.
pub fn openRef(self: *App, ref: App.Ref) !void {
    if (ref.file) |f| {
        const project = if (self.project) |*p| p else return;
        const files = self.search_panel.results.files.items;
        if (f >= files.len) return; // the search was re-run under us
        const path = try std.fs.path.join(self.gpa, &.{ project.root().path, files[f].path });
        defer self.gpa.free(path);
        self.openFile(path) catch |err| return self.reportError("Couldn't open file", path, err);
    }
    const buf = self.buf();
    if (ref.end > buf.items().len) return; // the file changed since the search
    buf.moveTo(ref.start, false);
    buf.moveTo(ref.end, true);
    self.reveal_cursor = true;
}

/// The menu's last row: every use, in the sidebar's Search view.
pub fn showRefsInSearch(self: *App) void {
    self.showView(.search);
    self.side_focus = .none;
}

/// Searches the project for the name as a whole word and keeps the
/// matches as `refs`. The Search view holds the same results, ready for
/// "All uses". Without a project folder the current file is searched
/// instead.
fn findUses(self: *App, name: []const u8) !void {
    self.refs.clearRetainingCapacity();
    self.ref_name.clearRetainingCapacity();
    try self.ref_name.appendSlice(self.gpa, name);
    const name_owned = self.ref_name.items;

    if (self.project) |_| {
        const panel = &self.search_panel;
        try panel.query.setText(name_owned);
        panel.options = symbol_options;
        try self.runSearch(.top);
        for (panel.results.matches.items) |m| {
            if (self.refs.items.len >= max_refs) break;
            try self.refs.append(self.gpa, .{ .file = m.file, .line = m.line, .start = m.start, .end = m.end });
        }
    }
    // No project folder, or a file outside it: the file being edited is
    // all there is to go on.
    if (self.refs.items.len == 0) try findUsesInFile(self, name_owned);
}

/// No project folder: the uses are the ones in the file being edited.
fn findUsesInFile(self: *App, name: []const u8) !void {
    const items = self.buf().items();
    var pos: usize = 0;
    var line: u32 = 0;
    var counted: usize = 0;
    while (core.find.next(items, pos, name, symbol_options)) |at| {
        line += @intCast(std.mem.count(u8, items[counted..at], "\n"));
        counted = at;
        if (self.refs.items.len >= max_refs) break;
        try self.refs.append(self.gpa, .{ .file = null, .line = line, .start = at, .end = at + name.len });
        pos = at + name.len;
    }
}

/// The first use that reads like the name's declaration, preferring one
/// in the file being edited over one elsewhere in the project.
fn declaration(self: *App, name: []const u8) ?App.Ref {
    if (declarationInFile(self, name)) |ref| return ref;
    const matches = self.search_panel.results.matches.items;
    for (self.refs.items, 0..) |ref, i| {
        if (ref.file == null or i >= matches.len) break;
        const m = matches[i];
        if (core.symbols.isDeclaration(m.preview, m.preview_start, m.preview_end)) return ref;
    }
    return null;
}

/// Where the current file declares the name, if it does.
fn declarationInFile(self: *App, name: []const u8) ?App.Ref {
    const buf = self.buf();
    const items = buf.items();
    var pos: usize = 0;
    while (core.find.next(items, pos, name, symbol_options)) |at| {
        const start = buf.lineStart(at);
        const line = items[start..buf.lineEnd(at)];
        if (core.symbols.isDeclaration(line, at - start, at + name.len - start)) {
            return .{ .file = null, .line = @intCast(buf.lineIndex(at)), .start = at, .end = at + name.len };
        }
        pos = at + name.len;
    }
    return null;
}

/// Lists the uses at the mouse: as many as the menu holds, and a last row
/// for all of them in the Search view when there are more.
fn openRefsMenu(self: *App, at: rl.Vector2) void {
    if (self.refs.items.len == 0) return;
    const all = self.refs.items.len > ContextMenu.max_items;
    const shown = @min(self.refs.items.len, ContextMenu.max_items - @as(usize, if (all) 1 else 0));

    // Roomy: a long path is cut down by the menu, which keeps its end.
    var rows: [ContextMenu.max_items][256]u8 = undefined;
    var labels: [ContextMenu.max_items][]const u8 = undefined;
    for (self.refs.items[0..shown], 0..) |ref, i| {
        self.menu_actions[i] = .{ .go_to_ref = @intCast(i) };
        labels[i] = refLabel(self, ref, &rows[i]);
    }
    if (all) {
        self.menu_actions[shown] = .all_refs;
        labels[shown] = std.fmt.bufPrint(&rows[shown], "All {d} uses...", .{self.refs.items.len}) catch "All uses...";
    }
    self.menu_node = null;
    self.menu.open(labels[0 .. shown + @as(usize, if (all) 1 else 0)], at, App.windowSize(), self.view.font);
}

/// "src/app/App.zig:214", or "line 214" for a place in the current file.
fn refLabel(self: *App, ref: App.Ref, out: []u8) []const u8 {
    const file = ref.file orelse return std.fmt.bufPrint(out, "line {d}", .{ref.line + 1}) catch "this file";
    const files = self.search_panel.results.files.items;
    if (file >= files.len) return "?";
    return std.fmt.bufPrint(out, "{s}:{d}", .{ files[file].path, ref.line + 1 }) catch files[file].path;
}
