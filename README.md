# byte code

A lightweight code editor written in [Zig](https://ziglang.org) with
[raylib](https://www.raylib.com). One small native executable (about 1.5 MB
zipped), no Electron, no runtime.

## Features

- **Editing** — multiple tabs, undo/redo, selection with keyboard and mouse,
  word-wise movement, auto-closing brackets and quotes, auto-indent, tab
  stops, UTF-8 (Latin, Cyrillic, Greek…)
- **Syntax highlighting** — JavaScript/TypeScript, JSON, HTML, XML, CSS/SCSS/
  Sass/Less, Markdown (with highlighted code blocks), Python, Go, Rust, Zig,
  TOML, YAML, `.env`, `.gitignore`, lock files
- **Completion** — suggestions as you type from the file's own words and
  language keywords, fuzzy matched
- **Find and replace** in a file; **search across the project**
- **Projects** — open a folder to get a file tree: create, rename, delete
  (to the Trash) and drag-and-drop to move files and folders
- **Go to file** (Cmd+P) by fuzzy name
- **Git** — branch, changed files, stage/unstage, commit
- **Integrated terminal** — your shell on a real pseudo-terminal, with
  colors, scrollback and full-screen programs (vim, htop)
- **Minimap**, line numbers, current-line highlight
- **Settings** — dark/light theme, accent color, auto save, zoom, minimap,
  opening folders in a new window

## Keyboard shortcuts

On macOS use Cmd; on Windows and Linux use Ctrl.

| Shortcut | Action |
|---|---|
| Cmd+O / Cmd+Shift+O | Open file / open folder |
| Cmd+N | New file |
| Cmd+S / Cmd+Shift+S | Save / save as |
| Cmd+W | Close tab |
| Option+Tab / Option+Shift+Tab | Next / previous tab (also Ctrl+Tab) |
| Cmd+P | Go to file |
| Cmd+F / Cmd+Option+F | Find / find and replace (Ctrl+H on Windows/Linux) |
| Cmd+G / Cmd+Shift+G | Next / previous match |
| Cmd+Shift+F | Search in project |
| Cmd+Shift+E | Explorer |
| Ctrl+Shift+G | Git |
| Cmd+B | Toggle sidebar |
| Cmd+K | Close folder (clears the screen in the terminal) |
| Cmd+T | Terminal (also Ctrl+`) |
| Ctrl+Space | Show suggestions |
| Cmd+, | Settings |
| Cmd+= / Cmd+- / Cmd+0 | Zoom in / out / reset |

The Welcome tab lists these too.

## Building

Requires **Zig 0.16**. Dependencies (raylib, raylib-zig) are fetched
automatically from `build.zig.zon`.

```bash
zig build run                      # build and run
zig build run -- path/to/folder    # open a folder (or a file)
zig build test                     # run the tests
zig build -Doptimize=ReleaseSafe   # optimized build in zig-out/bin/rl
```

On Linux, raylib needs the X11 and OpenGL development packages, e.g. on
Debian/Ubuntu:

```bash
sudo apt install libx11-dev libxrandr-dev libxinerama-dev libxi-dev libxcursor-dev libgl-dev
```

### Release packages

`scripts/package.sh` (on a Mac) builds shareable packages into `dist/`:

- `byte-code-macos.zip` — `byte code.app`, universal (Apple Silicon + Intel), macOS 13+
- `byte-code-windows.zip` — `byte-code.exe`, x86_64
- `byte-code-linux-x86_64.tar.gz` — glibc 2.31+, built in Docker
  (`scripts/linux/Dockerfile`); skipped if Docker isn't running

The apps aren't signed with a developer certificate, so macOS and Windows
show a warning the first time; `scripts/README.txt` (shipped in each
package) explains how to open them.

## Platform notes

- **macOS** and **Linux**: everything works. On Linux, the file dialogs use
  `zenity` and deleting to the Trash uses `gio`.
- **Windows**: builds, but is the least tested platform. The terminal and
  the native file dialogs aren't available yet — open files and folders by
  dropping them onto the window.

## Settings

Stored as JSON, and editable by hand:

- macOS: `~/Library/Application Support/byte-code/settings.json`
- Linux: `~/.config/byte-code/settings.json` (or `$XDG_CONFIG_HOME`)
- Windows: `%APPDATA%\byte-code\settings.json`

## Project layout

```
src/
  main.zig          window setup and the frame loop
  App.zig           ties everything together: tabs, input routing, drawing
  Tab.zig           one open tab (file, welcome page or settings)
  Terminal.zig      the integrated terminal: shell + screen
  core/             editor logic, no graphics — unit tested
    Buffer.zig        text, cursor, selection, undo (History.zig)
    edit.zig          smart editing (auto-close, indent)
    motion.zig        cursor movement
    Document.zig      loading and saving files
    FileTree.zig      the project tree; create/rename/move/delete
    FileSearch.zig    go to file · ProjectSearch.zig  search in files
    Search.zig        find in a file · Git.zig  git status/stage/commit
    Settings.zig      settings.json
    syntax/           one lexer per language, and the Highlighter
    completion/       suggestions and fuzzy matching
    terminal/         the terminal emulator (xterm escape sequences)
  ui/               drawing: editor view, sidebar, tabs, panels, theme
  input/            keyboard and mouse → commands
  platform/         OS specifics: dialogs, pseudo-terminals, paths
scripts/            release packaging
```

## License notes

The executable includes the DejaVu Sans Mono font (used when no suitable
system font is found); see `src/ui/fonts/DejaVu-LICENSE.txt`.
