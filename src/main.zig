//! Usage: rl [file or folder]
const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const App = @import("app/App.zig");
const theme = @import("ui/theme/lib/theme.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // raylib logs every step of starting up; only show problems in releases.
    if (builtin.mode != .Debug) rl.setTraceLogLevel(.err);
    rl.setConfigFlags(.{ .window_resizable = true, .window_highdpi = true, .vsync_hint = true });
    rl.initWindow(1000, 700, App.app_name);
    // E.g. no display (SSH without X forwarding) or no usable OpenGL driver.
    if (!rl.isWindowReady()) {
        std.debug.print("{s}: couldn't open a window (is a display available, with OpenGL 3.3?)\n", .{App.app_name});
        std.process.exit(1);
    }
    defer rl.closeWindow();
    rl.setWindowMinSize(200, 100);
    // Title bar and taskbar icon on Windows and Linux. macOS ignores it and
    // takes the Dock icon from the app bundle (scripts/package.sh).
    if (rl.loadImageFromMemory(".png", @embedFile("assets/icon.png"))) |icon| {
        rl.setWindowIcon(icon);
        rl.unloadImage(icon);
    } else |_| {}
    rl.setExitKey(.null); // Esc must not quit an editor
    rl.setTargetFPS(60);

    var app = try App.init(init.gpa, init.io);
    defer app.deinit();
    try app.start(if (args.len > 1) args[1] else null);

    // While the window is being resized, macOS and Windows keep the thread
    // inside their own event loop (in raylib's event polling), so the loop
    // below stalls and the last frame is stretched. GLFW asks for redraws
    // from in there; answer them with a frame for the new size.
    resizing_app = &app;
    defer resizing_app = null;
    if (glfwGetCurrentContext()) |window| _ = glfwSetWindowRefreshCallback(window, redrawWhileResizing);

    while (true) {
        // Closing the window (or Cmd+Q) asks about unsaved changes first.
        if (rl.windowShouldClose() and try app.confirmClose()) break;
        try app.update();
        rl.beginDrawing();
        drawScaled(&app);
        rl.endDrawing();
    }
}

/// The UI is laid out in unzoomed units and drawn scaled (Settings' zoom);
/// App.matchMouseToLayout sets the matching mouse scale. Zoom goes on top of
/// raylib's own Retina scaling; BeginMode2D would reset that and draw
/// everything at half size on HiDPI screens.
fn drawScaled(app: *const App) void {
    rl.gl.rlPushMatrix();
    rl.gl.rlScalef(theme.zoom, theme.zoom, 1);
    app.draw();
    rl.gl.rlPopMatrix();
}

var resizing_app: ?*App = null;

/// Called by GLFW from inside event polling, so it can't use EndDrawing
/// (which polls events again and waits for the frame rate): it flushes
/// raylib's batch and swaps buffers itself. raylib has already taken in
/// the new size (its framebuffer callback comes first).
fn redrawWhileResizing(window: *anyopaque) callconv(.c) void {
    const app = resizing_app orelse return;
    app.relayout() catch return;
    rl.beginDrawing();
    drawScaled(app);
    rl.gl.rlDrawRenderBatchActive();
    glfwSwapBuffers(window);
}

// raylib's GLFW, which it builds in.
extern "c" fn glfwGetCurrentContext() ?*anyopaque;
extern "c" fn glfwSetWindowRefreshCallback(window: *anyopaque, callback: ?*const fn (*anyopaque) callconv(.c) void) ?*const anyopaque;
extern "c" fn glfwSwapBuffers(window: *anyopaque) void;

test {
    _ = @import("platform/Pty.zig");
    _ = @import("app/Terminal.zig");
    _ = @import("input/Keymap.zig");
    _ = @import("i18n/i18n.zig");
    _ = @import("ui/fallback_fonts.zig");
}
