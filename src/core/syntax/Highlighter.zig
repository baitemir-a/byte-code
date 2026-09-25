//! Remembers the lexer state at the start of every line, so any visible
//! line can be highlighted on its own. Rebuilt whenever the buffer changes.
const std = @import("std");
const Buffer = @import("../buffer/Buffer.zig");
const token = @import("lib/token.zig");
const js = @import("lib/js.zig");
const json = @import("lib/json.zig");
const css = @import("lib/css.zig");
const html = @import("lib/html.zig");
const markdown = @import("lib/markdown.zig");
const python = @import("lib/python.zig");
const toml = @import("lib/toml.zig");
const yaml = @import("lib/yaml.zig");
const config = @import("lib/config.zig");
const clike = @import("lib/clike.zig");
const generic = @import("lib/generic.zig");

const Highlighter = @This();

pub const Language = enum {
    plain,
    /// Also used for JavaScript, which it is a superset of.
    typescript,
    /// TypeScript or JavaScript with JSX markup in it: .tsx and .jsx.
    jsx,
    json,
    css,
    /// SCSS, Sass and Less: CSS plus `//` comments and `$variables`.
    scss,
    html,
    xml,
    markdown,
    python,
    /// Also INI-style files, Cargo.lock, poetry.lock.
    toml,
    yaml,
    /// yarn.lock: YAML-like, but `key value` without a colon.
    yarn_lock,
    dotenv,
    /// .gitignore and friends.
    ignore,
    go,
    rust,
    zig,
    diff,
    // The languages of the `generic` lexer, named as its dialects.
    c,
    cpp,
    objc,
    csharp,
    java,
    kotlin,
    scala,
    groovy,
    swift,
    dart,
    php,
    solidity,
    shader,
    wgsl,
    protobuf,
    graphql,
    verilog,
    shell,
    fish,
    powershell,
    batch,
    ruby,
    perl,
    r,
    julia,
    elixir,
    erlang,
    nim,
    crystal,
    gdscript,
    lua,
    tcl,
    coffeescript,
    haskell,
    elm,
    ocaml,
    fsharp,
    lisp,
    clojure,
    sql,
    makefile,
    dockerfile,
    cmake,
    hcl,
    nix,
    fortran,
    pascal,
    ada,
    vhdl,
    vb,
    assembly,
    tex,

    /// JavaScript, TypeScript, and their JSX flavours: one language as
    /// far as keywords, completion and the lexer are concerned.
    pub fn isJs(self: Language) bool {
        return self == .typescript or self == .jsx;
    }

    /// The C-family dialect, for languages the `clike` lexer handles.
    pub fn clikeDialect(self: Language) ?clike.Dialect {
        return switch (self) {
            .go => .go,
            .rust => .rust,
            .zig => .zig,
            else => null,
        };
    }

    /// The dialect, for languages the `generic` lexer handles.
    pub fn genericDialect(self: Language) ?generic.Dialect {
        return switch (self) {
            inline else => |l| if (@hasField(generic.Dialect, @tagName(l))) @field(generic.Dialect, @tagName(l)) else null,
        };
    }

    pub fn fromPath(path: []const u8) Language {
        const name = std.fs.path.basename(path);
        // Files known by name (dotfiles have no extension to go by).
        const names = [_]struct { []const u8, Language }{
            .{ ".gitignore", .ignore },      .{ ".dockerignore", .ignore },     .{ ".npmignore", .ignore },
            .{ ".prettierignore", .ignore }, .{ ".eslintignore", .ignore },     .{ ".hgignore", .ignore },
            .{ ".ignore", .ignore },         .{ ".gitattributes", .ignore },    .{ ".env", .dotenv },
            .{ "yarn.lock", .yarn_lock },    .{ "Cargo.lock", .toml },          .{ "poetry.lock", .toml },
            .{ "uv.lock", .toml },           .{ "pdm.lock", .toml },            .{ "composer.lock", .json },
            .{ "Pipfile.lock", .json },      .{ "flake.lock", .json },          .{ "deno.lock", .json },
            .{ "Podfile.lock", .yaml },      .{ "Gemfile.lock", .yaml },        .{ ".editorconfig", .toml },
            .{ ".npmrc", .toml },            .{ ".gitconfig", .toml },          .{ "Pipfile", .toml },
            .{ "Makefile", .makefile },      .{ "makefile", .makefile },        .{ "GNUmakefile", .makefile },
            .{ "Dockerfile", .dockerfile },  .{ "Containerfile", .dockerfile }, .{ "CMakeLists.txt", .cmake },
            .{ "Gemfile", .ruby },           .{ "Rakefile", .ruby },            .{ "Podfile", .ruby },
            .{ "Vagrantfile", .ruby },       .{ "Brewfile", .ruby },            .{ "Jenkinsfile", .groovy },
            .{ ".bashrc", .shell },          .{ ".bash_profile", .shell },      .{ ".zshrc", .shell },
            .{ ".zprofile", .shell },        .{ ".profile", .shell },           .{ "PKGBUILD", .shell },
            .{ "justfile", .makefile },      .{ "Justfile", .makefile },
        };
        for (names) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        if (std.mem.startsWith(u8, name, ".env.")) return .dotenv; // .env.local, .env.production
        if (std.mem.startsWith(u8, name, "Dockerfile.")) return .dockerfile; // Dockerfile.dev

        const ext = std.fs.path.extension(path);
        const table = [_]struct { []const u8, Language }{
            .{ ".py", .python },           .{ ".pyw", .python },            .{ ".pyi", .python },
            .{ ".go", .go },               .{ ".rs", .rust },               .{ ".zig", .zig },
            .{ ".zon", .zig },             .{ ".toml", .toml },             .{ ".ini", .toml },
            .{ ".cfg", .toml },            .{ ".conf", .toml },             .{ ".yml", .yaml },
            .{ ".yaml", .yaml },           .{ ".env", .dotenv },            .{ ".gitignore", .ignore },
            .{ ".js", .typescript },       .{ ".jsx", .jsx },               .{ ".mjs", .typescript },
            .{ ".cjs", .typescript },      .{ ".ts", .typescript },         .{ ".tsx", .jsx },
            .{ ".mts", .typescript },      .{ ".cts", .typescript },        .{ ".json", .json },
            .{ ".jsonc", .json },          .{ ".json5", .json },            .{ ".css", .css },
            .{ ".scss", .scss },           .{ ".sass", .scss },             .{ ".less", .scss },
            .{ ".html", .html },           .{ ".htm", .html },              .{ ".vue", .html },
            .{ ".svelte", .html },         .{ ".xml", .xml },               .{ ".svg", .xml },
            .{ ".xsd", .xml },             .{ ".xsl", .xml },               .{ ".plist", .xml },
            .{ ".xhtml", .xml },           .{ ".md", .markdown },           .{ ".markdown", .markdown },
            .{ ".diff", .diff },           .{ ".patch", .diff },            .{ ".c", .c },
            .{ ".h", .cpp },               .{ ".cpp", .cpp },               .{ ".cc", .cpp },
            .{ ".cxx", .cpp },             .{ ".c++", .cpp },               .{ ".hpp", .cpp },
            .{ ".hh", .cpp },              .{ ".hxx", .cpp },               .{ ".ino", .cpp },
            .{ ".m", .objc },              .{ ".mm", .objc },               .{ ".cs", .csharp },
            .{ ".csx", .csharp },          .{ ".java", .java },             .{ ".kt", .kotlin },
            .{ ".kts", .kotlin },          .{ ".scala", .scala },           .{ ".sc", .scala },
            .{ ".sbt", .scala },           .{ ".groovy", .groovy },         .{ ".gradle", .groovy },
            .{ ".swift", .swift },         .{ ".dart", .dart },             .{ ".php", .php },
            .{ ".phtml", .php },           .{ ".sol", .solidity },          .{ ".glsl", .shader },
            .{ ".vert", .shader },         .{ ".frag", .shader },           .{ ".geom", .shader },
            .{ ".comp", .shader },         .{ ".hlsl", .shader },           .{ ".fx", .shader },
            .{ ".metal", .shader },        .{ ".wgsl", .wgsl },             .{ ".proto", .protobuf },
            .{ ".graphql", .graphql },     .{ ".gql", .graphql },           .{ ".v", .verilog },
            .{ ".sv", .verilog },          .{ ".svh", .verilog },           .{ ".sh", .shell },
            .{ ".bash", .shell },          .{ ".zsh", .shell },             .{ ".ksh", .shell },
            .{ ".fish", .fish },           .{ ".ps1", .powershell },        .{ ".psm1", .powershell },
            .{ ".psd1", .powershell },     .{ ".bat", .batch },             .{ ".cmd", .batch },
            .{ ".rb", .ruby },             .{ ".rake", .ruby },             .{ ".gemspec", .ruby },
            .{ ".pl", .perl },             .{ ".pm", .perl },               .{ ".r", .r },
            .{ ".jl", .julia },            .{ ".ex", .elixir },             .{ ".exs", .elixir },
            .{ ".erl", .erlang },          .{ ".hrl", .erlang },            .{ ".nim", .nim },
            .{ ".nims", .nim },            .{ ".cr", .crystal },            .{ ".gd", .gdscript },
            .{ ".lua", .lua },             .{ ".luau", .lua },              .{ ".tcl", .tcl },
            .{ ".coffee", .coffeescript }, .{ ".hs", .haskell },            .{ ".lhs", .haskell },
            .{ ".elm", .elm },             .{ ".ml", .ocaml },              .{ ".mli", .ocaml },
            .{ ".fs", .fsharp },           .{ ".fsi", .fsharp },            .{ ".fsx", .fsharp },
            .{ ".lisp", .lisp },           .{ ".lsp", .lisp },              .{ ".cl", .lisp },
            .{ ".el", .lisp },             .{ ".scm", .lisp },              .{ ".ss", .lisp },
            .{ ".rkt", .lisp },            .{ ".clj", .clojure },           .{ ".cljs", .clojure },
            .{ ".cljc", .clojure },        .{ ".edn", .clojure },           .{ ".sql", .sql },
            .{ ".mk", .makefile },         .{ ".dockerfile", .dockerfile }, .{ ".cmake", .cmake },
            .{ ".tf", .hcl },              .{ ".tfvars", .hcl },            .{ ".hcl", .hcl },
            .{ ".nix", .nix },             .{ ".f90", .fortran },           .{ ".f95", .fortran },
            .{ ".f03", .fortran },         .{ ".f", .fortran },             .{ ".for", .fortran },
            .{ ".pas", .pascal },          .{ ".pp", .pascal },             .{ ".dpr", .pascal },
            .{ ".adb", .ada },             .{ ".ads", .ada },               .{ ".vhd", .vhdl },
            .{ ".vhdl", .vhdl },           .{ ".vb", .vb },                 .{ ".vbs", .vb },
            .{ ".bas", .vb },              .{ ".asm", .assembly },          .{ ".s", .assembly },
            .{ ".nasm", .assembly },       .{ ".tex", .tex },               .{ ".sty", .tex },
            .{ ".cls", .tex },             .{ ".bib", .tex },
        };
        for (table) |entry| {
            if (std.ascii.eqlIgnoreCase(ext, entry[0])) return entry[1];
        }
        return .plain;
    }

    /// Like `fromPath`, but looks at the content when the name isn't
    /// enough: other `.lock` files are JSON, TOML or YAML.
    pub fn detect(path: []const u8, content: []const u8) Language {
        const by_name = fromPath(path);
        if (by_name != .plain or !std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".lock")) return by_name;
        const text = std.mem.trimStart(u8, content, " \t\r\n");
        if (text.len == 0) return .plain;
        // `{`, or a `[` that opens a JSON array rather than a TOML table.
        const head = text[0..@min(text.len, 200)];
        const json_array = text[0] == '[' and std.mem.indexOfScalar(u8, head, '"') != null and std.mem.indexOfScalar(u8, head, '=') == null;
        if (text[0] == '{' or json_array) return .json;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0 or t[0] == '#') continue;
            if (t[0] == '[' or std.mem.indexOf(u8, t, " = ") != null) return .toml;
            return .yaml;
        }
        return .plain;
    }
};

/// Lexer state at a line boundary, for whichever language is in use.
pub const State = union(enum) {
    plain,
    js: js.State,
    json: json.State,
    css: css.State,
    html: html.State,
    markdown: markdown.State,
    python: python.State,
    toml: toml.State,
    yaml: yaml.State,
    dotenv: config.DotenvState,
    ignore,
    clike: clike.State,
    diff,
    generic: generic.State,

    fn initial(language: Language) State {
        return switch (language) {
            .plain => .plain,
            .typescript => .{ .js = .{} },
            .jsx => .{ .js = .{ .jsx = true } },
            .json => .{ .json = .{} },
            .css, .scss => .{ .css = .{} },
            .html, .xml => .{ .html = .{} },
            .markdown => .{ .markdown = .{} },
            .python => .{ .python = .{} },
            .toml => .{ .toml = .{} },
            .yaml, .yarn_lock => .{ .yaml = .{} },
            .dotenv => .{ .dotenv = .{} },
            .ignore => .ignore,
            .go, .rust, .zig => .{ .clike = .{} },
            .diff => .diff,
            else => .{ .generic = .{} },
        };
    }
};

language: Language,
/// State at the start of each line.
line_states: std.ArrayList(State) = .empty,
/// Buffer version (and language) the cache was built for.
version: ?u64 = null,
built_for: Language = .plain,

pub fn init(language: Language) Highlighter {
    return .{ .language = language };
}

pub fn deinit(self: *Highlighter, gpa: std.mem.Allocator) void {
    self.line_states.deinit(gpa);
}

pub fn update(self: *Highlighter, gpa: std.mem.Allocator, buf: *const Buffer) !void {
    if (self.version == buf.version and self.built_for == self.language) return;
    self.line_states.clearRetainingCapacity();
    var state = State.initial(self.language);
    var lines = std.mem.splitScalar(u8, buf.items(), '\n');
    while (lines.next()) |line| {
        try self.line_states.append(gpa, state);
        var t = Tokens.init(self.language, line, state);
        while (t.next()) |_| {}
        state = t.endState();
    }
    self.version = buf.version;
    self.built_for = self.language;
}

/// Tokens of line number `index`, whose text is `line`.
pub fn tokens(self: *const Highlighter, index: usize, line: []const u8) Tokens {
    const cached = index < self.line_states.items.len and self.built_for == self.language;
    const state = if (cached) self.line_states.items[index] else State.initial(self.language);
    return .init(self.language, line, state);
}

/// Iterates a line's tokens with the right lexer for the language.
pub const Tokens = struct {
    lexer: union(enum) {
        plain: struct { line: []const u8, done: bool = false },
        js: js.Lexer,
        json: json.Lexer,
        css: css.Lexer,
        html: html.Lexer,
        markdown: markdown.Lexer,
        python: python.Lexer,
        toml: toml.Lexer,
        yaml: yaml.Lexer,
        dotenv: config.DotenvLexer,
        ignore: config.IgnoreLexer,
        clike: clike.Lexer,
        diff: config.DiffLexer,
        generic: generic.Lexer,
    },

    pub fn init(language: Language, line: []const u8, state: State) Tokens {
        return .{ .lexer = switch (state) {
            .plain => .{ .plain = .{ .line = line } },
            .js => |s| .{ .js = .init(line, s) },
            .json => |s| .{ .json = .init(line, s) },
            .css => |s| .{ .css = .init(line, s, if (language == .css) .css else .scss) },
            .html => |s| .{ .html = .init(line, s, language == .xml) },
            .markdown => |s| .{ .markdown = .init(line, s) },
            .python => |s| .{ .python = .init(line, s) },
            .toml => |s| .{ .toml = .init(line, s) },
            .yaml => |s| .{ .yaml = .init(line, s, language == .yarn_lock) },
            .dotenv => |s| .{ .dotenv = .init(line, s) },
            .ignore => .{ .ignore = .init(line) },
            .clike => |s| .{ .clike = .init(line, s, language.clikeDialect() orelse .go) },
            .diff => .{ .diff = .init(line) },
            .generic => |s| .{ .generic = .init(line, s, language.genericDialect() orelse .c) },
        } };
    }

    pub fn next(self: *Tokens) ?token.Span {
        switch (self.lexer) {
            .plain => |*p| {
                if (p.done or p.line.len == 0) return null;
                p.done = true;
                return .{ .start = 0, .end = p.line.len, .kind = .plain };
            },
            inline else => |*l| return l.next(),
        }
    }

    /// State after the line, once `next` has returned null.
    pub fn endState(self: *const Tokens) State {
        return switch (self.lexer) {
            .plain => .plain,
            .js => |l| .{ .js = l.state },
            .json => |l| .{ .json = l.state },
            .css => |l| .{ .css = l.state },
            .html => |l| .{ .html = l.state },
            .markdown => |l| .{ .markdown = l.state },
            .python => |l| .{ .python = l.state },
            .toml => |l| .{ .toml = l.state },
            .yaml => |l| .{ .yaml = l.state },
            .dotenv => |l| .{ .dotenv = l.state },
            .ignore => .ignore,
            .clike => |l| .{ .clike = l.state },
            .diff => .diff,
            .generic => |l| .{ .generic = l.state },
        };
    }
};

test {
    _ = @import("tests/Highlighter_test.zig");
}
