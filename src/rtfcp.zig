//! Compressed RTF bodies (PR_RTF_COMPRESSED).
//!
//! Outlook often stores only this property and no plain-text or HTML body, especially in
//! OST files. This module decompresses it ([MS-OXRTFCP]) and recovers the body it carries:
//!   * HTML wrapped in RTF (`\fromhtml1`, [MS-OXRTFEX]) is de-encapsulated back to HTML.
//!     Non-ASCII characters become numeric entities, so the result is correct whatever
//!     charset the HTML's own <meta> declares.
//!   * Any other RTF (`\fromtext` or native rich text) is reduced to UTF-8 plain text.
//!
//! Limits: `\'hh` bytes are decoded as Windows-1252 (multi-byte code pages are not decoded);
//! layout (tables, lists, fonts) is not kept in plain-text mode.
//! Portable: no OS calls.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { html, text };
pub const Body = struct { kind: Kind, data: []const u8 };

/// Decode PR_RTF_COMPRESSED into the HTML or plain-text body it carries.
pub fn body(a: Allocator, compressed: []const u8) !Body {
    return extract(a, try decompress(a, compressed));
}

// ================================================================ [MS-OXRTFCP] decompression

const comp_lzfu: u32 = 0x75465A4C; // "LZFu"
const comp_mela: u32 = 0x414C454D; // "MELA" (stored uncompressed)
const max_raw = 256 * 1024 * 1024;

/// Initial dictionary contents ([MS-OXRTFCP] 2.1.3.1.1).
const dict_init = "{\\rtf1\\ansi\\mac\\deff0\\deftab720{\\fonttbl;}{\\f0\\fnil \\froman \\fswiss \\fmodern \\fscript \\fdecor MS Sans SerifSymbolArialTimes New RomanCourier{\\colortbl\\red0\\green0\\blue0\r\n\\par \\pard\\plain\\f0\\fs20\\b\\i\\u\\tab\\tx";
comptime {
    std.debug.assert(dict_init.len == 207);
}

fn rd32(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}

pub fn decompress(a: Allocator, src: []const u8) ![]u8 {
    if (src.len < 16) return error.Corrupt;
    // header: COMPSIZE (bytes after this field), RAWSIZE, COMPTYPE, CRC
    const end: usize = @min(src.len, @as(usize, rd32(src, 0)) +| 4);
    const raw: usize = @min(rd32(src, 4), max_raw);
    switch (rd32(src, 8)) {
        comp_mela => return a.dupe(u8, src[16..@min(src.len, 16 + raw)]),
        comp_lzfu => {},
        else => return error.Corrupt,
    }
    var dict: [4096]u8 = undefined;
    @memcpy(dict[0..dict_init.len], dict_init);
    @memset(dict[dict_init.len..], 0);
    var wp: usize = dict_init.len;

    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, @min(raw, 16 * 1024 * 1024));
    var i: usize = 16;
    run: while (i < end) {
        const ctrl = src[i];
        i += 1;
        for (0..8) |bit| {
            if (i >= end or out.items.len >= raw) break :run;
            if ((ctrl >> @intCast(bit)) & 1 == 0) {
                const c = src[i];
                i += 1;
                try out.append(a, c);
                dict[wp] = c;
                wp = (wp + 1) & 0xFFF;
            } else {
                if (i + 2 > end) break :run;
                // big-endian: 12-bit dictionary offset, 4-bit length - 2
                const ref = (@as(usize, src[i]) << 8) | src[i + 1];
                i += 2;
                const off = ref >> 4;
                if (off == wp) break :run; // end marker
                for (0..(ref & 0xF) + 2) |k| {
                    const c = dict[(off + k) & 0xFFF];
                    try out.append(a, c);
                    dict[wp] = c;
                    wp = (wp + 1) & 0xFFF;
                }
            }
        }
    }
    if (out.items.len > raw) out.shrinkRetainingCapacity(raw);
    return out.toOwnedSlice(a);
}

// ================================================================ RTF -> HTML / text

/// Windows-1252 code points for bytes 0x80..0x9F (undefined bytes map to themselves).
const cp1252_hi = [32]u21{
    0x20AC, 0x81,   0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
    0x90,   0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
};

fn cp1252(b: u8) u21 {
    return if (b >= 0x80 and b < 0xA0) cp1252_hi[b - 0x80] else b;
}

/// Destinations whose content is never body text.
const skip_destinations = [_][]const u8{
    "fonttbl",            "colortbl",          "stylesheet", "info",    "pict",     "object",    "header",
    "headerl",            "headerr",           "headerf",    "footer",  "footerl",  "footerr",   "footerf",
    "listtable",          "listoverridetable", "revtbl",     "rsidtbl", "xmlnstbl", "generator", "themedata",
    "colorschememapping", "latentstyles",      "datastore",  "filetbl", "fldinst",  "mhtmltag",  "pgdsctbl",
};

const Group = struct {
    skip: bool = false,
    /// Inside \htmlrtf ... \htmlrtf0: RTF-only rendering of HTML content, not part of the HTML.
    htmlrtf: bool = false,
    /// Inside a {\*\htmltag ...} group: literal HTML markup.
    tag: bool = false,
    uc: u8 = 1,
};

const Extractor = struct {
    a: Allocator,
    html: bool,
    out: std.ArrayList(u8) = .empty,
    g: Group = .{},
    high_surrogate: u21 = 0,
    /// Fallback characters still to drop after a \uN.
    skip_chars: usize = 0,

    fn visible(self: *const Extractor) bool {
        if (self.g.skip) return false;
        return !self.html or self.g.tag or !self.g.htmlrtf;
    }

    fn emit(self: *Extractor, cp: u21) !void {
        if (!self.visible()) return;
        if (cp < 0x80) return self.out.append(self.a, @intCast(cp));
        if (self.html) return self.out.print(self.a, "&#{d};", .{cp});
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return self.out.appendSlice(self.a, "\u{FFFD}");
        try self.out.appendSlice(self.a, buf[0..n]);
    }

    fn emitStr(self: *Extractor, s: []const u8) !void {
        if (self.visible()) try self.out.appendSlice(self.a, s);
    }

    /// A character from the document (literal, \'hh or symbol); may be a \uN fallback to drop.
    fn char(self: *Extractor, cp: u21) !void {
        if (self.skip_chars > 0) {
            self.skip_chars -= 1;
            return;
        }
        try self.emit(cp);
    }

    fn unicode(self: *Extractor, param: i32) !void {
        var v: u21 = @intCast(@as(u16, @bitCast(@as(i16, @truncate(param)))));
        if (v >= 0xD800 and v <= 0xDBFF) {
            self.high_surrogate = v;
        } else {
            if (v >= 0xDC00 and v <= 0xDFFF) {
                v = if (self.high_surrogate != 0) 0x10000 + ((self.high_surrogate - 0xD800) << 10) + (v - 0xDC00) else 0xFFFD;
            }
            self.high_surrogate = 0;
            try self.emit(v);
        }
        self.skip_chars = self.g.uc;
    }

    fn word(self: *Extractor, w: []const u8, param: ?i32) !void {
        const eq = std.mem.eql;
        if (eq(u8, w, "u")) return self.unicode(param orelse 0);
        self.skip_chars = 0;
        if (eq(u8, w, "uc")) {
            self.g.uc = @intCast(std.math.clamp(param orelse 1, 0, 8));
        } else if (eq(u8, w, "htmlrtf")) {
            self.g.htmlrtf = (param orelse 1) != 0;
        } else if (eq(u8, w, "par") or eq(u8, w, "line")) {
            try self.emitStr("\r\n");
        } else if (eq(u8, w, "tab")) {
            try self.emitStr("\t");
        } else if (!self.html and (eq(u8, w, "row") or eq(u8, w, "sect") or eq(u8, w, "page"))) {
            try self.emitStr("\r\n");
        } else if (!self.html and eq(u8, w, "cell")) {
            try self.emitStr("\t");
        } else {
            const sym: ?u21 = if (eq(u8, w, "lquote")) 0x2018 else if (eq(u8, w, "rquote")) 0x2019 else if (eq(u8, w, "ldblquote")) 0x201C else if (eq(u8, w, "rdblquote")) 0x201D else if (eq(u8, w, "bullet")) 0x2022 else if (eq(u8, w, "endash")) 0x2013 else if (eq(u8, w, "emdash")) 0x2014 else if (eq(u8, w, "enspace") or eq(u8, w, "emspace") or eq(u8, w, "qmspace")) ' ' else null;
            if (sym) |c| try self.emit(c);
        }
    }

    /// First control word of a group: may make the whole group a destination.
    fn destination(self: *Extractor, w: []const u8, starred: bool) void {
        if (self.html and std.mem.eql(u8, w, "htmltag")) {
            self.g.tag = true;
            self.g.htmlrtf = false;
            return;
        }
        if (starred) {
            self.g.skip = true;
            return;
        }
        for (skip_destinations) |d| if (std.mem.eql(u8, w, d)) {
            self.g.skip = true;
            return;
        };
    }
};

fn hexVal(c: u8) ?u8 {
    return std.fmt.charToDigit(c, 16) catch null;
}

/// Recover the body from decompressed RTF: HTML for `\fromhtml1`, plain text otherwise.
pub fn extract(a: Allocator, rtf: []const u8) !Body {
    const head = rtf[0..@min(rtf.len, 2048)];
    var x: Extractor = .{ .a = a, .html = std.mem.indexOf(u8, head, "\\fromhtml") != null };
    var stack: std.ArrayList(Group) = .empty;
    var group_start = false; // next token is the first one in a group
    var starred = false; // \* seen at group start

    var i: usize = 0;
    while (i < rtf.len) {
        const c = rtf[i];
        switch (c) {
            '{' => {
                if (stack.items.len < 1024) try stack.append(a, x.g);
                group_start = true;
                starred = false;
                i += 1;
                continue;
            },
            '}' => {
                if (stack.pop()) |g| x.g = g;
                group_start = false;
                i += 1;
                continue;
            },
            '\r', '\n' => {
                i += 1;
                continue;
            },
            '\\' => {},
            else => {
                group_start = false;
                try x.char(cp1252(c));
                i += 1;
                continue;
            },
        }

        // control word or symbol
        if (i + 1 >= rtf.len) break;
        const n = rtf[i + 1];
        if (std.ascii.isAlphabetic(n)) {
            var j = i + 1;
            while (j < rtf.len and std.ascii.isAlphabetic(rtf[j])) j += 1;
            const w = rtf[i + 1 .. j];
            var param: ?i32 = null;
            const ps = j;
            if (j < rtf.len and rtf[j] == '-') j += 1;
            const ds = j;
            while (j < rtf.len and std.ascii.isDigit(rtf[j]) and j - ds < 10) j += 1;
            if (j > ds) param = std.fmt.parseInt(i32, rtf[ps..j], 10) catch null else j = ps;
            if (j < rtf.len and rtf[j] == ' ') j += 1;
            i = j;
            if (std.mem.eql(u8, w, "bin")) {
                // \binN: N raw bytes follow
                i +|= @intCast(@max(param orelse 0, 0));
                group_start = false;
                continue;
            }
            if (group_start) x.destination(w, starred);
            group_start = false;
            try x.word(w, param);
            continue;
        }
        i += 2;
        switch (n) {
            '*' => {
                starred = true;
                continue; // still at group start
            },
            '\'' => {
                if (i + 2 <= rtf.len) if (hexVal(rtf[i])) |hi| if (hexVal(rtf[i + 1])) |lo| {
                    i += 2;
                    try x.char(cp1252(hi * 16 + lo));
                };
            },
            '\\', '{', '}' => try x.char(n),
            '~' => try x.char(0xA0),
            '_' => try x.char('-'),
            '\r', '\n' => try x.emitStr("\r\n"),
            else => {}, // \- optional hyphen, \: index subentry, etc.
        }
        group_start = false;
    }
    return .{ .kind = if (x.html) .html else .text, .data = try x.out.toOwnedSlice(a) };
}

// ================================================================ tests

const testing = std.testing;

test "decompress: MS-OXRTFCP example 1 (simple)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const comp = [_]u8{
        0x2d, 0x00, 0x00, 0x00, 0x2b, 0x00, 0x00, 0x00, 0x4c, 0x5a, 0x46, 0x75, 0xf1, 0xc5, 0xc7, 0xa7,
        0x03, 0x00, 0x0a, 0x00, 0x72, 0x63, 0x70, 0x67, 0x31, 0x32, 0x35, 0x42, 0x32, 0x0a, 0xf3, 0x20,
        0x68, 0x65, 0x6c, 0x09, 0x00, 0x20, 0x62, 0x77, 0x05, 0xb0, 0x6c, 0x64, 0x7d, 0x0a, 0x80, 0x0f,
        0xa0,
    };
    try testing.expectEqualStrings("{\\rtf1\\ansi\\ansicpg1252\\pard hello world}\r\n", try decompress(arena.allocator(), &comp));
}

test "decompress: MS-OXRTFCP example 2 (run crosses write position)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const comp = [_]u8{
        0x1a, 0x00, 0x00, 0x00, 0x1c, 0x00, 0x00, 0x00, 0x4c, 0x5a, 0x46, 0x75, 0xe2, 0xd4, 0x4b, 0x51,
        0x41, 0x00, 0x04, 0x20, 0x57, 0x58, 0x59, 0x5a, 0x0d, 0x6e, 0x7d, 0x01, 0x0e, 0xb0,
    };
    try testing.expectEqualStrings("{\\rtf1 WXYZWXYZWXYZWXYZWXYZ}", try decompress(arena.allocator(), &comp));
}

test "decompress: uncompressed (MELA)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const comp = "\x10\x00\x00\x00\x04\x00\x00\x00MELA\x00\x00\x00\x00{\\x}";
    try testing.expectEqualStrings("{\\x}", try decompress(arena.allocator(), comp));
}

test "extract: plain text from \\fromtext RTF" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rtf = "{\\rtf1\\ansi\\ansicpg1252\\fromtext \\deff0{\\fonttbl{\\f0\\fswiss Arial;}}{\\colortbl;\\red0\\green0\\blue0;}\r\n" ++
        "{\\*\\generator Msftedit;}\\pard\\plain Hello\\par caf\\'e9 \\u8364?\\tab x\\'93q\\'94\\par\r\n}";
    const b = try extract(arena.allocator(), rtf);
    try testing.expectEqual(Kind.text, b.kind);
    try testing.expectEqualStrings("Hello\r\ncafé €\tx“q”\r\n", b.data);
}

test "extract: HTML de-encapsulation from \\fromhtml1 RTF" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rtf = "{\\rtf1\\ansi\\ansicpg1252\\fromhtml1 \\deff0{\\fonttbl{\\f0\\fswiss Arial;}}\r\n" ++
        "{\\*\\htmltag19 <html>}{\\*\\htmltag34 <head>}{\\*\\htmltag1 <meta charset=\"windows-1252\">}{\\*\\htmltag41 </head>}\r\n" ++
        "{\\*\\htmltag50 <body>}\\htmlrtf \\pard\\plain\\f0 \\htmlrtf0 \r\n" ++
        "{\\*\\htmltag64 <p class=\\'22x\\'22>}\\htmlrtf {\\htmlrtf0 caf\\'e9 &amp; \\u8364?\\htmlrtf\\par }\\htmlrtf0\r\n" ++
        "{\\*\\htmltag72 </p>}{\\*\\mhtmltag84 <img src=\"cid:1\">}{\\*\\htmltag84 <img src=\"a.png\">}\\par\r\n" ++
        "{\\*\\htmltag58 </body>}{\\*\\htmltag27 </html>}}";
    const b = try extract(arena.allocator(), rtf);
    try testing.expectEqual(Kind.html, b.kind);
    try testing.expectEqualStrings("<html><head><meta charset=\"windows-1252\"></head><body><p class=\"x\">caf&#233; &amp; &#8364;</p><img src=\"a.png\">\r\n</body></html>", b.data);
}

test "extract: surrogate pair and \\uc0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const b = try extract(arena.allocator(), "{\\rtf1\\uc0 a\\u-10179\\u-8704 b}");
    try testing.expectEqualStrings("a\u{1F600}b", b.data);
}
