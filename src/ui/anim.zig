//! Smooth movement, turned on and off in Settings ("Smooth animations").
//!
//! Everything is drawn from scratch each frame, so an animation is just a
//! value that walks toward the one the interface asks for: `approach` for
//! scrolls and sizes, `Fade` (and `fade` for things with nowhere to keep
//! state) for showing and hiding. With the setting off every one of them
//! lands on its target at once, which is how the editor behaves without
//! this file.
const std = @import("std");
const rl = @import("raylib");

/// Whether movement is animated; set from Settings (see settings_actions).
pub var enabled: bool = true;

/// Speeds, as "how far toward the target per second": a value covers
/// about 95% of the way in 3 / speed seconds, which is the duration to
/// think in — 12 is a quarter of a second.
pub const scroll_speed: f32 = 13;
pub const panel_speed: f32 = 10;
pub const hover_speed: f32 = 12;
pub const popup_speed: f32 = 13;
pub const collapse_speed: f32 = 11;

/// The frame's length, with a ceiling: a stalled frame (a git command, a
/// window resize) must not make everything jump.
pub fn dt() f32 {
    return @min(rl.getFrameTime(), 0.05);
}

/// How much of the way to a target to cover this frame, as a fraction:
/// frame-rate independent, so 30 and 144 frames a second look the same.
pub fn step(speed: f32) f32 {
    if (!enabled) return 1;
    return 1 - @exp(-speed * dt());
}

/// Moves `value` toward `target`. The last sliver is dropped so a value
/// that is all but there stops instead of creeping — small enough that a
/// 0 → 1 fade still plays all the way through.
pub fn approach(value: *f32, target: f32, speed: f32) void {
    if (!enabled) {
        value.* = target;
        return;
    }
    const next = value.* + (target - value.*) * step(speed);
    value.* = if (@abs(target - next) < 0.002) target else next;
}

pub fn approachVec(value: *rl.Vector2, target: rl.Vector2, speed: f32) void {
    approach(&value.x, target.x, speed);
    approach(&value.y, target.y, speed);
}

/// A 0 → 1 value for something that is shown or hidden: how far in it is.
pub const Fade = struct {
    t: f32 = 0,

    /// Call once a frame with whether the thing should be showing.
    pub fn update(self: *Fade, on: bool, speed: f32) f32 {
        approach(&self.t, if (on) 1 else 0, speed);
        return self.t;
    }

    /// Worth drawing at all.
    pub fn visible(self: Fade) bool {
        return self.t > 0.004;
    }
};

/// Fades for the many small things that have nowhere to keep one: rows,
/// buttons, tabs. `id` names the thing (see `hash`); the table forgets
/// whatever hasn't been asked about for a while, so ids that come and go
/// (a row per file, say) cost nothing.
const Slot = struct { id: u64 = 0, t: f32 = 0, seen: u64 = 0, used: bool = false, fresh: bool = true };
var slots: [256]Slot = @splat(.{});
var frame: u64 = 0;

/// Call once a frame, before drawing.
pub fn newFrame() void {
    frame += 1;
}

/// The fade of one small thing, 0 when it is off and 1 when fully on.
pub fn fade(id: u64, on: bool, speed: f32) f32 {
    return track(id, if (on) 1 else 0, speed);
}

/// A value of one small thing following a target — where a marker under
/// the current tab belongs, say. The first frame lands on it, so nothing
/// flies in from nowhere when it is first drawn.
pub fn track(id: u64, target: f32, speed: f32) f32 {
    const s = slot(id) orelse return target;
    s.seen = frame;
    if (s.fresh) {
        s.fresh = false;
        s.t = target;
        return s.t;
    }
    approach(&s.t, target, speed);
    return s.t;
}

/// The slot for `id`: its own, a free one, or the one nothing has asked
/// about for longest.
fn slot(id: u64) ?*Slot {
    const start: usize = @intCast(id % slots.len);
    var oldest: usize = start;
    for (0..slots.len) |i| {
        const at = (start + i) % slots.len;
        const s = &slots[at];
        if (s.used and s.id == id) return s;
        if (!s.used) {
            s.* = .{ .id = id, .seen = frame, .used = true };
            return s;
        }
        // A slot nobody has asked about for a few frames is up for reuse.
        if (s.seen < slots[oldest].seen) oldest = at;
        if (i >= 8) break;
    }
    const s = &slots[oldest];
    if (frame - s.seen < 4) return null; // all busy: this one goes without
    s.* = .{ .id = id, .seen = frame, .used = true };
    return s;
}

/// A list that just grew or shrank at one row — a folder opened in the
/// file tree, a section unfolded in the Git view. The rows below it start
/// where they were and slide to where they belong, so the new ones come
/// out from under the row that was clicked.
pub const Reveal = struct {
    /// The row that was clicked: everything below it moves.
    row: usize,
    /// Rows gained (positive) or lost (negative).
    delta: isize,
    /// 0 when it was clicked, 1 when everything has arrived.
    t: f32 = 0,

    /// Null when there is nothing to animate.
    pub fn start(row: usize, delta: isize) ?Reveal {
        if (!enabled or delta == 0) return null;
        return .{ .row = row, .delta = delta };
    }

    /// One frame; false once it is over.
    pub fn step(self: *Reveal, speed: f32) bool {
        approach(&self.t, 1, speed);
        return self.t < 1;
    }

    /// How far the rows below still are from where they belong.
    pub fn shift(self: Reveal, row_height: f32) f32 {
        return -@as(f32, @floatFromInt(self.delta)) * row_height * (1 - ease(self.t));
    }

    pub fn moves(self: Reveal, row: usize) bool {
        return row > self.row;
    }
};

/// Names a thing for `fade`: a kind (any short text) and a number, e.g.
/// the row or the button it is.
pub fn hash(comptime kind: []const u8, index: u64) u64 {
    const base = comptime std.hash.Wyhash.hash(0, kind);
    return base ^ (index *% 0x9E3779B97F4A7C15);
}

/// The chevron a folder or a section carries, `t` of the way from
/// pointing right (0, shut) to pointing down (1, open). Drawn rather than
/// taken from the icon font, which can only give the two ends of the turn.
pub fn drawChevron(center: rl.Vector2, turn: f32, size: f32, color: rl.Color) void {
    const a = std.math.clamp(turn, 0, 1) * std.math.pi / 2.0;
    const cos = @cos(a);
    const sin = @sin(a);
    const arm = size / 2;
    // The tip, and the two arms behind it, all turned by `a`.
    const spin = struct {
        fn f(c: rl.Vector2, x: f32, y: f32, co: f32, si: f32) rl.Vector2 {
            return .{ .x = c.x + x * co - y * si, .y = c.y + x * si + y * co };
        }
    }.f;
    const tip = spin(center, arm * 0.7, 0, cos, sin);
    const top = spin(center, -arm * 0.5, -arm, cos, sin);
    const bottom = spin(center, -arm * 0.5, arm, cos, sin);
    rl.drawLineEx(top, tip, 1.6, color);
    rl.drawLineEx(tip, bottom, 1.6, color);
}

/// Colors, mixed `t` of the way from `a` to `b`.
pub fn mix(a: rl.Color, b: rl.Color, t: f32) rl.Color {
    const k = std.math.clamp(t, 0, 1);
    const part = struct {
        fn f(x: u8, y: u8, amount: f32) u8 {
            return @intFromFloat(@as(f32, @floatFromInt(x)) * (1 - amount) + @as(f32, @floatFromInt(y)) * amount);
        }
    }.f;
    return .{
        .r = part(a.r, b.r, k),
        .g = part(a.g, b.g, k),
        .b = part(a.b, b.b, k),
        .a = part(a.a, b.a, k),
    };
}

/// A color faded in: the same color, `t` of its opacity.
pub fn alpha(c: rl.Color, t: f32) rl.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = @intFromFloat(@as(f32, @floatFromInt(c.a)) * std.math.clamp(t, 0, 1)) };
}

/// Eases a 0 → 1 fade so it starts fast and settles: for sizes and
/// distances, where a straight line looks mechanical.
pub fn ease(t: f32) f32 {
    const k = std.math.clamp(t, 0, 1);
    return 1 - (1 - k) * (1 - k) * (1 - k);
}
