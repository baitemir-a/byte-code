# byte code

A lightweight code editor written in [Zig](https://ziglang.org) with
[raylib](https://www.raylib.com). One small native executable (2–3 MB
zipped), no Electron, no runtime.

## Download

| Platform | Download |
|---|---|
| macOS 13+ (Apple Silicon and Intel) | [byte-code-macos.zip](https://github.com/baitemir-a/byte-code/releases/latest/download/byte-code-macos.zip) |
| Windows (x86_64) | [byte-code-windows.zip](https://github.com/baitemir-a/byte-code/releases/latest/download/byte-code-windows.zip) |
| Linux (x86_64, glibc 2.31+) | [byte-code-linux-x86_64.tar.gz](https://github.com/baitemir-a/byte-code/releases/latest/download/byte-code-linux-x86_64.tar.gz) |

All versions are on the [Releases](https://github.com/baitemir-a/byte-code/releases) page.

The apps aren't signed with an Apple or Microsoft developer certificate, so
the system warns the first time you open them:

- **macOS** says Apple can't check the app for malicious software. Click
  **Done** (not "Move to Trash"), then open **System Settings → Privacy &
  Security**, scroll down to the message about "byte code" and click **Open
  Anyway**. Or run this in Terminal once:
  ```bash
  xattr -dr com.apple.quarantine "/Applications/byte code.app"
  ```
- **Windows** SmartScreen: click **More info → Run anyway**.

## Features

- **Editing** — multiple tabs, undo/redo, selection with keyboard and mouse,
  word-wise movement, auto-closing brackets and quotes, auto-indent, tab
  stops, UTF-8 (Latin, Cyrillic, Greek…)
- **Syntax highlighting** — JavaScript/TypeScript (including JSX and TSX
  markup), JSON, HTML, XML, CSS/SCSS/Sass/Less, Markdown (with highlighted
  code blocks), Python, Go, Rust, Zig, TOML, YAML, `.env`, `.gitignore`,
  lock files
- **Multiple cursors** — Option+click (Alt+click) to add cursors,
  Option+Shift+click for a column of them; typing, deleting, moving and
  copy/paste work at all of them
- **Move lines** up and down with Option+Up / Down
- **Select scope** — grow the selection word → line → inside brackets or
  quotes → the brackets themselves → …, and back
- **Completion** — suggestions as you type from the file's own words and
  language keywords, fuzzy matched
- **Find and replace** in a file and **across the project** — match case
  and whole word options; replace one match, one file or everything
- **Projects** — open a folder to get a file tree: create, rename, delete
  (to the Trash) and drag-and-drop to move files and folders
- **Recent and favorite folders** — the welcome tab lists the folders you
  opened before; the star on a row keeps one at the top as a favorite, and
  favorites never fall off the end of the history
- **Go to file** (Cmd+P) by fuzzy name
- **Go to declaration** — Ctrl+click (Cmd+click) a name to jump to where it
  is declared; click the declaration itself to list where it is used. It
  reads the shape of the code, not a language server, so it is a good guess
  rather than an answer
- **Git** — branch, changed files, stage/unstage, commit
- **Integrated terminal** — your shell on a real pseudo-terminal, with
  colors, scrollback and full-screen programs (vim, htop)
- **Word wrap** (Option+Z) — long lines break to fit the window
- **Minimap**, line numbers, current-line highlight
- **12 languages** — English, Russian, German, Kyrgyz, Turkish, Spanish,
  Chinese, Japanese, French, Italian, Portuguese and Korean, switched in
  Settings
- **Settings** — language, dark/light theme, accent color, auto save, zoom,
  minimap, word wrap, opening folders in a new window
- **Keyboard shortcuts you can change** — the Help tab lists every
  combination, from Save to Select Word Left, and rebinds any of them

## Keyboard shortcuts

On macOS use Cmd; on Windows and Linux use Ctrl.

| Shortcut | Action |
|---|---|
| Cmd+O / Cmd+Shift+O | Open file / open folder |
| Cmd+N | New file |
| Cmd+S / Cmd+Shift+S | Save / save as |
| Cmd+W | Close tab |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous tab (also Option+Tab, Cmd+Shift+[ / ]) |
| Cmd+P | Go to file |
| Double-click / triple-click | Select the word / the whole line (keep dragging to select by word or line) |
| Ctrl+click (Cmd+click) | Go to where the clicked name is declared; on the declaration, a menu of where it is used |
| Option+click | Add a cursor (click it again to remove it); Esc goes back to one |
| Option+Shift+click | A cursor on every line from the cursor to the click, in that column (drag sideways for a box selection) |
| Option+Z | Word wrap on / off (Alt+Z on Windows and Linux) |
| Option+Up / Down | Move the line (or selected lines) up / down |
| Option+Shift+Up / Down | Select the enclosing scope / go back a step (Alt+Shift on Windows and Linux) |
| Cmd+F | Find and replace in the file |
| Down / Up (in the find bar) | Next / previous match (also Enter / Shift+Enter, or F3 / Shift+F3 anywhere) |
| Cmd+Shift+F | Find and replace in the project |
| Cmd+Option+C / Cmd+Option+W | Match case / whole word (Alt+C / Alt+W on Windows and Linux) |
| Enter / Cmd+Enter (in the replace box) | Replace one / replace all |
| Cmd+Shift+E | Explorer |
| Cmd+G | Git |
| Cmd+B | Toggle sidebar |
| Cmd+K | Close folder (clears the screen in the terminal) |
| Cmd+T | Terminal (also Ctrl+`) |
| Ctrl+Space | Show suggestions |
| Cmd+, | Settings |
| Cmd+= / Cmd+- / Cmd+0 | Zoom in / out / reset |

Every shortcut, including the ones left out of this table, is listed in the
**Help** tab — open it from the Welcome tab, the **?** button in the sidebar
or Settings. Click any shortcut there and press the keys you want instead;
Backspace clears it and Esc cancels. Changes are saved to keybindings.json
next to settings.json, and "Reset All" puts everything back.

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
- **Windows**: builds, but is the least tested platform. The terminal isn't
  available yet. Dialogs use the native Win32 ones, and deleting goes to the
  Recycle Bin.

## Settings

Stored as JSON, and editable by hand:

- macOS: `~/Library/Application Support/byte-code/settings.json`
- Linux: `~/.config/byte-code/settings.json` (or `$XDG_CONFIG_HOME`)
- Windows: `%APPDATA%\byte-code\settings.json`

## Languages

Settings → Language switches the app's own text between English, Russian,
German, Kyrgyz, Turkish, Spanish, Simplified Chinese, Japanese, French,
Italian, Portuguese (Brazil) and Korean. Each language is a file in
`src/i18n/lang/`, and a test fails if one misses a string or a `{1}`-style
placeholder. Chinese, Japanese and Korean text uses a font the system
already has (Hiragino / Apple SD Gothic Neo on macOS, Microsoft YaHei /
Yu Gothic / Malgun Gothic on Windows, Noto Sans CJK on Linux).

## Project layout

Each folder has the same shape:

```
some_module/
  Name.zig          types: files that are a struct with fields (see below)
  Name_draw.zig     drawing code of the UI component Name.zig
  lib/              functions: files that only group functions
  tests/            Name_test.zig tests Name.zig (or lib/name.zig)
```

```
src/
  main.zig            window setup and the frame loop
  app/                the application
    App.zig             its state, one frame, and an index of lib/
    Tab.zig, Terminal.zig
    lib/                dispatch (commands), files, tree, project_search,
                        panels, tabs, terminal, mouse, clipboard, settings,
                        render (drawing a frame)
  core/               editor logic, no graphics — unit tested
    root.zig            what the core module exports
    buffer/             text, undo history; lib/cursors (multi-cursor)
    editing/            lib/: edit, motion, command, scope, wrap, text
    search/             Search, ProjectSearch, FileSearch; lib/find
    project/            FileTree, Git
    syntax/             syntax.zig lists the languages; lib/ has one lexer
                        per language; Highlighter
    completion/         Completion, Index; lib/fuzzy, lib/builtins
    terminal/           Screen; lib/escapes (parsing escape sequences)
    Document.zig, Settings.zig
  ui/                 drawing and hit-testing
    editor/             View, Minimap, FindBar, CompletionPopup
    sidebar/            Sidebar, SearchPanel, GitPanel, ContextMenu
    pages/              WelcomePage, SettingsPage
    terminal/           TerminalPanel
    widgets/            TextField; lib/ file icons, search toggles
    theme/              lib/theme (colors, sizes, zoom), lib/palettes
    Font.zig, TabBar.zig, QuickOpen.zig
  input/              Mouse; lib/keymap, lib/terminal_keys
  platform/           Pty; lib/dialogs, lib/paths
scripts/              release packaging
```

Conventions:

- **`Name.zig` (capitalized) is a type.** In Zig a file is a struct; these
  have fields (`const FileTree = @This();`) and you make values of them:
  `var tree = try FileTree.load(...)`.
- **`lib/name.zig` (lowercase) is a group of functions**, no fields:
  `core.scope.expand(...)`.
- `Name_draw.zig` holds a UI component's drawing. The component re-exports
  it (`pub const draw = Name_draw.draw;`), so it's still called as
  `component.draw(...)`.
- `tests/Name_test.zig` tests `Name.zig`; `Name.zig` ends with
  `test { _ = @import("tests/Name_test.zig"); }` so `zig build test` runs it.

## License notes

The executable includes the DejaVu Sans Mono font (used when no suitable
system font is found); see `src/ui/fonts/DejaVu-LICENSE.txt`.
