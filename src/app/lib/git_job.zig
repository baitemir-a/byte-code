//! The git commands that reach the network (push, pull, fetch, both at
//! once, and clone) run on a thread of their own, so the window keeps
//! drawing while they wait on the remote: the Git view shows how far git
//! got, and a button that stops it. One at a time; the Git view takes no
//! other git clicks until it is done. When git asks for a password
//! meanwhile, the editor asks in a dialog (see AskPass).
const std = @import("std");
const core = @import("core");
const GitPanel = @import("../../ui/sidebar/GitPanel.zig");
const App = @import("../App.zig");
const AskPass = @import("../../platform/AskPass.zig");
const i18n = @import("../../i18n/i18n.zig");

pub const Kind = enum { push, pull, fetch, sync, clone };

pub const Job = struct {
    kind: Kind,
    /// Its own, so git's message doesn't land in the app's while the
    /// main thread is using it.
    git: core.Git,
    /// The project folder; for a clone, the folder the copy goes in.
    root: []u8,
    /// What a clone copies.
    url: []u8 = &.{},
    /// Where git's password questions go, when the editor can take them.
    askpass: ?AskPass.Session = null,
    /// How far git got, and the way to stop it.
    progress: core.Git.Progress = .{},
    thread: std.Thread = undefined,
    result: anyerror!void = {},
    done: std.atomic.Value(bool) = .init(false),

    fn run(job: *Job, io: std.Io) void {
        job.result = switch (job.kind) {
            .push => job.git.push(io, job.root),
            .pull => job.git.pull(io, job.root),
            .fetch => job.git.fetch(io, job.root),
            .sync => job.git.sync(io, job.root),
            .clone => job.git.clone(io, job.root, job.url),
        };
        job.done.store(true, .release);
    }

    fn destroy(job: *Job, gpa: std.mem.Allocator, io: std.Io) void {
        if (job.askpass) |*a| a.deinit(io);
        job.git.deinit();
        gpa.free(job.root);
        gpa.free(job.url);
        gpa.destroy(job);
    }
};

pub fn gitBusy(self: *const App) bool {
    return self.git_job != null;
}

/// Starts `kind` in the project folder.
pub fn startGitJob(self: *App, kind: Kind) void {
    const project = if (self.project) |*p| p else return;
    start(self, kind, project.root().path, "");
}

/// Copies the repository at `url` into a folder in `parent`; the copy
/// opens as the project once it is there.
pub fn startClone(self: *App, parent: []const u8, url: []const u8) void {
    start(self, .clone, parent, url);
}

fn start(self: *App, kind: Kind, root: []const u8, url: []const u8) void {
    if (self.git_job != null) return;
    const job = self.gpa.create(Job) catch return;
    job.* = .{ .kind = kind, .git = .init(self.gpa), .root = &.{} };
    job.root = self.gpa.dupe(u8, root) catch return job.destroy(self.gpa, self.io);
    job.url = self.gpa.dupe(u8, url) catch return job.destroy(self.gpa, self.io);
    job.git.progress = &job.progress;
    // Without it git still runs; it just can't ask for anything.
    if (self.environ) |environ| {
        job.askpass = AskPass.Session.start(self.gpa, self.io, environ) catch null;
        if (job.askpass) |*a| job.git.environ = &a.environ;
    }
    job.thread = std.Thread.spawn(.{}, Job.run, .{ job, self.io }) catch |err| {
        job.destroy(self.gpa, self.io);
        return self.gitAction(err);
    };
    self.git_job = job;
    const t = i18n.tr().git;
    self.git_panel.busy = .{ .label = switch (kind) {
        .push => t.running_push,
        .pull => t.running_pull,
        .fetch => t.running_fetch,
        .sync => t.running_sync,
        .clone => t.running_clone,
    } };
}

/// Called every frame: once the job is done, says what went wrong, if
/// anything, and re-reads the status.
pub fn pollGitJob(self: *App) void {
    const job = self.git_job orelse return;
    if (!job.done.load(.acquire)) {
        if (self.git_panel.busy) |*b| b.progress_len = job.progress.current(self.io, &b.progress).len;
        if (job.askpass) |*a| askIfAsked(self, a);
        return;
    }
    job.thread.join();
    self.git_job = null;
    self.git_panel.busy = null;
    defer job.destroy(self.gpa, self.io);
    self.git.last_error.clearRetainingCapacity();
    self.git.last_error.appendSlice(self.gpa, job.git.last_error.items) catch {};
    // Stopped on purpose: nothing went wrong to report.
    self.gitAction(if (job.result == error.GitCancelled) {} else job.result);
    if (job.kind == .clone) if (job.result) |_| self.openClone(job.root, job.url) else |_| {};
}

/// git is waiting on a question (a password, say): the dialog asks it,
/// and the answer goes back.
fn askIfAsked(self: *App, session: *AskPass.Session) void {
    const question = session.pending(self.io) catch return orelse return;
    defer self.gpa.free(question);
    const trimmed = std.mem.trim(u8, question, " \r\n");
    const reply = self.askText(i18n.tr().git.credentials_title, trimmed, AskPass.isSecret(trimmed)) catch null;
    defer if (reply) |r| {
        std.crypto.secureZero(u8, r);
        self.gpa.free(r);
    };
    session.answer(self.io, reply) catch {};
}

/// The stop button: git is ended (and what it started with it); the job
/// finishes as usual, without an error to report.
pub fn cancelGitJob(self: *App) void {
    const job = self.git_job orelse return;
    job.progress.cancel(self.io);
    // A question it was waiting on goes unanswered.
    if (job.askpass) |*a| a.answer(self.io, null) catch {};
}

/// On the way out: git is stopped rather than waited for.
pub fn finishGitJob(self: *App) void {
    const job = self.git_job orelse return;
    cancelGitJob(self);
    job.thread.join();
    self.git_job = null;
    job.destroy(self.gpa, self.io);
}
