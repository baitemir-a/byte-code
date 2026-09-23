//! Tests for Blame.zig.
const std = @import("std");
const Blame = @import("../Blame.zig");

/// Two lines from one commit, one from another, one not committed yet.
/// (A tab starts each line's own text, so this can't be a `\\` literal.)
const porcelain =
    "1a2b3c4d5e6f70819293a4b5c6d7e8f901234567 1 1 2\n" ++
    "author Ada Lovelace\n" ++
    "author-mail <ada@example.com>\n" ++
    "author-time 1700000000\n" ++
    "author-tz +0300\n" ++
    "committer Ada Lovelace\n" ++
    "summary first steps\n" ++
    "filename a.txt\n" ++
    "\tone\n" ++
    "1a2b3c4d5e6f70819293a4b5c6d7e8f901234567 2 2\n" ++
    "\ttwo\n" ++
    "9f8e7d6c5b4a39281706f5e4d3c2b1a098765432 3 3 1\n" ++
    "author Grace Hopper\n" ++
    "author-time 1700100000\n" ++
    "author-tz -0500\n" ++
    "summary a fix\n" ++
    "filename a.txt\n" ++
    "\tthree\n" ++
    "0000000000000000000000000000000000000000 4 4 1\n" ++
    "author Not Committed Yet\n" ++
    "author-time 1700200000\n" ++
    "author-tz +0000\n" ++
    "summary Version of a.txt from a.txt\n" ++
    "filename a.txt\n" ++
    "\tfour\n";

const text = "one\ntwo\nthree\nfour\n";

test "reads the porcelain blame" {
    var b = Blame.init(std.testing.allocator);
    defer b.deinit();
    try b.set("/repo/a.txt", text, porcelain);

    try std.testing.expect(b.isFor("/repo/a.txt"));
    try std.testing.expectEqual(@as(usize, 3), b.commits.items.len);
    try std.testing.expectEqual(@as(usize, 4), b.line_commit.items.len);

    const first = b.at(0).?;
    try std.testing.expectEqualStrings("Ada Lovelace", first.author);
    try std.testing.expectEqualStrings("first steps", first.summary);
    try std.testing.expectEqualStrings("1a2b3c4", first.shortHash());
    try std.testing.expectEqual(@as(i64, 1700000000), first.time);
    try std.testing.expectEqual(@as(i32, 180), first.tz_minutes);
    // The second line repeats the commit without its details.
    try std.testing.expectEqualStrings("Ada Lovelace", b.at(1).?.author);

    const third = b.at(2).?;
    try std.testing.expectEqualStrings("Grace Hopper", third.author);
    try std.testing.expectEqual(@as(i32, -300), third.tz_minutes);

    try std.testing.expect(b.at(3).?.uncommitted());
    try std.testing.expectEqual(null, b.at(4)); // past the end
}

test "follows lines through unsaved edits" {
    var b = Blame.init(std.testing.allocator);
    defer b.deinit();
    try b.set("/repo/a.txt", text, porcelain);

    // Two lines typed in at the top, and "two" changed.
    try b.follow("new\nalso new\none\nCHANGED\nthree\nfour\n", 2);
    try std.testing.expectEqual(null, b.at(0)); // typed since
    try std.testing.expectEqual(null, b.at(1));
    try std.testing.expectEqualStrings("Ada Lovelace", b.at(2).?.author); // "one"
    try std.testing.expectEqual(null, b.at(3)); // the changed line
    try std.testing.expectEqualStrings("Grace Hopper", b.at(4).?.author); // "three"
    try std.testing.expect(b.at(5).?.uncommitted()); // "four"

    // Back to the text that was blamed: everything lines up again.
    try b.follow(text, 3);
    try std.testing.expectEqualStrings("Ada Lovelace", b.at(0).?.author);
    try std.testing.expectEqualStrings("Grace Hopper", b.at(2).?.author);
}

test "how long ago" {
    const now: i64 = 1_700_000_000;
    try std.testing.expectEqual(Blame.Age.Unit.just_now, Blame.age(now, now - 30).unit);
    const minutes = Blame.age(now, now - 5 * 60);
    try std.testing.expectEqual(Blame.Age.Unit.minutes, minutes.unit);
    try std.testing.expectEqual(@as(u32, 5), minutes.count);
    const hours = Blame.age(now, now - 3 * 3600 - 60);
    try std.testing.expectEqual(Blame.Age.Unit.hours, hours.unit);
    try std.testing.expectEqual(@as(u32, 3), hours.count);
    const days = Blame.age(now, now - 4 * 24 * 3600);
    try std.testing.expectEqual(Blame.Age.Unit.days, days.unit);
    try std.testing.expectEqual(@as(u32, 4), days.count);
    const months = Blame.age(now, now - 70 * 24 * 3600);
    try std.testing.expectEqual(Blame.Age.Unit.months, months.unit);
    try std.testing.expectEqual(@as(u32, 2), months.count);
    const years = Blame.age(now, now - 800 * 24 * 3600);
    try std.testing.expectEqual(Blame.Age.Unit.years, years.unit);
    try std.testing.expectEqual(@as(u32, 2), years.count);
}

test "the author's own date and time" {
    var buf: [32]u8 = undefined;
    // 1700000000 is 2023-11-14 22:13 UTC.
    try std.testing.expectEqualStrings("2023-11-14 22:13 +0000", Blame.formatTime(&buf, 1_700_000_000, 0));
    try std.testing.expectEqualStrings("2023-11-15 01:13 +0300", Blame.formatTime(&buf, 1_700_000_000, 180));
    try std.testing.expectEqualStrings("2023-11-14 17:13 -0500", Blame.formatTime(&buf, 1_700_000_000, -300));
}
