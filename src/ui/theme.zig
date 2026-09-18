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

// ----------------------------------------------------------------- colors

pub const Mode = core.Settings.Theme;

const syntax_kinds = @typeInfo(core.syntax.Kind).@"enum".fields.len;

/// Every color that differs between dark and light.
const Palette = struct {
    background: rl.Color,
    foreground: rl.Color,
    caret: rl.Color,
    selection: rl.Color,
    current_line: rl.Color,
    line_number: rl.Color,
    line_number_current: rl.Color,

    popup_background: rl.Color,
    popup_border: rl.Color,
    popup_detail: rl.Color,
    popup_shadow: rl.Color,

    sidebar_background: rl.Color,
    sidebar_border: rl.Color,
    sidebar_header: rl.Color,
    sidebar_hover: rl.Color,
    sidebar_folder: rl.Color,
    sidebar_arrow: rl.Color,

    tab_bar_background: rl.Color,
    tab_hover: rl.Color,
    tab_separator: rl.Color,
    tab_inactive_text: rl.Color,
    tab_close_hover: rl.Color,

    welcome_heading: rl.Color,

    scrollbar_thumb: rl.Color,
    scrollbar_thumb_hover: rl.Color,

    minimap_background: rl.Color,
    minimap_marker: rl.Color,
    minimap_marker_hover: rl.Color,

    terminal_background: rl.Color,
    terminal_foreground: rl.Color,
    terminal_cursor: rl.Color,
    /// The terminal's 16 standard colors (black, red, ... bright white).
    terminal_ansi: [16]rl.Color,

    git_modified: rl.Color,
    git_added: rl.Color,
    git_deleted: rl.Color,
    git_renamed: rl.Color,

    find_match: rl.Color,
    find_current: rl.Color,
    find_no_results: rl.Color,

    /// Syntax highlighting, indexed by `core.syntax.Kind`.
    syntax: [syntax_kinds]rl.Color,
};

const dark: Palette = .{
    .background = rgb(30, 30, 34),
    .foreground = rgb(220, 220, 220),
    .caret = rgb(255, 204, 102),
    .selection = rgb(60, 90, 140),
    .current_line = rgb(40, 40, 46),
    .line_number = rgb(100, 100, 112),
    .line_number_current = rgb(200, 200, 210),

    .popup_background = rgb(37, 37, 42),
    .popup_border = rgb(69, 69, 77),
    .popup_detail = rgb(140, 140, 150),
    .popup_shadow = rgba(0, 0, 0, 90),

    .sidebar_background = rgb(25, 25, 28),
    .sidebar_border = rgb(48, 48, 54),
    .sidebar_header = rgb(140, 140, 150),
    .sidebar_hover = rgb(40, 40, 46),
    .sidebar_folder = rgb(200, 200, 210),
    .sidebar_arrow = rgb(150, 150, 160),

    .tab_bar_background = rgb(25, 25, 28),
    .tab_hover = rgb(38, 38, 44),
    .tab_separator = rgb(44, 44, 50),
    .tab_inactive_text = rgb(150, 150, 160),
    .tab_close_hover = rgb(60, 60, 68),

    .welcome_heading = rgb(140, 140, 150),

    .scrollbar_thumb = rgba(255, 255, 255, 38),
    .scrollbar_thumb_hover = rgba(255, 255, 255, 80),

    .minimap_background = rgb(27, 27, 31),
    .minimap_marker = rgba(255, 255, 255, 18),
    .minimap_marker_hover = rgba(255, 255, 255, 34),

    .terminal_background = rgb(24, 24, 27),
    .terminal_foreground = rgb(204, 204, 204),
    .terminal_cursor = rgb(220, 220, 220),
    .terminal_ansi = .{
        rgb(0x00, 0x00, 0x00), rgb(0xcd, 0x31, 0x31), rgb(0x0d, 0xbc, 0x79), rgb(0xe5, 0xe5, 0x10),
        rgb(0x24, 0x72, 0xc8), rgb(0xbc, 0x3f, 0xbc), rgb(0x11, 0xa8, 0xcd), rgb(0xe5, 0xe5, 0xe5),
        rgb(0x66, 0x66, 0x66), rgb(0xf1, 0x4c, 0x4c), rgb(0x23, 0xd1, 0x8b), rgb(0xf5, 0xf5, 0x43),
        rgb(0x3b, 0x8e, 0xea), rgb(0xd6, 0x70, 0xd6), rgb(0x29, 0xb8, 0xdb), rgb(0xff, 0xff, 0xff),
    },

    .git_modified = rgb(226, 192, 141),
    .git_added = rgb(115, 201, 145),
    .git_deleted = rgb(229, 115, 115),
    .git_renamed = rgb(100, 170, 240),

    .find_match = rgb(82, 66, 36),
    .find_current = rgb(150, 105, 20),
    .find_no_results = rgb(241, 76, 76),

    .syntax = syntaxTable(.{
        .plain = rgb(220, 220, 220),
        .keyword = rgb(197, 134, 192),
        .constant = rgb(86, 156, 214),
        .type = rgb(78, 201, 176),
        .function = rgb(220, 220, 170),
        .number = rgb(181, 206, 168),
        .string = rgb(206, 145, 120),
        .regex = rgb(209, 105, 105),
        .comment = rgb(106, 153, 85),
        .punctuation = rgb(170, 170, 180),
        .tag = rgb(86, 156, 214),
        .attribute = rgb(156, 220, 254),
        .property = rgb(156, 220, 254),
        .heading = rgb(86, 156, 214),
        .emphasis = rgb(215, 186, 125),
        .link = rgb(55, 148, 255),
        .code = rgb(206, 145, 120),
    }),
};

/// Colors after VS Code's "Light+".
const light: Palette = .{
    .background = rgb(255, 255, 255),
    .foreground = rgb(31, 31, 31),
    .caret = rgb(0, 0, 0),
    .selection = rgb(173, 214, 255),
    .current_line = rgb(243, 243, 246),
    .line_number = rgb(160, 160, 168),
    .line_number_current = rgb(40, 40, 48),

    .popup_background = rgb(248, 248, 250),
    .popup_border = rgb(200, 200, 208),
    .popup_detail = rgb(110, 110, 120),
    .popup_shadow = rgba(0, 0, 0, 40),

    .sidebar_background = rgb(243, 243, 245),
    .sidebar_border = rgb(220, 220, 226),
    .sidebar_header = rgb(100, 100, 110),
    .sidebar_hover = rgb(230, 230, 236),
    .sidebar_folder = rgb(40, 40, 48),
    .sidebar_arrow = rgb(110, 110, 120),

    .tab_bar_background = rgb(236, 236, 240),
    .tab_hover = rgb(226, 226, 232),
    .tab_separator = rgb(214, 214, 220),
    .tab_inactive_text = rgb(110, 110, 120),
    .tab_close_hover = rgb(214, 214, 222),

    .welcome_heading = rgb(110, 110, 120),

    .scrollbar_thumb = rgba(0, 0, 0, 40),
    .scrollbar_thumb_hover = rgba(0, 0, 0, 90),

    .minimap_background = rgb(246, 246, 248),
    .minimap_marker = rgba(0, 0, 0, 14),
    .minimap_marker_hover = rgba(0, 0, 0, 28),

    .terminal_background = rgb(250, 250, 252),
    .terminal_foreground = rgb(31, 31, 31),
    .terminal_cursor = rgb(40, 40, 48),
    .terminal_ansi = .{
        rgb(0x00, 0x00, 0x00), rgb(0xcd, 0x31, 0x31), rgb(0x00, 0xbc, 0x00), rgb(0x94, 0x98, 0x00),
        rgb(0x04, 0x51, 0xa5), rgb(0xbc, 0x05, 0xbc), rgb(0x05, 0x98, 0xbc), rgb(0x55, 0x55, 0x55),
        rgb(0x66, 0x66, 0x66), rgb(0xcd, 0x31, 0x31), rgb(0x14, 0xce, 0x14), rgb(0xb5, 0xba, 0x00),
        rgb(0x04, 0x51, 0xa5), rgb(0xbc, 0x05, 0xbc), rgb(0x05, 0x98, 0xbc), rgb(0xa5, 0xa5, 0xa5),
    },

    .git_modified = rgb(137, 95, 0),
    .git_added = rgb(56, 132, 60),
    .git_deleted = rgb(173, 11, 11),
    .git_renamed = rgb(0, 100, 190),

    .find_match = rgb(255, 232, 170),
    .find_current = rgb(255, 196, 80),
    .find_no_results = rgb(205, 49, 49),

    .syntax = syntaxTable(.{
        .plain = rgb(31, 31, 31),
        .keyword = rgb(175, 0, 219),
        .constant = rgb(0, 0, 255),
        .type = rgb(38, 127, 153),
        .function = rgb(121, 94, 38),
        .number = rgb(9, 134, 88),
        .string = rgb(163, 21, 21),
        .regex = rgb(129, 31, 63),
        .comment = rgb(0, 128, 0),
        .punctuation = rgb(80, 80, 90),
        .tag = rgb(128, 0, 0),
        .attribute = rgb(229, 0, 0),
        .property = rgb(4, 81, 165),
        .heading = rgb(128, 0, 0),
        .emphasis = rgb(121, 94, 38),
        .link = rgb(0, 112, 193),
        .code = rgb(163, 21, 21),
    }),
};

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
pub var find_match: rl.Color = dark.find_match;
pub var find_current: rl.Color = dark.find_current;
pub var find_no_results: rl.Color = dark.find_no_results;
pub var syntax: [syntax_kinds]rl.Color = dark.syntax;

/// Switches every color to the dark or light palette.
pub fn setMode(mode: Mode) void {
    const p = switch (mode) {
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

fn syntaxTable(colors: anytype) [syntax_kinds]rl.Color {
    var table: [syntax_kinds]rl.Color = undefined;
    inline for (@typeInfo(core.syntax.Kind).@"enum".fields) |f| {
        table[f.value] = @field(colors, f.name);
    }
    return table;
}

/// Highlight color (active tab, focused inputs, links, selected rows),
/// chosen in Settings. Set at startup and whenever the setting changes.
pub var accent: rl.Color = rgb(24, 163, 255);

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

fn rgb(r: u8, g: u8, b: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

fn rgba(r: u8, g: u8, b: u8, a: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}
