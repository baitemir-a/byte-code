//! Format Document (Shift+Option+F), and formatting on save: the file's
//! text goes through its language's formatter (see core/format) on a
//! thread of its own, so a slow one (Prettier starts node) doesn't hold
//! the window up. The result replaces only what changed, as one undo
//! step, and only if the text wasn't edited meanwhile.
const std = @import("std");
const core = @import("core");
const App = @import("../App.zig");
const Tab = @import("../Tab.zig");
const i18n = @import("../../i18n/i18n.zig");

pub const Job = struct {
    language: core.syntax.Language,
    /// The file's path (or a name for an untitled one), a copy of its
    /// text, and the buffer version that text is.
    path: []u8,
    source: []u8,
    version: u64,
    /// Save the file once it is formatted (Cmd+S with format on save).
    then_save: bool,
    search_path: ?[]const u8,
    environ: ?*const std.process.Environ.Map,
    /// Results, in `arena`.
    arena: std.heap.ArenaAllocator,
    found_path: ?[]const u8 = null,
    result: ?core.format.Result = null,
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
        job.result = core.format.run(alloc, io, job.language, job.path, job.source, search_path) catch null;
    }

    fn destroy(job: *Job, gpa: std.mem.Allocator) void {
        job.arena.deinit();
        gpa.free(job.path);
        gpa.free(job.source);
        gpa.destroy(job);
    }
};

/// Whether the active tab's language has a formatter to try.
pub fn canFormat(self: *const App) bool {
    const t = self.activeTab();
    return t.kind == .file and core.format.formattersFor(t.highlighter.language).len > 0;
}

/// Shift+Option+F.
pub fn formatDocument(self: *App) !void {
    if (self.activeTab().kind != .file) return;
    if (!canFormat(self)) return noFormatter(self);
    start(self, false);
}

/// Cmd+S: with "format on save", the file is formatted first and saved
/// when that is done; otherwise (or with nothing to format it) at once.
pub fn saveCommand(self: *App, save_as: bool) !void {
    const t = self.tab();
    if (!save_as and self.settings.format_on_save and t.document.path != null and canFormat(self)) {
        return start(self, true);
    }
    _ = self.save(save_as) catch |err| self.reportError(i18n.tr().errors.save_file, "", err);
}

fn start(self: *App, then_save: bool) void {
    // One at a time. Saving while it runs saves once it's done (the
    // thread never looks at `then_save`).
    if (self.format_job) |running| {
        if (then_save) running.then_save = true;
        return;
    }
    const t = self.tab();
    const job = self.gpa.create(Job) catch return;
    const path = self.gpa.dupe(u8, t.document.path orelse untitledName(t.highlighter.language)) catch return self.gpa.destroy(job);
    const source = self.gpa.dupe(u8, t.buffer.items()) catch {
        self.gpa.free(path);
        return self.gpa.destroy(job);
    };
    job.* = .{
        .language = t.highlighter.language,
        .path = path,
        .source = source,
        .version = t.buffer.version,
        .then_save = then_save,
        .search_path = self.tool_path,
        .environ = self.environ,
        .arena = .init(self.gpa),
    };
    job.thread = std.Thread.spawn(.{}, Job.run, .{ job, self.io }) catch return job.destroy(self.gpa);
    self.format_job = job;
}

/// A name that tells Prettier the language of an untitled file.
fn untitledName(language: core.syntax.Language) []const u8 {
    return switch (language) {
        .jsx => "untitled.tsx",
        .json => "untitled.json",
        .css => "untitled.css",
        .scss => "untitled.scss",
        .html => "untitled.html",
        .markdown => "untitled.md",
        .yaml => "untitled.yaml",
        .graphql => "untitled.graphql",
        .zig => "untitled.zig",
        .go => "untitled.go",
        .rust => "untitled.rs",
        .python => "untitled.py",
        .c => "untitled.c",
        .cpp => "untitled.cpp",
        .objc => "untitled.m",
        else => "untitled.ts",
    };
}

/// Once the formatter is done: its text goes into the tab it read (if
/// that text wasn't edited since), and the file is saved if that was
/// asked for. Called once a frame.
pub fn poll(self: *App) !void {
    const job = self.format_job orelse return;
    if (!job.done.load(.acquire)) return;
    job.thread.join();
    self.format_job = null;
    defer job.destroy(self.gpa);
    if (job.found_path) |p| if (self.tool_path == null) {
        self.tool_path = try self.gpa.dupe(u8, p);
    };

    // The tab, found by the text it had: tabs may have moved meanwhile.
    const index = for (self.tabs.items, 0..) |*t, i| {
        if (t.kind == .file and t.buffer.version == job.version) break i;
    } else null;
    if (index) |i| if (job.result) |result| switch (result) {
        .formatted => |text| try apply(&self.tabs.items[i].buffer, text),
        // Saving goes ahead anyway; asking for it says why not.
        .unavailable => if (!job.then_save) noFormatter(self),
        .failed => |f| if (!job.then_save) failed(self, f.formatter, f.message),
    };
    if (!job.then_save) return;
    // Edited meanwhile: saved as it is now.
    const save_index = index orelse for (self.tabs.items, 0..) |*t, i| {
        if (t.kind == .file and t.document.path != null and std.mem.eql(u8, t.document.path.?, job.path)) break i;
    } else return;
    self.saveTab(save_index);
}

/// Replaces what the formatter changed, keeping the cursor on its text.
pub fn apply(buf: *core.Buffer, text: []const u8) !void {
    const c = core.format.change(buf.items(), text) orelse return;
    const map = struct {
        fn f(p: usize, ch: core.format.Change) usize {
            if (p <= ch.start) return p;
            if (p >= ch.end) return p - ch.end + ch.start + ch.text.len;
            return ch.start + @min(p - ch.start, ch.text.len);
        }
    }.f;
    const cursor = map(buf.cursor, c);
    const anchor = if (buf.anchor) |a| map(a, c) else null;
    buf.history.seal();
    try buf.replace(c.start, c.end, c.text, 0, .other);
    buf.history.seal();
    buf.cursor = cursor;
    buf.anchor = anchor;
}

fn noFormatter(self: *App) void {
    const t = i18n.tr().errors;
    const list = core.format.formattersFor(self.activeTab().highlighter.language);
    var names: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&names);
    for (list, 0..) |f, i| {
        if (i > 0) w.writeAll(" / ") catch {};
        w.writeAll(f.name()) catch {};
    }
    var detail: [256]u8 = undefined;
    const message = if (list.len > 0) i18n.fill(&detail, t.install_formatter, .{w.buffered()}) else t.no_formatter_detail;
    self.showError(t.no_formatter, message);
}

fn failed(self: *App, formatter: core.format.Formatter, message: []const u8) void {
    var title: [128]u8 = undefined;
    // Long compiler output: the start is what matters.
    const cut = message[0..@min(message.len, 600)];
    self.showError(i18n.fill(&title, i18n.tr().errors.format_failed, .{formatter.name()}), cut);
}

/// Waits for a formatter still running, before the app goes away.
pub fn finish(self: *App) void {
    if (self.format_job) |job| {
        job.thread.join();
        job.destroy(self.gpa);
        self.format_job = null;
    }
}
