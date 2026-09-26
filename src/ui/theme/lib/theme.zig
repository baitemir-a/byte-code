//! Look and feel: colors, sizes and fonts in one place. Colors come from
//! the dark or light palette chosen in Settings (`setMode`).
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");

pub const font_size: f32 = 18;
pub const line_height: f32 = font_size * 1.4;
pub const padding: f32 = 12;
pub const caret_width: f32 = 2;
/// The gutter fits at least this many digits, so it doesn't jump at line 10.
pub const gutter_min_digits = 3;
/// Space between the line numbers and the text area.
pub const gutter_gap: f32 = 16;
/// Seconds the caret stays solid after activity, then half of each blink cycle.
pub const caret_blink: f64 = 0.5;
pub const sidebar_width: f32 = 240;

/// Monospace system fonts tried in order. If none exists, the DejaVu Sans
/// Mono built into the executable is used (see Font.zig).
pub const font_paths = [_][:0]const u8{
    // macOS
    "/System/Library/Fonts/SFNSMono.ttf",
    // Windows
    "C:/Windows/Fonts/consola.ttf",
    // Linux: DejaVu where Debian/Ubuntu, Fedora and Arch put it.
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
};

/// Dragging a selection to the top or bottom edge of a view scrolls it by
/// itself. Returns how fast, in lines per second, negative upwards and
/// zero while the pointer is well inside. Scrolling starts `margin` short
/// of the edges, so a pointer pinned to the bottom of a maximized window
/// (where there is nothing below to drag into) still scrolls, and gets
/// faster the further past that the pointer goes.
pub fn dragScrollLines(y: f32, top: f32, bottom: f32, margin: f32) f32 {
    const past = if (y < top + margin)
        y - (top + margin)
    else if (y > bottom - margin)
        y - (bottom - margin)
    else
        return 0;
    const reach = 6 * line_height; // how far out it reaches full speed
    const speed = 6 + 54 * @min(@abs(past), reach) / reach;
    return if (past < 0) -speed else speed;
}

// ----------------------------------------------------------------- colors

pub const Mode = core.Settings.Theme;

const palettes = @import("palettes.zig");
const Palette = palettes.Palette;
const dark = palettes.dark;
const light = palettes.light;
const syntax_kinds = palettes.syntax_kinds;

// The current colors, read by all drawing code. `setMode` fills them in.
pub var background: rl.Color = dark.background;
pub var foreground: rl.Color = dark.foreground;
pub var caret: rl.Color = dark.caret;
pub var selection: rl.Color = dark.selection;
pub var current_line: rl.Color = dark.current_line;
pub var line_number: rl.Color = dark.line_number;
pub var line_number_current: rl.Color = dark.line_number_current;
pub var popup_background: rl.Color = dark.popup_background;
pub var popup_border: rl.Color = dark.popup_border;
pub var popup_detail: rl.Color = dark.popup_detail;
pub var popup_shadow: rl.Color = dark.popup_shadow;
pub var sidebar_background: rl.Color = dark.sidebar_background;
pub var sidebar_border: rl.Color = dark.sidebar_border;
pub var sidebar_header: rl.Color = dark.sidebar_header;
pub var sidebar_hover: rl.Color = dark.sidebar_hover;
pub var sidebar_folder: rl.Color = dark.sidebar_folder;
pub var sidebar_arrow: rl.Color = dark.sidebar_arrow;
pub var tab_bar_background: rl.Color = dark.tab_bar_background;
pub var tab_hover: rl.Color = dark.tab_hover;
pub var tab_separator: rl.Color = dark.tab_separator;
pub var tab_inactive_text: rl.Color = dark.tab_inactive_text;
pub var tab_close_hover: rl.Color = dark.tab_close_hover;
pub var welcome_heading: rl.Color = dark.welcome_heading;
pub var scrollbar_thumb: rl.Color = dark.scrollbar_thumb;
pub var scrollbar_thumb_hover: rl.Color = dark.scrollbar_thumb_hover;
pub var minimap_background: rl.Color = dark.minimap_background;
pub var minimap_marker: rl.Color = dark.minimap_marker;
pub var minimap_marker_hover: rl.Color = dark.minimap_marker_hover;
pub var terminal_background: rl.Color = dark.terminal_background;
pub var terminal_foreground: rl.Color = dark.terminal_foreground;
pub var terminal_cursor: rl.Color = dark.terminal_cursor;
pub var terminal_ansi: [16]rl.Color = dark.terminal_ansi;
pub var git_modified: rl.Color = dark.git_modified;
pub var git_added: rl.Color = dark.git_added;
pub var git_deleted: rl.Color = dark.git_deleted;
pub var git_renamed: rl.Color = dark.git_renamed;
pub var git_pull: rl.Color = dark.git_pull;
pub var diff_added: rl.Color = dark.diff_added;
pub var diff_modified: rl.Color = dark.diff_modified;
pub var diff_deleted: rl.Color = dark.diff_deleted;
pub var diff_added_band: rl.Color = dark.diff_added_band;
pub var diff_deleted_band: rl.Color = dark.diff_deleted_band;
pub var find_match: rl.Color = dark.find_match;
pub var find_current: rl.Color = dark.find_current;
pub var find_no_results: rl.Color = dark.find_no_results;
pub var problem: rl.Color = dark.problem;
pub var warning: rl.Color = dark.warning;
pub var syntax: [syntax_kinds]rl.Color = dark.syntax;

/// The palette in use, for artwork drawn in its own colors (file icons).
pub var mode: Mode = .dark;

/// Switches every color to the dark or light palette.
pub fn setMode(m: Mode) void {
    mode = m;
    const p = switch (m) {
        .dark => dark,
        .light => light,
    };
    inline for (@typeInfo(Palette).@"struct".fields) |f| {
        @field(@This(), f.name) = @field(p, f.name);
    }
}

pub fn syntaxColor(kind: core.syntax.Kind) rl.Color {
    return syntax[@intFromEnum(kind)];
}

/// Highlight color (active tab, focused inputs, links, selected rows),
/// chosen in Settings. Set at startup and whenever the setting changes.
pub var accent: rl.Color = palettes.rgb(24, 163, 255);

/// The accent mixed into the background: `amount` 0 is the background, 1
/// the full accent. For selected rows, which need to stay readable.
pub fn accentDim(amount: f32) rl.Color {
    const mix = struct {
        fn f(a: u8, b: u8, t: f32) u8 {
            return @intFromFloat(@as(f32, @floatFromInt(a)) * (1 - t) + @as(f32, @floatFromInt(b)) * t);
        }
    }.f;
    return .{ .r = mix(background.r, accent.r, amount), .g = mix(background.g, accent.g, amount), .b = mix(background.b, accent.b, amount), .a = 255 };
}

/// Hands a color to raylib. Zig 0.16 miscompiles optimized builds (the ones
/// releases are built with) when a color picked by an `if` goes straight
/// into a raylib call: the register holding the color argument is left
/// unset, so the shape draws in whatever it happened to hold — usually
/// nothing, since that garbage is most often fully transparent. Copying the
/// value field by field makes the call pass it. Wrap any color chosen by a
/// condition in this on its way into a draw call.
pub fn copy(c: rl.Color) rl.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

// ------------------------------------------------------------------- zoom

/// UI zoom from Settings (1 = 100%). Everything is laid out in unzoomed
/// units and drawn scaled (see main.zig).
pub var zoom: f32 = 1;

/// Clips drawing to a rectangle given in UI units. (raylib's scissor
/// rectangle is in screen points, which the zoom scaling doesn't convert.)
pub fn clip(r: rl.Rectangle) void {
    rl.beginScissorMode(
        @intFromFloat(@floor(r.x * zoom)),
        @intFromFloat(@floor(r.y * zoom)),
        @intFromFloat(@ceil(r.width * zoom)),
        @intFromFloat(@ceil(r.height * zoom)),
    );
}
