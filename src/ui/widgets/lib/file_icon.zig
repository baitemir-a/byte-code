//! File-type icons from the icon pack (assets/icon-pack): picked by file
//! name (Makefile, package.json, README.md, ...), else by extension, else a
//! plain page. Each SVG is rasterized with nanosvg (svg.c) the first time
//! it's drawn, for the display's density and the zoom, so it stays sharp;
//! the dark theme uses an icon's `_dark` variant where the pack has one.
const std = @import("std");
const rl = @import("raylib");
const theme = @import("../../theme/lib/theme.zig");

/// Width and height of an icon, in UI units (the pack draws on 16x16).
pub const size: f32 = 16;

/// What a file shows in front of its name (Settings): the same plain
/// page for every file, the icon for its type, or nothing at all.
pub const Mode = enum { same, by_type, none };
pub var mode: Mode = .by_type;

/// Room a row leaves in front of a name: the icon and the gap after it,
/// or nothing when icons are off.
pub fn space() f32 {
    return if (mode == .none) 0 else size + 8;
}

/// The pack's icons that are used, by file name without `.svg`.
const Icon = enum {
    file,
    // Languages
    ada,
    ahk,
    applescript,
    @"asm",
    astro,
    c,
    clojure,
    cmake,
    cobol,
    coffeescript,
    cpp,
    crystal,
    csharp,
    css,
    dart,
    dlang,
    elm,
    erlang,
    ex,
    fish,
    fortran,
    fsharp,
    gleam,
    go,
    godot,
    graphql,
    groovy,
    haskell,
    haxe,
    hh,
    hlsl,
    html,
    java,
    js,
    json,
    json5,
    jsx,
    julia,
    jupyter,
    kotlin,
    kotlinscript,
    less,
    lisp,
    livescript,
    lua,
    markdown,
    mdx,
    nim,
    nix,
    objc,
    ocaml,
    odin,
    pascal,
    perl,
    php,
    powershell,
    prisma,
    protobuf,
    purescript,
    python,
    r,
    racket,
    react,
    reason,
    rescript,
    ruby,
    rust,
    sass,
    scala,
    scheme,
    scss,
    shader,
    shell,
    solidity,
    sql,
    stylus,
    svelte,
    swift,
    tcl,
    terraform,
    hcl,
    toml,
    typeScript,
    typings,
    v,
    vb,
    verilog,
    vhdl,
    vim,
    emacslisp,
    vue,
    wgsl,
    metal,
    webassembly,
    xml,
    xsd,
    yaml,
    zig,
    // Templates
    ejs,
    erb,
    liquid,
    mustache,
    pug,
    twig,
    // Documents and data
    csv,
    db,
    diff,
    patch,
    log,
    pdf,
    rst,
    tex,
    text,
    subtitle,
    excel,
    word,
    powerpoint,
    http,
    plist,
    config,
    lock,
    msdos,
    // Media and binaries
    archive,
    audio,
    video,
    font,
    png,
    jpg,
    gif,
    webp,
    bmp,
    avif,
    favicon,
    svg,
    psd,
    ai,
    figma,
    binary,
    dll,
    dylib,
    lib,
    certificate,
    key,
    apk,
    iso,
    // Particular files
    makefile,
    docker,
    dockercompose,
    dockerignore,
    git,
    gitignore,
    gitlab,
    npm,
    npmlock,
    npmignore,
    yarn,
    yarnlock,
    pnpm,
    bun,
    bunlock,
    deno,
    denolock,
    tsconfig,
    jsconfig,
    cargo,
    rusttoolchain,
    goconfig,
    readme,
    license,
    unlicense,
    changelog,
    authors,
    contributors,
    codeowners,
    todo,
    editorconfig,
    prettier,
    prettierignore,
    eslint,
    eslintignore,
    vite,
    vitest,
    webpack,
    rollup,
    tailwindcss,
    postcss,
    babel,
    jest,
    nextjs,
    nuxt,
    svelte_config,
    astroconfig,
    gemfile,
    rakefile,
    procfile,
    justfile,
    cmakelists,
    pythonconfig,
    pipfile,
    pipfilelock,
    pythonversion,
    pypi,
    nvm,
    nodeversion,
    vercel,
    netlify,
    travis,
    htaccess,
    nginx,
    robots,
    cocoapods,
    vagrant,
    jenkins,
    mkdocs,
    turborepo,
    renovate,
    firebase,
    serverless,
    composer,
    composerlock,
    bower,
};

/// Icons with a `_dark` variant, for the dark theme.
const has_dark = [_]Icon{ .css, .config, .diff, .readme, .svg, .justfile, .deno, .bun, .vercel };

const pack = "../../../assets/icon-pack/";
const Svgs = struct { light: []const u8, dark: []const u8 };
const svgs = blk: {
    const fields = @typeInfo(Icon).@"enum".fields;
    var list: [fields.len]Svgs = undefined;
    @setEvalBranchQuota(100_000);
    for (fields, 0..) |f, i| {
        const light = @embedFile(pack ++ f.name ++ ".svg");
        const dark = for (has_dark) |d| {
            if (@intFromEnum(d) == i) break @embedFile(pack ++ f.name ++ "_dark.svg");
        } else light;
        list[i] = .{ .light = light, .dark = dark };
    }
    break :blk list;
};

/// Whole file names (lowercase), checked first.
const by_name = std.StaticStringMap(Icon).initComptime(.{
    .{ "package.json", .npm },            .{ "package-lock.json", .npmlock },
    .{ "npm-shrinkwrap.json", .npmlock }, .{ "yarn.lock", .yarnlock },
    .{ "pnpm-lock.yaml", .pnpm },         .{ "pnpm-workspace.yaml", .pnpm },
    .{ "bun.lock", .bunlock },            .{ "bun.lockb", .bunlock },
    .{ "bunfig.toml", .bun },             .{ "deno.lock", .denolock },
    .{ "cargo.toml", .cargo },            .{ "cargo.lock", .cargo },
    .{ "go.mod", .goconfig },             .{ "go.sum", .goconfig },
    .{ "go.work", .goconfig },            .{ "pipfile.lock", .pipfilelock },
    .{ "requirements.txt", .pypi },       .{ "flake.lock", .nix },
    .{ "composer.lock", .composerlock },  .{ "turbo.json", .turborepo },
});

/// File names without their extension (lowercase): README.md, vite.config.ts,
/// .eslintrc.json, .env.local, ...
const by_stem = std.StaticStringMap(Icon).initComptime(.{
    .{ "makefile", .makefile },              .{ "gnumakefile", .makefile },
    .{ "dockerfile", .docker },              .{ "containerfile", .docker },
    .{ "docker-compose", .dockercompose },   .{ "compose", .dockercompose },
    .{ ".dockerignore", .dockerignore },     .{ ".gitignore", .gitignore },
    .{ ".gitattributes", .git },             .{ ".gitmodules", .git },
    .{ ".gitkeep", .git },                   .{ ".mailmap", .git },
    .{ ".gitlab-ci", .gitlab },              .{ ".npmrc", .npm },
    .{ ".npmignore", .npmignore },           .{ ".yarnrc", .yarn },
    .{ "deno", .deno },                      .{ "tsconfig", .tsconfig },
    .{ "jsconfig", .jsconfig },              .{ "rust-toolchain", .rusttoolchain },
    .{ "readme", .readme },                  .{ "license", .license },
    .{ "licence", .license },                .{ "copying", .license },
    .{ "unlicense", .unlicense },            .{ "changelog", .changelog },
    .{ "changes", .changelog },              .{ "authors", .authors },
    .{ "contributors", .contributors },      .{ "codeowners", .codeowners },
    .{ "todo", .todo },                      .{ ".editorconfig", .editorconfig },
    .{ ".prettierrc", .prettier },           .{ "prettier.config", .prettier },
    .{ ".prettierignore", .prettierignore }, .{ ".eslintrc", .eslint },
    .{ "eslint.config", .eslint },           .{ ".eslintignore", .eslintignore },
    .{ "vite.config", .vite },               .{ "vitest.config", .vitest },
    .{ "webpack.config", .webpack },         .{ "rollup.config", .rollup },
    .{ "tailwind.config", .tailwindcss },    .{ "postcss.config", .postcss },
    .{ "babel.config", .babel },             .{ ".babelrc", .babel },
    .{ "jest.config", .jest },               .{ "next.config", .nextjs },
    .{ "nuxt.config", .nuxt },               .{ "svelte.config", .svelte_config },
    .{ "astro.config", .astroconfig },       .{ "gemfile", .gemfile },
    .{ "rakefile", .rakefile },              .{ "procfile", .procfile },
    .{ "justfile", .justfile },              .{ ".justfile", .justfile },
    .{ "cmakelists", .cmakelists },          .{ "pyproject", .pythonconfig },
    .{ "pipfile", .pipfile },                .{ ".python-version", .pythonversion },
    .{ ".nvmrc", .nvm },                     .{ ".node-version", .nodeversion },
    .{ "vercel", .vercel },                  .{ "netlify", .netlify },
    .{ ".travis", .travis },                 .{ ".htaccess", .htaccess },
    .{ "nginx", .nginx },                    .{ "robots", .robots },
    .{ "podfile", .cocoapods },              .{ "vagrantfile", .vagrant },
    .{ "jenkinsfile", .jenkins },            .{ "mkdocs", .mkdocs },
    .{ "renovate", .renovate },              .{ "firebase", .firebase },
    .{ "serverless", .serverless },          .{ "composer", .composer },
    .{ "bower", .bower },                    .{ ".env", .config },
    .{ ".clang-format", .config },           .{ ".bashrc", .shell },
    .{ ".bash_profile", .shell },            .{ ".zshrc", .shell },
    .{ ".zprofile", .shell },                .{ ".profile", .shell },
    .{ ".vimrc", .vim },
});

/// Extensions (lowercase, with the dot).
const by_extension = std.StaticStringMap(Icon).initComptime(.{
    .{ ".zig", .zig },           .{ ".zon", .zig },
    .{ ".c", .c },               .{ ".h", .hh },
    .{ ".cpp", .cpp },           .{ ".cc", .cpp },
    .{ ".cxx", .cpp },           .{ ".c++", .cpp },
    .{ ".hpp", .hh },            .{ ".hh", .hh },
    .{ ".hxx", .hh },            .{ ".m", .objc },
    .{ ".mm", .objc },           .{ ".cs", .csharp },
    .{ ".java", .java },         .{ ".jar", .java },
    .{ ".kt", .kotlin },         .{ ".kts", .kotlinscript },
    .{ ".swift", .swift },       .{ ".go", .go },
    .{ ".rs", .rust },           .{ ".py", .python },
    .{ ".pyw", .python },        .{ ".pyi", .python },
    .{ ".ipynb", .jupyter },     .{ ".rb", .ruby },
    .{ ".php", .php },           .{ ".js", .js },
    .{ ".mjs", .js },            .{ ".cjs", .js },
    .{ ".jsx", .jsx },           .{ ".ts", .typeScript },
    .{ ".mts", .typeScript },    .{ ".cts", .typeScript },
    .{ ".tsx", .react },         .{ ".vue", .vue },
    .{ ".svelte", .svelte },     .{ ".astro", .astro },
    .{ ".html", .html },         .{ ".htm", .html },
    .{ ".xhtml", .html },        .{ ".css", .css },
    .{ ".scss", .scss },         .{ ".sass", .sass },
    .{ ".less", .less },         .{ ".styl", .stylus },
    .{ ".json", .json },         .{ ".jsonc", .json },
    .{ ".jsonl", .json },        .{ ".json5", .json5 },
    .{ ".yaml", .yaml },         .{ ".yml", .yaml },
    .{ ".toml", .toml },         .{ ".xml", .xml },
    .{ ".xsd", .xsd },           .{ ".xsl", .xml },
    .{ ".plist", .plist },       .{ ".svg", .svg },
    .{ ".md", .markdown },       .{ ".markdown", .markdown },
    .{ ".mdx", .mdx },           .{ ".rst", .rst },
    .{ ".tex", .tex },           .{ ".txt", .text },
    .{ ".log", .log },           .{ ".csv", .csv },
    .{ ".tsv", .csv },           .{ ".sql", .sql },
    .{ ".db", .db },             .{ ".sqlite", .db },
    .{ ".sqlite3", .db },        .{ ".sh", .shell },
    .{ ".bash", .shell },        .{ ".zsh", .shell },
    .{ ".fish", .fish },         .{ ".ps1", .powershell },
    .{ ".psm1", .powershell },   .{ ".bat", .msdos },
    .{ ".cmd", .msdos },         .{ ".lua", .lua },
    .{ ".dart", .dart },         .{ ".ex", .ex },
    .{ ".exs", .ex },            .{ ".erl", .erlang },
    .{ ".hrl", .erlang },        .{ ".hs", .haskell },
    .{ ".ml", .ocaml },          .{ ".mli", .ocaml },
    .{ ".fs", .fsharp },         .{ ".fsx", .fsharp },
    .{ ".clj", .clojure },       .{ ".cljs", .clojure },
    .{ ".cljc", .clojure },      .{ ".edn", .clojure },
    .{ ".scala", .scala },       .{ ".sc", .scala },
    .{ ".r", .r },               .{ ".jl", .julia },
    .{ ".nim", .nim },           .{ ".nix", .nix },
    .{ ".odin", .odin },         .{ ".v", .v },
    .{ ".sv", .verilog },        .{ ".vhd", .vhdl },
    .{ ".vhdl", .vhdl },         .{ ".asm", .@"asm" },
    .{ ".s", .@"asm" },          .{ ".wasm", .webassembly },
    .{ ".wat", .webassembly },   .{ ".graphql", .graphql },
    .{ ".gql", .graphql },       .{ ".proto", .protobuf },
    .{ ".tf", .terraform },      .{ ".tfvars", .terraform },
    .{ ".hcl", .hcl },           .{ ".dockerfile", .docker },
    .{ ".gradle", .groovy },     .{ ".groovy", .groovy },
    .{ ".pl", .perl },           .{ ".pm", .perl },
    .{ ".elm", .elm },           .{ ".cr", .crystal },
    .{ ".d", .dlang },           .{ ".gleam", .gleam },
    .{ ".hx", .haxe },           .{ ".pug", .pug },
    .{ ".jade", .pug },          .{ ".ejs", .ejs },
    .{ ".erb", .erb },           .{ ".hbs", .mustache },
    .{ ".mustache", .mustache }, .{ ".twig", .twig },
    .{ ".liquid", .liquid },     .{ ".glsl", .shader },
    .{ ".vert", .shader },       .{ ".frag", .shader },
    .{ ".hlsl", .hlsl },         .{ ".wgsl", .wgsl },
    .{ ".metal", .metal },       .{ ".cmake", .cmake },
    .{ ".mk", .makefile },       .{ ".diff", .diff },
    .{ ".patch", .patch },       .{ ".lock", .lock },
    .{ ".ini", .config },        .{ ".cfg", .config },
    .{ ".conf", .config },       .{ ".properties", .config },
    .{ ".env", .config },        .{ ".vim", .vim },
    .{ ".el", .emacslisp },      .{ ".sol", .solidity },
    .{ ".prisma", .prisma },     .{ ".gd", .godot },
    .{ ".ahk", .ahk },           .{ ".applescript", .applescript },
    .{ ".vb", .vb },             .{ ".tcl", .tcl },
    .{ ".ada", .ada },           .{ ".adb", .ada },
    .{ ".ads", .ada },           .{ ".f90", .fortran },
    .{ ".f", .fortran },         .{ ".cob", .cobol },
    .{ ".pas", .pascal },        .{ ".lisp", .lisp },
    .{ ".scm", .scheme },        .{ ".rkt", .racket },
    .{ ".purs", .purescript },   .{ ".res", .rescript },
    .{ ".re", .reason },         .{ ".coffee", .coffeescript },
    .{ ".ls", .livescript },     .{ ".http", .http },
    .{ ".rest", .http },         .{ ".srt", .subtitle },
    .{ ".vtt", .subtitle },      .{ ".pdf", .pdf },
    .{ ".doc", .word },          .{ ".docx", .word },
    .{ ".xls", .excel },         .{ ".xlsx", .excel },
    .{ ".ppt", .powerpoint },    .{ ".pptx", .powerpoint },
    .{ ".png", .png },           .{ ".jpg", .jpg },
    .{ ".jpeg", .jpg },          .{ ".gif", .gif },
    .{ ".webp", .webp },         .{ ".bmp", .bmp },
    .{ ".avif", .avif },         .{ ".ico", .favicon },
    .{ ".icns", .favicon },      .{ ".psd", .psd },
    .{ ".ai", .ai },             .{ ".fig", .figma },
    .{ ".zip", .archive },       .{ ".tar", .archive },
    .{ ".gz", .archive },        .{ ".tgz", .archive },
    .{ ".xz", .archive },        .{ ".bz2", .archive },
    .{ ".zst", .archive },       .{ ".7z", .archive },
    .{ ".rar", .archive },       .{ ".mp3", .audio },
    .{ ".wav", .audio },         .{ ".ogg", .audio },
    .{ ".flac", .audio },        .{ ".m4a", .audio },
    .{ ".mp4", .video },         .{ ".mov", .video },
    .{ ".mkv", .video },         .{ ".webm", .video },
    .{ ".avi", .video },         .{ ".ttf", .font },
    .{ ".otf", .font },          .{ ".woff", .font },
    .{ ".woff2", .font },        .{ ".exe", .binary },
    .{ ".bin", .binary },        .{ ".o", .binary },
    .{ ".a", .lib },             .{ ".so", .lib },
    .{ ".dll", .dll },           .{ ".dylib", .dylib },
    .{ ".pem", .certificate },   .{ ".crt", .certificate },
    .{ ".cer", .certificate },   .{ ".key", .key },
    .{ ".apk", .apk },           .{ ".iso", .iso },
});

fn iconFor(name: []const u8) Icon {
    if (mode != .by_type) return .file;
    var buf: [128]u8 = undefined;
    if (name.len > buf.len) return by_extension.get(lower(&buf, std.fs.path.extension(name))) orelse .file;
    const n = lower(&buf, name);
    if (by_name.get(n)) |icon| return icon;
    if (by_stem.get(std.fs.path.stem(n))) |icon| return icon;
    if (std.mem.endsWith(u8, n, ".d.ts")) return .typings;
    return by_extension.get(std.fs.path.extension(n)) orelse .file;
}

fn lower(buf: []u8, s: []const u8) []const u8 {
    const n = @min(s.len, buf.len);
    return std.ascii.lowerString(buf[0..n], s[0..n]);
}

/// Rasterized icons, made on first use and remade when the pixel size or
/// the theme changes.
const Rendered = struct { texture: rl.Texture2D, px: i32, dark: bool };
var rendered: [svgs.len]?Rendered = @splat(null);

extern fn svgRasterize(data: [*]const u8, len: usize, px: c_int) ?[*]u8;
extern fn svgFree(pixels: [*]u8) void;

fn texture(icon: Icon, px: i32, dark: bool) ?rl.Texture2D {
    const slot = &rendered[@intFromEnum(icon)];
    if (slot.*) |r| {
        if (r.px == px and r.dark == dark) return r.texture;
        rl.unloadTexture(r.texture);
        slot.* = null;
    }
    const svg = if (dark) svgs[@intFromEnum(icon)].dark else svgs[@intFromEnum(icon)].light;
    const pixels = svgRasterize(svg.ptr, svg.len, px) orelse return null;
    defer svgFree(pixels);
    const image: rl.Image = .{ .data = pixels, .width = px, .height = px, .mipmaps = 1, .format = .uncompressed_r8g8b8a8 };
    const t = rl.loadTextureFromImage(image) catch return null;
    rl.setTextureFilter(t, .bilinear);
    slot.* = .{ .texture = t, .px = px, .dark = dark };
    return t;
}

/// Draws the icon for file `name` centered at `center`, on whole screen
/// pixels.
pub fn draw(name: []const u8, center: rl.Vector2) void {
    if (mode == .none) return;
    // Screen pixels per UI unit: display density times zoom.
    const scale = @max(1, rl.getWindowScaleDPI().x) * theme.zoom;
    const px: i32 = @intFromFloat(@round(size * scale));
    const t = texture(iconFor(name), px, theme.mode == .dark) orelse return;
    const pixel = 1 / scale;
    const dest: rl.Rectangle = .{
        .x = @round((center.x - size / 2) / pixel) * pixel,
        .y = @round((center.y - size / 2) / pixel) * pixel,
        .width = size,
        .height = size,
    };
    const side: f32 = @floatFromInt(px);
    rl.drawTexturePro(t, .{ .x = 0, .y = 0, .width = side, .height = side }, dest, .{ .x = 0, .y = 0 }, 0, rl.Color.white);
}

/// Frees the rasterized icons (before the window closes).
pub fn unload() void {
    for (&rendered) |*slot| if (slot.*) |r| {
        rl.unloadTexture(r.texture);
        slot.* = null;
    };
}

test "icons by name, then stem, then extension" {
    try std.testing.expectEqual(Icon.zig, iconFor("main.zig"));
    try std.testing.expectEqual(Icon.npm, iconFor("package.json"));
    try std.testing.expectEqual(Icon.readme, iconFor("README.md"));
    try std.testing.expectEqual(Icon.makefile, iconFor("Makefile"));
    try std.testing.expectEqual(Icon.vite, iconFor("vite.config.ts"));
    try std.testing.expectEqual(Icon.gitignore, iconFor(".gitignore"));
    try std.testing.expectEqual(Icon.config, iconFor(".env.local"));
    try std.testing.expectEqual(Icon.typings, iconFor("index.d.ts"));
    try std.testing.expectEqual(Icon.python, iconFor("SCRIPT.PY"));
    try std.testing.expectEqual(Icon.file, iconFor("notes"));
}
