const std = @import("std");
const testing = std.testing;
const Keymap = @import("../Keymap.zig");

const Chord = Keymap.Chord;

test "no two actions share a default combination" {
    const km = Keymap.default;
    for (Keymap.entries) |e| {
        const chord = km.chordFor(e.action) orelse continue;
        if (km.conflict(chord, e.action)) |other| {
            std.debug.print("{s} and {s} share a default\n", .{ @tagName(e.action), @tagName(other) });
            return error.DuplicateDefault;
        }
    }
}

test "an extra combination never repeats another action's default" {
    const km = Keymap.default;
    for (Keymap.entries) |e| {
        for (e.also) |chord| {
            if (km.conflict(chord, e.action)) |other| {
                std.debug.print("{s}'s extra combination is {s}'s default\n", .{ @tagName(e.action), @tagName(other) });
                return error.DuplicateExtra;
            }
        }
    }
}

test "no default types text on its own" {
    for (Keymap.entries) |e| {
        const chord = e.default orelse continue;
        try testing.expect(!chord.typesText());
    }
}

test "combinations survive a round trip through text" {
    const cases = [_]Chord{
        .{ .key = .s, .mods = .{ .cmd = true } },
        .{ .key = .f, .mods = .{ .ctrl = true, .shift = true } },
        .{ .key = .left, .mods = .{ .alt = true, .shift = true } },
        .{ .key = .f3 },
        .{ .key = .kp_enter },
        .{ .key = .backslash, .mods = .{ .ctrl = true } },
    };
    for (cases) |chord| {
        var buf: [48]u8 = undefined;
        const text = chord.write(&buf);
        const back = Chord.parse(text) orelse {
            std.debug.print("couldn't parse back: {s}\n", .{text});
            return error.ParseFailed;
        };
        try testing.expect(chord.eql(back));
    }
}

test "combinations are read whatever platform wrote them" {
    const cmd_s = Chord.parse("Cmd+S").?;
    try testing.expect(cmd_s.eql(.{ .key = .s, .mods = .{ .cmd = true } }));
    try testing.expect(Chord.parse("super+s").?.eql(cmd_s));
    try testing.expect(Chord.parse("Meta+S").?.eql(cmd_s));
    const opt_left = Chord.parse("Option+Left").?;
    try testing.expect(opt_left.eql(.{ .key = .left, .mods = .{ .alt = true } }));
    try testing.expect(Chord.parse("alt+left").?.eql(opt_left));
    try testing.expect(Chord.parse("Ctrl+Shift+PageUp").?.eql(.{ .key = .page_up, .mods = .{ .ctrl = true, .shift = true } }));
}

test "nonsense combinations are rejected" {
    try testing.expect(Chord.parse("") == null);
    try testing.expect(Chord.parse("Hyper+S") == null);
    try testing.expect(Chord.parse("Cmd+Nope") == null);
    try testing.expect(Chord.parse("Cmd+") == null);
}

test "letters need a command modifier, other keys don't" {
    try testing.expect((Chord{ .key = .s }).typesText());
    try testing.expect((Chord{ .key = .s, .mods = .{ .shift = true } }).typesText());
    try testing.expect(!(Chord{ .key = .s, .mods = .{ .ctrl = true } }).typesText());
    try testing.expect(!(Chord{ .key = .f3 }).typesText());
    try testing.expect(!(Chord{ .key = .left, .mods = .{ .shift = true } }).typesText());
}

test "binding a combination takes it from whoever had it" {
    var km = Keymap.default;
    const save_chord = km.chordFor(.save).?;
    km.set(.find, save_chord);
    try testing.expect(km.chordFor(.save) == null);
    try testing.expect(km.chordFor(.find).?.eql(save_chord));
    try testing.expect(!km.isDefault(.save));
    try testing.expect(!km.isDefault(.find));

    km.reset(.find);
    try testing.expect(km.isDefault(.find));
    // Save stays cleared: resetting one action doesn't touch another.
    try testing.expect(km.chordFor(.save) == null);
    km.reset(.save);
    try testing.expect(km.isDefault(.save));
}

test "clearing a combination leaves the action unbound" {
    var km = Keymap.default;
    km.set(.copy, null);
    try testing.expect(km.chordFor(.copy) == null);
    try testing.expect(!km.isDefault(.copy));
    km.resetAll();
    try testing.expect(km.isDefault(.copy));
}

test "every action has a label and shows up once" {
    var seen = [_]bool{false} ** Keymap.count;
    for (Keymap.entries) |e| {
        try testing.expect(Keymap.label(e.action).len > 0);
        try testing.expect(!seen[@intFromEnum(e.action)]);
        seen[@intFromEnum(e.action)] = true;
    }
    for (seen) |s| try testing.expect(s);
}

test "every bindable key has a name" {
    for (Keymap.entries) |e| {
        const chord = e.default orelse continue;
        try testing.expect(Keymap.keyName(chord.key) != null);
        for (e.also) |c| try testing.expect(Keymap.keyName(c.key) != null);
    }
}

test "changes survive being saved and read back" {
    const gpa = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // No file yet: the defaults.
    const fresh = Keymap.load(gpa, io, tmp.dir, "none.json");
    try testing.expect(fresh.chordFor(.save).?.eql(Keymap.entryFor(.save).default.?));

    var km = Keymap.default;
    const new_save: Chord = .{ .key = .f2, .mods = .{ .ctrl = true } };
    km.set(.save, new_save);
    km.set(.copy, null);
    try km.save(gpa, io, tmp.dir, "conf/keybindings.json");

    const read = Keymap.load(gpa, io, tmp.dir, "conf/keybindings.json");
    try testing.expect(read.chordFor(.save).?.eql(new_save));
    try testing.expect(read.chordFor(.copy) == null);
    // Everything else is untouched.
    try testing.expect(read.isDefault(.paste));
    try testing.expect(read.isDefault(.cursor_left));
}

test "only what changed is written" {
    const gpa = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const km = Keymap.default;
    try km.save(gpa, io, tmp.dir, "stock.json");
    const bytes = try tmp.dir.readFileAlloc(io, "stock.json", gpa, .limited(4096));
    defer gpa.free(bytes);
    try testing.expectEqualStrings("{}\n", bytes);
}

test "a hand-edited file can't break the keymap" {
    const gpa = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "edited.json", .data =
        \\{ "save": "Ctrl+Alt+S", "nonsense": "Cmd+Q", "find": "Nope+X", "paste": 7, "undo": "S" }
    });
    const km = Keymap.load(gpa, io, tmp.dir, "edited.json");
    try testing.expect(km.chordFor(.save).?.eql(.{ .key = .s, .mods = .{ .ctrl = true, .alt = true } }));
    // Unreadable or text-typing combinations keep the default.
    try testing.expect(km.isDefault(.find));
    try testing.expect(km.isDefault(.paste));
    try testing.expect(km.isDefault(.undo));

    try tmp.dir.writeFile(io, .{ .sub_path = "broken.json", .data = "{ not json" });
    try testing.expect(Keymap.load(gpa, io, tmp.dir, "broken.json").isDefault(.save));
}
