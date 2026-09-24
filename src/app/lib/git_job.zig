//! The git commands that reach the network (push, pull, fetch, and both
//! at once) run on a thread of their own, so the window keeps drawing,
//! with a spinner, while they wait on the remote. One at a time; the Git
//! view takes no other git clicks until it is done.
const std = @import("std");
const core = @import("core");
const GitPanel = @import("../../ui/sidebar/GitPanel.zig");
const App = @import("../App.zig");

pub const Kind = enum { push, pull, fetch, sync };

pub const Job = struct {
    kind: Kind,
    /// Its own, so git's message doesn't land in the app's while the
    /// main thread is using it.
    git: core.Git,
    root: []u8,
    thread: std.Thread = undefined,
    result: anyerror!void = {},
    done: std.atomic.Value(bool) = .init(false),

    fn run(job: *Job, io: std.Io) void {
        job.result = switch (job.kind) {
            .push => job.git.push(io, job.root),
            .pull => job.git.pull(io, job.root),
            .fetch => job.git.fetch(io, job.root),
            .sync => job.git.sync(io, job.root),
        };
        job.done.store(true, .release);
    }

    fn destroy(job: *Job, gpa: std.mem.Allocator) void {
        job.git.deinit();
        gpa.free(job.root);
        gpa.destroy(job);
    }
};

pub fn gitBusy(self: *const App) bool {
    return self.git_job != null;
}

/// Starts `kind` in the project folder. `from` is the command row that
/// asked for it (null for the commit button), which gets the spinner.
pub fn startGitJob(self: *App, kind: Kind, from: ?GitPanel.Command) void {
    if (self.git_job != null) return;
    const project = if (self.project) |*p| p else return;
    const job = self.gpa.create(Job) catch return;
    job.* = .{ .kind = kind, .git = .init(self.gpa), .root = undefined };
    job.root = self.gpa.dupe(u8, project.root().path) catch {
        self.gpa.destroy(job);
        return;
    };
    job.thread = std.Thread.spawn(.{}, Job.run, .{ job, self.io }) catch |err| {
        job.destroy(self.gpa);
        return self.gitAction(err);
    };
    self.git_job = job;
    self.git_panel.busy = .{ .from = from };
}

/// Called every frame: once the job is done, says what went wrong, if
/// anything, and re-reads the status.
pub fn pollGitJob(self: *App) void {
    const job = self.git_job orelse return;
    if (!job.done.load(.acquire)) return;
    job.thread.join();
    self.git_job = null;
    self.git_panel.busy = null;
    defer job.destroy(self.gpa);
    self.git.last_error.clearRetainingCapacity();
    self.git.last_error.appendSlice(self.gpa, job.git.last_error.items) catch {};
    self.gitAction(job.result);
}

/// On the way out: waits for git to finish rather than leave it halfway.
pub fn finishGitJob(self: *App) void {
    const job = self.git_job orelse return;
    job.thread.join();
    self.git_job = null;
    job.destroy(self.gpa);
}
