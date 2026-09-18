//! HTML and XML lexer for highlighting, one line at a time. In HTML, the
//! contents of <script> and <style> are highlighted as JavaScript and CSS.
const std = @import("std");
const token = @import("token.zig");
const js = @import("js.zig");
const css = @import("css.zig");

const Kind = token.Kind;
const Span = token.Span;

pub const Mode = enum(u8) { text, comment, cdata, tag, script, style };

pub const State = struct {
    mode: Mode = .text,
    /// While inside an opening tag: the mode after its `>` (script or style
    /// content, or plain text).
    content: Mode = .text,
    /// Inside a tag: the quote of an attribute value continuing onto the
    /// next line, or 0.
    quote: u8 = 0,
    /// States of the embedded lexers, carried across lines.
    js: js.State = .{},
    css: css.State = .{},
};

pub const Lexer = struct {
    line: []const u8,
    pos: usize = 0,
    state: State,
    xml: bool,
    /// The next word in the current tag is its name.
    expect_name: bool = false,
    /// The current tag is a closing one (`</...`).
    closing: bool = false,
    /// Lexer for script/style content, up to `end` (the closing tag or
    /// line end); its spans are offset by `base`.
    inner: ?Inner = null,

    const Inner = struct {
        base: usize,
        end: usize,
        lexer: union(enum) { js: js.Lexer, css: css.Lexer },
    };

    pub fn init(line: []const u8, state: State, xml: bool) Lexer {
        return .{ .line = line, .state = state, .xml = xml };
    }

    pub fn next(self: *Lexer) ?Span {
        while (true) {
            if (self.inner) |*in| {
                const span = switch (in.lexer) {
                    inline else => |*l| l.next(),
                };
                if (span) |s| return .{ .start = in.base + s.start, .end = in.base + s.end, .kind = s.kind };
                switch (in.lexer) {
                    .js => |l| self.state.js = l.state,
                    .css => |l| self.state.css = l.state,
                }
                self.pos = in.end;
                self.inner = null;
            }
            if (self.pos >= self.line.len) return null;
            if (self.state.mode == .script or self.state.mode == .style) {
                if (self.startEmbedded()) continue;
            }
            const start = self.pos;
            const kind = switch (self.state.mode) {
                .comment => self.until("-->", .comment),
                .cdata => self.until("]]>", .string),
                .tag => self.tag(),
                .text => self.text(),
                .script, .style => unreachable,
            };
            return .{ .start = start, .end = self.pos, .kind = kind };
        }
    }

    fn peek(self: *const Lexer, offset: usize) ?u8 {
        const i = self.pos + offset;
        return if (i < self.line.len) self.line[i] else null;
    }

    /// Hands script/style content up to its closing tag to the JS or CSS
    /// lexer. Returns false when the closing tag starts right here.
    fn startEmbedded(self: *Lexer) bool {
        const script = self.state.mode == .script;
        const closing_tag = if (script) "</script" else "</style";
        const end = indexOfIgnoreCasePos(self.line, self.pos, closing_tag) orelse self.line.len;
        if (end == self.pos) {
            self.state.mode = .text;
            return false;
        }
        const part = self.line[self.pos..end];
        self.inner = .{ .base = self.pos, .end = end, .lexer = if (script)
            .{ .js = .init(part, self.state.js) }
        else
            .{ .css = .init(part, self.state.css, .css) } };
        return true;
    }

    /// Consumes up to and including `marker` (then back to text), or to the
    /// end of the line.
    fn until(self: *Lexer, marker: []const u8, kind: Kind) Kind {
        if (std.mem.indexOfPos(u8, self.line, self.pos, marker)) |i| {
            self.pos = i + marker.len;
            self.state.mode = .text;
        } else self.pos = self.line.len;
        return kind;
    }

    fn text(self: *Lexer) Kind {
        const l = self.line;
        const rest = l[self.pos..];
        if (rest[0] == '<') {
            if (std.mem.startsWith(u8, rest, "<!--")) {
                self.pos += 4;
                self.state.mode = .comment;
                return self.until("-->", .comment);
            }
            if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
                self.pos += 9;
                self.state.mode = .cdata;
                return self.until("]]>", .string);
            }
            const n = self.peek(1) orelse 0;
            if (n == '/' or n == '!' or n == '?' or std.ascii.isAlphabetic(n)) {
                self.closing = n == '/';
                self.pos += if (std.ascii.isAlphabetic(n)) 1 else 2;
                self.state.mode = .tag;
                self.state.content = .text;
                self.expect_name = true;
                return .punctuation;
            }
            self.pos += 1;
            return .plain; // a lone '<' in text
        }
        if (rest[0] == '&') {
            // Entities: &amp; &#39; &#x2014;
            var i: usize = 1;
            while (i < rest.len and i < 12 and (std.ascii.isAlphanumeric(rest[i]) or rest[i] == '#')) i += 1;
            if (i > 1 and i < rest.len and rest[i] == ';') {
                self.pos += i + 1;
                return .constant;
            }
            self.pos += 1;
            return .plain;
        }
        self.pos += std.mem.indexOfAny(u8, rest, "<&") orelse rest.len;
        return .plain;
    }

    fn tag(self: *Lexer) Kind {
        const l = self.line;
        const c = l[self.pos];
        if (self.state.quote != 0) return self.quoted(self.state.quote);
        switch (c) {
            ' ', '\t', '\r' => {
                while (self.peek(0)) |w| : (self.pos += 1) if (w != ' ' and w != '\t' and w != '\r') break;
                return .plain;
            },
            '>' => {
                self.pos += 1;
                self.state.mode = self.state.content;
                self.state.content = .text;
                return .punctuation;
            },
            '/', '?' => if (self.peek(1) == '>') {
                self.pos += 2;
                self.state.mode = .text;
                self.state.content = .text;
                return .punctuation;
            },
            '"', '\'' => {
                self.pos += 1;
                return self.quoted(c);
            },
            else => if (isNameChar(c)) {
                const start = self.pos;
                while (self.peek(0)) |w| : (self.pos += 1) if (!isNameChar(w)) break;
                if (!self.expect_name) return .attribute;
                self.expect_name = false;
                const name = l[start..self.pos];
                if (!self.xml and !self.closing) {
                    if (std.ascii.eqlIgnoreCase(name, "script")) self.state.content = .script;
                    if (std.ascii.eqlIgnoreCase(name, "style")) self.state.content = .style;
                }
                // <!DOCTYPE ...>, <?xml ...?>
                const declaration = start >= 2 and (l[start - 1] == '!' or l[start - 1] == '?');
                return if (declaration) .keyword else .tag;
            },
        }
        self.pos += 1;
        return .punctuation;
    }

    /// An attribute value up to its closing quote, possibly continuing on
    /// the next line.
    fn quoted(self: *Lexer, quote: u8) Kind {
        if (std.mem.indexOfScalarPos(u8, self.line, self.pos, quote)) |end| {
            self.pos = end + 1;
            self.state.quote = 0;
        } else {
            self.pos = self.line.len;
            self.state.quote = quote;
        }
        return .string;
    }
};

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':' or c == '.' or c == '@' or c >= 0x80;
}

fn indexOfIgnoreCasePos(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

test "tags, attributes, entities, comments" {
    const expect = token.expectTokens;
    _ = try expect(Lexer.init("<a href=\"/x\" hidden>Hi &amp; bye</a><!-- note -->", .{}, false), "<a href=\"/x\" hidden>Hi &amp; bye</a><!-- note -->", &.{
        "punctuation:<", "tag:a", "attribute:href", "punctuation:=", "string:\"/x\"", "attribute:hidden", "punctuation:>",
        "plain:Hi ",     "constant:&amp;", "plain: bye", "punctuation:</", "tag:a", "punctuation:>", "comment:<!-- note -->",
    });
    _ = try expect(Lexer.init("<!DOCTYPE html>", .{}, false), "<!DOCTYPE html>", &.{ "punctuation:<!", "keyword:DOCTYPE", "attribute:html", "punctuation:>" });
}

test "script and style content" {
    const expect = token.expectTokens;
    const lx = try expect(Lexer.init("<script>let x = 1;", .{}, false), "<script>let x = 1;", &.{
        "punctuation:<", "tag:script", "punctuation:>", "keyword:let", "plain:x", "punctuation:=", "number:1", "punctuation:;",
    });
    try std.testing.expectEqual(Mode.script, lx.state.mode);
    _ = try expect(Lexer.init("f(x)</script>", lx.state, false), "f(x)</script>", &.{
        "function:f", "punctuation:(", "plain:x", "punctuation:)", "punctuation:</", "tag:script", "punctuation:>",
    });
    _ = try expect(Lexer.init("<style>p { color: red }</style>", .{}, false), "<style>p { color: red }</style>", &.{
        "punctuation:<", "tag:style", "punctuation:>", "tag:p", "punctuation:{", "property:color", "punctuation::", "constant:red", "punctuation:}",
        "punctuation:</", "tag:style", "punctuation:>",
    });
}

test "multi-line tags and xml" {
    const expect = token.expectTokens;
    const lx = try expect(Lexer.init("<div class=\"a", .{}, false), "<div class=\"a", &.{ "punctuation:<", "tag:div", "attribute:class", "punctuation:=", "string:\"a" });
    _ = try expect(Lexer.init("b\" id=x>", lx.state, false), "b\" id=x>", &.{ "string:b\"", "attribute:id", "punctuation:=", "attribute:x", "punctuation:>" });
    _ = try expect(Lexer.init("<?xml version=\"1.0\"?><script/>", .{}, true), "<?xml version=\"1.0\"?><script/>", &.{
        "punctuation:<?", "keyword:xml", "attribute:version", "punctuation:=", "string:\"1.0\"", "punctuation:?>",
        "punctuation:<",  "tag:script",  "punctuation:/>",
    });
}
