//! The languages' own parsers, run on the buffer to find its syntax
//! errors: TypeScript's (through node) for JS/TS, `zig ast-check`, Python's
//! `compile`, `gofmt -e` and `rustfmt`. For JS/TS a long-running TypeScript
//! language service (see `Server`) also finds type errors, and for Python
//! the names used but never defined are reported. Each reads the text on stdin, so
//! unsaved edits are checked too. A tool that isn't installed is reported
//! as such, and the editor makes do with its own bracket checks.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Highlighter = @import("../../syntax/Highlighter.zig");

pub const Tool = enum { typescript, zig, python, go, rust };

/// One error, as the tool located it: 1-based lines and columns.
pub const Found = struct {
    line: u32,
    col: u32,
    /// Where it ends, when the tool says; 0 for just the spot.
    end_line: u32 = 0,
    end_col: u32 = 0,
    message: []const u8,
};

pub const Result = union(enum) {
    /// The tool (or node, or TypeScript) isn't on this machine.
    unavailable,
    found: struct {
        items: []const Found,
        /// Columns count characters rather than bytes.
        in_chars: bool,
    },
};

/// The parser for a file in `language`, if there is one.
pub fn toolFor(language: Highlighter.Language) ?Tool {
    return switch (language) {
        .typescript, .jsx => .typescript,
        .zig => .zig,
        .python => .python,
        .go => .go,
        .rust => .rust,
        else => null,
    };
}

/// Where the tools are looked for.
pub const Env = struct {
    /// A PATH-style list of folders (see `searchPath`).
    search_path: []const u8,
    /// The user's home folder, for global TypeScript installs.
    home: []const u8 = "",
    /// Keeps TypeScript running between checks, for type errors; without
    /// it JS/TS get their syntax checked only.
    server: ?*Server = null,
};

/// Runs the parser for `tool` over `source`. `path` is the file's path (or
/// just a name for an untitled one): its extension picks the TS dialect and
/// its folder is where a project's own TypeScript is looked for.
pub fn run(alloc: Allocator, io: Io, tool: Tool, path: []const u8, source: []const u8, env: Env) !Result {
    const search_path = env.search_path;
    switch (tool) {
        .typescript => {
            const node = findExe(alloc, io, search_path, "node") orelse return .unavailable;
            const ts = findTypeScript(alloc, io, path, env.home) orelse return .unavailable;
            if (env.server) |server| {
                if (server.check(alloc, io, node, ts, path, source)) |out| {
                    return .{ .found = .{ .items = try parseTabbed(alloc, out), .in_chars = true } };
                } else |_| server.stop(io); // started again next time
            }
            const out = try runTool(alloc, io, &.{ node, "-e", ts_script, ts, std.fs.path.basename(path) }, source, .stdout) orelse return .unavailable;
            return .{ .found = .{ .items = try parseTabbed(alloc, out), .in_chars = true } };
        },
        .python => {
            const python = findExe(alloc, io, search_path, "python3") orelse findExe(alloc, io, search_path, "python") orelse return .unavailable;
            const out = try runTool(alloc, io, &.{ python, "-c", python_script, std.fs.path.basename(path) }, source, .stdout) orelse return .unavailable;
            return .{ .found = .{ .items = try parseTabbed(alloc, out), .in_chars = true } };
        },
        .zig => {
            const zig = findExe(alloc, io, search_path, "zig") orelse return .unavailable;
            // A build.zig.zon is ZON, which ast-check reads with --zon.
            const zon = std.mem.endsWith(u8, path, ".zon");
            const argv: []const []const u8 = if (zon) &.{ zig, "ast-check", "--zon" } else &.{ zig, "ast-check" };
            const out = try runTool(alloc, io, argv, source, .stderr) orelse return .unavailable;
            return .{ .found = .{ .items = try parseLocated(alloc, out), .in_chars = false } };
        },
        .go => {
            const gofmt = findExe(alloc, io, search_path, "gofmt") orelse return .unavailable;
            const out = try runTool(alloc, io, &.{ gofmt, "-e" }, source, .stderr) orelse return .unavailable;
            return .{ .found = .{ .items = try parseLocated(alloc, out), .in_chars = false } };
        },
        .rust => {
            const rustfmt = findExe(alloc, io, search_path, "rustfmt") orelse return .unavailable;
            const out = try runTool(alloc, io, &.{ rustfmt, "--edition", "2021", "--emit", "stdout" }, source, .stderr) orelse return .unavailable;
            return .{ .found = .{ .items = try parseRustfmt(alloc, out), .in_chars = true } };
        },
    }
}

/// Prints each of TypeScript's parse errors as
/// `line \t col \t end line \t end col \t message`.
const ts_script =
    \\const ts = require(process.argv[1]);
    \\const name = process.argv[2];
    \\const src = require('fs').readFileSync(0, 'utf8');
    \\const ext = name.slice(name.lastIndexOf('.')).toLowerCase();
    \\const kinds = { '.tsx': ts.ScriptKind.TSX, '.jsx': ts.ScriptKind.JSX, '.js': ts.ScriptKind.JS, '.mjs': ts.ScriptKind.JS, '.cjs': ts.ScriptKind.JS };
    \\const sf = ts.createSourceFile(name, src, ts.ScriptTarget.Latest, false, kinds[ext] ?? ts.ScriptKind.TS);
    \\for (const d of sf.parseDiagnostics || []) {
    \\  const a = sf.getLineAndCharacterOfPosition(d.start);
    \\  const b = sf.getLineAndCharacterOfPosition(d.start + (d.length || 0));
    \\  const text = ts.flattenDiagnosticMessageText(d.messageText, ' ').replace(/\s+/g, ' ');
    \\  console.log([a.line + 1, a.character + 1, b.line + 1, b.character + 1, text].join('\t'));
    \\}
;

/// The language service: reads requests `{"file", "text"}`, one JSON per
/// line, and answers each with the file's syntax and type errors (in the
/// format above) and a line `END`. The project is set up from the nearest
/// tsconfig.json / jsconfig.json (following `references`, as Vite's
/// does); other files are read from disk, and re-read when they change.
const ts_server_script =
    \\const ts = require(process.argv[1]);
    \\const fs = require('fs'), path = require('path');
    \\// Missing modules and their types are reported by the editor itself.
    \\const skip = new Set([2307, 2792, 7016, 2875, 7026]);
    \\const projects = new Map();
    \\const norm = f => f.replace(/\\/g, '/');
    \\function parse(config) {
    \\  const read = ts.readConfigFile(config, ts.sys.readFile);
    \\  if (read.error) return null;
    \\  return ts.parseJsonConfigFileContent(read.config, ts.sys, path.dirname(config), undefined, config);
    \\}
    \\function configFor(file) {
    \\  const dir = path.dirname(file);
    \\  const found = ts.findConfigFile(dir, ts.sys.fileExists, 'tsconfig.json') || ts.findConfigFile(dir, ts.sys.fileExists, 'jsconfig.json');
    \\  if (!found) return null;
    \\  const parsed = parse(found);
    \\  if (!parsed) return null;
    \\  if (parsed.fileNames.map(norm).includes(file)) return { config: found, parsed };
    \\  // A solution config (Vite's): the referenced one that has the file, or
    \\  // for a file not saved yet, the first one that has any.
    \\  let fallback = null;
    \\  for (const ref of parsed.projectReferences || []) {
    \\    let p = ref.path;
    \\    if (!p.endsWith('.json')) p = path.join(p, 'tsconfig.json');
    \\    const sub = ts.sys.fileExists(p) && parse(p);
    \\    if (!sub) continue;
    \\    if (sub.fileNames.map(norm).includes(file)) return { config: p, parsed: sub };
    \\    if (!fallback && sub.fileNames.length > 0) fallback = { config: p, parsed: sub };
    \\  }
    \\  return fallback || { config: found, parsed };
    \\}
    \\function projectFor(file) {
    \\  const found = configFor(file);
    \\  const key = found ? found.config : '';
    \\  let p = projects.get(key);
    \\  if (p) return p;
    \\  const options = found ? { ...found.parsed.options } : {
    \\    target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.ESNext,
    \\    moduleResolution: ts.ModuleResolutionKind.Bundler ?? ts.ModuleResolutionKind.NodeJs,
    \\    jsx: ts.JsxEmit.ReactJSX, allowJs: true, esModuleInterop: true, allowSyntheticDefaultImports: true,
    \\    resolveJsonModule: true, allowImportingTsExtensions: true,
    \\  };
    \\  Object.assign(options, { noEmit: true, skipLibCheck: true });
    \\  if (found && path.basename(found.config) === 'jsconfig.json') options.allowJs = true;
    \\  const roots = found ? found.parsed.fileNames.map(norm) : [];
    \\  const open = new Map();
    \\  const host = {
    \\    getScriptFileNames: () => [...new Set([...roots, ...open.keys()])],
    \\    getScriptVersion: f => {
    \\      const o = open.get(f);
    \\      if (o) return 'open' + o.version;
    \\      try { return String(fs.statSync(f).mtimeMs); } catch { return '0'; }
    \\    },
    \\    getScriptSnapshot: f => {
    \\      const o = open.get(f);
    \\      if (o) return ts.ScriptSnapshot.fromString(o.text);
    \\      const text = ts.sys.readFile(f);
    \\      return text === undefined ? undefined : ts.ScriptSnapshot.fromString(text);
    \\    },
    \\    getCurrentDirectory: () => found ? path.dirname(found.config) : process.cwd(),
    \\    getCompilationSettings: () => options,
    \\    getDefaultLibFileName: o => ts.getDefaultLibFilePath(o),
    \\    fileExists: f => open.has(f) || ts.sys.fileExists(f),
    \\    readFile: f => open.has(f) ? open.get(f).text : ts.sys.readFile(f),
    \\    readDirectory: ts.sys.readDirectory,
    \\    directoryExists: ts.sys.directoryExists,
    \\    getDirectories: ts.sys.getDirectories,
    \\    realpath: ts.sys.realpath,
    \\  };
    \\  p = { open, ls: ts.createLanguageService(host, ts.createDocumentRegistry()), n: 0 };
    \\  projects.set(key, p);
    \\  return p;
    \\}
    \\function check(req) {
    \\  const file = norm(req.file);
    \\  const p = projectFor(file);
    \\  p.open.set(file, { version: ++p.n, text: req.text });
    \\  const sf = p.ls.getProgram().getSourceFile(file);
    \\  const diags = [...p.ls.getSyntacticDiagnostics(file), ...p.ls.getSemanticDiagnostics(file)];
    \\  const out = [];
    \\  for (const d of diags) {
    \\    if (d.start === undefined || skip.has(d.code) || d.category !== ts.DiagnosticCategory.Error) continue;
    \\    const a = sf.getLineAndCharacterOfPosition(d.start);
    \\    const b = sf.getLineAndCharacterOfPosition(d.start + (d.length || 0));
    \\    const text = ts.flattenDiagnosticMessageText(d.messageText, ' ').replace(/\s+/g, ' ');
    \\    out.push([a.line + 1, a.character + 1, b.line + 1, b.character + 1, text].join('\t') + '\n');
    \\  }
    \\  return out.join('');
    \\}
    \\let buf = '';
    \\// The editor gone (even without saying so): so is this.
    \\process.stdin.on('end', () => process.exit(0));
    \\process.stdin.setEncoding('utf8');
    \\process.stdin.on('data', d => {
    \\  buf += d;
    \\  let i;
    \\  while ((i = buf.indexOf('\n')) >= 0) {
    \\    const line = buf.slice(0, i);
    \\    buf = buf.slice(i + 1);
    \\    let out = '';
    \\    try { out = check(JSON.parse(line)); } catch (e) {}
    \\    process.stdout.write(out + 'END\n');
    \\  }
    \\});
;

/// Python stops at the first syntax error; the same format as above. With
/// none, names that are used but never defined anywhere in the file (nor
/// built in) are reported, as pyflakes does. Columns are in characters.
const python_script =
    \\import sys, ast, builtins
    \\src = sys.stdin.buffer.read().decode('utf-8', 'replace')
    \\lines = src.split('\n')
    \\def out(l, c, el, ec, msg):
    \\    print(f"{l}\t{c}\t{el}\t{ec}\t{' '.join(str(msg).split())}")
    \\def col(l, off):
    \\    line = lines[l - 1] if 0 < l <= len(lines) else ''
    \\    return len(line.encode('utf-8')[:off].decode('utf-8', 'replace')) + 1
    \\try:
    \\    tree = compile(src, sys.argv[1], 'exec', ast.PyCF_ONLY_AST)
    \\except SyntaxError as e:
    \\    out(e.lineno or 1, e.offset or 1, getattr(e, 'end_lineno', None) or 0, getattr(e, 'end_offset', None) or 0, e.msg)
    \\    sys.exit()
    \\bound = set(dir(builtins)) | {'__file__', '__name__', '__doc__', '__builtins__', '__spec__', '__loader__',
    \\    '__package__', '__path__', '__annotations__', '__dict__', '__class__', '__module__', '__qualname__'}
    \\star = False
    \\for n in ast.walk(tree):
    \\    if isinstance(n, ast.Name) and not isinstance(n.ctx, ast.Load):
    \\        bound.add(n.id)
    \\    elif isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
    \\        bound.add(n.name)
    \\    elif isinstance(n, ast.arg):
    \\        bound.add(n.arg)
    \\    elif isinstance(n, (ast.Import, ast.ImportFrom)):
    \\        for a in n.names:
    \\            if a.name == '*': star = True
    \\            else: bound.add(a.asname or a.name.split('.')[0])
    \\    elif isinstance(n, (ast.Global, ast.Nonlocal)):
    \\        bound.update(n.names)
    \\    elif isinstance(getattr(n, 'name', None), str):
    \\        bound.add(n.name)  # except ... as e, match captures, type parameters
    \\    elif isinstance(getattr(n, 'rest', None), str):
    \\        bound.add(n.rest)  # case {**rest}
    \\if not star:
    \\    for n in ast.walk(tree):
    \\        if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load) and n.id not in bound:
    \\            out(n.lineno, col(n.lineno, n.col_offset), n.end_lineno, col(n.end_lineno, n.end_col_offset), f"'{n.id}' is not defined")
;

/// node running TypeScript's language service between checks, so a check
/// only re-reads what changed (the first one in a project reads it all).
/// Used by one thread at a time.
pub const Server = struct {
    gpa: Allocator,
    child: ?std.process.Child = null,
    /// The typescript.js it runs; a file needing another one restarts it.
    ts_path: []u8 = &.{},

    pub fn init(gpa: Allocator) Server {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Server, io: Io) void {
        self.stop(io);
    }

    pub fn stop(self: *Server, io: Io) void {
        if (self.child) |*c| c.kill(io);
        self.child = null;
        self.gpa.free(self.ts_path);
        self.ts_path = &.{};
    }

    /// The errors in `source`, as the file at `path`: the service's raw
    /// answer (without its `END`).
    fn check(self: *Server, alloc: Allocator, io: Io, node: []const u8, ts: []const u8, path: []const u8, source: []const u8) ![]const u8 {
        if (self.child == null or !std.mem.eql(u8, self.ts_path, ts)) {
            self.stop(io);
            self.child = try std.process.spawn(io, .{
                .argv = &.{ node, "-e", ts_server_script, ts },
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .ignore,
            });
            self.ts_path = try self.gpa.dupe(u8, ts);
        }
        const child = &self.child.?;
        const request = try std.json.Stringify.valueAlloc(alloc, .{ .file = path, .text = source }, .{});
        try child.stdin.?.writeStreamingAll(io, request);
        try child.stdin.?.writeStreamingAll(io, "\n");

        var out: std.ArrayList(u8) = .empty;
        var buf: [16384]u8 = undefined;
        while (true) {
            const n = try child.stdout.?.readStreaming(io, &.{&buf});
            if (n == 0) return error.ServerExited;
            try out.appendSlice(alloc, buf[0..n]);
            if (std.mem.eql(u8, out.items, "END\n")) return "";
            if (std.mem.endsWith(u8, out.items, "\nEND\n")) return out.items[0 .. out.items.len - 4];
        }
    }
};

const Stream = enum { stdout, stderr };

/// Runs `argv` with `source` on stdin and returns what it wrote to
/// `stream`, or null if it couldn't be started.
fn runTool(alloc: Allocator, io: Io, argv: []const []const u8, source: []const u8, stream: Stream) !?[]const u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = if (stream == .stdout) .pipe else .ignore,
        .stderr = if (stream == .stderr) .pipe else .ignore,
    }) catch return null;
    defer child.kill(io);
    // The tools read all their input before saying anything.
    child.stdin.?.writeStreamingAll(io, source) catch {};
    child.stdin.?.close(io);
    child.stdin = null;

    const pipe = (if (stream == .stdout) child.stdout else child.stderr).?;
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pipe.readStreaming(io, &.{&buf}) catch break;
        if (n == 0) break;
        if (out.items.len < 1024 * 1024) try out.appendSlice(alloc, buf[0..n]);
    }
    _ = child.wait(io) catch {};
    return out.items;
}

/// Lines of `line \t col \t end line \t end col \t message`.
pub fn parseTabbed(alloc: Allocator, out: []const u8) ![]const Found {
    var list: std.ArrayList(Found) = .empty;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var fields = std.mem.splitScalar(u8, line, '\t');
        const l = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        const c = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        const el = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        const ec = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        const message = fields.rest();
        try list.append(alloc, .{ .line = l, .col = c, .end_line = el, .end_col = ec, .message = try alloc.dupe(u8, message) });
    }
    return list.items;
}

/// Compiler-style lines: `<stdin>:3:5: error: expected ';'`. Notes, and
/// the source and caret lines under each error, are skipped.
pub fn parseLocated(alloc: Allocator, out: []const u8) ![]const Found {
    var list: std.ArrayList(Found) = .empty;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const loc = locationIn(line) orelse continue;
        var message = std.mem.trimStart(u8, line[loc.rest..], " ");
        if (std.mem.startsWith(u8, message, "note:")) continue;
        if (std.mem.startsWith(u8, message, "error:")) message = std.mem.trimStart(u8, message["error:".len..], " ");
        try list.append(alloc, .{ .line = loc.line, .col = loc.col, .message = try alloc.dupe(u8, message) });
    }
    return list.items;
}

/// rustfmt: `error: message` followed by ` --> <stdin>:3:5`.
pub fn parseRustfmt(alloc: Allocator, out: []const u8) ![]const Found {
    var list: std.ArrayList(Found) = .empty;
    var message: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "error")) {
            const colon = std.mem.indexOf(u8, line, ": ") orelse continue;
            message = line[colon + 2 ..];
        } else if (std.mem.indexOf(u8, line, "--> ")) |arrow| {
            const m = message orelse continue;
            const loc = locationIn(line[arrow + 4 ..]) orelse continue;
            try list.append(alloc, .{ .line = loc.line, .col = loc.col, .message = try alloc.dupe(u8, m) });
            message = null;
        }
    }
    return list.items;
}

/// `<stdin>:L:C` (or `<standard input>:L:C`) at the start of `line`.
fn locationIn(line: []const u8) ?struct { line: u32, col: u32, rest: usize } {
    if (line.len == 0 or line[0] != '<') return null;
    const close = std.mem.indexOfScalar(u8, line, '>') orelse return null;
    var parts = std.mem.splitScalar(u8, line[close + 1 ..], ':');
    if ((parts.next() orelse return null).len != 0) return null;
    const l_text = parts.next() orelse return null;
    const c_text = parts.next() orelse return null;
    const l = std.fmt.parseInt(u32, l_text, 10) catch return null;
    const c = std.fmt.parseInt(u32, c_text, 10) catch return null;
    const rest = close + 1 + 1 + l_text.len + 1 + c_text.len + 1;
    return .{ .line = l, .col = c, .rest = @min(rest, line.len) };
}

/// The program `name` in one of the folders of `search_path`.
pub fn findExe(alloc: Allocator, io: Io, search_path: []const u8, name: []const u8) ?[]const u8 {
    const exe_name = if (builtin.os.tag == .windows) std.mem.concat(alloc, u8, &.{ name, ".exe" }) catch return null else name;
    var dirs = std.mem.tokenizeScalar(u8, search_path, std.fs.path.delimiter);
    while (dirs.next()) |dir| {
        const full = std.fs.path.join(alloc, &.{ dir, exe_name }) catch return null;
        const st = Io.Dir.cwd().statFile(io, full, .{}) catch continue;
        if (st.kind == .file or st.kind == .sym_link) return full;
    }
    return null;
}

/// TypeScript's compiler: the project's own (in a node_modules up from
/// the file), else a global install, else the one inside VS Code or Cursor.
pub fn findTypeScript(alloc: Allocator, io: Io, path: []const u8, home: []const u8) ?[]const u8 {
    const rel = "node_modules/typescript/lib/typescript.js";
    var up: ?[]const u8 = std.fs.path.dirname(path);
    while (up) |d| : (up = std.fs.path.dirname(d)) {
        const full = std.fs.path.join(alloc, &.{ d, rel }) catch return null;
        if (isFile(io, full)) return full;
    }
    var candidates: std.ArrayList([]const u8) = .empty;
    candidates.appendSlice(alloc, &.{
        "/opt/homebrew/lib/" ++ rel,
        "/usr/local/lib/" ++ rel,
        "/usr/lib/" ++ rel,
        "/Applications/Visual Studio Code.app/Contents/Resources/app/extensions/" ++ rel,
        "/Applications/Cursor.app/Contents/Resources/app/extensions/" ++ rel,
        "/Applications/Windsurf.app/Contents/Resources/app/extensions/" ++ rel,
        "/usr/share/code/resources/app/extensions/" ++ rel,
    }) catch return null;
    if (home.len > 0) for ([_][]const u8{ ".npm-global/lib/", ".bun/install/global/", ".local/lib/" }) |sub| {
        candidates.append(alloc, std.mem.concat(alloc, u8, &.{ home, "/", sub, rel }) catch continue) catch {};
    };
    for (candidates.items) |c| if (isFile(io, c)) return c;
    return null;
}

fn isFile(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

/// Where to look for programs. An app opened from the Dock doesn't get the
/// PATH a terminal has, so the login shell is asked for it, and the usual
/// install folders are added.
pub fn searchPath(alloc: Allocator, io: Io, environ: ?*const std.process.Environ.Map) []const u8 {
    var parts: std.ArrayList(u8) = .empty;
    const sep = [_]u8{std.fs.path.delimiter};
    if (builtin.os.tag != .windows) {
        const shell = if (environ) |e| e.get("SHELL") orelse "/bin/zsh" else "/bin/zsh";
        if (std.process.run(alloc, io, .{
            .argv = &.{ shell, "-l", "-c", "printf %s \"$PATH\"" },
            .timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } },
        })) |r| {
            parts.appendSlice(alloc, std.mem.trim(u8, r.stdout, " \r\n")) catch {};
        } else |_| {}
    }
    if (environ) |e| if (e.get("PATH")) |p| {
        parts.appendSlice(alloc, &sep) catch {};
        parts.appendSlice(alloc, p) catch {};
    };
    if (builtin.os.tag != .windows) {
        const home = if (environ) |e| e.get("HOME") orelse "" else "";
        for ([_][]const u8{ "/opt/homebrew/bin", "/usr/local/bin", "/usr/local/go/bin" }) |d| {
            parts.appendSlice(alloc, &sep) catch {};
            parts.appendSlice(alloc, d) catch {};
        }
        if (home.len > 0) for ([_][]const u8{ "/.cargo/bin", "/go/bin", "/.bun/bin", "/.volta/bin", "/.local/bin" }) |d| {
            parts.appendSlice(alloc, &sep) catch {};
            parts.appendSlice(alloc, home) catch {};
            parts.appendSlice(alloc, d) catch {};
        };
    }
    return parts.items;
}

test {
    _ = @import("../tests/checkers_test.zig");
}
