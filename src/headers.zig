//! Internet-header analysis (portable): delivery path, sender authentication, Microsoft 365
//! anti-spam verdicts and impersonation indicators.

const std = @import("std");
const pst = @import("pst.zig");
const Allocator = std.mem.Allocator;

pub const Severity = enum(u8) {
    none,
    info,
    low,
    medium,
    high,

    pub fn label(s: Severity) []const u8 {
        return switch (s) {
            .none => "",
            .info => "Info",
            .low => "Low",
            .medium => "Medium",
            .high => "HIGH",
        };
    }
};

pub const Finding = struct { sev: Severity, text: []const u8 };

pub const Hop = struct {
    from: []const u8 = "",
    by: []const u8 = "",
    ip: []const u8 = "",
    with: []const u8 = "",
    time: ?i64 = null,
};

/// What the analysis needs from a message (decoupled from the PST layer so it can be cached cheaply).
pub const Input = struct {
    headers: []const u8,
    sender_name: []const u8,
    sender_email: []const u8,
    recipient_addrs: []const []const u8,
};

/// Organisation knowledge used for impersonation checks (built from a folder / mailbox).
pub const Context = struct {
    org_domains: []const []const u8 = &.{},
    /// normalised display name -> internal address
    internal_names: ?*const std.StringHashMapUnmanaged([]const u8) = null,
};

pub const Analysis = struct {
    has_headers: bool = false,
    from_name: []const u8 = "",
    from_addr: []const u8 = "",
    from_domain: []const u8 = "",
    return_path: []const u8 = "",
    reply_to: []const u8 = "",
    message_id: []const u8 = "",
    date: ?i64 = null,
    spf: []const u8 = "",
    dkim: []const u8 = "",
    dmarc: []const u8 = "",
    compauth: []const u8 = "",
    client_ip: []const u8 = "",
    country: []const u8 = "",
    sfv: []const u8 = "",
    cat: []const u8 = "",
    scl: []const u8 = "",
    bcl: []const u8 = "",
    auth_as: []const u8 = "",
    direction: []const u8 = "",
    mailer: []const u8 = "",
    origin_device: []const u8 = "",
    origin_ip: []const u8 = "",
    hops: []Hop = &.{},
    findings: []Finding = &.{},
    risk: Severity = .none,

    /// Short text for list columns, e.g. "HIGH: impersonation of Peter Mahar".
    pub fn summary(self: Analysis) []const u8 {
        var best: ?Finding = null;
        for (self.findings) |f| if (best == null or @intFromEnum(f.sev) > @intFromEnum(best.?.sev)) {
            best = f;
        };
        if (best) |b| if (@intFromEnum(b.sev) >= @intFromEnum(Severity.low)) return b.text;
        return if (self.has_headers) "no issues found" else "no internet headers (internal/sent item)";
    }
};

pub const freemail = [_][]const u8{
    "gmail.com",     "googlemail.com", "outlook.com",  "hotmail.com",   "live.com",       "msn.com",     "yahoo.com",
    "yahoo.com.au",  "ymail.com",      "icloud.com",   "me.com",        "mac.com",        "aol.com",     "proton.me",
    "protonmail.com", "gmx.com",       "gmx.net",      "mail.com",      "zoho.com",       "yandex.com",  "bigpond.com",
    "bigpond.net.au", "optusnet.com.au", "iinet.net.au", "tpg.com.au",  "internode.on.net", "outlook.com.au", "hotmail.com.au",
};

pub fn isFreemail(domain: []const u8) bool {
    for (freemail) |d| if (std.ascii.eqlIgnoreCase(domain, d)) return true;
    return false;
}

pub fn domainOf(addr: []const u8) []const u8 {
    const at = std.mem.lastIndexOfScalar(u8, addr, '@') orelse return "";
    return std.mem.trim(u8, addr[at + 1 ..], " >\"';,.");
}

/// True if `d` equals `base` or is a subdomain of it.
pub fn domainIs(d: []const u8, base: []const u8) bool {
    if (base.len == 0 or d.len < base.len) return false;
    if (!std.ascii.endsWithIgnoreCase(d, base)) return false;
    return d.len == base.len or d[d.len - base.len - 1] == '.';
}

/// Registrable-ish domain (last two labels, or three for country second-levels like com.au).
pub fn baseDomain(d: []const u8) []const u8 {
    var dots: [8]usize = undefined;
    var n: usize = 0;
    var i = d.len;
    while (i > 0) : (i -= 1) {
        if (d[i - 1] == '.') {
            if (n < dots.len) dots[n] = i - 1;
            n += 1;
        }
    }
    if (n < 2) return d;
    const tld2 = d[dots[1] + 1 ..]; // e.g. "com.au"
    const sl = tld2[0 .. std.mem.indexOfScalar(u8, tld2, '.') orelse tld2.len];
    const generic_sld = [_][]const u8{ "com", "net", "org", "edu", "gov", "co", "ac", "asn", "id" };
    var is_cc_sld = false;
    for (generic_sld) |g| if (std.ascii.eqlIgnoreCase(sl, g) and d.len - dots[0] <= 4) {
        is_cc_sld = true;
    };
    if (is_cc_sld and n >= 3) return d[dots[2] + 1 ..];
    if (is_cc_sld) return d;
    return d[dots[1] + 1 ..];
}

fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 64 or b.len > 64) return 99;
    var prev: [65]usize = undefined;
    var cur: [65]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (std.ascii.toLower(ca) == std.ascii.toLower(cb)) 0 else 1;
            cur[j + 1] = @min(@min(prev[j + 1] + 1, cur[j] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// "Peter Mahar | BK-ECS" -> "peter mahar"
pub fn normaliseName(a: Allocator, name: []const u8) []const u8 {
    var s = name;
    if (std.mem.indexOfAny(u8, s, "|(<[")) |i| s = s[0..i];
    s = std.mem.trim(u8, s, " \"'\t");
    var out = a.alloc(u8, s.len) catch return "";
    var n: usize = 0;
    var last_space = false;
    for (s) |c| {
        if (c == ' ' or c == '.' or c == '_') {
            if (!last_space and n > 0) {
                out[n] = ' ';
                n += 1;
            }
            last_space = true;
        } else {
            out[n] = std.ascii.toLower(c);
            n += 1;
            last_space = false;
        }
    }
    return std.mem.trim(u8, out[0..n], " ");
}

// ---------------------------------------------------------------- header parsing

pub const Header = struct { name: []const u8, value: []const u8 };

/// Unfold and split raw headers into (name, value) pairs.
pub fn parseHeaders(a: Allocator, raw: []const u8) []Header {
    var list: std.ArrayList(Header) = .empty;
    var cur_name: []const u8 = "";
    var cur_val: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |l0| {
        const line = std.mem.trimEnd(u8, l0, "\r");
        if (line.len == 0) continue;
        if ((line[0] == ' ' or line[0] == '\t') and cur_name.len > 0) {
            cur_val.append(a, ' ') catch {};
            cur_val.appendSlice(a, std.mem.trim(u8, line, " \t")) catch {};
            continue;
        }
        if (cur_name.len > 0) list.append(a, .{ .name = cur_name, .value = cur_val.toOwnedSlice(a) catch "" }) catch {};
        cur_val = .empty;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            cur_name = "";
            continue;
        };
        cur_name = std.mem.trim(u8, line[0..colon], " \t");
        cur_val.appendSlice(a, std.mem.trim(u8, line[colon + 1 ..], " \t")) catch {};
    }
    if (cur_name.len > 0) list.append(a, .{ .name = cur_name, .value = cur_val.toOwnedSlice(a) catch "" }) catch {};
    return list.items;
}

fn first(hs: []const Header, name: []const u8) []const u8 {
    for (hs) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return "";
}

/// Last occurrence = the EARLIEST one added (headers are prepended as mail travels).
fn last(hs: []const Header, name: []const u8) []const u8 {
    var i = hs.len;
    while (i > 0) : (i -= 1) if (std.ascii.eqlIgnoreCase(hs[i - 1].name, name)) return hs[i - 1].value;
    return "";
}

/// Earliest header of this name whose value contains `needle`.
fn lastWith(hs: []const Header, name: []const u8, needle: []const u8) []const u8 {
    var i = hs.len;
    while (i > 0) : (i -= 1) {
        const h = hs[i - 1];
        if (std.ascii.eqlIgnoreCase(h.name, name) and std.ascii.indexOfIgnoreCase(h.value, needle) != null) return h.value;
    }
    return "";
}

fn count(hs: []const Header, name: []const u8) usize {
    var n: usize = 0;
    for (hs) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) {
        n += 1;
    };
    return n;
}

/// Mail-filtering services that re-inject mail (their later authentication results are expected to fail).
const gateways = [_][]const u8{ "inkyphishfence", "inky.com", "mimecast", "pphosted", "proofpoint", "barracuda", "messagelabs", "mailguard", "trendmicro", "sophos", "forcepoint", "cisco.com", "iphmx" };

/// Platforms that legitimately send on behalf of named people (not impersonation).
const notification_platforms = [_][]const u8{ "teams.mail.microsoft", "microsoft.com", "microsoftonline.com", "office365.com", "office.com", "sharepointonline.com", "yammer.com", "linkedin.com", "facebookmail.com", "google.com", "docusign.net", "zoom.us", "slack.com", "atlassian.net" };

fn isNotificationPlatform(d: []const u8) bool {
    for (notification_platforms) |p| if (domainIs(d, p)) return true;
    return false;
}

/// Minimal RFC 2047 decoding (UTF-8 / ASCII / Latin-1, B and Q encodings).
pub fn decodeWords(a: Allocator, s: []const u8) []const u8 {
    if (std.mem.indexOf(u8, s, "=?") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var last_was_word = false;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], "=?")) {
            const q1 = std.mem.indexOfScalarPos(u8, s, i + 2, '?') orelse break;
            const q2 = std.mem.indexOfScalarPos(u8, s, q1 + 1, '?') orelse break;
            const end = std.mem.indexOfPos(u8, s, q2 + 1, "?=") orelse break;
            const charset = s[i + 2 .. q1];
            const enc = s[q1 + 1 .. q2];
            const text = s[q2 + 1 .. end];
            var decoded: []const u8 = text;
            if (std.ascii.eqlIgnoreCase(enc, "B")) {
                const dec = std.base64.standard.Decoder;
                const n = dec.calcSizeForSlice(text) catch 0;
                const buf = a.alloc(u8, n) catch break;
                dec.decode(buf, text) catch {};
                decoded = buf;
            } else {
                var q: std.ArrayList(u8) = .empty;
                var k: usize = 0;
                while (k < text.len) : (k += 1) {
                    if (text[k] == '_') {
                        q.append(a, ' ') catch {};
                    } else if (text[k] == '=' and k + 2 < text.len) {
                        q.append(a, std.fmt.parseInt(u8, text[k + 1 .. k + 3], 16) catch '?') catch {};
                        k += 2;
                    } else q.append(a, text[k]) catch {};
                }
                decoded = q.items;
            }
            if (std.ascii.startsWithIgnoreCase(charset, "iso-8859") or std.ascii.startsWithIgnoreCase(charset, "windows-125"))
                decoded = pst.latin1ToUtf8(a, decoded) catch decoded;
            out.appendSlice(a, decoded) catch {};
            i = end + 2;
            last_was_word = true;
            continue;
        }
        // whitespace between two encoded words is dropped
        if (last_was_word and (s[i] == ' ' or s[i] == '\t')) {
            var j = i;
            while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
            if (std.mem.startsWith(u8, s[j..], "=?")) {
                i = j;
                continue;
            }
        }
        last_was_word = false;
        out.append(a, s[i]) catch {};
        i += 1;
    }
    return out.items;
}

/// Split an address header value into display name and address.
pub fn parseMailbox(a: Allocator, v: []const u8) struct { name: []const u8, addr: []const u8 } {
    const value = decodeWords(a, v);
    if (std.mem.lastIndexOfScalar(u8, value, '<')) |lt| {
        const gt = std.mem.indexOfScalarPos(u8, value, lt, '>') orelse value.len;
        return .{ .name = std.mem.trim(u8, value[0..lt], " \t\""), .addr = std.mem.trim(u8, value[lt + 1 .. gt], " ") };
    }
    return .{ .name = "", .addr = std.mem.trim(u8, value, " <>\"") };
}

const month_names = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };

fn daysFromCivil(y0: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Parse an RFC 5322 date ("Thu, 5 Nov 2026 08:24:07 +1100") to unix seconds (UTC).
pub fn parseDate(s: []const u8) ?i64 {
    var it = std.mem.tokenizeAny(u8, s, " ,\t");
    var day: ?i64 = null;
    var mon: ?i64 = null;
    var year: ?i64 = null;
    var h: i64 = 0;
    var mi: i64 = 0;
    var sec: i64 = 0;
    var have_time = false;
    var off: i64 = 0;
    while (it.next()) |tok| {
        if (std.mem.indexOfScalar(u8, tok, ':') != null and !have_time) {
            var tp = std.mem.splitScalar(u8, tok, ':');
            h = std.fmt.parseInt(i64, tp.next() orelse "0", 10) catch 0;
            mi = std.fmt.parseInt(i64, tp.next() orelse "0", 10) catch 0;
            sec = std.fmt.parseInt(i64, tp.next() orelse "0", 10) catch 0;
            have_time = true;
            continue;
        }
        if ((tok[0] == '+' or tok[0] == '-') and tok.len == 5 and have_time) {
            const v = std.fmt.parseInt(i64, tok[1..], 10) catch 0;
            off = (@divTrunc(v, 100) * 3600 + @mod(v, 100) * 60) * (if (tok[0] == '-') @as(i64, -1) else 1);
            continue;
        }
        if (std.ascii.isDigit(tok[0])) {
            const v = std.fmt.parseInt(i64, tok, 10) catch continue;
            if (day == null and v <= 31 and !have_time) day = v else if (year == null and v > 31) year = v;
            continue;
        }
        if (mon == null and tok.len >= 3) for (month_names, 0..) |mn, k| {
            if (std.ascii.eqlIgnoreCase(tok[0..3], mn)) {
                mon = @intCast(k + 1);
                break;
            }
        };
    }
    const y = year orelse return null;
    const yy = if (y < 100) y + 2000 else y;
    return daysFromCivil(yy, mon orelse return null, day orelse return null) * 86400 + h * 3600 + mi * 60 + sec - off;
}

fn isPrivateIp(ip: []const u8) bool {
    return std.mem.startsWith(u8, ip, "10.") or std.mem.startsWith(u8, ip, "192.168.") or std.mem.startsWith(u8, ip, "127.") or
        (std.mem.startsWith(u8, ip, "172.") and blk: {
            const rest = ip[4..];
            const dot = std.mem.indexOfScalar(u8, rest, '.') orelse break :blk false;
            const o = std.fmt.parseInt(u8, rest[0..dot], 10) catch break :blk false;
            break :blk o >= 16 and o <= 31;
        }) or std.ascii.startsWithIgnoreCase(ip, "fe80") or std.ascii.startsWithIgnoreCase(ip, "fd") or std.mem.eql(u8, ip, "::1");
}

fn looksLikeIp(s: []const u8) bool {
    if (s.len < 3 or s.len > 45) return false;
    var dots: usize = 0;
    var colons: usize = 0;
    for (s) |c| {
        if (c == '.') dots += 1 else if (c == ':') colons += 1 else if (!std.ascii.isHex(c)) return false;
    }
    return dots == 3 or colons >= 2;
}

fn parseReceived(a: Allocator, v: []const u8) Hop {
    var hop: Hop = .{};
    const semi = std.mem.lastIndexOfScalar(u8, v, ';');
    if (semi) |s| hop.time = parseDate(v[s + 1 ..]);
    const body = if (semi) |s| v[0..s] else v;
    var it = std.mem.tokenizeAny(u8, body, " \t");
    var prev: []const u8 = "";
    while (it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(prev, "from") and hop.from.len == 0) hop.from = tok;
        if (std.ascii.eqlIgnoreCase(prev, "by") and hop.by.len == 0) hop.by = tok;
        if (std.ascii.eqlIgnoreCase(prev, "with") and hop.with.len == 0) hop.with = tok;
        prev = tok;
    }
    // first IP literal inside [...] or (...)
    var i: usize = 0;
    while (i < body.len and hop.ip.len == 0) : (i += 1) {
        if (body[i] == '[' or body[i] == '(') {
            const close: u8 = if (body[i] == '[') ']' else ')';
            const e = std.mem.indexOfScalarPos(u8, body, i + 1, close) orelse break;
            var inner = std.mem.trim(u8, body[i + 1 .. e], " ");
            if (std.ascii.startsWithIgnoreCase(inner, "ipv6:")) inner = inner[5..];
            // "(host [1.2.3.4])" form
            if (std.mem.indexOfScalar(u8, inner, '[')) |b| {
                const e2 = std.mem.indexOfScalarPos(u8, inner, b, ']') orelse inner.len;
                inner = inner[b + 1 .. e2];
            }
            if (looksLikeIp(inner)) hop.ip = inner;
        }
    }
    _ = a;
    return hop;
}

fn kv(list: []const u8, key: []const u8, sep: u8, term: []const u8) []const u8 {
    var i: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(list, i, key)) |p| {
        const e = p + key.len;
        if (e < list.len and list[e] == sep and (p == 0 or !std.ascii.isAlphanumeric(list[p - 1]))) {
            const vs = e + 1;
            const ve = std.mem.indexOfAnyPos(u8, list, vs, term) orelse list.len;
            return std.mem.trim(u8, list[vs..ve], " ");
        }
        i = p + 1;
    }
    return "";
}

// ---------------------------------------------------------------- analysis

pub fn inputFromMessage(a: Allocator, m: *const pst.Message) Input {
    var addrs: std.ArrayList([]const u8) = .empty;
    for (m.recipients) |r| if (r.email.len > 0) addrs.append(a, r.email) catch {};
    return .{
        .headers = m.pc.string(a, pst.Tag.transport_headers) catch "",
        .sender_name = m.senderName(a) catch "",
        .sender_email = m.senderEmail(a) catch "",
        .recipient_addrs = addrs.items,
    };
}

pub fn analyse(a: Allocator, in: Input, ctx: Context) Analysis {
    var an: Analysis = .{};
    var findings: std.ArrayList(Finding) = .empty;
    const add = struct {
        fn f(al: Allocator, fl: *std.ArrayList(Finding), sev: Severity, comptime fmt: []const u8, args: anytype) void {
            fl.append(al, .{ .sev = sev, .text = std.fmt.allocPrint(al, fmt, args) catch fmt }) catch {};
        }
    }.f;

    const hs = parseHeaders(a, in.headers);
    an.has_headers = hs.len > 0;
    const from_h = first(hs, "From");
    if (from_h.len > 0) {
        const mb = parseMailbox(a, from_h);
        an.from_name = mb.name;
        an.from_addr = mb.addr;
    } else {
        an.from_name = in.sender_name;
        an.from_addr = in.sender_email;
    }
    an.from_domain = domainOf(an.from_addr);
    an.return_path = parseMailbox(a, first(hs, "Return-Path")).addr;
    an.reply_to = parseMailbox(a, first(hs, "Reply-To")).addr;
    an.message_id = first(hs, "Message-ID");
    an.date = parseDate(first(hs, "Date"));
    an.mailer = first(hs, "X-Mailer");
    if (an.mailer.len == 0) an.mailer = first(hs, "User-Agent");

    // org domains: given, else domains of this message's recipients (excluding free-mail)
    var org: std.ArrayList([]const u8) = .empty;
    for (ctx.org_domains) |d| org.append(a, d) catch {};
    if (org.items.len == 0) for (in.recipient_addrs) |r| {
        const d = domainOf(r);
        if (d.len > 0 and !isFreemail(d)) org.append(a, baseDomain(d)) catch {};
    };
    var from_is_internal = false;
    for (org.items) |d| if (domainIs(an.from_domain, d)) {
        from_is_internal = true;
    };

    if (an.has_headers) {
        // Authentication results: use the EARLIEST verdict (when the message first entered the
        // organisation). Filtering gateways such as INKY/Mimecast re-inject mail, and the later
        // re-checks fail because the gateway's servers are not the sender's.
        // Microsoft keeps the first-arrival verdict as "Authentication-Results-Original" (and the
        // first anti-spam report as "X-Forefront-Antispam-Report-Untrusted") when mail re-enters
        // the tenant from a gateway such as INKY.
        const ar_orig = last(hs, "Authentication-Results-Original");
        var ar = if (ar_orig.len > 0) ar_orig else lastWith(hs, "Authentication-Results", "spf=");
        if (ar.len == 0) ar = last(hs, "Authentication-Results");
        if (ar_orig.len > 0) add(a, &findings, .info, "Re-delivered through a filtering service; using Microsoft's original (first-arrival) authentication result", .{});
        an.spf = kv(ar, "spf", '=', " ;(");
        an.dkim = kv(ar, "dkim", '=', " ;(");
        an.dmarc = kv(ar, "dmarc", '=', " ;(");
        an.compauth = kv(ar, "compauth", '=', " ;(");
        if (count(hs, "Authentication-Results") > 1 or count(hs, "X-Forefront-Antispam-Report") > 1) {
            var gw: []const u8 = "";
            for (hs) |h| if (std.ascii.eqlIgnoreCase(h.name, "Received")) for (gateways) |g| {
                if (gw.len == 0 and std.ascii.indexOfIgnoreCase(h.value, g) != null) gw = g;
            };
            add(a, &findings, .info, "Message passed through the mail system more than once{s}{s}; using the first-arrival authentication result", .{ if (gw.len > 0) " via filtering service " else "", gw });
        }
        const fo = last(hs, "X-Forefront-Antispam-Report");
        const fo_orig = last(hs, "X-Forefront-Antispam-Report-Untrusted");
        an.client_ip = kv(if (fo_orig.len > 0) fo_orig else fo, "CIP", ':', ";");
        an.country = kv(if (fo_orig.len > 0) fo_orig else fo, "CTRY", ':', ";");
        if (an.country.len == 0 and fo_orig.len == 0) an.country = kv(fo, "CTRY", ':', ";");
        if (first(hs, "X-InkyPhishWall").len > 0 or first(hs, "X-Inky-Quarantine").len > 0) {
            const banner = first(hs, "X-Inky-BannerRequired");
            add(a, &findings, .info, "Scanned by INKY{s}", .{if (std.ascii.eqlIgnoreCase(banner, "true")) " (warning banner added)" else ""});
        }
        an.sfv = kv(fo, "SFV", ':', ";");
        an.cat = kv(fo, "CAT", ':', ";");
        an.scl = kv(fo, "SCL", ':', ";");
        an.direction = kv(fo, "DIR", ':', ";");
        an.bcl = kv(last(hs, "X-Microsoft-Antispam"), "BCL", ':', ";");
        if (an.scl.len == 0) an.scl = last(hs, "X-MS-Exchange-Organization-SCL");
        an.auth_as = last(hs, "X-MS-Exchange-Organization-AuthAs");
        if (an.client_ip.len == 0) an.client_ip = first(hs, "X-Originating-IP");
        an.client_ip = std.mem.trim(u8, an.client_ip, "[] ");

        var hops: std.ArrayList(Hop) = .empty;
        for (hs) |h| if (std.ascii.eqlIgnoreCase(h.name, "Received")) hops.append(a, parseReceived(a, h.value)) catch {};
        std.mem.reverse(Hop, hops.items); // origin first
        an.hops = hops.items;
        // the very first hop often names the sender's own computer and IP (e.g. "from LAPTOP.local ([1.2.3.4]) by smtp.gmail.com")
        if (an.hops.len > 0) {
            const h0 = an.hops[0];
            if (h0.ip.len > 0 and !isPrivateIp(h0.ip)) {
                an.origin_device = h0.from;
                an.origin_ip = h0.ip;
                add(a, &findings, .info, "Sent from device \"{s}\" at IP {s} (first relay: {s})", .{ h0.from, h0.ip, h0.by });
            }
        }

        // --- authentication
        if (std.ascii.startsWithIgnoreCase(an.dmarc, "fail")) add(a, &findings, .high, "DMARC failed for {s} - sender not authorised to use this domain", .{an.from_domain});
        if (std.ascii.startsWithIgnoreCase(an.compauth, "fail")) add(a, &findings, .high, "Microsoft composite authentication failed (compauth=fail)", .{});
        if (std.ascii.startsWithIgnoreCase(an.spf, "fail")) add(a, &findings, .medium, "SPF failed - sending server not permitted by the domain", .{});
        if (std.ascii.startsWithIgnoreCase(an.spf, "softfail")) add(a, &findings, .medium, "SPF softfail - sending server not clearly permitted", .{});
        if (std.ascii.startsWithIgnoreCase(an.dkim, "fail")) add(a, &findings, .medium, "DKIM signature failed - content may have been altered", .{});
        if (std.ascii.startsWithIgnoreCase(an.spf, "none") and (an.dkim.len == 0 or std.ascii.startsWithIgnoreCase(an.dkim, "none")))
            add(a, &findings, .low, "No SPF or DKIM authentication for the sender", .{});

        // --- Microsoft 365 verdicts
        const cats = [_]struct { c: []const u8, s: Severity, t: []const u8 }{
            .{ .c = "HPHSH", .s = .high, .t = "high-confidence phishing" },  .{ .c = "PHSH", .s = .high, .t = "phishing" },
            .{ .c = "SPOOF", .s = .high, .t = "spoofing" },                   .{ .c = "UIMP", .s = .high, .t = "user impersonation" },
            .{ .c = "DIMP", .s = .high, .t = "domain impersonation" },        .{ .c = "GIMP", .s = .high, .t = "mailbox-intelligence impersonation" },
            .{ .c = "MALW", .s = .high, .t = "malware" },                     .{ .c = "HSPM", .s = .medium, .t = "high-confidence spam" },
            .{ .c = "SPM", .s = .medium, .t = "spam" },                       .{ .c = "BULK", .s = .info, .t = "bulk mail" },
        };
        for (cats) |c| if (std.ascii.eqlIgnoreCase(an.cat, c.c)) add(a, &findings, c.s, "Microsoft 365 classified this as {s} (CAT:{s})", .{ c.t, c.c });
        if (std.ascii.eqlIgnoreCase(an.sfv, "SPM")) add(a, &findings, .medium, "Microsoft 365 spam filter verdict: spam (SFV:SPM)", .{});
        if (an.scl.len > 0) if (std.fmt.parseInt(i32, an.scl, 10)) |v| {
            if (v >= 5) add(a, &findings, .medium, "Spam confidence level {d}", .{v});
        } else |_| {};

        // --- envelope / reply mismatches
        const rp_d = domainOf(an.return_path);
        if (rp_d.len > 0 and an.from_domain.len > 0 and !std.ascii.eqlIgnoreCase(baseDomain(rp_d), baseDomain(an.from_domain)))
            add(a, &findings, .info, "Envelope sender (Return-Path) domain {s} differs from From domain {s}", .{ rp_d, an.from_domain });
        const rt_d = domainOf(an.reply_to);
        if (rt_d.len > 0 and an.from_domain.len > 0 and !std.ascii.eqlIgnoreCase(baseDomain(rt_d), baseDomain(an.from_domain)))
            add(a, &findings, if (isFreemail(rt_d)) .high else .medium, "Replies go to a different domain: Reply-To {s} (From {s})", .{ an.reply_to, an.from_addr });

        // --- timing
        if (an.date != null and an.hops.len > 0) if (an.hops[0].time) |t0| {
            const diff = @abs(t0 - an.date.?);
            if (diff > 2 * 3600) add(a, &findings, .low, "Date header differs from first relay time by {d} h", .{@divTrunc(diff, 3600)});
        };
        var prev_t: ?i64 = null;
        for (an.hops) |h| {
            if (h.time) |t| {
                if (prev_t) |p| if (t - p > 3600) add(a, &findings, .info, "Delivery delay of {d} min at {s}", .{ @divTrunc(t - p, 60), h.by });
                prev_t = t;
            }
        }
    }

    // --- impersonation (works with or without internet headers)
    if (an.from_name.len > 0 and std.mem.indexOfScalar(u8, an.from_name, '@') != null) {
        const inner = std.mem.trim(u8, an.from_name, " \"'<>");
        if (!std.ascii.eqlIgnoreCase(inner, an.from_addr) and std.ascii.indexOfIgnoreCase(an.from_name, an.from_addr) == null)
            add(a, &findings, .high, "Display name contains a different e-mail address (\"{s}\" sent from {s})", .{ an.from_name, an.from_addr });
    }
    const via_platform = isNotificationPlatform(an.from_domain) or std.ascii.indexOfIgnoreCase(an.from_name, " via ") != null;
    if (!from_is_internal and an.from_domain.len > 0 and !via_platform) {
        if (ctx.internal_names) |names| {
            const nn = normaliseName(a, an.from_name);
            if (nn.len >= 4) if (names.get(nn)) |internal_addr| {
                add(a, &findings, .high, "Impersonation: \"{s}\" is an internal user ({s}) but this came from {s}", .{ an.from_name, internal_addr, an.from_addr });
            };
        }
        for (org.items) |d| {
            const fb = baseDomain(an.from_domain);
            const dist = editDistance(fb, d);
            if (dist > 0 and dist <= 2 and fb.len >= 5) {
                add(a, &findings, .high, "Lookalike domain: {s} resembles {s}", .{ an.from_domain, d });
                break;
            }
        }
        if (isFreemail(an.from_domain) and an.from_name.len > 0) {
            const nm = std.mem.trim(u8, an.from_name, " \"'");
            if (std.mem.indexOfScalar(u8, nm, ' ') != null)
                add(a, &findings, .low, "Personal/free-mail address ({s}) using a person's name - verify sender", .{an.from_domain});
        }
    }
    an.findings = findings.items;
    for (an.findings) |f| if (@intFromEnum(f.sev) > @intFromEnum(an.risk)) {
        an.risk = f.sev;
    };
    if (an.risk == .info) an.risk = .none;
    return an;
}

/// Text block for preview panes.
pub fn reportText(a: Allocator, an: Analysis, fmt_time: *const fn (buf: []u8, t: ?i64) []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var tb: [96]u8 = undefined;
    out.print(a, "================ Header analysis: {s} ================\n", .{if (an.risk == .none) "no significant issues" else an.risk.label()}) catch {};
    for (an.findings) |f| out.print(a, "  [{s}] {s}\n", .{ f.sev.label(), f.text }) catch {};
    if (!an.has_headers) {
        out.appendSlice(a, "  No internet headers stored (internal message, sent item or draft).\n") catch {};
        return out.items;
    }
    out.print(a, "  From: {s} <{s}>   Return-Path: {s}   Reply-To: {s}\n", .{ an.from_name, an.from_addr, an.return_path, an.reply_to }) catch {};
    out.print(a, "  Auth: SPF={s}  DKIM={s}  DMARC={s}  compauth={s}\n", .{ orDash(an.spf), orDash(an.dkim), orDash(an.dmarc), orDash(an.compauth) }) catch {};
    if (an.origin_ip.len > 0) out.print(a, "  Sender device: {s}  IP: {s}\n", .{ orDash(an.origin_device), an.origin_ip }) catch {};
    out.print(a, "  Connecting IP: {s}  Country: {s}  Direction: {s}  Auth-as: {s}  M365 verdict: SFV={s} CAT={s} SCL={s} BCL={s}\n", .{ orDash(an.client_ip), orDash(an.country), orDash(an.direction), orDash(an.auth_as), orDash(an.sfv), orDash(an.cat), orDash(an.scl), orDash(an.bcl) }) catch {};
    if (an.mailer.len > 0) out.print(a, "  Mailer: {s}\n", .{an.mailer}) catch {};
    out.appendSlice(a, "  Delivery path (origin first):\n") catch {};
    var prev: ?i64 = null;
    for (an.hops, 0..) |h, i| {
        var delay: [32]u8 = undefined;
        const d = if (prev != null and h.time != null) (std.fmt.bufPrint(&delay, "+{d}s", .{h.time.? - prev.?}) catch "") else "";
        out.print(a, "   {d:>2}. {s}  {s} -> {s}  {s}{s}{s}\n", .{ i + 1, fmt_time(&tb, h.time), orDash(h.from), orDash(h.by), if (h.ip.len > 0) "[" else "", h.ip, if (h.ip.len > 0) "] " else "" }) catch {};
        if (d.len > 0) out.print(a, "       {s}\n", .{d}) catch {};
        if (h.time) |t| prev = t;
    }
    if (an.hops.len == 0) out.appendSlice(a, "   (no Received headers)\n") catch {};
    return out.items;
}

fn orDash(s: []const u8) []const u8 {
    return if (s.len == 0) "-" else s;
}

/// Build org knowledge from many messages: most common non-free-mail recipient base domain(s),
/// and display names of people with addresses in those domains.
pub const DirectoryBuilder = struct {
    domain_counts: std.StringHashMapUnmanaged(usize) = .empty,
    names: std.StringHashMapUnmanaged([]const u8) = .empty, // normalised name -> address (all domains)
    pairs: std.ArrayList(struct { name: []const u8, addr: []const u8 }) = .empty,

    pub fn addRecipientDomain(self: *DirectoryBuilder, a: Allocator, addr: []const u8) void {
        const d = domainOf(addr);
        if (d.len == 0 or isFreemail(d)) return;
        const b = baseDomain(d);
        const gop = self.domain_counts.getOrPut(a, b) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    pub fn addPerson(self: *DirectoryBuilder, a: Allocator, name: []const u8, addr: []const u8) void {
        if (name.len == 0 or std.mem.indexOfScalar(u8, addr, '@') == null) return;
        self.pairs.append(a, .{ .name = name, .addr = addr }) catch {};
    }
    /// Finish: returns context with the top org domain and internal names.
    pub fn finish(self: *DirectoryBuilder, a: Allocator, out_names: *std.StringHashMapUnmanaged([]const u8)) Context {
        var best: []const u8 = "";
        var best_n: usize = 0;
        var it = self.domain_counts.iterator();
        while (it.next()) |e| if (e.value_ptr.* > best_n) {
            best = e.key_ptr.*;
            best_n = e.value_ptr.*;
        };
        const doms = a.alloc([]const u8, if (best.len > 0) 1 else 0) catch return .{};
        if (best.len > 0) doms[0] = best;
        for (self.pairs.items) |p| {
            if (best.len == 0 or !domainIs(domainOf(p.addr), best)) continue;
            const nn = normaliseName(a, p.name);
            if (nn.len >= 4) out_names.put(a, nn, p.addr) catch {};
        }
        return .{ .org_domains = doms, .internal_names = out_names };
    }
};
