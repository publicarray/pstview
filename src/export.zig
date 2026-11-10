//! Export: .eml (MIME), .msg (Outlook item, Compound File Binary) and CSV/HTML reports.

const std = @import("std");
const pst = @import("pst.zig");
const Allocator = std.mem.Allocator;
const List = std.ArrayList(u8);

// ================================================================ helpers

fn isAscii(s: []const u8) bool {
    for (s) |c| if (c >= 0x80 or c == '\r' or c == '\n') return false;
    return true;
}

/// RFC 2047 encoded-word for header values containing non-ASCII.
fn encodeWord(a: Allocator, out: *List, s: []const u8) !void {
    if (isAscii(s)) return out.appendSlice(a, s);
    const enc = std.base64.standard.Encoder;
    // split into chunks of 45 bytes on UTF-8 boundaries
    var i: usize = 0;
    var first = true;
    while (i < s.len) {
        var end = @min(s.len, i + 45);
        while (end < s.len and end > i and (s[end] & 0xC0) == 0x80) end -= 1;
        if (!first) try out.appendSlice(a, "\r\n ");
        first = false;
        var buf: [128]u8 = undefined;
        try out.print(a, "=?UTF-8?B?{s}?=", .{enc.encode(&buf, s[i..end])});
        i = end;
    }
}

fn base64Lines(a: Allocator, out: *List, data: []const u8) !void {
    const enc = std.base64.standard.Encoder;
    var i: usize = 0;
    var buf: [80]u8 = undefined;
    while (i < data.len) : (i += 57) {
        const chunk = data[i..@min(data.len, i + 57)];
        try out.appendSlice(a, enc.encode(&buf, chunk));
        try out.appendSlice(a, "\r\n");
    }
}

const day_names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn rfc5322Date(buf: []u8, t: i64) []const u8 {
    const d = pst.unixToDateTime(t);
    const dow = day_names[@intCast(@mod(@divFloor(t, 86400), 7))];
    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} +0000", .{ dow, d.day, month_names[d.month - 1], d.year, d.hour, d.minute, d.second }) catch "";
}

fn mailbox(a: Allocator, out: *List, name: []const u8, email: []const u8) !void {
    if (name.len > 0 and !std.mem.eql(u8, name, email)) {
        if (isAscii(name)) {
            try out.append(a, '"');
            for (name) |c| {
                if (c == '"' or c == '\\') try out.append(a, '\\');
                try out.append(a, c);
            }
            try out.append(a, '"');
        } else try encodeWord(a, out, name);
        if (email.len > 0) try out.print(a, " <{s}>", .{email});
    } else if (email.len > 0) {
        try out.appendSlice(a, email);
    } else {
        try out.appendSlice(a, "undisclosed-recipients:;");
    }
}

/// Drop MIME structural headers (and their folded continuation lines) from transport headers.
fn filterTransportHeaders(a: Allocator, out: *List, hdrs: []const u8) !void {
    var skipping = false;
    var it = std.mem.splitSequence(u8, hdrs, "\n");
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const cont = line[0] == ' ' or line[0] == '\t';
        if (!cont) {
            skipping = std.ascii.startsWithIgnoreCase(line, "content-type:") or
                std.ascii.startsWithIgnoreCase(line, "content-transfer-encoding:") or
                std.ascii.startsWithIgnoreCase(line, "mime-version:") or
                std.ascii.startsWithIgnoreCase(line, "content-disposition:");
        }
        if (skipping) continue;
        try out.appendSlice(a, line);
        try out.appendSlice(a, "\r\n");
    }
}

fn htmlCharset(html: []const u8) []const u8 {
    const lim = html[0..@min(html.len, 4096)];
    if (std.ascii.indexOfIgnoreCase(lim, "charset=")) |i| {
        var j = i + 8;
        if (j < lim.len and (lim[j] == '"' or lim[j] == '\'')) j += 1;
        const s = j;
        while (j < lim.len and (std.ascii.isAlphanumeric(lim[j]) or lim[j] == '-' or lim[j] == '_')) j += 1;
        if (j > s) return lim[s..j];
    }
    return "utf-8";
}

// ================================================================ EML

pub fn buildEml(a: Allocator, m: *pst.Message, depth: u8) ![]u8 {
    var out: List = .empty;
    var tbuf: [64]u8 = undefined;

    const subject = try m.subject(a);
    const hdrs = try m.pc.string(a, pst.Tag.transport_headers);
    if (hdrs.len > 0) {
        try filterTransportHeaders(a, &out, hdrs);
    } else {
        try out.appendSlice(a, "From: ");
        try mailbox(a, &out, try m.senderName(a), try m.senderEmail(a));
        try out.appendSlice(a, "\r\n");
        inline for (.{ .{ 1, "To" }, .{ 2, "Cc" }, .{ 3, "Bcc" } }) |kv| {
            var first = true;
            for (m.recipients) |r| {
                if (r.kind != kv[0]) continue;
                try out.appendSlice(a, if (first) kv[1] ++ ": " else ",\r\n ");
                first = false;
                try mailbox(a, &out, r.name, r.email);
            }
            if (!first) try out.appendSlice(a, "\r\n");
        }
        try out.appendSlice(a, "Subject: ");
        try encodeWord(a, &out, subject);
        try out.appendSlice(a, "\r\n");
        const t = m.pc.time(pst.Tag.client_submit_time) orelse m.pc.time(pst.Tag.delivery_time) orelse m.pc.time(pst.Tag.creation_time);
        if (t) |tv| try out.print(a, "Date: {s}\r\n", .{rfc5322Date(&tbuf, tv)});
        const mid = try m.pc.string(a, pst.Tag.internet_message_id);
        if (mid.len > 0) try out.print(a, "Message-ID: {s}\r\n", .{mid});
    }
    // provenance headers
    try out.print(a, "X-PST-Message-Class: {s}\r\n", .{try m.pc.string(a, pst.Tag.message_class)});
    if (m.pc.time(pst.Tag.delivery_time)) |t| try out.print(a, "X-PST-Delivery-Time: {s}\r\n", .{rfc5322Date(&tbuf, t)});
    if (m.pc.time(pst.Tag.last_modified)) |t| try out.print(a, "X-PST-Last-Modified: {s}\r\n", .{rfc5322Date(&tbuf, t)});
    try out.print(a, "X-PST-NID: 0x{x:0>8}\r\n", .{m.nid});
    try out.appendSlice(a, "MIME-Version: 1.0\r\n");

    const text = try m.bodyText(a);
    const html = try m.bodyHtml(a);
    var bnd_buf: [64]u8 = undefined;
    const b_mixed = try std.fmt.bufPrint(&bnd_buf, "=_pstview_mixed_{x:0>8}_{d}", .{ m.nid, depth });
    const b_mixed_s = try a.dupe(u8, b_mixed);
    const b_alt = try std.fmt.allocPrint(a, "=_pstview_alt_{x:0>8}_{d}", .{ m.nid, depth });

    try out.print(a, "Content-Type: multipart/mixed; boundary=\"{s}\"\r\n\r\n", .{b_mixed_s});
    try out.appendSlice(a, "This is a multi-part message in MIME format.\r\n\r\n");

    // body
    try out.print(a, "--{s}\r\nContent-Type: multipart/alternative; boundary=\"{s}\"\r\n\r\n", .{ b_mixed_s, b_alt });
    try out.print(a, "--{s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n", .{b_alt});
    try base64Lines(a, &out, text);
    if (html.len > 0) {
        try out.print(a, "--{s}\r\nContent-Type: text/html; charset={s}\r\nContent-Transfer-Encoding: base64\r\n\r\n", .{ b_alt, htmlCharset(html) });
        try base64Lines(a, &out, html);
    }
    try out.print(a, "--{s}--\r\n\r\n", .{b_alt});

    // attachments
    for (m.attachments) |*att| {
        if (att.method == 5 and depth < 4) {
            if (pst.embeddedMessage(a, att) catch null) |inner_c| {
                var inner = inner_c;
                const inner_eml = try buildEml(a, &inner, depth + 1);
                try out.print(a, "--{s}\r\nContent-Type: message/rfc822\r\nContent-Disposition: attachment; filename=\"", .{b_mixed_s});
                try encodeWord(a, &out, if (att.filename.len > 0) att.filename else "attached message.eml");
                try out.appendSlice(a, "\"\r\n\r\n");
                try out.appendSlice(a, inner_eml);
                try out.appendSlice(a, "\r\n");
                continue;
            }
        }
        const data = att.data();
        const mime = if (att.mime.len > 0) att.mime else "application/octet-stream";
        try out.print(a, "--{s}\r\nContent-Type: {s}; name=\"", .{ b_mixed_s, mime });
        try encodeWord(a, &out, att.filename);
        try out.appendSlice(a, "\"\r\nContent-Transfer-Encoding: base64\r\n");
        try out.appendSlice(a, if (att.content_id.len > 0) "Content-Disposition: inline; filename=\"" else "Content-Disposition: attachment; filename=\"");
        try encodeWord(a, &out, att.filename);
        try out.appendSlice(a, "\"\r\n");
        if (att.content_id.len > 0) try out.print(a, "Content-ID: <{s}>\r\n", .{att.content_id});
        try out.appendSlice(a, "\r\n");
        try base64Lines(a, &out, data);
    }
    try out.print(a, "--{s}--\r\n", .{b_mixed_s});
    return out.toOwnedSlice(a);
}

// ================================================================ MSG (Compound File Binary, v3)

const FREESECT: u32 = 0xFFFFFFFF;
const ENDOFCHAIN: u32 = 0xFFFFFFFE;
const FATSECT: u32 = 0xFFFFFFFD;
const DIFSECT: u32 = 0xFFFFFFFC;
const NOSTREAM: u32 = 0xFFFFFFFF;
const mini_cutoff = 4096;

const CfbEntry = struct {
    name: []const u8, // ASCII
    kind: u8, // 1 storage, 2 stream, 5 root
    data: []const u8 = &.{},
    children: std.ArrayList(u32) = .empty,
    clsid: [16]u8 = [_]u8{0} ** 16,
    // computed
    left: u32 = NOSTREAM,
    right: u32 = NOSTREAM,
    child: u32 = NOSTREAM,
    start: u32 = ENDOFCHAIN,
    size: u32 = 0,
};

const Cfb = struct {
    a: Allocator,
    entries: std.ArrayList(CfbEntry) = .empty,

    fn init(a: Allocator) !Cfb {
        var c: Cfb = .{ .a = a };
        try c.entries.append(a, .{ .name = "Root Entry", .kind = 5 });
        return c;
    }
    fn addStorage(self: *Cfb, parent: u32, name: []const u8) !u32 {
        const id: u32 = @intCast(self.entries.items.len);
        try self.entries.append(self.a, .{ .name = name, .kind = 1 });
        try self.entries.items[parent].children.append(self.a, id);
        return id;
    }
    fn addStream(self: *Cfb, parent: u32, name: []const u8, data: []const u8) !void {
        const id: u32 = @intCast(self.entries.items.len);
        try self.entries.append(self.a, .{ .name = name, .kind = 2, .data = data });
        try self.entries.items[parent].children.append(self.a, id);
    }

    fn lessName(_: void, x: []const u8, y: []const u8) bool {
        if (x.len != y.len) return x.len < y.len;
        for (x, y) |cx, cy| {
            const ux = std.ascii.toUpper(cx);
            const uy = std.ascii.toUpper(cy);
            if (ux != uy) return ux < uy;
        }
        return false;
    }

    fn buildTree(self: *Cfb, ids: []u32) u32 {
        if (ids.len == 0) return NOSTREAM;
        const mid = ids.len / 2;
        const root = ids[mid];
        self.entries.items[root].left = self.buildTree(ids[0..mid]);
        self.entries.items[root].right = self.buildTree(ids[mid + 1 ..]);
        return root;
    }

    fn serialize(self: *Cfb) ![]u8 {
        const a = self.a;
        const E = self.entries.items;
        // sibling trees (sorted, balanced; all nodes black)
        for (E) |*e| {
            if (e.children.items.len == 0) continue;
            const ids = e.children.items;
            const Ctx = struct {
                ents: []CfbEntry,
                fn lt(ctx: @This(), l: u32, r: u32) bool {
                    return lessName({}, ctx.ents[l].name, ctx.ents[r].name);
                }
            };
            std.mem.sort(u32, ids, Ctx{ .ents = E }, Ctx.lt);
        }
        for (0..E.len) |i| {
            if (E[i].children.items.len > 0) E[i].child = self.buildTree(E[i].children.items);
        }

        // mini stream
        var mini: List = .empty;
        var minifat: std.ArrayList(u32) = .empty;
        for (E) |*e| {
            if (e.kind != 2) continue;
            e.size = @intCast(e.data.len);
            if (e.data.len == 0) {
                e.start = ENDOFCHAIN;
                continue;
            }
            if (e.data.len >= mini_cutoff) continue;
            const first: u32 = @intCast(minifat.items.len);
            const n = (e.data.len + 63) / 64;
            for (0..n) |k| try minifat.append(a, if (k + 1 == n) ENDOFCHAIN else first + @as(u32, @intCast(k)) + 1);
            try mini.appendSlice(a, e.data);
            try mini.appendNTimes(a, 0, n * 64 - e.data.len);
            e.start = first;
        }

        // sector budget
        var big_secs: usize = 0;
        for (E) |e| if (e.kind == 2 and e.data.len >= mini_cutoff) {
            big_secs += (e.data.len + 511) / 512;
        };
        const mini_secs = (mini.items.len + 511) / 512;
        const minifat_secs = (minifat.items.len * 4 + 511) / 512;
        const dir_secs = (E.len + 3) / 4;
        const data_secs = big_secs + mini_secs + minifat_secs + dir_secs;
        var fat_secs: usize = 1;
        var difat_secs: usize = 0;
        while (true) {
            const total = data_secs + fat_secs + difat_secs;
            const nf = (total + 127) / 128;
            const nd = if (nf > 109) (nf - 109 + 126) / 127 else 0;
            if (nf == fat_secs and nd == difat_secs) break;
            fat_secs = nf;
            difat_secs = nd;
        }
        const total_secs = data_secs + fat_secs + difat_secs;
        const fat = try a.alloc(u32, fat_secs * 128);
        @memset(fat, FREESECT);

        var next: u32 = 0;
        const fat_start = next;
        for (0..fat_secs) |k| fat[fat_start + k] = FATSECT;
        next += @intCast(fat_secs);
        const difat_start = next;
        for (0..difat_secs) |k| fat[difat_start + k] = DIFSECT;
        next += @intCast(difat_secs);

        const chain = struct {
            fn run(f: []u32, start: u32, n: usize) void {
                for (0..n) |k| f[start + k] = if (k + 1 == n) ENDOFCHAIN else start + @as(u32, @intCast(k)) + 1;
            }
        }.run;

        const dir_start = next;
        chain(fat, dir_start, dir_secs);
        next += @intCast(dir_secs);
        const minifat_start: u32 = if (minifat_secs > 0) next else ENDOFCHAIN;
        if (minifat_secs > 0) chain(fat, next, minifat_secs);
        next += @intCast(minifat_secs);
        const mini_start: u32 = if (mini_secs > 0) next else ENDOFCHAIN;
        if (mini_secs > 0) chain(fat, next, mini_secs);
        next += @intCast(mini_secs);
        for (E) |*e| {
            if (e.kind != 2 or e.data.len < mini_cutoff) continue;
            const n = (e.data.len + 511) / 512;
            e.start = next;
            chain(fat, next, n);
            next += @intCast(n);
        }
        std.debug.assert(next == total_secs);
        E[0].start = mini_start;
        E[0].size = @intCast(mini.items.len);

        // write
        const out = try a.alloc(u8, 512 * (1 + total_secs));
        @memset(out, 0);
        const hdr = out[0..512];
        @memcpy(hdr[0..8], &[_]u8{ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 });
        std.mem.writeInt(u16, hdr[24..26], 0x003E, .little);
        std.mem.writeInt(u16, hdr[26..28], 0x0003, .little);
        std.mem.writeInt(u16, hdr[28..30], 0xFFFE, .little);
        std.mem.writeInt(u16, hdr[30..32], 9, .little);
        std.mem.writeInt(u16, hdr[32..34], 6, .little);
        std.mem.writeInt(u32, hdr[44..48], @intCast(fat_secs), .little);
        std.mem.writeInt(u32, hdr[48..52], dir_start, .little);
        std.mem.writeInt(u32, hdr[56..60], mini_cutoff, .little);
        std.mem.writeInt(u32, hdr[60..64], minifat_start, .little);
        std.mem.writeInt(u32, hdr[64..68], @intCast(minifat_secs), .little);
        std.mem.writeInt(u32, hdr[68..72], if (difat_secs > 0) difat_start else ENDOFCHAIN, .little);
        std.mem.writeInt(u32, hdr[72..76], @intCast(difat_secs), .little);
        for (0..109) |k| {
            const v: u32 = if (k < fat_secs) fat_start + @as(u32, @intCast(k)) else FREESECT;
            std.mem.writeInt(u32, hdr[76 + k * 4 ..][0..4], v, .little);
        }
        const sec = struct {
            fn at(buf: []u8, s: usize) []u8 {
                return buf[512 * (1 + s) ..][0..512];
            }
        }.at;
        // FAT
        for (0..fat_secs) |k| {
            const s = sec(out, fat_start + k);
            for (0..128) |j| std.mem.writeInt(u32, s[j * 4 ..][0..4], fat[k * 128 + j], .little);
        }
        // DIFAT sectors
        for (0..difat_secs) |k| {
            const s = sec(out, difat_start + k);
            for (0..127) |j| {
                const idx = 109 + k * 127 + j;
                const v: u32 = if (idx < fat_secs) fat_start + @as(u32, @intCast(idx)) else FREESECT;
                std.mem.writeInt(u32, s[j * 4 ..][0..4], v, .little);
            }
            const nxt: u32 = if (k + 1 < difat_secs) difat_start + @as(u32, @intCast(k)) + 1 else ENDOFCHAIN;
            std.mem.writeInt(u32, s[508..512], nxt, .little);
        }
        // directory
        const dir = out[512 * (1 + dir_start) ..][0 .. dir_secs * 512];
        for (0..dir_secs * 4) |i| {
            const d = dir[i * 128 ..][0..128];
            if (i >= E.len) {
                std.mem.writeInt(u32, d[68..72], NOSTREAM, .little);
                std.mem.writeInt(u32, d[72..76], NOSTREAM, .little);
                std.mem.writeInt(u32, d[76..80], NOSTREAM, .little);
                continue;
            }
            const e = E[i];
            const nl: usize = @min(e.name.len, 31);
            for (e.name[0..nl], 0..) |c, k| std.mem.writeInt(u16, d[k * 2 ..][0..2], c, .little);
            std.mem.writeInt(u16, d[64..66], @intCast((nl + 1) * 2), .little);
            d[66] = e.kind;
            d[67] = 1; // black
            std.mem.writeInt(u32, d[68..72], e.left, .little);
            std.mem.writeInt(u32, d[72..76], e.right, .little);
            std.mem.writeInt(u32, d[76..80], e.child, .little);
            @memcpy(d[80..96], &e.clsid);
            const start: u32 = if (e.kind == 1) 0 else e.start;
            std.mem.writeInt(u32, d[116..120], start, .little);
            std.mem.writeInt(u64, d[120..128], if (e.kind == 1) 0 else e.size, .little);
        }
        // mini FAT
        if (minifat_secs > 0) {
            const mf = out[512 * (1 + minifat_start) ..][0 .. minifat_secs * 512];
            @memset(mf, 0xFF);
            for (minifat.items, 0..) |v, k| std.mem.writeInt(u32, mf[k * 4 ..][0..4], v, .little);
        }
        if (mini_secs > 0) @memcpy(out[512 * (1 + mini_start) ..][0..mini.items.len], mini.items);
        for (E) |e| {
            if (e.kind != 2 or e.data.len < mini_cutoff) continue;
            @memcpy(out[512 * (1 + e.start) ..][0..e.data.len], e.data);
        }
        return out;
    }
};

const msg_clsid = [16]u8{ 0x0B, 0x0D, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 };

const PropSink = struct {
    a: Allocator,
    cfb: *Cfb,
    storage: u32,
    table: List = .empty,

    fn add(self: *PropSink, p: pst.Prop) !void {
        if (p.id >= 0x8000) return; // named properties need the PST name map; not exported
        if ((p.ptype & pst.PT.mv_flag) != 0) return;
        if (p.ptype == pst.PT.object) return;
        const tag: u32 = (@as(u32, p.id) << 16) | p.ptype;
        var ent: [16]u8 = [_]u8{0} ** 16;
        std.mem.writeInt(u32, ent[0..4], tag, .little);
        std.mem.writeInt(u32, ent[4..8], 0x6, .little);
        if (pst.fixedSize(p.ptype)) |sz| {
            const n = @min(sz, p.data.len, 8);
            @memcpy(ent[8..][0..n], p.data[0..n]);
        } else {
            var data = p.data;
            if (p.ptype == pst.PT.unicode) {
                const d = try self.a.alloc(u8, p.data.len + 2);
                @memcpy(d[0..p.data.len], p.data);
                d[p.data.len] = 0;
                d[p.data.len + 1] = 0;
                data = d;
            } else if (p.ptype == pst.PT.string8) {
                const d = try self.a.alloc(u8, p.data.len + 1);
                @memcpy(d[0..p.data.len], p.data);
                d[p.data.len] = 0;
                data = d;
            }
            std.mem.writeInt(u32, ent[8..12], @intCast(data.len), .little);
            const name = try std.fmt.allocPrint(self.a, "__substg1.0_{X:0>8}", .{tag});
            try self.cfb.addStream(self.storage, name, data);
        }
        try self.table.appendSlice(self.a, &ent);
    }
};

fn addMessageToCfb(a: Allocator, cfb: *Cfb, storage: u32, m: *pst.Message, embedded: bool, depth: u8) !void {
    var sink: PropSink = .{ .a = a, .cfb = cfb, .storage = storage };
    for (m.pc.props) |p| try sink.add(p);
    // PR_STORE_SUPPORT_MASK with STORE_UNICODE_OK: without it Outlook reads Unicode (0x001F)
    // string properties as ANSI and shows every other character as a box.
    if (m.pc.find(0x340D) == null) {
        const mask = [4]u8{ 0x00, 0x00, 0x04, 0x00 }; // 0x00040000
        try sink.add(.{ .id = 0x340D, .ptype = pst.PT.int32, .data = &mask });
    }

    // recipients
    for (m.recipients, 0..) |r, i| {
        const name = try std.fmt.allocPrint(a, "__recip_version1.0_#{X:0>8}", .{i});
        const st = try cfb.addStorage(storage, name);
        var rs: PropSink = .{ .a = a, .cfb = cfb, .storage = st };
        var row_id: [4]u8 = undefined;
        std.mem.writeInt(u32, &row_id, @intCast(i), .little);
        try rs.add(.{ .id = 0x3000, .ptype = pst.PT.int32, .data = &row_id });
        for (r.props) |p| if (p.id != 0x3000) try rs.add(p);
        var hdr = [_]u8{0} ** 8;
        const pdata = try std.mem.concat(a, u8, &.{ &hdr, rs.table.items });
        _ = &hdr;
        try cfb.addStream(st, "__properties_version1.0", pdata);
    }
    // attachments
    for (m.attachments, 0..) |*att, i| {
        const name = try std.fmt.allocPrint(a, "__attach_version1.0_#{X:0>8}", .{i});
        const st = try cfb.addStorage(storage, name);
        var as: PropSink = .{ .a = a, .cfb = cfb, .storage = st };
        for (att.pc.props) |p| try as.add(p);
        if (att.method == 5 and depth < 4) {
            if (pst.embeddedMessage(a, att) catch null) |inner_c| {
                var inner = inner_c;
                const inner_st = try cfb.addStorage(st, "__substg1.0_3701000D");
                try addMessageToCfb(a, cfb, inner_st, &inner, true, depth + 1);
                var ent: [16]u8 = [_]u8{0} ** 16;
                std.mem.writeInt(u32, ent[0..4], (0x3701 << 16) | 0x000D, .little);
                std.mem.writeInt(u32, ent[4..8], 0x6, .little);
                std.mem.writeInt(u32, ent[8..12], 0xFFFFFFFF, .little);
                try as.table.appendSlice(a, &ent);
            }
        }
        const hdr = [_]u8{0} ** 8;
        try cfb.addStream(st, "__properties_version1.0", try std.mem.concat(a, u8, &.{ &hdr, as.table.items }));
    }

    // property stream header
    var h: [32]u8 = [_]u8{0} ** 32;
    const nr: u32 = @intCast(m.recipients.len);
    const na: u32 = @intCast(m.attachments.len);
    std.mem.writeInt(u32, h[8..12], nr, .little);
    std.mem.writeInt(u32, h[12..16], na, .little);
    std.mem.writeInt(u32, h[16..20], nr, .little);
    std.mem.writeInt(u32, h[20..24], na, .little);
    const hlen: usize = if (embedded) 24 else 32;
    try cfb.addStream(storage, "__properties_version1.0", try std.mem.concat(a, u8, &.{ h[0..hlen], sink.table.items }));
}

pub fn buildMsg(a: Allocator, m: *pst.Message) ![]u8 {
    var cfb = try Cfb.init(a);
    cfb.entries.items[0].clsid = msg_clsid;
    const nameid = try cfb.addStorage(0, "__nameid_version1.0");
    try cfb.addStream(nameid, "__substg1.0_00020102", &.{});
    try cfb.addStream(nameid, "__substg1.0_00030102", &.{});
    try cfb.addStream(nameid, "__substg1.0_00040102", &.{});
    try addMessageToCfb(a, &cfb, 0, m, false, 0);
    return cfb.serialize();
}

// ================================================================ file names

/// Windows-safe file name: "<prefix> <subject>.<ext>" (max ~150 chars).
pub fn safeName(a: Allocator, prefix: []const u8, subject: []const u8, ext: []const u8) ![]u8 {
    var out: List = .empty;
    try out.appendSlice(a, prefix);
    if (prefix.len > 0) try out.append(a, ' ');
    var count: usize = 0;
    var view = std.unicode.Utf8View.init(subject) catch std.unicode.Utf8View.initUnchecked("");
    var it = view.iterator();
    while (it.nextCodepointSlice()) |cs| {
        if (count >= 100) break;
        if (cs.len == 1) {
            const c = cs[0];
            if (c < 0x20 or std.mem.indexOfScalar(u8, "<>:\"/\\|?*", c) != null) {
                try out.append(a, '_');
                count += 1;
                continue;
            }
        }
        try out.appendSlice(a, cs);
        count += 1;
    }
    while (out.items.len > 0 and (out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '.')) _ = out.pop();
    if (count == 0) try out.appendSlice(a, "(no subject)");
    try out.append(a, '.');
    try out.appendSlice(a, ext);
    return out.toOwnedSlice(a);
}

// ================================================================ reports

pub fn csvField(a: Allocator, out: *List, s: []const u8) !void {
    try out.append(a, '"');
    for (s) |c| {
        if (c == '"') try out.append(a, '"');
        if (c == '\r' or c == '\n') {
            try out.append(a, ' ');
            continue;
        }
        try out.append(a, c);
    }
    try out.append(a, '"');
}

pub fn htmlEscape(a: Allocator, out: *List, s: []const u8) !void {
    for (s) |c| switch (c) {
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '&' => try out.appendSlice(a, "&amp;"),
        '"' => try out.appendSlice(a, "&quot;"),
        else => try out.append(a, c),
    };
}

pub const ReportRow = struct {
    folder: []const u8,
    nid: u32,
    received: ?i64,
    sent: ?i64,
    modified: ?i64,
    from: []const u8,
    to: []const u8,
    cc: []const u8,
    subject: []const u8,
    class: []const u8,
    size: ?i64,
    attachments: []const u8,
    export_file: []const u8,
};

pub const ReportMeta = struct {
    pst_path: []const u8,
    pst_size: u64,
    sha256_hex: []const u8,
    generated_utc: i64,
    tz_label: []const u8,
    tz_offset: i64,
    title: []const u8,
};

pub fn reportCsv(a: Allocator, rows: []const ReportRow, meta: ReportMeta) ![]u8 {
    var out: List = .empty;
    try out.appendSlice(a, "\xEF\xBB\xBF"); // BOM for Excel
    var b: [32]u8 = undefined;
    try out.print(a, "Folder,NID,Received ({s}),Sent ({s}),Last modified ({s}),From,To,Cc,Subject,Class,Size,Attachments,Exported file\r\n", .{ meta.tz_label, meta.tz_label, meta.tz_label });
    for (rows) |r| {
        try csvField(a, &out, r.folder);
        try out.print(a, ",0x{x:0>8},", .{r.nid});
        try csvField(a, &out, pst.fmtTime(&b, r.received, meta.tz_offset));
        try out.append(a, ',');
        try csvField(a, &out, pst.fmtTime(&b, r.sent, meta.tz_offset));
        try out.append(a, ',');
        try csvField(a, &out, pst.fmtTime(&b, r.modified, meta.tz_offset));
        inline for (.{ "from", "to", "cc", "subject", "class" }) |f| {
            try out.append(a, ',');
            try csvField(a, &out, @field(r, f));
        }
        try out.print(a, ",{d},", .{r.size orelse 0});
        try csvField(a, &out, r.attachments);
        try out.append(a, ',');
        try csvField(a, &out, r.export_file);
        try out.appendSlice(a, "\r\n");
    }
    return out.toOwnedSlice(a);
}

pub fn reportHtml(a: Allocator, rows: []const ReportRow, meta: ReportMeta) ![]u8 {
    var out: List = .empty;
    var b: [32]u8 = undefined;
    try out.appendSlice(a,
        \\<!doctype html><html><head><meta charset="utf-8"><title>
    );
    try htmlEscape(a, &out, meta.title);
    try out.appendSlice(a,
        \\</title><style>
        \\body{font:13px/1.4 Segoe UI,Arial,sans-serif;margin:24px;color:#222}
        \\h1{font-size:18px;margin:0 0 8px}
        \\table{border-collapse:collapse;width:100%}
        \\th,td{border:1px solid #ccc;padding:4px 6px;text-align:left;vertical-align:top}
        \\th{background:#1f3864;color:#fff;position:sticky;top:0}
        \\tr:nth-child(even) td{background:#f4f6fa}
        \\.meta td{border:none;padding:1px 12px 1px 0}
        \\.mono{font-family:Consolas,monospace;font-size:12px}
        \\</style></head><body><h1>
    );
    try htmlEscape(a, &out, meta.title);
    try out.appendSlice(a, "</h1><table class=\"meta\">");
    try out.appendSlice(a, "<tr><td>Source PST</td><td class=\"mono\">");
    try htmlEscape(a, &out, meta.pst_path);
    try out.print(a, "</td></tr><tr><td>Size</td><td>{d} bytes</td></tr>", .{meta.pst_size});
    try out.print(a, "<tr><td>SHA-256</td><td class=\"mono\">{s}</td></tr>", .{meta.sha256_hex});
    try out.print(a, "<tr><td>Report generated (UTC)</td><td>{s}</td></tr>", .{pst.fmtTime(&b, meta.generated_utc, 0)});
    try out.print(a, "<tr><td>Times shown in</td><td>{s}</td></tr>", .{meta.tz_label});
    try out.print(a, "<tr><td>Items</td><td>{d}</td></tr>", .{rows.len});
    try out.appendSlice(a, "<tr><td>Tool</td><td>pstview (read-only; source file opened without write access)</td></tr></table><br>");
    try out.appendSlice(a, "<table><tr><th>#</th><th>Folder</th><th>Received</th><th>Sent</th><th>Modified</th><th>From</th><th>To</th><th>Subject</th><th>Attachments</th><th>Size</th><th>NID</th><th>Export</th></tr>\n");
    for (rows, 0..) |r, i| {
        try out.print(a, "<tr><td>{d}</td><td>", .{i + 1});
        try htmlEscape(a, &out, r.folder);
        try out.print(a, "</td><td>{s}</td>", .{pst.fmtTime(&b, r.received, meta.tz_offset)});
        try out.print(a, "<td>{s}</td>", .{pst.fmtTime(&b, r.sent, meta.tz_offset)});
        try out.print(a, "<td>{s}</td><td>", .{pst.fmtTime(&b, r.modified, meta.tz_offset)});
        try htmlEscape(a, &out, r.from);
        try out.appendSlice(a, "</td><td>");
        try htmlEscape(a, &out, r.to);
        try out.appendSlice(a, "</td><td>");
        try htmlEscape(a, &out, r.subject);
        try out.appendSlice(a, "</td><td>");
        try htmlEscape(a, &out, r.attachments);
        try out.print(a, "</td><td>{d}</td><td class=\"mono\">0x{x:0>8}</td><td>", .{ r.size orelse 0, r.nid });
        if (r.export_file.len > 0) {
            try out.appendSlice(a, "<a href=\"");
            try htmlEscape(a, &out, r.export_file);
            try out.appendSlice(a, "\">");
            try htmlEscape(a, &out, r.export_file);
            try out.appendSlice(a, "</a>");
        }
        try out.appendSlice(a, "</td></tr>\n");
    }
    try out.appendSlice(a, "</table></body></html>\n");
    return out.toOwnedSlice(a);
}
