//! Usage: rl [file or folder]
const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const App = @import("App.zig");
const theme = @import("ui/theme.zig");

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
    rl.setExitKey(.null); // Esc must not quit an editor
    rl.setTargetFPS(60);

    var app = try App.init(init.gpa, init.io);
    defer app.deinit();
    try app.start(if (args.len > 1) args[1] else null);

    while (true) {
        // Closing the window (or Cmd+Q) asks about unsaved changes first.
        if (rl.windowShouldClose() and try app.confirmClose()) break;
        try app.update();
        rl.beginDrawing();
        // The UI is laid out in unzoomed units and drawn scaled (Settings'
        // zoom); App sets the matching mouse scale. Zoom goes on top of
        // raylib's own Retina scaling; BeginMode2D would reset that and draw
        // everything at half size on HiDPI screens.
        rl.gl.rlPushMatrix();
        rl.gl.rlScalef(theme.zoom, theme.zoom, 1);
        app.draw();
        rl.gl.rlPopMatrix();
        rl.endDrawing();
    }
}

test {
    _ = @import("platform/Pty.zig");
    _ = @import("Terminal.zig");
}
