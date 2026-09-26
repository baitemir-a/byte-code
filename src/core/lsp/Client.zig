//! One language server: the process, a thread reading what it says, and
//! the requests waiting for an answer. The editor's thread writes to it
//! and, once a frame, takes what came in (`poll`).
//!
//! Until the server has answered `initialize`, messages are held back.
//! Requests the server makes of the editor are answered here, except for
//! `workspace/applyEdit`, which `poll` hands over.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");

const Client = @This();

pub const State = enum { starting, ready, dead };

/// What the server said it can do.
pub const Capabilities = struct {
    hover: bool = false,
    definition: bool = false,
    references: bool = false,
    signature_help: bool = false,
    document_symbol: bool = false,
    workspace_symbol: bool = false,
    /// Characters that open the parameter hint ("(", ",").
    signature_chars: []const []const u8 = &.{},
    completion: bool = false,
    /// Suggestions come without their extra edits (the import), which
    /// `completionItem/resolve` fills in.
    completion_resolve: bool = false,
    rename: bool = false,
    code_action: bool = false,
    code_action_resolve: bool = false,
    /// Characters that open suggestions (".", "::"...).
    trigger_chars: []const []const u8 = &.{},
};

/// An open file, as the server has it.
pub const Doc = struct {
    /// What the server calls its version, and the buffer's version sent.
    version: i64,
    buffer_version: u64,
};

pub const Incoming = union(enum) {
    /// The answer to a request of ours.
    response: struct { id: i64, result: std.json.Value, err: ?[]const u8 },
    notification: struct { method: []const u8, params: std.json.Value },
    /// The server wants text changed; answer with `respond`.
    apply_edit: struct { id: std.json.Value, edit: std.json.Value },
};

gpa: Allocator,
io: Io,
child: std.process.Child,
thread: std.Thread = undefined,
/// Filled by the reading thread, emptied by `poll`.
mutex: Io.Mutex = .init,
inbox: std.ArrayList([]u8) = .empty,
reading: std.atomic.Value(bool) = .init(true),
state: State = .starting,
init_id: i64 = 0,
next_id: i64 = 1,
/// Written once the server is ready.
held: std.ArrayList([]u8) = .empty,
caps: Capabilities = .{},
caps_arena: std.heap.ArenaAllocator,
/// Open files, by path (owned keys).
docs: std.StringHashMapUnmanaged(Doc) = .empty,
/// The folder it was started for.
root: []u8,

/// Starts `argv` for the project at `root` (absolute) and asks it to
/// initialize.
pub fn start(gpa: Allocator, io: Io, argv: []const []const u8, root: []const u8) !*Client {
    const child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = root },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    const self = try gpa.create(Client);
    self.* = .{ .gpa = gpa, .io = io, .child = child, .caps_arena = .init(gpa), .root = try gpa.dupe(u8, root) };
    self.thread = std.Thread.spawn(.{}, readLoop, .{self}) catch |err| {
        self.child.kill(io);
        gpa.free(self.root);
        gpa.destroy(self);
        return err;
    };
    try self.initialize();
    return self;
}

/// Asks the server to stop, and waits for it to.
pub fn destroy(self: *Client) void {
    if (self.state == .ready) {
        _ = self.request("shutdown", null) catch {};
        self.notify("exit", null) catch {};
    }
    self.child.kill(self.io);
    self.thread.join();
    for (self.inbox.items) |m| self.gpa.free(m);
    self.inbox.deinit(self.gpa);
    for (self.held.items) |m| self.gpa.free(m);
    self.held.deinit(self.gpa);
    var it = self.docs.keyIterator();
    while (it.next()) |k| self.gpa.free(k.*);
    self.docs.deinit(self.gpa);
    self.caps_arena.deinit();
    self.gpa.free(self.root);
    self.gpa.destroy(self);
}

fn readLoop(self: *Client) void {
    defer self.reading.store(false, .release);
    var framer: protocol.Framer = .{};
    defer framer.deinit(self.gpa);
    var buf: [65536]u8 = undefined;
    const out = self.child.stdout orelse return;
    while (true) {
        const n = out.readStreaming(self.io, &.{&buf}) catch return;
        if (n == 0) return;
        framer.push(self.gpa, buf[0..n]) catch return;
        while (framer.next(self.gpa) catch return) |body| {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.inbox.append(self.gpa, body) catch self.gpa.free(body);
        }
    }
}

/// Whether the server has gone away (crashed, or never started).
pub fn isDead(self: *const Client) bool {
    return self.state == .dead or !self.reading.load(.acquire);
}

// ---------------------------------------------------------------- sending

fn initialize(self: *Client) !void {
    const alloc = self.caps_arena.allocator();
    const uri = try protocol.uriFromPath(alloc, self.root);
    self.init_id = self.next_id;
    self.next_id += 1;
    const params = .{
        .processId = null,
        .rootUri = uri,
        .rootPath = self.root,
        .workspaceFolders = .{.{ .uri = uri, .name = std.fs.path.basename(self.root) }},
        .clientInfo = .{ .name = "byte code" },
        .capabilities = .{
            .general = .{ .positionEncodings = .{"utf-16"} },
            .workspace = .{
                .applyEdit = true,
                .workspaceEdit = .{ .documentChanges = true },
                .configuration = true,
                .workspaceFolders = true,
                .symbol = .{ .dynamicRegistration = false },
            },
            .textDocument = .{
                .synchronization = .{ .dynamicRegistration = false, .didSave = false },
                .hover = .{ .contentFormat = .{ "markdown", "plaintext" } },
                .definition = .{ .linkSupport = true },
                .references = .{ .dynamicRegistration = false },
                .signatureHelp = .{ .signatureInformation = .{
                    .documentationFormat = .{"plaintext"},
                    .parameterInformation = .{ .labelOffsetSupport = true },
                    .activeParameterSupport = true,
                } },
                .documentSymbol = .{ .hierarchicalDocumentSymbolSupport = true },
                .completion = .{ .completionItem = .{
                    .snippetSupport = false,
                    .documentationFormat = .{"plaintext"},
                    .labelDetailsSupport = true,
                    .resolveSupport = .{ .properties = .{ "additionalTextEdits", "detail" } },
                } },
                .rename = .{ .prepareSupport = false },
                .codeAction = .{
                    .codeActionLiteralSupport = .{ .codeActionKind = .{ .valueSet = .{ "", "quickfix", "refactor", "source" } } },
                    .resolveSupport = .{ .properties = .{"edit"} },
                    .dataSupport = true,
                    .isPreferredSupport = true,
                },
                .publishDiagnostics = .{ .relatedInformation = false },
            },
        },
    };
    try self.write(try message(self.gpa, .{ .jsonrpc = "2.0", .id = self.init_id, .method = "initialize", .params = params }), true);
}

fn message(gpa: Allocator, value: anytype) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, value, .{ .emit_null_optional_fields = false });
    defer gpa.free(body);
    return protocol.frame(gpa, body);
}

/// Writes a framed message (owned); held back until the server is ready
/// unless `now`.
fn write(self: *Client, framed: []u8, now: bool) !void {
    if (self.state == .dead) return self.gpa.free(framed);
    if (self.state == .starting and !now) return self.held.append(self.gpa, framed);
    defer self.gpa.free(framed);
    const in = self.child.stdin orelse return;
    in.writeStreamingAll(self.io, framed) catch {
        self.state = .dead;
    };
}

/// Sends a request; returns its id, for matching the answer.
pub fn request(self: *Client, method: []const u8, params: anytype) !i64 {
    const id = self.next_id;
    self.next_id += 1;
    try self.write(try message(self.gpa, .{ .jsonrpc = "2.0", .id = id, .method = method, .params = params }), false);
    return id;
}

pub fn notify(self: *Client, method: []const u8, params: anytype) !void {
    try self.write(try message(self.gpa, .{ .jsonrpc = "2.0", .method = method, .params = params }), false);
}

/// Answers a request the server made.
pub fn respond(self: *Client, id: std.json.Value, result: anytype) !void {
    try self.write(try message(self.gpa, .{ .jsonrpc = "2.0", .id = id, .result = result }), false);
}

// --------------------------------------------------------------- documents

/// Tells the server about the text of `path`, if it doesn't have this
/// version yet: opens it the first time, sends it whole after that.
pub fn sync(self: *Client, path: []const u8, language_id: []const u8, text: []const u8, buffer_version: u64) !void {
    const uri = try protocol.uriFromPath(self.gpa, path);
    defer self.gpa.free(uri);
    if (self.docs.getPtr(path)) |doc| {
        if (doc.buffer_version == buffer_version) return;
        doc.version += 1;
        doc.buffer_version = buffer_version;
        return self.notify("textDocument/didChange", .{
            .textDocument = .{ .uri = uri, .version = doc.version },
            .contentChanges = .{.{ .text = text }},
        });
    }
    const key = try self.gpa.dupe(u8, path);
    errdefer self.gpa.free(key);
    try self.docs.put(self.gpa, key, .{ .version = 1, .buffer_version = buffer_version });
    try self.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = language_id, .version = 1, .text = text } });
}

/// The buffer version the server last got for `path`.
pub fn sentVersion(self: *const Client, path: []const u8) ?u64 {
    const doc = self.docs.get(path) orelse return null;
    return doc.buffer_version;
}

/// The buffer version the server's version `v` of `path` was.
pub fn bufferVersionOf(self: *const Client, path: []const u8, v: ?i64) ?u64 {
    const doc = self.docs.get(path) orelse return null;
    if (v) |x| if (x != doc.version) return null;
    return doc.buffer_version;
}

// ---------------------------------------------------------------- receiving

/// Takes what the server said since the last call. Everything lives in
/// `arena`.
pub fn poll(self: *Client, arena: Allocator) ![]Incoming {
    var bodies: std.ArrayList([]u8) = .empty;
    defer bodies.deinit(self.gpa);
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.mem.swap(std.ArrayList([]u8), &bodies, &self.inbox);
    }
    var out: std.ArrayList(Incoming) = .empty;
    for (bodies.items) |body| {
        defer self.gpa.free(body);
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch continue;
        if (value != .object) continue;
        const obj = value.object;
        const method: ?[]const u8 = if (obj.get("method")) |m| (if (m == .string) m.string else null) else null;
        const id = obj.get("id");
        if (method) |m| {
            const params = obj.get("params") orelse .null;
            if (id) |i| {
                if (std.mem.eql(u8, m, "workspace/applyEdit")) {
                    const edit = if (params == .object) params.object.get("edit") orelse .null else .null;
                    try out.append(arena, .{ .apply_edit = .{ .id = i, .edit = edit } });
                } else try self.answerServer(m, i, params);
            } else try out.append(arena, .{ .notification = .{ .method = m, .params = params } });
            continue;
        }
        const i = id orelse continue;
        if (i != .integer) continue;
        const err: ?[]const u8 = if (obj.get("error")) |e| blk: {
            if (e == .object) if (e.object.get("message")) |msg| if (msg == .string) break :blk msg.string;
            break :blk "error";
        } else null;
        const result = obj.get("result") orelse .null;
        if (i.integer == self.init_id and self.state == .starting) {
            try self.ready(result);
            continue;
        }
        try out.append(arena, .{ .response = .{ .id = i.integer, .result = result, .err = err } });
    }
    if (!self.reading.load(.acquire)) self.state = .dead;
    return out.items;
}

/// The server answered `initialize`: note what it can do, and send what
/// was held back.
fn ready(self: *Client, result: std.json.Value) !void {
    self.state = .ready;
    const alloc = self.caps_arena.allocator();
    if (field(result, "capabilities")) |c| {
        self.caps.hover = provided(c, "hoverProvider");
        self.caps.definition = provided(c, "definitionProvider");
        self.caps.references = provided(c, "referencesProvider");
        self.caps.document_symbol = provided(c, "documentSymbolProvider");
        self.caps.workspace_symbol = provided(c, "workspaceSymbolProvider");
        if (field(c, "signatureHelpProvider")) |sh| if (sh != .null) {
            self.caps.signature_help = true;
            var list: std.ArrayList([]const u8) = .empty;
            for ([_][]const u8{ "triggerCharacters", "retriggerCharacters" }) |name| {
                if (field(sh, name)) |tc| if (tc == .array) for (tc.array.items) |t| {
                    if (t == .string) try list.append(alloc, try alloc.dupe(u8, t.string));
                };
            }
            self.caps.signature_chars = list.items;
        };
        self.caps.rename = provided(c, "renameProvider");
        self.caps.code_action = provided(c, "codeActionProvider");
        if (field(c, "codeActionProvider")) |ca| if (field(ca, "resolveProvider")) |r| {
            self.caps.code_action_resolve = r == .bool and r.bool;
        };
        if (field(c, "completionProvider")) |cp| {
            self.caps.completion = cp != .null;
            if (field(cp, "resolveProvider")) |r| self.caps.completion_resolve = r == .bool and r.bool;
            if (field(cp, "triggerCharacters")) |tc| if (tc == .array) {
                var list: std.ArrayList([]const u8) = .empty;
                for (tc.array.items) |t| if (t == .string) try list.append(alloc, try alloc.dupe(u8, t.string));
                self.caps.trigger_chars = list.items;
            };
        }
    }
    try self.write(try message(self.gpa, .{ .jsonrpc = "2.0", .method = "initialized", .params = .{} }), true);
    const held = self.held;
    self.held = .empty;
    defer self.gpa.free(held.allocatedSlice());
    for (held.items) |m| try self.write(m, true);
}

/// Answers what the server asks that needs no more than a polite reply.
fn answerServer(self: *Client, method: []const u8, id: std.json.Value, params: std.json.Value) !void {
    if (std.mem.eql(u8, method, "workspace/configuration")) {
        // No settings of ours: one null per item asked about.
        const n = if (field(params, "items")) |items| (if (items == .array) items.array.items.len else 0) else 0;
        var nulls: [64]?u8 = @splat(null);
        return self.respond(id, nulls[0..@min(n, nulls.len)]);
    }
    if (std.mem.eql(u8, method, "workspace/workspaceFolders")) {
        const uri = try protocol.uriFromPath(self.gpa, self.root);
        defer self.gpa.free(uri);
        return self.respond(id, .{.{ .uri = uri, .name = std.fs.path.basename(self.root) }});
    }
    try self.respond(id, null);
}

/// `value.name`, if `value` is an object that has it.
pub fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

fn provided(caps: std.json.Value, name: []const u8) bool {
    const v = field(caps, name) orelse return false;
    return switch (v) {
        .bool => |b| b,
        .null => false,
        else => true,
    };
}
