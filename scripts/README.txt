byte code — a lightweight code editor
======================================

MAC (Apple Silicon or Intel, macOS 13 or newer)
-----------------------------------------------
1. Unzip and drag "byte code.app" into Applications.
2. Open it. The first time, macOS will say it can't verify the developer
   (the app isn't registered with Apple). To allow it:
     System Settings > Privacy & Security > scroll down >
     "byte code" was blocked... > Open Anyway
   Or, in Terminal:
     xattr -dr com.apple.quarantine "/Applications/byte code.app"
3. The first time you delete a file from the sidebar, macOS asks whether
   byte code may control Finder: that's how deleted files go to the Trash.

WINDOWS (64-bit)
----------------
1. Unzip and run byte-code.exe.
2. If Windows SmartScreen appears: More info > Run anyway.
3. Limitation for now: the Open / Save As / "save changes?" dialogs aren't
   available on Windows yet. Drag files or folders onto the window to open
   them; Ctrl+S saves files that were opened. A file with unsaved changes
   keeps the window from closing, so save it (or undo) first.

LINUX (x86_64: Ubuntu 20.04+, Debian 11+, Fedora 30+ and similar)
-----------------------------------------------------------------
1. Unpack and run:
     tar -xzf byte-code-linux-x86_64.tar.gz
     ./byte-code/byte-code
2. Needs a desktop session (X11, or Wayland with XWayland) and OpenGL 3.3,
   which normal desktop installs have.
3. The Open / Save As dialogs use zenity, preinstalled on GNOME. If Ctrl+O
   does nothing, install it (e.g. sudo apt install zenity) or drop files onto
   the window. Deleted files go to the Trash via `gio` (part of GLib).

GETTING STARTED
---------------
On Mac use Cmd, on Windows and Linux use Ctrl:
Open a file: Cmd+O, or drop it onto the window.
Open a folder as a project: Cmd+Shift+O, or drop it onto the window.
The Welcome tab lists the main shortcuts.
