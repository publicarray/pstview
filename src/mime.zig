//! RFC 5322 / MIME message parsing (portable, no OS calls).
//!
//! Turns raw message bytes into header fields, a plain-text body, an HTML body and attachments.
//! Embedded messages (message/rfc822) are parsed recursively. All text comes out as UTF-8:
//! RFC 2047 encoded words, RFC 2231 parameters, base64 and quoted-printable are decoded, and
//! charsets are converted (UTF-8, ASCII, Latin-1 and Windows-1252 built in; others through
//! `charset_hook`). Parsing is lenient: malformed input degrades to raw text, never an error.

const std = @import("std");
const Allocator = std.mem.Allocator;

const eqlIc = std.ascii.eqlIgnoreCase;

// ================================================================ charsets

/// Decoder for charsets beyond the built-in ones; returns UTF-8 or null if the charset is unknown.
/// Front ends set this (e.g. to Windows code-page conversion).
pub var charset_hook: ?*const fn (a: Allocator, charset: []const u8, bytes: []const u8) ?[]u8 = null;

/// Windows-1252 code points for bytes 0x80..0x9F (undefined bytes map to themselves).
const cp1252_hi = [32]u21{
    0x20AC, 0x81,   0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
    0x90,   0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
};

/// Windows-1252 (superset of Latin-1 for printable text) -> UTF-8.
pub fn cp1252ToUtf8(a: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, bytes.len + bytes.len / 4);
    for (bytes) |b| {
        const cp: u21 = if (b >= 0x80 and b < 0xA0) cp1252_hi[b - 0x80] else b;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        out.appendSliceAssumeCapacity(buf[0..n]);
        if (out.capacity - out.items.len < 4) try out.ensureUnusedCapacity(a, 64);
    }
    return out.toOwnedSlice(a);
}

fn isAscii(bytes: []const u8) bool {
    for (bytes) |b| if (b >= 0x80) return false;
    return true;
}

fn cleanCharset(cs: []const u8) []const u8 {
    var c = std.mem.trim(u8, cs, " \t\"'");
    if (std.mem.indexOfScalar(u8, c, '*')) |i| c = c[0..i]; // RFC 2231 language suffix
    return c;
}

/// Convert `bytes` in `charset` to UTF-8. Falls back to Windows-1252 for invalid or unknown input.
pub fn toUtf8(a: Allocator, charset: []const u8, bytes: []const u8) []const u8 {
    if (isAscii(bytes)) return bytes;
    const cs = cleanCharset(charset);
    const utf8_valid = std.unicode.utf8ValidateSlice(bytes);
    if (cs.len == 0 or eqlIc(cs, "utf-8") or eqlIc(cs, "utf8") or eqlIc(cs, "us-ascii") or eqlIc(cs, "ascii")) {
        if (utf8_valid) return bytes;
    } else if (eqlIc(cs, "iso-8859-1") or eqlIc(cs, "latin1") or eqlIc(cs, "latin-1") or eqlIc(cs, "l1") or
        eqlIc(cs, "windows-1252") or eqlIc(cs, "cp1252") or eqlIc(cs, "x-cp1252") or eqlIc(cs, "iso8859-1"))
    {
        return cp1252ToUtf8(a, bytes) catch bytes;
    } else if (charset_hook) |hook| {
        if (hook(a, cs, bytes)) |s| return s;
    }
    if (utf8_valid) return bytes;
    return cp1252ToUtf8(a, bytes) catch bytes;
}

// ================================================================ transfer encodings

fn b64Value(c: u8) ?u6 {
    return switch (c) {
        'A'...'Z' => @intCast(c - 'A'),
        'a'...'z' => @intCast(c - 'a' + 26),
        '0'...'9' => @intCast(c - '0' + 52),
        '+', '-' => 62,
        '/', '_' => 63,
        else => null,
    };
}

/// Lenient base64: skips line breaks and stray characters, tolerates missing padding.
pub fn base64Decode(a: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, s.len / 4 * 3 + 3);
    var acc: u32 = 0;
    var bits: u5 = 0;
    for (s) |c| {
        if (c == '=') break;
        const v = b64Value(c) orelse continue;
        acc = ((acc << 6) | v) & 0xFFFFFF;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out.appendAssumeCapacity(@truncate(acc >> bits));
        }
    }
    return out.toOwnedSlice(a);
}

fn hexVal(c: u8) ?u8 {
    return std.fmt.charToDigit(c, 16) catch null;
}

/// Quoted-printable body decoding (soft line breaks removed).
pub fn qpDecode(a: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, s.len);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '=') {
            if (i + 1 < s.len and s[i + 1] == '\n') {
                i += 2;
                continue;
            }
            if (i + 2 < s.len and s[i + 1] == '\r' and s[i + 2] == '\n') {
                i += 3;
                continue;
            }
            if (i + 2 < s.len) if (hexVal(s[i + 1])) |hi| if (hexVal(s[i + 2])) |lo| {
                out.appendAssumeCapacity(hi * 16 + lo);
                i += 3;
                continue;
            };
        }
        out.appendAssumeCapacity(c);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

/// Undo a Content-Transfer-Encoding (base64, quoted-printable; anything else is returned as is).
pub fn decodeBody(a: Allocator, cte: []const u8, body: []const u8) []const u8 {
    const t = std.mem.trim(u8, cte, " \t\r\n");
    if (eqlIc(t, "base64")) return base64Decode(a, body) catch body;
    if (eqlIc(t, "quoted-printable")) return qpDecode(a, body) catch body;
    return body;
}

// ================================================================ headers

pub const Header = struct {
    name: []const u8,
    /// Unfolded raw value (not decoded), leading whitespace removed.
    value: []const u8,
};

pub const Headers = struct {
    list: []const Header = &.{},

    /// First header with this name (case-insensitive), raw value.
    pub fn get(self: Headers, name: []const u8) ?[]const u8 {
        for (self.list) |h| if (eqlIc(h.name, name)) return h.value;
        return null;
    }
};

pub const Split = struct { head: []const u8, body: []const u8 };

/// Split a message or MIME part at the first empty line. `head` keeps its final line break.
pub fn splitMessage(raw: []const u8) Split {
    if (std.mem.startsWith(u8, raw, "\r\n")) return .{ .head = "", .body = raw[2..] };
    if (std.mem.startsWith(u8, raw, "\n")) return .{ .head = "", .body = raw[1..] };
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, raw, i, '\n')) |nl| {
        const rest = raw[nl + 1 ..];
        if (std.mem.startsWith(u8, rest, "\r\n")) return .{ .head = raw[0 .. nl + 1], .body = rest[2..] };
        if (std.mem.startsWith(u8, rest, "\n")) return .{ .head = raw[0 .. nl + 1], .body = rest[1..] };
        i = nl + 1;
    }
    return .{ .head = raw, .body = "" };
}

/// Parse a header block (unfolding continuation lines). Lines without a colon are skipped.
pub fn parseHeaders(a: Allocator, head: []const u8) Allocator.Error!Headers {
    var list: std.ArrayList(Header) = .empty;
    var cur_name: []const u8 = "";
    var cur_val: std.ArrayList(u8) = .empty;
    var have = false;
    var it = std.mem.splitScalar(u8, head, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        if (line.len == 0) continue;
        if ((line[0] == ' ' or line[0] == '\t') and have) {
            try cur_val.appendSlice(a, line);
            continue;
        }
        if (have) try list.append(a, .{ .name = cur_name, .value = try cur_val.toOwnedSlice(a) });
        have = false;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, ' ') != null) continue;
        cur_name = name;
        cur_val = .empty;
        try cur_val.appendSlice(a, std.mem.trimStart(u8, line[colon + 1 ..], " \t"));
        have = true;
    }
    if (have) try list.append(a, .{ .name = cur_name, .value = try cur_val.toOwnedSlice(a) });
    return .{ .list = try list.toOwnedSlice(a) };
}

/// Decode an unstructured header value: RFC 2047 encoded words (whitespace between adjacent
/// encoded words dropped) and raw 8-bit text (taken as UTF-8, else Windows-1252).
pub fn decodeHeader(a: Allocator, value_in: []const u8) []const u8 {
    const value = if (std.unicode.utf8ValidateSlice(value_in)) value_in else (cp1252ToUtf8(a, value_in) catch value_in);
    if (std.mem.indexOf(u8, value, "=?") == null) return std.mem.trim(u8, value, " \t");
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var ws_after_word: ?usize = null; // out position where whitespace after an encoded word began
    while (i < value.len) {
        if (std.mem.startsWith(u8, value[i..], "=?")) if (encodedWord(a, value[i..])) |ew| {
            if (ws_after_word) |p| out.shrinkRetainingCapacity(p);
            out.appendSlice(a, ew.text) catch return value;
            i += ew.len;
            ws_after_word = out.items.len;
            continue;
        };
        const c = value[i];
        if (c != ' ' and c != '\t') ws_after_word = null;
        out.append(a, c) catch return value;
        i += 1;
    }
    return std.mem.trim(u8, out.items, " \t");
}

const EncodedWord = struct { text: []const u8, len: usize };

/// Parse one "=?charset?B|Q?text?=" at the start of `s`.
fn encodedWord(a: Allocator, s: []const u8) ?EncodedWord {
    const q1 = std.mem.indexOfScalarPos(u8, s, 2, '?') orelse return null;
    if (q1 + 3 > s.len or s[q1 + 2] != '?') return null;
    const enc = s[q1 + 1];
    const end = std.mem.indexOfPos(u8, s, q1 + 3, "?=") orelse return null;
    const charset = s[2..q1];
    const text = s[q1 + 3 .. end];
    if (charset.len == 0 or std.mem.indexOfAny(u8, text, " \t") != null) return null;
    const bytes: []const u8 = switch (enc) {
        'B', 'b' => base64Decode(a, text) catch return null,
        'Q', 'q' => blk: {
            var out = a.alloc(u8, text.len) catch return null;
            var n: usize = 0;
            var i: usize = 0;
            while (i < text.len) {
                if (text[i] == '_') {
                    out[n] = ' ';
                    i += 1;
                } else if (text[i] == '=' and i + 2 < text.len) {
                    if (hexVal(text[i + 1])) |hi| if (hexVal(text[i + 2])) |lo| {
                        out[n] = hi * 16 + lo;
                        n += 1;
                        i += 3;
                        continue;
                    };
                    out[n] = '=';
                    i += 1;
                } else {
                    out[n] = text[i];
                    i += 1;
                }
                n += 1;
            }
            break :blk out[0..n];
        },
        else => return null,
    };
    return .{ .text = toUtf8(a, charset, bytes), .len = end + 2 };
}

/// "type/subtype" of a Content-Type value, lower-cased (empty if absent).
pub fn mediaType(a: Allocator, value: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const t = std.mem.trim(u8, value[0..end], " \t\r\n");
    return std.ascii.allocLowerString(a, t) catch t;
}

/// Disposition type ("attachment", "inline" or "") of a Content-Disposition value.
pub fn dispositionIs(value: []const u8, kind: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    return eqlIc(std.mem.trim(u8, value[0..end], " \t\r\n"), kind);
}

fn pctDecode(a: Allocator, s: []const u8) []const u8 {
    var out = a.alloc(u8, s.len) catch return s;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (hexVal(s[i + 1])) |hi| if (hexVal(s[i + 2])) |lo| {
                out[n] = hi * 16 + lo;
                n += 1;
                i += 3;
                continue;
            };
        }
        out[n] = s[i];
        n += 1;
        i += 1;
    }
    return out[0..n];
}

const Segment = struct { index: u32, extended: bool, value: []const u8 };

/// A parameter of a structured header (Content-Type, Content-Disposition), decoded to UTF-8.
/// Handles quoted strings, RFC 2231 extended values and continuations, and RFC 2047 words.
pub fn param(a: Allocator, value: []const u8, name: []const u8) ?[]const u8 {
    var plain: ?[]const u8 = null;
    var segs: std.ArrayList(Segment) = .empty;
    var i = std.mem.indexOfScalar(u8, value, ';') orelse return null;
    while (i < value.len) {
        while (i < value.len and (value[i] == ';' or value[i] == ' ' or value[i] == '\t' or value[i] == '\r' or value[i] == '\n')) i += 1;
        const as = i;
        while (i < value.len and value[i] != '=' and value[i] != ';') i += 1;
        if (i >= value.len or value[i] == ';') continue;
        const attr = std.mem.trim(u8, value[as..i], " \t");
        i += 1;
        while (i < value.len and (value[i] == ' ' or value[i] == '\t')) i += 1;
        var val: []const u8 = undefined;
        if (i < value.len and value[i] == '"') {
            var buf: std.ArrayList(u8) = .empty;
            i += 1;
            while (i < value.len and value[i] != '"') {
                if (value[i] == '\\' and i + 1 < value.len) i += 1;
                buf.append(a, value[i]) catch return null;
                i += 1;
            }
            i += 1;
            val = buf.items;
        } else {
            const vs = i;
            while (i < value.len and value[i] != ';') i += 1;
            val = std.mem.trim(u8, value[vs..i], " \t\r\n");
        }
        // attr forms: name | name* | name*N | name*N*
        if (attr.len < name.len or !eqlIc(attr[0..name.len], name)) continue;
        const rest = attr[name.len..];
        if (rest.len == 0) {
            plain = val;
        } else if (rest[0] == '*') {
            const ext_last = rest[rest.len - 1] == '*';
            const num = rest[1 .. rest.len - @intFromBool(ext_last and rest.len > 1)];
            const idx: u32 = if (num.len == 0) 0 else std.fmt.parseInt(u32, num, 10) catch continue;
            segs.append(a, .{ .index = idx, .extended = (num.len == 0) or ext_last, .value = val }) catch return null;
        }
    }
    if (segs.items.len > 0) {
        std.mem.sort(Segment, segs.items, {}, struct {
            fn lt(_: void, x: Segment, y: Segment) bool {
                return x.index < y.index;
            }
        }.lt);
        var charset: []const u8 = "";
        var bytes: std.ArrayList(u8) = .empty;
        for (segs.items, 0..) |sg, k| {
            var v = sg.value;
            if (sg.extended) {
                if (k == 0) {
                    // charset'language'value
                    if (std.mem.indexOfScalar(u8, v, '\'')) |q1| {
                        charset = v[0..q1];
                        if (std.mem.indexOfScalarPos(u8, v, q1 + 1, '\'')) |q2| v = v[q2 + 1 ..];
                    }
                }
                bytes.appendSlice(a, pctDecode(a, v)) catch return null;
            } else bytes.appendSlice(a, v) catch return null;
        }
        return decodeHeader(a, toUtf8(a, charset, bytes.items));
    }
    if (plain) |p| return decodeHeader(a, p);
    return null;
}

// ================================================================ dates

const months = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };

fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn zoneOffset(t: []const u8) ?i64 {
    const names = [_]struct { []const u8, i64 }{
        .{ "UT", 0 },        .{ "UTC", 0 },       .{ "GMT", 0 },       .{ "Z", 0 },
        .{ "EST", -5 * 60 }, .{ "EDT", -4 * 60 }, .{ "CST", -6 * 60 }, .{ "CDT", -5 * 60 },
        .{ "MST", -7 * 60 }, .{ "MDT", -6 * 60 }, .{ "PST", -8 * 60 }, .{ "PDT", -7 * 60 },
    };
    for (names) |z| if (eqlIc(t, z[0])) return z[1] * 60;
    if (t.len == 5 and (t[0] == '+' or t[0] == '-')) {
        const h = std.fmt.parseInt(i64, t[1..3], 10) catch return null;
        const m = std.fmt.parseInt(i64, t[3..5], 10) catch return null;
        const off = (h * 60 + m) * 60;
        return if (t[0] == '-') -off else off;
    }
    return null;
}

/// Parse an RFC 5322 date ("Tue, 1 Jul 2003 10:52:37 +0200") or an asctime-style mbox From_ line
/// date ("Tue Jul  1 10:52:37 2003", optionally with a zone). Returns unix seconds (UTC).
pub fn parseDate(s: []const u8) ?i64 {
    var day: ?i64 = null;
    var month: ?i64 = null;
    var year: ?i64 = null;
    var hh: i64 = 0;
    var mi: i64 = 0;
    var ss: i64 = 0;
    var have_time = false;
    var zone: i64 = 0;
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n,");
    while (it.next()) |tok_raw| {
        if (tok_raw[0] == '(') break; // trailing comment
        const tok = std.mem.trimEnd(u8, tok_raw, ".");
        if (tok.len == 0) continue;
        if (std.mem.indexOfScalar(u8, tok, ':') != null and !have_time) {
            var p = std.mem.splitScalar(u8, tok, ':');
            hh = std.fmt.parseInt(i64, p.next() orelse "", 10) catch continue;
            mi = std.fmt.parseInt(i64, p.next() orelse "", 10) catch continue;
            ss = if (p.next()) |x| std.fmt.parseInt(i64, x[0..@min(x.len, 2)], 10) catch 0 else 0;
            have_time = true;
            continue;
        }
        if (zoneOffset(tok)) |z| {
            zone = z;
            continue;
        }
        if (std.ascii.isDigit(tok[0])) {
            const n = std.fmt.parseInt(i64, tok, 10) catch continue;
            if (tok.len >= 3) year = n else if (day == null) day = n else if (year == null) year = if (n < 50) 2000 + n else 1900 + n;
            continue;
        }
        if (tok.len >= 3) for (months, 0..) |mn, k| {
            if (eqlIc(tok[0..3], mn)) month = @intCast(k + 1);
        };
    }
    const d = day orelse return null;
    const m = month orelse return null;
    const y = year orelse return null;
    if (!have_time or d < 1 or d > 31 or y < 1900 or y > 9999 or hh > 23 or mi > 59 or ss > 60) return null;
    return daysFromCivil(y, m, d) * 86400 + hh * 3600 + mi * 60 + ss - zone;
}

// ================================================================ addresses

pub const Address = struct { name: []const u8, email: []const u8 };

fn unquote(a: Allocator, s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len < 2 or t[0] != '"' or t[t.len - 1] != '"') return t;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i < t.len - 1) : (i += 1) {
        if (t[i] == '\\' and i + 1 < t.len - 1) i += 1;
        out.append(a, t[i]) catch return t;
    }
    return out.items;
}

/// Parse an address list ("A <a@x>, \"B, C\" <b@y>, c@z (Name), Group: d@w;").
pub fn parseAddresses(a: Allocator, value: []const u8) []Address {
    var out: std.ArrayList(Address) = .empty;
    var start: usize = 0;
    var in_q = false;
    var in_angle = false;
    var paren: u32 = 0;
    var i: usize = 0;
    while (i <= value.len) : (i += 1) {
        const c: u8 = if (i < value.len) value[i] else ',';
        if (in_q) {
            if (c == '\\') i += 1 else if (c == '"') in_q = false;
            if (i < value.len) continue;
        }
        switch (c) {
            '"' => in_q = true,
            '(' => paren += 1,
            ')' => paren -|= 1,
            '<' => in_angle = true,
            '>' => in_angle = false,
            ',', ';' => if (paren == 0 and !in_angle) {
                addAddress(a, &out, value[start..@min(i, value.len)]);
                start = i + 1;
            },
            ':' => if (paren == 0 and !in_angle) {
                start = i + 1; // group name
            },
            else => {},
        }
    }
    return out.toOwnedSlice(a) catch &.{};
}

fn addAddress(a: Allocator, out: *std.ArrayList(Address), piece_in: []const u8) void {
    const piece = std.mem.trim(u8, piece_in, " \t\r\n");
    if (piece.len == 0) return;
    // comments "(...)" outside quotes: remember the first as a fallback display name
    var comment: []const u8 = "";
    var clean: std.ArrayList(u8) = .empty;
    var in_q = false;
    var depth: u32 = 0;
    var cs: usize = 0;
    for (piece, 0..) |c, k| {
        if (!in_q and c == '(') {
            if (depth == 0) cs = k + 1;
            depth += 1;
            continue;
        }
        if (!in_q and c == ')' and depth > 0) {
            depth -= 1;
            if (depth == 0 and comment.len == 0) comment = piece[cs..k];
            continue;
        }
        if (depth > 0) continue;
        if (c == '"') in_q = !in_q;
        clean.append(a, c) catch return;
    }
    const s = std.mem.trim(u8, clean.items, " \t");
    var name: []const u8 = "";
    var email: []const u8 = "";
    if (std.mem.lastIndexOfScalar(u8, s, '<')) |lt| {
        const gt = std.mem.indexOfScalarPos(u8, s, lt, '>') orelse s.len;
        email = std.mem.trim(u8, s[lt + 1 .. gt], " \t");
        name = unquote(a, s[0..lt]);
    } else {
        email = s;
        name = std.mem.trim(u8, comment, " \t");
    }
    if (email.len == 0 and name.len == 0) return;
    out.append(a, .{ .name = decodeHeader(a, name), .email = email }) catch {};
}

/// Display string for a list: names (or addresses when unnamed) joined by "; " like PR_DISPLAY_TO.
pub fn displayList(a: Allocator, list: []const Address) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (list, 0..) |ad, k| {
        if (k > 0) out.appendSlice(a, "; ") catch break;
        out.appendSlice(a, if (ad.name.len > 0) ad.name else ad.email) catch break;
    }
    return out.items;
}

// ================================================================ message structure

pub const Attachment = struct {
    filename: []const u8,
    mime: []const u8,
    content_id: []const u8,
    /// Decoded bytes; for message/rfc822 the raw embedded message.
    data: []const u8,
    inline_part: bool,
    /// Parsed embedded message (message/rfc822 parts).
    embedded: ?*Message = null,
};

pub const Message = struct {
    head: []const u8,
    headers: Headers,
    /// Plain-text body, UTF-8 (inline text/plain parts, joined).
    text: []const u8 = "",
    /// HTML body, UTF-8.
    html: []const u8 = "",
    attachments: []Attachment = &.{},
};

const Walker = struct {
    a: Allocator,
    text: std.ArrayList(u8) = .empty,
    html: std.ArrayList(u8) = .empty,
    atts: std.ArrayList(Attachment) = .empty,
    depth: u32,
};

/// Parse a complete message (headers + MIME body). `depth` limits message/rfc822 nesting.
pub fn parse(a: Allocator, raw: []const u8, depth: u32) Allocator.Error!Message {
    const sp = splitMessage(raw);
    const hdrs = try parseHeaders(a, sp.head);
    var w: Walker = .{ .a = a, .depth = depth };
    walk(&w, hdrs, sp.body, 0);
    return .{
        .head = sp.head,
        .headers = hdrs,
        .text = w.text.items,
        .html = w.html.items,
        .attachments = w.atts.items,
    };
}

/// Parse only the header block (no body processing).
pub fn parseHead(a: Allocator, raw: []const u8) Allocator.Error!Message {
    const sp = splitMessage(raw);
    return .{ .head = sp.head, .headers = try parseHeaders(a, sp.head) };
}

fn extFor(mt: []const u8) []const u8 {
    const map = [_]struct { []const u8, []const u8 }{
        .{ "text/plain", "txt" },              .{ "text/html", "html" },          .{ "text/calendar", "ics" },
        .{ "image/jpeg", "jpg" },              .{ "image/png", "png" },           .{ "image/gif", "gif" },
        .{ "application/pdf", "pdf" },         .{ "message/rfc822", "eml" },      .{ "text/rfc822-headers", "txt" },
        .{ "message/delivery-status", "txt" }, .{ "application/ms-tnef", "dat" }, .{ "application/pkcs7-signature", "p7s" },
    };
    for (map) |e| if (std.mem.eql(u8, mt, e[0])) return e[1];
    return "bin";
}

fn walk(w: *Walker, hdrs: Headers, body: []const u8, level: u32) void {
    const a = w.a;
    const ctv = hdrs.get("content-type") orelse "text/plain";
    var mt = mediaType(a, ctv);
    if (mt.len == 0 or std.mem.indexOfScalar(u8, mt, '/') == null) mt = "text/plain";
    const cte = hdrs.get("content-transfer-encoding") orelse "";
    const disp = hdrs.get("content-disposition") orelse "";
    const is_attachment = dispositionIs(disp, "attachment");
    const fname = param(a, disp, "filename") orelse param(a, ctv, "name") orelse "";

    if (std.mem.startsWith(u8, mt, "multipart/") and level < 32) {
        if (param(a, ctv, "boundary")) |b| if (b.len > 0) {
            for (splitMultipart(a, body, b)) |part| {
                const sp = splitMessage(part);
                const ph = parseHeaders(a, sp.head) catch continue;
                walk(w, ph, sp.body, level + 1);
            }
            return;
        };
        mt = "text/plain"; // no boundary: show as text
    }

    if (std.mem.eql(u8, mt, "message/rfc822") or std.mem.eql(u8, mt, "message/global")) {
        const inner_raw = decodeBody(a, cte, body);
        var att: Attachment = .{ .filename = fname, .mime = mt, .content_id = "", .data = inner_raw, .inline_part = !is_attachment };
        if (w.depth < 8) {
            if (a.create(Message)) |m| {
                m.* = parse(a, inner_raw, w.depth + 1) catch return;
                att.embedded = m;
                if (att.filename.len == 0) {
                    const subj = decodeHeader(a, m.headers.get("subject") orelse "");
                    att.filename = std.fmt.allocPrint(a, "{s}.eml", .{if (subj.len > 0) subj else "message"}) catch "message.eml";
                }
            } else |_| {}
        }
        if (att.filename.len == 0) att.filename = "message.eml";
        w.atts.append(a, att) catch {};
        return;
    }

    const data = decodeBody(a, cte, body);
    const is_text = std.mem.eql(u8, mt, "text/plain") or std.mem.eql(u8, mt, "text/html");
    if (is_text and !is_attachment and fname.len == 0) {
        const txt = toUtf8(a, param(a, ctv, "charset") orelse "", data);
        const dst = if (std.mem.eql(u8, mt, "text/html")) &w.html else &w.text;
        if (dst.items.len > 0) dst.appendSlice(a, "\n") catch {};
        dst.appendSlice(a, txt) catch {};
        return;
    }

    var cid = std.mem.trim(u8, hdrs.get("content-id") orelse "", " \t<>");
    if (cid.len == 0) cid = "";
    const name = if (fname.len > 0) fname else std.fmt.allocPrint(a, "part{d}.{s}", .{ w.atts.items.len + 1, extFor(mt) }) catch "attachment.bin";
    w.atts.append(a, .{ .filename = name, .mime = mt, .content_id = cid, .data = data, .inline_part = !is_attachment }) catch {};
}

/// Parts of a multipart body (preamble and epilogue dropped).
pub fn splitMultipart(a: Allocator, body: []const u8, boundary: []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const delim = std.fmt.allocPrint(a, "--{s}", .{boundary}) catch return &.{};
    var pos: usize = 0;
    var part_start: ?usize = null;
    while (std.mem.indexOfPos(u8, body, pos, delim)) |d| {
        pos = d + delim.len;
        if (d != 0 and body[d - 1] != '\n') continue; // not at line start
        if (part_start) |ps| {
            var end = d;
            if (end > ps and body[end - 1] == '\n') end -= 1;
            if (end > ps and body[end - 1] == '\r') end -= 1;
            out.append(a, body[ps..end]) catch break;
        }
        if (std.mem.startsWith(u8, body[pos..], "--")) {
            part_start = null;
            break; // close delimiter
        }
        const nl = std.mem.indexOfScalarPos(u8, body, pos, '\n') orelse body.len;
        part_start = @min(nl + 1, body.len);
    }
    if (part_start) |ps| if (ps < body.len) out.append(a, body[ps..]) catch {};
    return out.items;
}

// ================================================================ tests

const testing = std.testing;

test "encoded words, adjacent-word whitespace, 8-bit fallback" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // whitespace between adjacent encoded words is not part of the text (RFC 2047 6.2)
    try testing.expectEqualStrings("Cafédéjà vu", decodeHeader(a, "=?ISO-8859-1?Q?Caf=E9?= =?utf-8?B?ZMOpasOgIHZ1?="));
    try testing.expectEqualStrings("Café déjà vu", decodeHeader(a, "=?ISO-8859-1?Q?Caf=E9_?= =?utf-8?B?ZMOpasOgIHZ1?="));
    try testing.expectEqualStrings("Re: Café x", decodeHeader(a, "Re: =?ISO-8859-1?Q?Caf=E9?= x"));
    try testing.expectEqualStrings("a b", decodeHeader(a, "=?utf-8?q?a_b?="));
    try testing.expectEqualStrings("Re: plain", decodeHeader(a, "Re: plain"));
    try testing.expectEqualStrings("é", decodeHeader(a, "\xe9"));
    try testing.expectEqualStrings("x =?bad", decodeHeader(a, "x =?bad"));
}

test "parameters: quoted, RFC 2231 extended and continued" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("b1", param(a, "multipart/mixed; boundary=\"b1\"", "boundary").?);
    try testing.expectEqualStrings("naïve file.txt", param(a, "attachment; filename*=UTF-8''na%C3%AFve%20file.txt", "filename").?);
    try testing.expectEqualStrings("long name.pdf", param(a, "attachment; filename*0=\"long \"; filename*1=\"name.pdf\"", "filename").?);
    try testing.expectEqualStrings("Résumé.doc", param(a, "application/msword; name=\"=?utf-8?Q?R=C3=A9sum=C3=A9.doc?=\"", "name").?);
    try testing.expect(param(a, "text/plain", "charset") == null);
}

test "dates" {
    try testing.expectEqual(@as(?i64, 1057049557), parseDate("Tue, 1 Jul 2003 10:52:37 +0200"));
    try testing.expectEqual(@as(?i64, 1057056757), parseDate("Tue Jul  1 10:52:37 2003"));
    try testing.expectEqual(@as(?i64, 1640995200), parseDate("Sat Jan 01 00:00:00 +0000 2022"));
    try testing.expectEqual(@as(?i64, 1057074757), parseDate("1 Jul 03 10:52:37 EST (comment)"));
    try testing.expectEqual(@as(?i64, null), parseDate("garbage"));
}

test "addresses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = parseAddresses(a, "\"Doe, John\" <john@x.com>, jane@y.org (Jane Y), =?utf-8?q?J=C3=B6rg?= <j@z.de>, Team: a@t.com, b@t.com;, undisclosed-recipients:;");
    try testing.expectEqual(@as(usize, 5), l.len);
    try testing.expectEqualStrings("Doe, John", l[0].name);
    try testing.expectEqualStrings("john@x.com", l[0].email);
    try testing.expectEqualStrings("Jane Y", l[1].name);
    try testing.expectEqualStrings("jane@y.org", l[1].email);
    try testing.expectEqualStrings("Jörg", l[2].name);
    try testing.expectEqualStrings("a@t.com", l[3].email);
    try testing.expectEqualStrings("b@t.com", l[4].email);
}

test "multipart message with alternative bodies, attachment and embedded message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw =
        "From: A <a@x.com>\r\nSubject: =?utf-8?q?Gr=C3=BC=C3=9Fe?=\r\nContent-Type: multipart/mixed;\r\n boundary=\"outer\"\r\n\r\n" ++
        "preamble\r\n--outer\r\nContent-Type: multipart/alternative; boundary=inner\r\n\r\n" ++
        "--inner\r\nContent-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nHall=F6 =\r\nWelt\r\n" ++
        "--inner\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>Hallo</p>\r\n--inner--\r\n" ++
        "--outer\r\nContent-Type: application/pdf; name=\"r.pdf\"\r\nContent-Disposition: attachment\r\nContent-Transfer-Encoding: base64\r\n\r\nSGVs\r\nbG8=\r\n" ++
        "--outer\r\nContent-Type: message/rfc822\r\n\r\nSubject: inner\r\n\r\nbody\r\n--outer--\r\nepilogue\r\n";
    const m = try parse(a, raw, 0);
    try testing.expectEqualStrings("Grüße", decodeHeader(a, m.headers.get("subject").?));
    try testing.expectEqualStrings("Hallö Welt", m.text);
    try testing.expectEqualStrings("<p>Hallo</p>", m.html);
    try testing.expectEqual(@as(usize, 2), m.attachments.len);
    try testing.expectEqualStrings("r.pdf", m.attachments[0].filename);
    try testing.expectEqualStrings("Hello", m.attachments[0].data);
    try testing.expectEqualStrings("inner.eml", m.attachments[1].filename);
    try testing.expectEqualStrings("body", m.attachments[1].embedded.?.text);
}
