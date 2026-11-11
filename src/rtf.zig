//! Syntax colouring for the preview panes: converts pstview's preview text into RTF.
//! Portable (no OS calls). Regions:
//!   - message header + header analysis (until the "-----" separator): labels, severities, auth results
//!   - body: plain
//!   - after "Internet headers": header names, IPs, e-mail addresses, pass/fail verdicts, dates

const std = @import("std");
const Allocator = std.mem.Allocator;
const mime = @import("mime.zig");

pub const C = enum(u8) {
    normal = 1,
    label,
    hname,
    ip,
    email,
    pass,
    fail,
    warn,
    subtle,
    high,
    medium,
    low,
    date,
    title,
};

// colour table entries in enum order (index 1..)
const palette = [_][3]u8{
    .{ 0x1f, 0x23, 0x28 }, // normal
    .{ 0x6a, 0x73, 0x7d }, // label
    .{ 0x00, 0x55, 0xb3 }, // header name
    .{ 0x8a, 0x3f, 0xc8 }, // ip
    .{ 0x00, 0x7a, 0x7a }, // email
    .{ 0x1a, 0x7f, 0x37 }, // pass
    .{ 0xcf, 0x22, 0x2e }, // fail
    .{ 0xc2, 0x6a, 0x00 }, // warn
    .{ 0x8c, 0x95, 0x9f }, // subtle
    .{ 0xcf, 0x22, 0x2e }, // high
    .{ 0xc2, 0x6a, 0x00 }, // medium
    .{ 0x9a, 0x7d, 0x00 }, // low
    .{ 0x0b, 0x6e, 0x8a }, // date
    .{ 0x1f, 0x38, 0x64 }, // title
};

const Writer = struct {
    a: Allocator,
    out: std.ArrayList(u8) = .empty,
    cur: C = .normal,
    bold: bool = false,

    fn set(self: *Writer, c: C, bold: bool) void {
        if (c != self.cur) self.out.print(self.a, "\\cf{d} ", .{@intFromEnum(c)}) catch {};
        if (bold != self.bold) self.out.appendSlice(self.a, if (bold) "\\b " else "\\b0 ") catch {};
        self.cur = c;
        self.bold = bold;
    }

    fn text(self: *Writer, c: C, bold: bool, s: []const u8) void {
        if (s.len == 0) return;
        self.set(c, bold);
        // Message text is not always valid UTF-8 (bodies in a legacy code page); iterating it
        // unchecked panics, so repair it first.
        const valid = mime.repairUtf8(self.a, s) catch return;
        var view = std.unicode.Utf8View.init(valid) catch return;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            switch (cp) {
                '\\' => self.out.appendSlice(self.a, "\\\\") catch {},
                '{' => self.out.appendSlice(self.a, "\\{") catch {},
                '}' => self.out.appendSlice(self.a, "\\}") catch {},
                '\t' => self.out.appendSlice(self.a, "\\tab ") catch {},
                '\r' => {},
                '\n' => self.out.appendSlice(self.a, "\\par\n") catch {},
                else => if (cp < 0x80) {
                    self.out.append(self.a, @intCast(cp)) catch {};
                } else if (cp < 0x10000) {
                    self.out.print(self.a, "\\u{d}?", .{@as(i16, @bitCast(@as(u16, @intCast(cp))))}) catch {};
                } else {
                    const v = cp - 0x10000;
                    const hi: u16 = @intCast(0xD800 + (v >> 10));
                    const lo: u16 = @intCast(0xDC00 + (v & 0x3FF));
                    self.out.print(self.a, "\\u{d}?\\u{d}?", .{ @as(i16, @bitCast(hi)), @as(i16, @bitCast(lo)) }) catch {};
                },
            }
        }
    }
};

fn isIpv4(t: []const u8) bool {
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, t, '.');
    while (it.next()) |p| {
        if (p.len == 0 or p.len > 3) return false;
        for (p) |c| if (!std.ascii.isDigit(c)) return false;
        parts += 1;
    }
    return parts == 4;
}

fn isIpv6(t: []const u8) bool {
    if (t.len < 5) return false;
    var colons: usize = 0;
    var hexd: usize = 0;
    for (t) |c| {
        if (c == ':') colons += 1 else if (std.ascii.isHex(c)) hexd += 1 else if (c != '.') return false;
    }
    return colons >= 2 and hexd >= 2;
}

fn isEmail(t: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, t, '@') orelse return false;
    return at > 0 and std.mem.indexOfScalarPos(u8, t, at, '.') != null;
}

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn isTimeOrDate(t: []const u8) bool {
    // hh:mm:ss  /  YYYY-MM-DD
    if (t.len >= 8 and std.ascii.isDigit(t[0]) and t[2] == ':' and t[5] == ':') return true;
    if (t.len == 10 and t[4] == '-' and t[7] == '-' and std.ascii.isDigit(t[0])) return true;
    for (months) |m| if (std.mem.eql(u8, t, m)) return true;
    return false;
}

fn verdictColour(word: []const u8) ?C {
    const v = std.mem.trim(u8, word, "=;,()");
    if (std.ascii.eqlIgnoreCase(v, "pass") or std.ascii.eqlIgnoreCase(v, "bestguesspass")) return .pass;
    if (std.ascii.eqlIgnoreCase(v, "fail") or std.ascii.eqlIgnoreCase(v, "hardfail") or std.ascii.eqlIgnoreCase(v, "permerror")) return .fail;
    if (std.ascii.eqlIgnoreCase(v, "softfail") or std.ascii.eqlIgnoreCase(v, "neutral") or std.ascii.eqlIgnoreCase(v, "temperror")) return .warn;
    if (std.ascii.eqlIgnoreCase(v, "none")) return .subtle;
    return null;
}

/// Colour the tokens of a value: IPs, e-mail addresses, verdicts, dates.
fn tokens(w: *Writer, s: []const u8, base: C) void {
    var i: usize = 0;
    while (i < s.len) {
        // delimiters pass through
        const delims = " \t;,()[]<>=\"'";
        if (std.mem.indexOfScalar(u8, delims, s[i]) != null) {
            const st = i;
            while (i < s.len and std.mem.indexOfScalar(u8, delims, s[i]) != null) i += 1;
            w.text(base, false, s[st..i]);
            continue;
        }
        const st = i;
        while (i < s.len and std.mem.indexOfScalar(u8, delims, s[i]) == null) i += 1;
        const tok = s[st..i];
        const tclean = std.mem.trimEnd(u8, tok, ".:");
        const c: C = if (isIpv4(tclean) or isIpv6(tclean)) .ip else if (isEmail(tok)) .email else if (verdictColour(tok)) |vc| vc else if (isTimeOrDate(tok)) .date else base;
        w.text(c, c == .fail, tok);
    }
}

const header_labels = [_][]const u8{ "Subject:", "From:", "To:", "Cc:", "Bcc:", "Received:", "Sent:", "Created:", "Modified:", "Class:", "Msg-ID:", "PST NID:", "Attach:" };

fn sevColour(label: []const u8) C {
    if (std.mem.eql(u8, label, "HIGH")) return .high;
    if (std.mem.eql(u8, label, "Medium")) return .medium;
    if (std.mem.eql(u8, label, "Low")) return .low;
    return .subtle;
}

fn headerAreaLine(w: *Writer, line: []const u8) void {
    const t = std.mem.trimStart(u8, line, " ");
    const indent = line[0 .. line.len - t.len];
    w.text(.normal, false, indent);
    // analysis title
    if (std.mem.startsWith(u8, t, "=====") and std.mem.indexOf(u8, t, "Header analysis") != null) {
        const c: C = if (std.mem.indexOf(u8, t, "HIGH") != null) .high else if (std.mem.indexOf(u8, t, "Medium") != null) .medium else if (std.mem.indexOf(u8, t, "Low") != null) .low else .pass;
        w.text(c, true, t);
        return;
    }
    // [SEV] finding
    if (t.len > 2 and t[0] == '[') if (std.mem.indexOfScalar(u8, t, ']')) |e| {
        const sev = t[1..e];
        const c = sevColour(sev);
        w.text(c, c == .high, t[0 .. e + 1]);
        w.text(if (c == .high) .high else .normal, false, t[e + 1 ..]);
        return;
    };
    // Field: value lines
    for (header_labels) |lb| if (std.mem.startsWith(u8, t, lb)) {
        w.text(.label, false, lb);
        const rest = t[lb.len..];
        if (std.mem.eql(u8, lb, "Subject:")) w.text(.title, true, rest) else tokens(w, rest, .normal);
        return;
    };
    // analysis detail lines like "Auth: SPF=pass ..." / "From: ..." / "Origin IP: ..."
    if (std.mem.indexOfScalar(u8, t, ':')) |c| if (c < 24 and c > 0) {
        w.text(.label, false, t[0 .. c + 1]);
        tokens(w, t[c + 1 ..], .normal);
        return;
    };
    tokens(w, t, .normal);
}

fn internetHeaderLine(w: *Writer, line: []const u8) void {
    if (line.len > 0 and line[0] != ' ' and line[0] != '\t') {
        if (std.mem.indexOfScalar(u8, line, ':')) |c| {
            const name = line[0..c];
            var ok = name.len > 0;
            for (name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) {
                ok = false;
            };
            if (ok) {
                w.text(.hname, true, line[0 .. c + 1]);
                tokens(w, line[c + 1 ..], .normal);
                return;
            }
        }
    }
    tokens(w, line, .normal);
}

/// Convert preview text to RTF with syntax colouring. `font` is the face name, `half_points` the size.
pub fn colorize(a: Allocator, text: []const u8, font: []const u8, half_points: u32) []const u8 {
    var w: Writer = .{ .a = a };
    w.out.print(a, "{{\\rtf1\\ansi\\ansicpg1252\\deff0\\uc1{{\\fonttbl{{\\f0\\fnil {s};}}}}{{\\colortbl ;", .{font}) catch {};
    for (palette) |p| w.out.print(a, "\\red{d}\\green{d}\\blue{d};", .{ p[0], p[1], p[2] }) catch {};
    w.out.print(a, "}}\\f0\\fs{d}\\cf1 ", .{half_points}) catch {};

    const Region = enum { head, body, inet };
    var region: Region = .head;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!first) w.out.appendSlice(a, "\\par\n") catch {};
        first = false;
        if (region == .head and std.mem.startsWith(u8, line, "-----")) {
            w.text(.subtle, false, line);
            region = .body;
            continue;
        }
        if (std.mem.indexOf(u8, line, "Internet headers") != null and std.mem.startsWith(u8, line, "-----")) {
            w.text(.subtle, true, line);
            region = .inet;
            continue;
        }
        switch (region) {
            .head => headerAreaLine(&w, line),
            .body => w.text(.normal, false, line),
            .inet => internetHeaderLine(&w, line),
        }
    }
    w.out.appendSlice(a, "}") catch {};
    return w.out.items;
}

// ================================================================ tests

const testing = std.testing;

test "colorize: text that is not valid UTF-8 (legacy code-page bodies) does not panic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = colorize(a, "Subject:   You\x92ll see\n-----\nbody \x93q\x94 cut \xe2\x80\nok \u{2019}", "Consolas", 19);
    // RTF \uN? escapes: 0x92 -> U+2019, 0x93/0x94 -> U+201C/U+201D, stray E2 80 -> U+00E2 U+20AC
    try testing.expect(std.mem.indexOf(u8, doc, "You\\u8217?ll see") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\\u8220?q\\u8221?") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "cut \\u226?\\u8364?") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "ok \\u8217?") != null);
}
