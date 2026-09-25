//! Mistakes in the files being shown: checked once typing pauses, for the
//! wavy underlines and the messages at the ends of their lines. The own
//! checks run at once; the language's parser (node + TypeScript, zig,
//! python...) runs on a thread of its own, one file at a time, and its
//! errors are added when it's done. TypeScript stays running between
//! checks (`App.ts_server`), so type errors come quickly after the first.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const App = @import("../App.zig");
const Tab = @import("../Tab.zig");
const i18n = @import("../../i18n/i18n.zig");

/// How long typing has to pause before the file is checked again, so
/// half-typed code isn't marked while it's being written.
const settle_seconds = 0.5;

const Tool = core.Diagnostics.checkers.Tool;

/// The parser running over one file's text, on its own thread.
pub const Job = struct {
    tool: Tool,
    /// The file's path (or a name for an untitled file), a copy of its
    /// text, and the buffer version that text is.
    path: []u8,
    source: []u8,
    version: u64,
    /// Where programs are found: the app's, or null to work it out here
    /// (asking the login shell) and hand back in `found_path`.
    search_path: ?[]const u8,
    home: []const u8,
    environ: ?*const std.process.Environ.Map,
    /// The app's TypeScript service; only this job uses it while it runs.
    server: *core.Diagnostics.checkers.Server,
    /// Results, in `arena`.
    arena: std.heap.ArenaAllocator,
    found_path: ?[]const u8 = null,
    result: ?core.Diagnostics.checkers.Result = null,
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),

    fn run(job: *Job, io: std.Io) void {
        defer job.done.store(true, .release);
        const alloc = job.arena.allocator();
        const search_path = job.search_path orelse blk: {
            const p = core.Diagnostics.checkers.searchPath(alloc, io, job.environ);
            job.found_path = p;
            break :blk p;
        };
        job.result = core.Diagnostics.checkers.run(alloc, io, job.tool, job.path, job.source, .{ .search_path = search_path, .home = job.home, .server = job.server }) catch null;
    }

    fn destroy(job: *Job, gpa: std.mem.Allocator) void {
        job.arena.deinit();
        gpa.free(job.path);
        gpa.free(job.source);
        gpa.destroy(job);
    }
};

/// Keeps the problems of the tabs on screen up to date; called once a frame.
pub fn updateProblems(self: *App) !void {
    try pollJob(self);
    try check(self, self.tab());
    if (self.split != null) try check(self, self.otherTab());
}

fn check(self: *App, t: *Tab) !void {
    if (t.kind != .file) return;
    if (rl.getTime() - t.changed_at < settle_seconds) return;
    const tool = core.Diagnostics.checkers.toolFor(t.highlighter.language);
    if (!t.problems.isCurrent(&t.buffer)) {
        // With a parser that works, it has the say on brackets and strings.
        const parsed = if (tool) |tl| self.tools_working.contains(tl) else false;
        try t.problems.update(self.gpa, &t.buffer, &t.highlighter, .{ .files = filesOf(self, t), .structural = !parsed });
    }
    if (tool) |tl| if (t.problems.syntax_asked != t.buffer.version and !self.tools_missing.contains(tl)) startJob(self, t, tl);
}

/// Starts the parser on the tab's text, unless one is running already
/// (then this is tried again on a later frame).
fn startJob(self: *App, t: *Tab, tool: Tool) void {
    if (self.syntax_job != null) return;
    const job = self.gpa.create(Job) catch return;
    const name = t.document.path orelse switch (tool) {
        .typescript => "untitled.tsx",
        .zig => "untitled.zig",
        .python => "untitled.py",
        .go => "untitled.go",
        .rust => "untitled.rs",
    };
    const path = self.gpa.dupe(u8, name) catch return self.gpa.destroy(job);
    const source = self.gpa.dupe(u8, t.buffer.items()) catch {
        self.gpa.free(path);
        return self.gpa.destroy(job);
    };
    job.* = .{
        .tool = tool,
        .path = path,
        .source = source,
        .version = t.buffer.version,
        .search_path = self.tool_path,
        .home = if (self.environ) |e| e.get("HOME") orelse "" else "",
        .environ = self.environ,
        .server = &self.ts_server,
        .arena = .init(self.gpa),
    };
    job.thread = std.Thread.spawn(.{}, Job.run, .{ job, self.io }) catch return job.destroy(self.gpa);
    t.problems.syntax_asked = t.buffer.version;
    self.syntax_job = job;
}

/// Once the parser is done, hands its findings to the tab it read (if
/// that tab still has the same text).
fn pollJob(self: *App) !void {
    const job = self.syntax_job orelse return;
    if (!job.done.load(.acquire)) return;
    job.thread.join();
    self.syntax_job = null;
    defer job.destroy(self.gpa);
    if (job.found_path) |p| if (self.tool_path == null) {
        self.tool_path = try self.gpa.dupe(u8, p);
    };
    const result = job.result orelse return;
    switch (result) {
        .unavailable => self.tools_missing.insert(job.tool),
        .found => |f| {
            self.tools_working.insert(job.tool);
            for (self.tabs.items) |*t| {
                if (t.kind != .file or t.buffer.version != job.version) continue;
                const same = if (t.document.path) |p| std.mem.eql(u8, p, job.path) else std.mem.startsWith(u8, job.path, "untitled.");
                if (same) try t.problems.setSyntax(&t.buffer, job.version, f.items, f.in_chars);
            }
        },
    }
}

/// Waits for a parser still running and stops TypeScript, before the app
/// goes away.
pub fn finishJob(self: *App) void {
    if (self.syntax_job) |job| {
        job.thread.join();
        job.destroy(self.gpa);
        self.syntax_job = null;
    }
    self.ts_server.deinit(self.io);
}

/// Where a tab's file is, for resolving its imports.
pub fn filesOf(self: *const App, t: *const Tab) ?core.Completion.Files {
    const path = t.document.path orelse return null;
    if (!std.fs.path.isAbsolute(path)) return null;
    return .{ .io = self.io, .path = path, .root = if (self.project) |*p| p.root().path else null };
}

/// The problem on the cursor's line of the active tab, if any.
pub fn problemAtCursor(self: *const App) ?core.Diagnostics.Item {
    const t = self.activeTab();
    if (t.kind != .file or !t.problems.isCurrent(&t.buffer)) return null;
    return t.problems.onLine(&t.buffer, t.buffer.lineStart(t.buffer.cursor));
}

/// What to say about a problem, in the app's language.
pub fn message(buf: []u8, item: core.Diagnostics.Item) []const u8 {
    const s = i18n.tr().problems;
    const a = [_]u8{ '\'', item.a, '\'' };
    const b = [_]u8{ '\'', item.b, '\'' };
    return switch (item.kind) {
        .unclosed => i18n.fill(buf, s.unclosed, .{@as([]const u8, &a)}),
        .unexpected => i18n.fill(buf, s.unexpected, .{@as([]const u8, &a)}),
        .mismatched => i18n.fill(buf, s.mismatched, .{ @as([]const u8, &a), @as([]const u8, &b) }),
        .unterminated_string => s.unterminated_string,
        .invalid_json => s.invalid_json,
        .syntax => item.message,
        .missing_import => blk: {
            var quoted: [200]u8 = undefined;
            const q = std.fmt.bufPrint(&quoted, "'{s}'", .{item.path[0..@min(item.path.len, 190)]}) catch item.path;
            break :blk i18n.fill(buf, s.missing_import, .{q});
        },
    };
}
