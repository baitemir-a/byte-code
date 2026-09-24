//! The git commands that reach the network (push, pull, fetch, both at
//! once, and clone) run on a thread of their own, so the window keeps
//! drawing, with a spinner, while they wait on the remote. One at a time;
//! the Git view takes no other git clicks until it is done. When git asks
//! for a password meanwhile, the editor asks in a dialog (see AskPass).
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

/// Starts `kind` in the project folder. `from` is the command row that
/// asked for it (null for the commit button), which gets the spinner.
pub fn startGitJob(self: *App, kind: Kind, from: ?GitPanel.Command) void {
    const project = if (self.project) |*p| p else return;
    start(self, kind, from, project.root().path, "");
}

/// Copies the repository at `url` into a folder in `parent`; the copy
/// opens as the project once it is there.
pub fn startClone(self: *App, parent: []const u8, url: []const u8) void {
    start(self, .clone, .clone, parent, url);
}

fn start(self: *App, kind: Kind, from: ?GitPanel.Command, root: []const u8, url: []const u8) void {
    if (self.git_job != null) return;
    const job = self.gpa.create(Job) catch return;
    job.* = .{ .kind = kind, .git = .init(self.gpa), .root = &.{} };
    job.root = self.gpa.dupe(u8, root) catch return job.destroy(self.gpa, self.io);
    job.url = self.gpa.dupe(u8, url) catch return job.destroy(self.gpa, self.io);
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
    self.git_panel.busy = .{ .from = from };
}

/// Called every frame: once the job is done, says what went wrong, if
/// anything, and re-reads the status.
pub fn pollGitJob(self: *App) void {
    const job = self.git_job orelse return;
    if (!job.done.load(.acquire)) {
        if (job.askpass) |*a| askIfAsked(self, a);
        return;
    }
    job.thread.join();
    self.git_job = null;
    self.git_panel.busy = null;
    defer job.destroy(self.gpa, self.io);
    self.git.last_error.clearRetainingCapacity();
    self.git.last_error.appendSlice(self.gpa, job.git.last_error.items) catch {};
    self.gitAction(job.result);
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

/// On the way out: waits for git to finish rather than leave it halfway.
pub fn finishGitJob(self: *App) void {
    const job = self.git_job orelse return;
    // A question left open would keep git waiting: it is called off.
    if (job.askpass) |*a| if (!job.done.load(.acquire)) a.answer(self.io, null) catch {};
    job.thread.join();
    self.git_job = null;
    job.destroy(self.gpa, self.io);
}
