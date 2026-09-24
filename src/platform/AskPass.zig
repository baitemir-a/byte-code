//! git's questions for a password (or a username, or an SSH key's
//! passphrase), answered in the editor's own dialog instead of a terminal
//! nobody is looking at.
//!
//! git asks by running the program named in GIT_ASKPASS (SSH_ASKPASS for
//! ssh) with the question as its argument, and reads the answer from its
//! output. That program is the editor itself, started again with
//! `env_var` naming a folder only this user can read: it writes the
//! question there as `request`, and waits for the editor to write
//! `response` (a '1' and the answer, or a '0' when cancelled). The editor
//! looks for requests while a git command runs (see git_job.zig).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const env_var = "RL_ASKPASS_DIR";

const request_file = "request";
const response_file = "response";
/// How long the helper waits for an answer before giving up.
const timeout_ms = 10 * 60 * 1000;
const poll_ms = 50;

/// One git command's way of asking: the folder, and the environment git
/// runs with.
pub const Session = struct {
    gpa: Allocator,
    dir: []u8,
    environ: std.process.Environ.Map,

    /// Makes the folder and the environment that points git at it.
    pub fn start(gpa: Allocator, io: Io, parent: *const std.process.Environ.Map) !Session {
        const exe = try std.process.executablePathAlloc(io, gpa);
        defer gpa.free(exe);
        const tmp = parent.get("TMPDIR") orelse parent.get("TEMP") orelse parent.get("TMP") orelse "/tmp";
        var random: [8]u8 = undefined;
        io.random(&random);
        const name = try std.fmt.allocPrint(gpa, "rl-askpass-{x}", .{&random});
        defer gpa.free(name);
        const dir = try std.fs.path.join(gpa, &.{ tmp, name });
        errdefer gpa.free(dir);
        const private: std.Io.File.Permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(0o700) else .default_dir;
        try Io.Dir.cwd().createDir(io, dir, private);
        errdefer Io.Dir.cwd().deleteTree(io, dir) catch {};

        var environ = try parent.clone(gpa);
        errdefer environ.deinit();
        try environ.put("GIT_ASKPASS", exe);
        try environ.put("SSH_ASKPASS", exe);
        try environ.put("SSH_ASKPASS_REQUIRE", "force");
        // Never a question on a terminal: there isn't one to answer it.
        try environ.put("GIT_TERMINAL_PROMPT", "0");
        try environ.put(env_var, dir);
        return .{ .gpa = gpa, .dir = dir, .environ = environ };
    }

    pub fn deinit(self: *Session, io: Io) void {
        Io.Dir.cwd().deleteTree(io, self.dir) catch {};
        self.gpa.free(self.dir);
        self.environ.deinit();
    }

    /// A question git is waiting on, if there is one. Caller frees.
    pub fn pending(self: *Session, io: Io) !?[]u8 {
        const path = try std.fs.path.join(self.gpa, &.{ self.dir, request_file });
        defer self.gpa.free(path);
        const question = Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .limited(4096)) catch return null;
        Io.Dir.cwd().deleteFile(io, path) catch {};
        return question;
    }

    /// Answers the question; null says it was cancelled.
    pub fn answer(self: *Session, io: Io, reply: ?[]const u8) !void {
        const data = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ if (reply != null) "1" else "0", reply orelse "" });
        defer {
            std.crypto.secureZero(u8, data);
            self.gpa.free(data);
        }
        try writeAtomic(self.gpa, io, self.dir, response_file, data);
    }
};

/// Whether a question looks like it wants a secret, so the answer is
/// hidden as it is typed.
pub fn isSecret(question: []const u8) bool {
    var buf: [256]u8 = undefined;
    const lower = std.ascii.lowerString(&buf, question[0..@min(question.len, buf.len)]);
    for ([_][]const u8{ "password", "passphrase", "token", "pin for" }) |word| {
        if (std.mem.indexOf(u8, lower, word) != null) return true;
    }
    return false;
}

/// The editor started by git to ask `question`: hands it to the editor
/// that is running and prints the answer. Returns the exit code.
pub fn helper(gpa: Allocator, io: Io, dir: []const u8, question: []const u8) u8 {
    writeAtomic(gpa, io, dir, request_file, question) catch return 1;
    const path = std.fs.path.join(gpa, &.{ dir, response_file }) catch return 1;
    defer gpa.free(path);
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += poll_ms) {
        // The folder goes when the git command is over: nobody to ask.
        Io.Dir.cwd().access(io, dir, .{}) catch return 1;
        if (Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096))) |response| {
            defer {
                std.crypto.secureZero(u8, response);
                gpa.free(response);
            }
            Io.Dir.cwd().deleteFile(io, path) catch {};
            if (response.len == 0 or response[0] != '1') return 1;
            const out = Io.File.stdout();
            out.writeStreamingAll(io, response[1..]) catch return 1;
            out.writeStreamingAll(io, "\n") catch return 1;
            return 0;
        } else |_| {}
        io.sleep(.fromMilliseconds(poll_ms), .awake) catch return 1;
    }
    return 1;
}

/// Written under another name first, so the reader never sees half of it.
fn writeAtomic(gpa: Allocator, io: Io, dir: []const u8, name: []const u8, data: []const u8) !void {
    const tmp_name = try std.fmt.allocPrint(gpa, "{s}.tmp", .{name});
    defer gpa.free(tmp_name);
    const tmp = try std.fs.path.join(gpa, &.{ dir, tmp_name });
    defer gpa.free(tmp);
    const final = try std.fs.path.join(gpa, &.{ dir, name });
    defer gpa.free(final);
    const cwd = Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = data });
    try cwd.rename(tmp, cwd, final, io);
}

test isSecret {
    try std.testing.expect(isSecret("Password for 'https://x@github.com': "));
    try std.testing.expect(isSecret("Enter passphrase for key '/home/x/.ssh/id_ed25519': "));
    try std.testing.expect(!isSecret("Username for 'https://github.com': "));
}
