//! Language servers in the editor: one is started for a file's language
//! and project the first time a file of it shows (zls, gopls,
//! rust-analyzer, pyright, clangd, or the editor's own for JS/TS; see
//! core/lsp/servers.zig). Once typing pauses the server gets the text,
//! and what it finds wrong replaces the one-off parser runs. On top of
//! that: what's under the mouse (hover), its suggestions in the
//! completion list, Rename Symbol (F2) and Quick Fix (Cmd+.).
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const App = @import("../App.zig");
const Tab = @import("../Tab.zig");
const theme = @import("../../ui/theme/lib/theme.zig");
const ContextMenu = @import("../../ui/sidebar/ContextMenu.zig");
const problems = @import("problems.zig");
const symbol_nav = @import("symbol_nav.zig");
const palette = @import("palette.zig");
const i18n = @import("../../i18n/i18n.zig");

const lsp = core.lsp;
const Client = lsp.Client;
const Value = std.json.Value;

/// How long typing pauses before the server gets the text, and the
/// mouse rests on a name before it's asked about it.
const sync_after = 0.3;
const hover_after = 0.5;

const Pending = struct {
    client: *Client,
    id: i64,
    what: union(enum) {
        hover: Key,
        definition: struct { word: core.Buffer.Range, version: u64, point: rl.Vector2 },
        completion: struct { word_start: usize, version: u64, explicit: bool },
        resolve_completion: struct { word: lsp.protocol.Position },
        rename,
        code_action,
        resolve,
    },
};

/// What the mouse rests on: a stretch of one tab's text as it is now.
const Key = struct { start: usize, end: usize, version: u64 };

const Hover = struct {
    key: ?Key = null,
    since: f64 = 0,
    asked: bool = false,
    /// Where the stretch starts on screen, to put the box by it.
    anchor: rl.Vector2 = .{ .x = 0, .y = 0 },
    problem: std.ArrayList(u8) = .empty,
    text: std.ArrayList(u8) = .empty,
};

/// Finding where programs are, on a thread (it asks the login shell).
const PathJob = struct {
    arena: std.heap.ArenaAllocator,
    environ: ?*const std.process.Environ.Map,
    result: []const u8 = "",
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),

    fn run(job: *PathJob, io: std.Io) void {
        defer job.done.store(true, .release);
        job.result = core.Diagnostics.checkers.searchPath(job.arena.allocator(), io, job.environ);
    }
};

pub const State = struct {
    /// The servers running, by what they are and the folder they serve.
    clients: std.ArrayList(struct { key: []u8, client: *Client }) = .empty,
    /// "language|folder" to the server for it, or null when none is
    /// installed (so it isn't looked for again every frame).
    resolved: std.StringHashMapUnmanaged(?*Client) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    /// What came in this frame lives here until the next.
    frame: std.heap.ArenaAllocator,
    /// The problems each server last reported for a file (as JSON), to
    /// give back when asking for fixes.
    diagnostics: std.StringHashMapUnmanaged([]u8) = .empty,
    hover: Hover = .{},
    /// The quick fixes offered in the menu, and the server they're from.
    actions_arena: std.heap.ArenaAllocator,
    actions: []lsp.results.Action = &.{},
    actions_client: ?*Client = null,
    /// A suggestions list the server said was cut short: ask again as
    /// the word grows.
    incomplete: bool = false,
    path_job: ?*PathJob = null,

    pub fn init(gpa: std.mem.Allocator) State {
        return .{ .frame = .init(gpa), .actions_arena = .init(gpa) };
    }

    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        if (self.path_job) |job| {
            job.thread.join();
            job.arena.deinit();
            gpa.destroy(job);
        }
        for (self.clients.items) |e| {
            e.client.destroy();
            gpa.free(e.key);
        }
        self.clients.deinit(gpa);
        var keys = self.resolved.keyIterator();
        while (keys.next()) |k| gpa.free(k.*);
        self.resolved.deinit(gpa);
        var it = self.diagnostics.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        self.diagnostics.deinit(gpa);
        self.pending.deinit(gpa);
        self.hover.problem.deinit(gpa);
        self.hover.text.deinit(gpa);
        self.frame.deinit();
        self.actions_arena.deinit();
    }
};

// ---------------------------------------------------------------- servers

/// Where programs are: known once the login shell was asked (here or by
/// the parser runs).
fn searchPath(self: *App) ?[]const u8 {
    if (self.tool_path) |p| return p;
    const s = &self.lsp;
    if (s.path_job) |job| {
        if (!job.done.load(.acquire)) return null;
        job.thread.join();
        self.tool_path = self.gpa.dupe(u8, job.result) catch null;
        job.arena.deinit();
        self.gpa.destroy(job);
        s.path_job = null;
        return self.tool_path;
    }
    const job = self.gpa.create(PathJob) catch return null;
    job.* = .{ .arena = .init(self.gpa), .environ = self.environ };
    job.thread = std.Thread.spawn(.{}, PathJob.run, .{ job, self.io }) catch {
        job.arena.deinit();
        self.gpa.destroy(job);
        return null;
    };
    s.path_job = job;
    return null;
}

/// The folder a file's server works in: the project's, if the file is in
/// it, else the file's own.
fn rootOf(self: *const App, path: []const u8) []const u8 {
    if (self.project) |*p| {
        const root = p.root().path;
        if (std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == std.fs.path.sep) return root;
    }
    return std.fs.path.dirname(path) orelse path;
}

/// The server for a tab's file, started the first time it's needed. Null
/// when there's none for its language, or none installed, or it died.
pub fn clientFor(self: *App, t: *const Tab) ?*Client {
    if (t.kind != .file) return null;
    const path = t.document.path orelse return null;
    const language = t.highlighter.language;
    if (lsp.servers.serversFor(language).len == 0) return null;
    const root = rootOf(self, path);
    var key_buf: [1024]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}|{s}", .{ @tagName(language), root }) catch return null;
    if (self.lsp.resolved.get(key)) |c| {
        const client = c orelse return null;
        return if (client.isDead()) null else client;
    }
    const search_path = searchPath(self) orelse return null;
    const client = startServer(self, language, path, root, search_path);
    const owned = self.gpa.dupe(u8, key) catch return null;
    self.lsp.resolved.put(self.gpa, owned, client) catch self.gpa.free(owned);
    return client;
}

fn startServer(self: *App, language: core.syntax.Language, path: []const u8, root: []const u8, search_path: []const u8) ?*Client {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const home = if (self.environ) |e| e.get("HOME") orelse "" else "";
    const found = (lsp.servers.find(arena.allocator(), self.io, language, path, search_path, home) catch return null) orelse return null;
    // One server of a kind per folder, whichever of its languages asked.
    var key_buf: [1200]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}|{s}|{s}", .{ @tagName(found.server), found.variant, root }) catch return null;
    for (self.lsp.clients.items) |e| if (std.mem.eql(u8, e.key, key)) return e.client;
    const client = Client.start(self.gpa, self.io, found.argv, root) catch return null;
    const owned = self.gpa.dupe(u8, key) catch {
        client.destroy();
        return null;
    };
    self.lsp.clients.append(self.gpa, .{ .key = owned, .client = client }) catch {
        self.gpa.free(owned);
        client.destroy();
        return null;
    };
    return client;
}

/// Whether a server looks after the tab's file (its problems come from
/// it, not from the one-off parser runs).
pub fn serves(self: *App, t: *const Tab) bool {
    return clientFor(self, t) != null;
}

/// Sends the tab's text to its server, if it hasn't this version yet.
fn sync(_: *App, t: *const Tab, client: *Client) void {
    const path = t.document.path orelse return;
    client.sync(path, lsp.servers.languageId(t.highlighter.language, path), t.buffer.items(), t.buffer.version) catch {};
}

// ------------------------------------------------------------ every frame

pub fn update(self: *App) !void {
    const s = &self.lsp;
    _ = s.frame.reset(.retain_capacity);
    const arena = s.frame.allocator();
    for (s.clients.items) |e| {
        const incoming = e.client.poll(arena) catch continue;
        for (incoming) |m| try handle(self, e.client, m);
    }
    // The shown files' text, once typing pauses.
    const now = rl.getTime();
    syncShown(self, self.tab(), now);
    if (self.split != null) syncShown(self, self.otherTab(), now);
    try updateHover(self, now);
}

fn syncShown(self: *App, t: *Tab, now: f64) void {
    const client = clientFor(self, t) orelse return;
    const path = t.document.path orelse return;
    const sent = client.sentVersion(path);
    if (sent == t.buffer.version) return;
    if (sent != null and now - t.changed_at < sync_after) return;
    sync(self, t, client);
}

fn handle(self: *App, client: *Client, m: Client.Incoming) !void {
    const arena = self.lsp.frame.allocator();
    switch (m) {
        .notification => |n| if (std.mem.eql(u8, n.method, "textDocument/publishDiagnostics")) {
            try published(self, client, n.params);
        },
        .apply_edit => |a| {
            _ = try applyWorkspaceEdit(self, a.edit);
            client.respond(a.id, .{ .applied = true }) catch {};
        },
        .response => |r| {
            const i = for (self.lsp.pending.items, 0..) |p, i| {
                if (p.client == client and p.id == r.id) break i;
            } else return;
            const p = self.lsp.pending.swapRemove(i);
            switch (p.what) {
                .hover => |key| {
                    const h = &self.lsp.hover;
                    if (h.key == null or !std.meta.eql(h.key.?, key) or r.err != null) return;
                    const text = try lsp.results.hoverText(arena, r.result) orelse return;
                    h.text.clearRetainingCapacity();
                    try h.text.appendSlice(self.gpa, text);
                },
                .completion => |c| try completionAnswer(self, c.word_start, c.version, c.explicit, r.result),
                .definition => |d| try definitionAnswer(self, d.word, d.version, d.point, if (r.err == null) r.result else .null),
                .rename => {
                    if (r.err) |e| return self.showError(i18n.tr().lsp.rename_failed, e);
                    if (r.result == .null) return self.showError(i18n.tr().lsp.rename_failed, "");
                    _ = try applyWorkspaceEdit(self, r.result);
                },
                .code_action => try showActions(self, client, r.result),
                .resolve => if (r.err == null) try runResolved(self, client, r.result),
                .resolve_completion => |rc| {
                    const t = self.tab();
                    // Typed on since: the import still goes above.
                    if (r.err != null or t.kind != .file) return;
                    if (Client.field(r.result, "additionalTextEdits")) |e| try addImport(self, t, e, rc.word);
                },
            }
        },
    }
}

/// A server's problems for a file: in its tab, if the text is still the
/// version they were found in.
fn published(self: *App, client: *Client, params: Value) !void {
    const arena = self.lsp.frame.allocator();
    const p = try lsp.results.published(arena, params) orelse return;
    // Kept for asking about fixes.
    if (Client.field(params, "diagnostics")) |list| {
        const json = try std.json.Stringify.valueAlloc(self.gpa, list, .{});
        const gop = try self.lsp.diagnostics.getOrPut(self.gpa, p.path);
        if (gop.found_existing) self.gpa.free(gop.value_ptr.*) else gop.key_ptr.* = try self.gpa.dupe(u8, p.path);
        gop.value_ptr.* = json;
    }
    const version = client.bufferVersionOf(p.path, p.version) orelse return;
    for (self.tabs.items) |*t| {
        if (!t.hasPath(p.path) or t.buffer.version != version) continue;
        var lines = try lsp.protocol.Lines.init(arena, t.buffer.items());
        var found: std.ArrayList(core.Diagnostics.Range) = .empty;
        // Errors only: they're underlined in red, like the parser's.
        for (p.problems) |x| if (x.severity <= 1) try found.append(arena, .{
            .start = lines.offset(x.start),
            .end = lines.offset(x.end),
            .message = x.message,
        });
        try t.problems.setRanges(&t.buffer, version, found.items);
    }
}

// ------------------------------------------------------------------ hover

/// The name (or problem) under the mouse, once it has rested there: its
/// problem at once, and what the server says about it when it answers.
fn updateHover(self: *App, now: f64) !void {
    const h = &self.lsp.hover;
    const key = hoverKey(self) orelse return resetHover(self, null, now);
    if (h.key == null or !std.meta.eql(h.key.?, key)) return resetHover(self, key, now);
    if (h.asked or now - h.since < hover_after) return;
    h.asked = true;
    const t = self.tab();
    h.anchor = self.view.screenPos(&t.buffer, key.start);
    // The problems there, first.
    if (t.problems.isCurrent(&t.buffer)) for (t.problems.items.items) |it| {
        if (it.start > key.end or it.end < key.start) continue;
        var buf: [512]u8 = undefined;
        if (h.problem.items.len > 0) try h.problem.append(self.gpa, '\n');
        try h.problem.appendSlice(self.gpa, problems.message(&buf, it));
    };
    const client = clientFor(self, t) orelse return;
    if (!client.caps.hover and client.state == .ready) return;
    if (!isWord(t.buffer.items()[key.start..key.end])) return;
    sync(self, t, client);
    const id = client.request("textDocument/hover", .{
        .textDocument = .{ .uri = try uriOf(self, t) },
        .position = lsp.protocol.toPosition(t.buffer.items(), key.start),
    }) catch return;
    try self.lsp.pending.append(self.gpa, .{ .client = client, .id = id, .what = .{ .hover = key } });
}

fn resetHover(self: *App, key: ?Key, now: f64) void {
    const h = &self.lsp.hover;
    if (key == null and h.key == null) return;
    h.key = key;
    h.since = now;
    h.asked = false;
    h.problem.clearRetainingCapacity();
    h.text.clearRetainingCapacity();
}

fn isWord(s: []const u8) bool {
    return s.len > 0 and core.text.isWordChar(s[0]);
}

/// The word, or the underlined problem, right under the mouse. Null when
/// the mouse is anywhere else, or something is on top of the text.
fn hoverKey(self: *App) ?Key {
    if (!self.isEditing() or self.modal != null or self.menu.is_open or self.quick_open.is_open or self.picker.is_open) return null;
    if (self.mouse.dragging or self.popup.visible) return null;
    const t = self.activeTab();
    if (t.kind != .file) return null;
    const view = &self.view;
    const p = rl.getMousePosition();
    if (p.x < view.textLeft() or p.x > view.right() or p.y < view.area.y or p.y > view.bottom()) return null;
    if (self.find.contains(p)) return null;
    const buf = &t.buffer;
    const pos = view.posAt(buf, p);
    // Over a problem's underline: that problem.
    var range: ?core.Buffer.Range = null;
    if (t.problems.isCurrent(buf)) for (t.problems.items.items) |it| {
        if (pos >= it.start and pos <= it.end and onText(view.*, buf, it.start, it.end, p)) {
            range = .{ .start = it.start, .end = it.end };
            break;
        }
    };
    const w = core.motion.wordRange(buf.items(), pos);
    if (isWord(buf.items()[w.start..w.end]) and onText(view.*, buf, w.start, w.end, p)) range = w;
    const r = range orelse return null;
    return .{ .start = r.start, .end = r.end, .version = buf.version };
}

/// Whether the point is over the text from `start` to `end` (on its
/// first row).
fn onText(view: @import("../../ui/editor/View.zig"), buf: *const core.Buffer, start: usize, end: usize, p: rl.Vector2) bool {
    const a = view.screenPos(buf, start);
    const b = view.screenPos(buf, end);
    if (p.y < a.y or p.y > a.y + theme.line_height) return false;
    const right = if (b.y == a.y) b.x else view.right();
    return p.x >= a.x and p.x <= @max(right, a.x + view.font.cell_width);
}

/// The box with the problem and what the server said, by the name.
pub fn drawHover(self: *const App) void {
    const h = &self.lsp.hover;
    if (!h.asked or (h.problem.items.len == 0 and h.text.items.len == 0)) return;
    const font = self.view.font;
    const cw = font.cell_width;
    const max_cols = 80;
    const max_rows = 18;

    // Lines cut to fit, the problem's first (in its color).
    var rows: [max_rows]struct { text: []const u8, problem: bool } = undefined;
    var n: usize = 0;
    var widest: usize = 0;
    for ([_][]const u8{ h.problem.items, h.text.items }, 0..) |part, which| {
        var lines = std.mem.splitScalar(u8, part, '\n');
        while (lines.next()) |line| {
            var rest = line;
            while (n < max_rows) {
                const cut = cutAt(rest, max_cols);
                rows[n] = .{ .text = rest[0..cut], .problem = which == 0 };
                n += 1;
                widest = @max(widest, core.text.codepointCount(rest[0..cut]));
                rest = std.mem.trimStart(u8, rest[cut..], " ");
                if (rest.len == 0) break;
            }
        }
    }
    if (n == 0) return;
    const pad: f32 = 8;
    const w = @as(f32, @floatFromInt(widest)) * cw + 2 * pad;
    const hgt = @as(f32, @floatFromInt(n)) * theme.line_height + 2 * pad;
    const window = App.windowSize();
    var y = h.anchor.y - hgt - 4;
    if (y < self.view.area.y) y = h.anchor.y + theme.line_height + 4;
    const x = std.math.clamp(h.anchor.x - pad, 4, @max(4, window.x - w - 4));
    const r: rl.Rectangle = .{ .x = x, .y = y, .width = w, .height = hgt };
    rl.drawRectangleRec(.{ .x = r.x + 3, .y = r.y + 4, .width = r.width, .height = r.height }, theme.popup_shadow);
    rl.drawRectangleRec(r, theme.popup_background);
    rl.drawRectangleLinesEx(r, 1, theme.popup_border);
    for (rows[0..n], 0..) |row, i| {
        const ty = r.y + pad + @as(f32, @floatFromInt(i)) * theme.line_height + (theme.line_height - theme.font_size) / 2;
        _ = font.drawFit(row.text, r.x + pad, ty, r.x + r.width, if (row.problem) theme.problem else theme.foreground);
    }
}

/// Where to break `s` to fit `cols` columns: after a space if there's
/// one, else mid-word. A byte offset.
fn cutAt(s: []const u8, cols: usize) usize {
    var col: usize = 0;
    var i: usize = 0;
    var space: ?usize = null;
    while (i < s.len) {
        if (col == cols) return space orelse i;
        if (s[i] == ' ') space = i + 1;
        i = core.text.nextBoundary(s, i);
        col += 1;
    }
    return s.len;
}

// ------------------------------------------------------------ definition

/// Asks the server where the name in `word` is declared. False when
/// there's no server ready to answer (then the caller looks itself).
pub fn requestDefinition(self: *App, word: core.Buffer.Range, point: rl.Vector2) !bool {
    const t = self.tab();
    const client = clientFor(self, t) orelse return false;
    // Still starting (rust-analyzer can take a while): no waiting on it.
    if (client.state != .ready or !client.caps.definition) return false;
    sync(self, t, client);
    const id = try client.request("textDocument/definition", .{
        .textDocument = .{ .uri = try uriOf(self, t) },
        .position = lsp.protocol.toPosition(t.buffer.items(), word.start),
    });
    try self.lsp.pending.append(self.gpa, .{ .client = client, .id = id, .what = .{ .definition = .{ .word = word, .version = t.buffer.version, .point = point } } });
    return true;
}

/// Goes to the declaration the server named. With none — or when the
/// name clicked is the declaration — it's looked for in the text, which
/// lists the uses in that case.
fn definitionAnswer(self: *App, word: core.Buffer.Range, version: u64, point: rl.Vector2, result: Value) !void {
    const t = self.tab();
    // Another tab, or the text changed: the click is stale.
    if (t.kind != .file or t.buffer.version != version) return;
    const here = t.document.path orelse return;
    const places = try lsp.results.locations(self.lsp.frame.allocator(), result);
    const target = for (places) |p| {
        if (!std.mem.eql(u8, p.path, here)) break p;
        const start = lsp.protocol.toOffset(t.buffer.items(), p.start);
        const end = lsp.protocol.toOffset(t.buffer.items(), p.end);
        // The name clicked is the one declared: not somewhere to go.
        if (start <= word.start and word.end <= @max(end, start + 1)) continue;
        break p;
    } else return symbol_nav.lookUp(self, word, point);

    if (!std.mem.eql(u8, target.path, here)) {
        self.openFile(target.path) catch |err| return self.reportError(i18n.tr().errors.open_file, target.path, err);
    }
    const b = self.buf();
    const start = lsp.protocol.toOffset(b.items(), target.start);
    const end = lsp.protocol.toOffset(b.items(), target.end);
    b.moveTo(start, false);
    // A place that spans lines (a whole declaration) only puts the cursor.
    if (end > start and std.mem.indexOfScalar(u8, b.items()[start..end], '\n') == null) b.moveTo(end, true);
    palette.center(self, b.lineIndex(start));
}

// ------------------------------------------------------------ completion

/// Asks the server for suggestions for the word at the cursor, when that
/// word is a new one (or the last answer was cut short). The answer
/// joins the list when it comes.
pub fn requestCompletion(self: *App, explicit: bool) !void {
    const t = self.tab();
    const c = &self.completion;
    if (c.path_mode and c.is_open) return;
    const client = clientFor(self, t) orelse return;
    if (!client.caps.completion and client.state == .ready) return;
    const b = &t.buffer;
    var start = b.cursor;
    while (start > 0 and core.syntax.js.isIdentChar(b.items()[start - 1])) start -= 1;
    if (!explicit and c.server_start == start and !self.lsp.incomplete) return;
    sync(self, t, client);
    const trigger = b.byteBefore(start);
    const is_trigger = start == b.cursor and trigger != null and isTrigger(client, trigger.?);
    const Context = struct { triggerKind: u8, triggerCharacter: ?[]const u8 = null };
    const trigger_text: [1]u8 = .{trigger orelse 0};
    const id = try client.request("textDocument/completion", .{
        .textDocument = .{ .uri = try uriOf(self, t) },
        .position = lsp.protocol.toPosition(b.items(), b.cursor),
        .context = if (is_trigger)
            Context{ .triggerKind = 2, .triggerCharacter = &trigger_text }
        else
            Context{ .triggerKind = 1 },
    });
    try self.lsp.pending.append(self.gpa, .{ .client = client, .id = id, .what = .{ .completion = .{ .word_start = start, .version = b.version, .explicit = explicit } } });
}

fn isTrigger(client: *const Client, c: u8) bool {
    for (client.caps.trigger_chars) |t| if (t.len == 1 and t[0] == c) return true;
    return c == '.';
}

fn completionAnswer(self: *App, word_start: usize, version: u64, explicit: bool, result: Value) !void {
    const t = self.tab();
    const b = &t.buffer;
    // Typed on since (the word may have grown): fine, as long as it's the
    // same word in the same text.
    if (b.version != version and !self.completion.is_open) return;
    var start = b.cursor;
    while (start > 0 and core.syntax.js.isIdentChar(b.items()[start - 1])) start -= 1;
    if (start != word_start) return;
    const arena = self.lsp.frame.allocator();
    const found = try lsp.results.suggestions(arena, result);
    self.lsp.incomplete = if (Client.field(result, "isIncomplete")) |v| v == .bool and v.bool else false;
    // In the server's order: the names already in reach before the ones
    // an import would bring in, so a name offered twice is the near one.
    std.mem.sort(lsp.results.Suggestion, found, {}, struct {
        fn f(_: void, x: lsp.results.Suggestion, y: lsp.results.Suggestion) bool {
            return std.mem.order(u8, x.sort, y.sort) == .lt;
        }
    }.f);
    const items = try arena.alloc(core.Completion.ServerItem, found.len);
    for (found, items) |f, *it| it.* = .{
        .label = f.label,
        .kind = std.meta.stringToEnum(core.Completion.ItemKind, @tagName(f.kind)).?,
        .insert = f.insert,
        .detail = f.detail,
        // Only what needs more than the name: an import, or resolving.
        .raw = if (f.detail.len > 0 or Client.field(f.raw, "additionalTextEdits") != null or Client.field(f.raw, "data") != null)
            try std.json.Stringify.valueAlloc(arena, f.raw, .{})
        else
            "",
    };
    const c = &self.completion;
    try c.setServer(word_start, items);
    // Shown if the list is open, was asked for, or is for a member (after
    // a dot there may be nothing else to offer).
    if (c.is_open or explicit or b.byteBefore(start) == '.') {
        // Its old rows named the suggestions just replaced.
        if (b.hasExtraCursors()) return c.close();
        try c.refresh(b, &t.highlighter, explicit, problems.filesOf(self, t));
    }
}

/// A server's suggestion was picked (its word starts at `word`): the
/// edits that come with it — the import it needs — are made, asking the
/// server for them first if it didn't send them along.
pub fn completionPicked(self: *App, raw: []const u8, word: lsp.protocol.Position) !void {
    if (raw.len == 0) return;
    const t = self.tab();
    const client = clientFor(self, t) orelse return;
    const arena = self.lsp.frame.allocator();
    const item = std.json.parseFromSliceLeaky(Value, arena, raw, .{}) catch return;
    if (Client.field(item, "additionalTextEdits")) |e| return addImport(self, t, e, word);
    if (!client.caps.completion_resolve) return;
    const id = try client.request("completionItem/resolve", item);
    try self.lsp.pending.append(self.gpa, .{ .client = client, .id = id, .what = .{ .resolve_completion = .{ .word = word } } });
}

/// The extra edits of a picked suggestion. Only those before its word are
/// made: the server placed them in the text before the word went in, and
/// only there has nothing moved since.
fn addImport(self: *App, t: *Tab, list: Value, word: lsp.protocol.Position) !void {
    const arena = self.lsp.frame.allocator();
    const all = try lsp.edits.parseEdits(arena, list);
    var above: std.ArrayList(lsp.edits.TextEdit) = .empty;
    for (all) |e| {
        const before = e.end.line < word.line or (e.end.line == word.line and e.end.character <= word.character);
        if (before) try above.append(arena, e);
    }
    if (above.items.len == 0) return;
    try lsp.edits.applyToBuffer(arena, &t.buffer, above.items);
    self.reveal_cursor = true;
}

// ----------------------------------------------------------------- rename

pub fn rename(self: *App) !void {
    const t = self.tab();
    if (t.kind != .file) return;
    const client = clientFor(self, t) orelse return noServer(self);
    if (!client.caps.rename and client.state == .ready) return noServer(self);
    const b = &t.buffer;
    const w = core.motion.wordRange(b.items(), b.cursor);
    const old = b.items()[w.start..w.end];
    if (!isWord(old)) return;
    var title_buf: [256]u8 = undefined;
    const title = i18n.fill(&title_buf, i18n.tr().lsp.rename_title, .{old});
    const typed = try self.askText(title, i18n.tr().lsp.new_name, false) orelse return;
    defer self.gpa.free(typed);
    const name = std.mem.trim(u8, typed, " \t");
    if (name.len == 0 or std.mem.eql(u8, name, old)) return;
    // The dialog may have taken a while: the text the server has is the
    // text now.
    const tab_now = self.tab();
    sync(self, tab_now, client);
    const id = try client.request("textDocument/rename", .{
        .textDocument = .{ .uri = try uriOf(self, tab_now) },
        .position = lsp.protocol.toPosition(tab_now.buffer.items(), w.start),
        .newName = name,
    });
    try self.lsp.pending.append(self.gpa, .{ .client = client, .id = id, .what = .rename });
}

/// Makes a server's edits: in the tabs of the files open, else in the
/// files themselves. Returns how many files changed.
pub fn applyWorkspaceEdit(self: *App, edit: Value) !usize {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const files = try lsp.edits.parseWorkspaceEdit(a, edit);
    var changed: usize = 0;
    for (files) |f| {
        if (f.edits.len == 0) continue;
        const tab = for (self.tabs.items) |*t| {
            if (t.hasPath(f.path)) break t;
        } else null;
        if (tab) |t| {
            try lsp.edits.applyToBuffer(a, &t.buffer, f.edits);
        } else {
            const dir = std.Io.Dir.cwd();
            const text = dir.readFileAlloc(self.io, f.path, a, .limited(core.Document.max_file_size)) catch |err| {
                self.reportError(i18n.tr().errors.save_file, f.path, err);
                continue;
            };
            const new = try lsp.edits.applyToText(a, text, f.edits);
            var file = dir.createFileAtomic(self.io, f.path, .{ .replace = true }) catch |err| {
                self.reportError(i18n.tr().errors.save_file, f.path, err);
                continue;
            };
            defer file.deinit(self.io);
            file.file.writeStreamingAll(self.io, new) catch continue;
            file.replace(self.io) catch continue;
        }
        changed += 1;
    }
    if (changed > 0) {
        self.gitChanged();
        self.reveal_cursor = true;
    }
    return changed;
}

// -------------------------------------------------------------- quick fix

/// Cmd+.: asks the server what it can do about the problems at the
/// cursor (or in the selection); a menu there lists it.
pub fn quickFix(self: *App) !void {
    const t = self.tab();
    if (t.kind != .file) return;
    const client = clientFor(self, t) orelse return noServer(self);
    if (!client.caps.code_action and client.state == .ready) return noServer(self);
    sync(self, t, client);
    const b = &t.buffer;
    const sel = b.selectionOrCursor();
    const from = lsp.protocol.toPosition(b.items(), sel.start);
    const to = lsp.protocol.toPosition(b.items(), sel.end);
    const arena = self.lsp.frame.allocator();
    // The problems the server reported there.
    var here: std.ArrayList(Value) = .empty;
    if (self.lsp.diagnostics.get(t.document.path.?)) |json| {
        const all = std.json.parseFromSliceLeaky(Value, arena, json, .{}) catch Value.null;
        if (all == .array) for (all.array.items) |d| {
            const r = lsp.edits.parseRange(Client.field(d, "range") orelse continue) orelse continue;
            if (r[1].line < from.line or r[0].line > to.line) continue;
            try here.append(arena, d);
        };
    }
    const id = try client.request("textDocument/codeAction", .{
        .textDocument = .{ .uri = try uriOf(self, t) },
        .range = .{ .start = from, .end = to },
        .context = .{ .diagnostics = here.items },
    });
    try self.lsp.pending.append(self.gpa, .{ .client = client, .id = id, .what = .code_action });
}

fn showActions(self: *App, client: *Client, result: Value) !void {
    const s = &self.lsp;
    _ = s.actions_arena.reset(.retain_capacity);
    const a = s.actions_arena.allocator();
    // Out of this frame's memory: the menu stays open for a while.
    const json = try std.json.Stringify.valueAlloc(a, result, .{});
    const kept = std.json.parseFromSliceLeaky(Value, a, json, .{}) catch return;
    s.actions = try lsp.results.actions(a, kept);
    s.actions_client = client;

    var labels: [ContextMenu.max_items][]const u8 = undefined;
    const n = @min(s.actions.len, ContextMenu.max_items);
    for (s.actions[0..n], 0..) |act, i| {
        labels[i] = act.title;
        self.menu_actions[i] = .{ .code_action = @intCast(i) };
    }
    const count = if (n == 0) blk: {
        labels[0] = i18n.tr().lsp.no_fixes;
        self.menu_actions[0] = .{ .code_action = std.math.maxInt(u32) };
        break :blk 1;
    } else n;
    const b = self.buf();
    const at = self.view.screenPos(b, b.cursor);
    self.menu_node = null;
    self.menu.open(labels[0..count], .{ .x = at.x, .y = at.y + theme.line_height }, App.windowSize(), self.view.font);
}

/// A row of the Quick Fix menu was picked.
pub fn runCodeAction(self: *App, index: u32) !void {
    const s = &self.lsp;
    if (index >= s.actions.len) return;
    const client = s.actions_client orelse return;
    const act = s.actions[index];
    if (act.edit == null and act.command == null) {
        // Its edit is worked out when asked for.
        if (!client.caps.code_action_resolve) return;
        const id = try client.request("codeAction/resolve", act.raw);
        return s.pending.append(self.gpa, .{ .client = client, .id = id, .what = .resolve });
    }
    try runAction(self, client, act);
}

fn runResolved(self: *App, client: *Client, result: Value) !void {
    if (lsp.results.action(result)) |a| try runAction(self, client, a);
}

fn runAction(self: *App, client: *Client, act: lsp.results.Action) !void {
    if (act.edit) |e| _ = try applyWorkspaceEdit(self, e);
    // A command runs on the server, which may send edits back.
    if (act.command) |cmd| {
        const name = Client.field(cmd, "command") orelse return;
        if (name != .string) return;
        _ = try client.request("workspace/executeCommand", .{
            .command = name.string,
            .arguments = Client.field(cmd, "arguments"),
        });
    }
}

// ----------------------------------------------------------------- helpers

fn uriOf(self: *App, t: *const Tab) ![]u8 {
    return lsp.protocol.uriFromPath(self.lsp.frame.allocator(), t.document.path.?);
}

/// Rename or Quick Fix without a server: what to install.
fn noServer(self: *App) void {
    const t = i18n.tr().lsp;
    const list = lsp.servers.serversFor(self.activeTab().highlighter.language);
    if (list.len == 0) return self.showError(t.no_server, t.no_server_any);
    var names: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&names);
    for (list, 0..) |s, i| {
        if (i > 0) w.writeAll(" / ") catch {};
        w.writeAll(if (s == .typescript) "node + TypeScript" else s.name()) catch {};
    }
    var detail: [256]u8 = undefined;
    self.showError(t.no_server, i18n.fill(&detail, t.no_server_detail, .{w.buffered()}));
}
