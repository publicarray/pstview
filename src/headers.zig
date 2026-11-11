//! Internet-header analysis (portable): delivery path, sender authentication, Microsoft 365
//! anti-spam verdicts and impersonation indicators.
//!
//! `analyse` is the fast triage pass used for whole folders (risk + findings). `analyseDetailed`
//! additionally decodes everything a message-header analyser shows (in the spirit of Microsoft's
//! Message Header Analyzer, MXToolbox and the Google Admin Toolbox): every Received hop with
//! hosts, IP, protocol, TLS and delays; every Authentication-Results / ARC / Received-SPF entry;
//! DKIM and ARC signatures; SPF/DKIM alignment with the From domain; decoded anti-spam fields;
//! indicators (IPs, hosts, addresses, URLs); and the full header list. Fully offline: no DNS,
//! reputation or geo-IP lookups.

const std = @import("std");
const pst = @import("pst.zig");
const mime = @import("mime.zig");
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
    /// Host named after "from" (as the sending server introduced itself).
    from: []const u8 = "",
    /// Comment after the "from" host: reverse DNS, HELO name and/or IP as seen by the receiver.
    from_detail: []const u8 = "",
    by: []const u8 = "",
    by_detail: []const u8 = "",
    ip: []const u8 = "",
    with: []const u8 = "",
    id: []const u8 = "",
    for_addr: []const u8 = "",
    /// TLS version / cipher when recorded ("TLS1_2 ECDHE-RSA-AES256-GCM-SHA384"), or "TLS" for ESMTPS.
    tls: []const u8 = "",
    time: ?i64 = null,
    /// Seconds since the previous hop (origin first); negative means clock skew between servers.
    delay: ?i64 = null,
    /// "Received" or "X-Received".
    header: []const u8 = "Received",
    raw: []const u8 = "",
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

/// One method result from Authentication-Results, ARC-Authentication-Results or Received-SPF.
pub const AuthResult = struct {
    header: []const u8,
    /// ARC instance (i=N) for ARC-Authentication-Results.
    instance: []const u8 = "",
    /// Server that evaluated the result (authserv-id), when given.
    authserv: []const u8 = "",
    method: []const u8 = "",
    result: []const u8 = "",
    /// Comments and reason= text.
    detail: []const u8 = "",
    /// Properties such as "smtp.mailfrom=example.com header.d=example.com".
    props: []const u8 = "",
};

/// DKIM-Signature, ARC-Message-Signature or ARC-Seal tags (signature data itself omitted).
pub const Signature = struct {
    header: []const u8,
    domain: []const u8 = "",
    selector: []const u8 = "",
    algorithm: []const u8 = "",
    identity: []const u8 = "",
    canonicalization: []const u8 = "",
    signed_headers: []const u8 = "",
    timestamp: ?i64 = null,
    expires: ?i64 = null,
    instance: []const u8 = "",
    /// ARC-Seal chain validation (cv=none|pass|fail).
    chain: []const u8 = "",
};

/// A decoded anti-spam / filtering field.
pub const Field = struct {
    /// Group shown in reports, e.g. "X-Forefront-Antispam-Report".
    group: []const u8,
    key: []const u8,
    value: []const u8,
    meaning: []const u8 = "",
};

pub const IocKind = enum {
    ip,
    host,
    email,
    url,

    pub fn label(k: IocKind) []const u8 {
        return switch (k) {
            .ip => "IP address",
            .host => "Host / domain",
            .email => "E-mail address",
            .url => "URL",
        };
    }
};

/// An indicator found in the headers, with the header it came from.
pub const Ioc = struct { kind: IocKind, value: []const u8, source: []const u8, private: bool = false };

pub const Alignment = enum {
    unknown,
    aligned,
    not_aligned,

    pub fn label(x: Alignment) []const u8 {
        return switch (x) {
            .unknown => "-",
            .aligned => "aligned",
            .not_aligned => "NOT aligned",
        };
    }
};

pub const Analysis = struct {
    has_headers: bool = false,
    subject: []const u8 = "",
    from_name: []const u8 = "",
    from_addr: []const u8 = "",
    from_domain: []const u8 = "",
    sender: []const u8 = "",
    to: []const u8 = "",
    cc: []const u8 = "",
    delivered_to: []const u8 = "",
    return_path: []const u8 = "",
    reply_to: []const u8 = "",
    message_id: []const u8 = "",
    in_reply_to: []const u8 = "",
    date: ?i64 = null,
    spf: []const u8 = "",
    dkim: []const u8 = "",
    dmarc: []const u8 = "",
    compauth: []const u8 = "",
    compauth_reason: []const u8 = "",
    /// Domain checked by SPF (smtp.mailfrom / envelope sender).
    spf_domain: []const u8 = "",
    /// Signing domain (header.d) of the DKIM result.
    dkim_domain: []const u8 = "",
    spf_alignment: Alignment = .unknown,
    dkim_alignment: Alignment = .unknown,
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
    /// Seconds from the first to the last recorded hop.
    transit: ?i64 = null,
    findings: []Finding = &.{},
    risk: Severity = .none,

    // ---- filled by analyseDetailed only
    auth: []AuthResult = &.{},
    signatures: []Signature = &.{},
    fields: []Field = &.{},
    iocs: []Ioc = &.{},
    all: []Header = &.{},

    /// Short text for list columns, e.g. "HIGH: impersonation of Peter Mahar".
    pub fn summary(self: Analysis) []const u8 {
        var best: ?Finding = null;
        for (self.findings) |f| if (best == null or @intFromEnum(f.sev) > @intFromEnum(best.?.sev)) {
            best = f;
        };
        if (best) |b| if (@intFromEnum(b.sev) >= @intFromEnum(Severity.low)) return b.text;
        return if (self.has_headers) "no issues found" else "no internet headers (internal/sent item)";
    }

    /// DMARC outcome from our own relaxed-alignment evaluation of the first-arrival results.
    pub fn dmarcComputed(self: Analysis) []const u8 {
        const spf_ok = std.ascii.startsWithIgnoreCase(self.spf, "pass") and self.spf_alignment == .aligned;
        const dkim_ok = std.ascii.startsWithIgnoreCase(self.dkim, "pass") and self.dkim_alignment == .aligned;
        if (self.spf.len == 0 and self.dkim.len == 0) return "-";
        return if (spf_ok or dkim_ok) "pass (aligned SPF or DKIM)" else "fail (no aligned SPF or DKIM pass)";
    }
};

pub const freemail = [_][]const u8{
    "gmail.com",      "googlemail.com",  "outlook.com",  "hotmail.com", "live.com",         "msn.com",        "yahoo.com",
    "yahoo.com.au",   "ymail.com",       "icloud.com",   "me.com",      "mac.com",          "aol.com",        "proton.me",
    "protonmail.com", "gmx.com",         "gmx.net",      "mail.com",    "zoho.com",         "yandex.com",     "bigpond.com",
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

/// Relaxed DMARC alignment: same organisational domain.
fn aligned(d: []const u8, from_domain: []const u8) Alignment {
    if (d.len == 0 or from_domain.len == 0) return .unknown;
    return if (std.ascii.eqlIgnoreCase(baseDomain(d), baseDomain(from_domain))) .aligned else .not_aligned;
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

/// Unfold and split raw headers into (name, value) pairs, in stored order (most recent first).
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
        if (std.mem.indexOfScalar(u8, cur_name, ' ') != null) {
            cur_name = ""; // not a header line (e.g. an mbox "From " separator)
            continue;
        }
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
        if (std.ascii.eqlIgnoreCase(h.name, name) and std.ascii.findIgnoreCase(h.value, needle) != null) return h.value;
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

/// RFC 2047 decoding of a header value (all charsets via `mime`).
pub fn decodeWords(a: Allocator, s: []const u8) []const u8 {
    return mime.decodeHeader(a, s);
}

/// Split an address header value into display name and address (first address of a list).
pub fn parseMailbox(a: Allocator, v: []const u8) struct { name: []const u8, addr: []const u8 } {
    const list = mime.parseAddresses(a, v);
    if (list.len == 0) return .{ .name = "", .addr = "" };
    return .{ .name = list[0].name, .addr = list[0].email };
}

/// Parse an RFC 5322 date to unix seconds (UTC).
pub fn parseDate(s: []const u8) ?i64 {
    return mime.parseDate(s);
}

pub fn isPrivateIp(ip: []const u8) bool {
    return std.mem.startsWith(u8, ip, "10.") or std.mem.startsWith(u8, ip, "192.168.") or std.mem.startsWith(u8, ip, "127.") or
        std.mem.startsWith(u8, ip, "169.254.") or std.mem.startsWith(u8, ip, "100.64.") or
        (std.mem.startsWith(u8, ip, "172.") and blk: {
            const rest = ip[4..];
            const dot = std.mem.indexOfScalar(u8, rest, '.') orelse break :blk false;
            const o = std.fmt.parseInt(u8, rest[0..dot], 10) catch break :blk false;
            break :blk o >= 16 and o <= 31;
        }) or std.ascii.startsWithIgnoreCase(ip, "fe80") or std.ascii.startsWithIgnoreCase(ip, "fd") or std.ascii.startsWithIgnoreCase(ip, "fc") or std.mem.eql(u8, ip, "::1");
}

fn isIpv4(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '.');
    var n: usize = 0;
    while (it.next()) |p| {
        if (p.len == 0 or p.len > 3) return false;
        const v = std.fmt.parseInt(u16, p, 10) catch return false;
        if (v > 255) return false;
        n += 1;
    }
    return n == 4;
}

fn isIpv6(s: []const u8) bool {
    if (s.len < 3 or s.len > 45) return false;
    var colons: usize = 0;
    for (s) |c| {
        if (c == ':') colons += 1 else if (!std.ascii.isHex(c) and c != '.') return false;
    }
    return colons >= 3 or (colons >= 2 and std.mem.indexOf(u8, s, "::") != null);
}

pub fn looksLikeIp(s: []const u8) bool {
    return isIpv4(s) or isIpv6(s);
}

/// First IP address in a Received comment such as "(mail.example.com [1.2.3.4])" or "(2603:10c6::20)".
fn findIp(s: []const u8) []const u8 {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, s, i, '[')) |b| {
        const e = std.mem.indexOfScalarPos(u8, s, b + 1, ']') orelse break;
        var inner = std.mem.trim(u8, s[b + 1 .. e], " ");
        if (std.ascii.startsWithIgnoreCase(inner, "ipv6:")) inner = inner[5..];
        if (looksLikeIp(inner)) return inner;
        i = e + 1;
    }
    var it = std.mem.tokenizeAny(u8, s, " \t()[],;=");
    while (it.next()) |tok| {
        const t = std.mem.trimEnd(u8, if (std.ascii.startsWithIgnoreCase(tok, "ipv6:")) tok[5..] else tok, ".");
        if (looksLikeIp(t)) return t;
    }
    return "";
}

/// TLS details of a Received line ("version=TLS1_2 cipher=..." / "using TLSv1.3 with cipher ...").
fn findTls(a: Allocator, raw: []const u8, with: []const u8) []const u8 {
    if (std.ascii.findIgnoreCase(raw, "version=TLS")) |p| {
        const ve = std.mem.indexOfAnyPos(u8, raw, p, " ,;)") orelse raw.len;
        const ver = raw[p + 8 .. ve];
        var cipher: []const u8 = "";
        if (std.ascii.findIgnoreCasePos(raw, p, "cipher=")) |c| {
            const ce = std.mem.indexOfAnyPos(u8, raw, c, " ,;)") orelse raw.len;
            cipher = raw[c + 7 .. ce];
        }
        return std.fmt.allocPrint(a, "{s}{s}{s}", .{ ver, if (cipher.len > 0) " " else "", cipher }) catch ver;
    }
    if (std.ascii.findIgnoreCase(raw, "using TLS")) |p| {
        const e = std.mem.indexOfScalarPos(u8, raw, p, ')') orelse raw.len;
        return std.mem.trim(u8, raw[p + 6 .. e], " (");
    }
    if (std.ascii.endsWithIgnoreCase(with, "S") or std.ascii.endsWithIgnoreCase(with, "SA") or std.ascii.findIgnoreCase(with, "HTTPS") != null) {
        if (std.ascii.startsWithIgnoreCase(with, "ESMTP") or std.ascii.startsWithIgnoreCase(with, "LMTP") or std.ascii.startsWithIgnoreCase(with, "SMTP") or std.ascii.findIgnoreCase(with, "HTTPS") != null) return "TLS";
    }
    return "";
}

/// Parse "from X (detail) by Y (detail) with P id I for <A>; date".
pub fn parseReceived(a: Allocator, name: []const u8, v: []const u8) Hop {
    var hop: Hop = .{ .header = name, .raw = v };
    const semi = std.mem.lastIndexOfScalar(u8, v, ';');
    if (semi) |s| hop.time = mime.parseDate(v[s + 1 ..]);
    const body = if (semi) |s| v[0..s] else v;
    const Kw = enum { none, from, by, via, with, id, for_ };
    var cur: Kw = .none;
    var filled = false; // value for `cur` taken
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == ' ' or c == '\t') {
            i += 1;
            continue;
        }
        if (c == '(') {
            var depth: usize = 0;
            var j = i;
            while (j < body.len) : (j += 1) {
                if (body[j] == '(') depth += 1;
                if (body[j] == ')') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            const comment = std.mem.trim(u8, body[i + 1 .. @min(j, body.len)], " ");
            switch (cur) {
                .from => if (hop.from_detail.len == 0) {
                    hop.from_detail = comment;
                },
                .by => if (hop.by_detail.len == 0) {
                    hop.by_detail = comment;
                },
                else => {},
            }
            i = @min(j + 1, body.len);
            continue;
        }
        var j = i;
        while (j < body.len and body[j] != ' ' and body[j] != '\t' and body[j] != '(') j += 1;
        const word = body[i..j];
        i = j;
        const kw: Kw = if (std.ascii.eqlIgnoreCase(word, "from")) .from else if (std.ascii.eqlIgnoreCase(word, "by")) .by else if (std.ascii.eqlIgnoreCase(word, "via")) .via else if (std.ascii.eqlIgnoreCase(word, "with")) .with else if (std.ascii.eqlIgnoreCase(word, "id")) .id else if (std.ascii.eqlIgnoreCase(word, "for")) .for_ else .none;
        if (kw != .none) {
            cur = kw;
            filled = false;
            continue;
        }
        if (filled) continue;
        filled = true;
        switch (cur) {
            .from => hop.from = word,
            .by => hop.by = word,
            .with => hop.with = word,
            .id => hop.id = std.mem.trimEnd(u8, word, ","),
            .for_ => hop.for_addr = std.mem.trim(u8, word, "<>,"),
            .via, .none => {},
        }
    }
    hop.ip = findIp(hop.from_detail);
    if (hop.ip.len == 0 and looksLikeIp(std.mem.trim(u8, hop.from, "[]"))) hop.ip = std.mem.trim(u8, hop.from, "[]");
    if (hop.ip.len == 0 and hop.from.len > 0) {
        // fall back to an IP literal before " by "
        const by_pos = std.ascii.findIgnoreCase(body, " by ") orelse body.len;
        hop.ip = findIp(body[0..by_pos]);
    }
    hop.tls = findTls(a, v, hop.with);
    return hop;
}

fn kv(list: []const u8, key: []const u8, sep: u8, term: []const u8) []const u8 {
    var i: usize = 0;
    while (std.ascii.findIgnoreCasePos(list, i, key)) |p| {
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

/// Split on `sep` outside parentheses and double quotes.
fn splitTop(a: Allocator, s: []const u8, sep: u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var in_q = false;
    var start: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '"') in_q = !in_q;
        if (in_q) continue;
        if (c == '(') depth += 1;
        if (c == ')' and depth > 0) depth -= 1;
        if (c == sep and depth == 0) {
            out.append(a, std.mem.trim(u8, s[start..i], " \t")) catch break;
            start = i + 1;
        }
    }
    out.append(a, std.mem.trim(u8, s[start..], " \t")) catch {};
    return out.items;
}

/// "method=result ..." (method has no '.', result is a word)?
fn isResultSeg(seg: []const u8) bool {
    const end = std.mem.indexOfAny(u8, seg, " \t(") orelse seg.len;
    const tok = seg[0..end];
    const eq = std.mem.indexOfScalar(u8, tok, '=') orelse return false;
    if (eq == 0 or eq + 1 >= tok.len) return false;
    for (tok[0..eq]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '/' or c == '_')) return false;
    return std.ascii.isAlphabetic(tok[eq + 1]);
}

/// Parse one Authentication-Results style value into per-method results.
pub fn parseAuthResults(a: Allocator, header: []const u8, value: []const u8, out: *std.ArrayList(AuthResult)) void {
    var authserv: []const u8 = "";
    var instance: []const u8 = "";
    for (splitTop(a, value, ';'), 0..) |seg, k| {
        if (seg.len == 0) continue;
        if (!isResultSeg(seg)) {
            if (std.ascii.startsWithIgnoreCase(seg, "i=") and instance.len == 0) {
                instance = std.mem.trim(u8, seg[2..], " ");
            } else if (k <= 1 and authserv.len == 0 and !std.mem.eql(u8, seg, "none")) {
                const e = std.mem.indexOfAny(u8, seg, " \t") orelse seg.len;
                authserv = seg[0..e];
            }
            continue;
        }
        var r: AuthResult = .{ .header = header, .instance = instance, .authserv = authserv };
        const end = std.mem.indexOfAny(u8, seg, " \t(") orelse seg.len;
        const tok = seg[0..end];
        const eq = std.mem.indexOfScalar(u8, tok, '=').?;
        r.method = tok[0..eq];
        r.result = tok[eq + 1 ..];
        var detail: std.ArrayList(u8) = .empty;
        var props: std.ArrayList(u8) = .empty;
        var i = end;
        while (i < seg.len) {
            const c = seg[i];
            if (c == ' ' or c == '\t') {
                i += 1;
                continue;
            }
            if (c == '(') {
                var depth: usize = 0;
                var j = i;
                while (j < seg.len) : (j += 1) {
                    if (seg[j] == '(') depth += 1;
                    if (seg[j] == ')') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                if (detail.items.len > 0) detail.appendSlice(a, "; ") catch {};
                detail.appendSlice(a, std.mem.trim(u8, seg[i + 1 .. @min(j, seg.len)], " ")) catch {};
                i = @min(j + 1, seg.len);
                continue;
            }
            var j = i;
            var in_q = false;
            while (j < seg.len and (in_q or (seg[j] != ' ' and seg[j] != '\t' and seg[j] != '('))) : (j += 1) {
                if (seg[j] == '"') in_q = !in_q;
            }
            const w = seg[i..j];
            if (std.ascii.startsWithIgnoreCase(w, "reason=")) {
                if (detail.items.len > 0) detail.appendSlice(a, "; ") catch {};
                detail.appendSlice(a, std.mem.trim(u8, w, "\"")) catch {};
            } else {
                if (props.items.len > 0) props.append(a, ' ') catch {};
                props.appendSlice(a, w) catch {};
            }
            i = j;
        }
        r.detail = detail.items;
        r.props = props.items;
        out.append(a, r) catch {};
    }
}

/// Received-SPF: "Pass (comment) client-ip=...; envelope-from=...; helo=...".
fn parseReceivedSpf(a: Allocator, value: []const u8, out: *std.ArrayList(AuthResult)) void {
    var r: AuthResult = .{ .header = "Received-SPF", .method = "spf" };
    const end = std.mem.indexOfAny(u8, value, " \t(;") orelse value.len;
    r.result = value[0..end];
    var rest = value[end..];
    if (std.mem.indexOfScalar(u8, rest, '(')) |p| {
        if (std.mem.indexOfScalarPos(u8, rest, p, ')')) |q| {
            r.detail = rest[p + 1 .. q];
            rest = rest[q + 1 ..];
        }
    }
    var props: std.ArrayList(u8) = .empty;
    for (splitTop(a, rest, ';')) |seg| {
        var it = std.mem.tokenizeAny(u8, seg, " \t");
        while (it.next()) |w| if (std.mem.indexOfScalar(u8, w, '=') != null) {
            if (props.items.len > 0) props.append(a, ' ') catch {};
            props.appendSlice(a, w) catch {};
        };
    }
    r.props = props.items;
    out.append(a, r) catch {};
}

/// Value of "key=" in an Authentication-Results props string ("smtp.mailfrom=x header.d=y").
fn prop(props: []const u8, key: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, props, " \t");
    while (it.next()) |w| {
        if (w.len > key.len and std.ascii.startsWithIgnoreCase(w, key) and w[key.len] == '=') return std.mem.trim(u8, w[key.len + 1 ..], "\"");
    }
    return "";
}

/// "tag=value; tag=value" (DKIM / ARC); whitespace inside values removed.
fn tag(a: Allocator, v: []const u8, name: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, v, ';');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, p[0..eq], " \t"), name)) continue;
        const val = std.mem.trim(u8, p[eq + 1 ..], " \t");
        if (std.mem.indexOfAny(u8, val, " \t") == null) return val;
        var out: std.ArrayList(u8) = .empty;
        for (val) |c| if (c != ' ' and c != '\t') out.append(a, c) catch {};
        return out.items;
    }
    return "";
}

fn parseSignature(a: Allocator, header: []const u8, v: []const u8) Signature {
    const t = std.fmt.parseInt(i64, tag(a, v, "t"), 10) catch null;
    const x = std.fmt.parseInt(i64, tag(a, v, "x"), 10) catch null;
    return .{
        .header = header,
        .domain = tag(a, v, "d"),
        .selector = tag(a, v, "s"),
        .algorithm = tag(a, v, "a"),
        .identity = tag(a, v, "i"),
        .canonicalization = tag(a, v, "c"),
        .signed_headers = tag(a, v, "h"),
        .timestamp = t,
        .expires = x,
        .instance = tag(a, v, "i"),
        .chain = tag(a, v, "cv"),
    };
}

// ---------------------------------------------------------------- anti-spam field meanings

const Meaning = struct { k: []const u8, v: []const u8 = "", m: []const u8 };

/// Microsoft 365 X-Forefront-Antispam-Report fields (Microsoft Learn: "Anti-spam message headers").
const forefront = [_]Meaning{
    .{ .k = "ARC", .m = "ARC fields evaluated (AAR = Authentication-Results, AMS = message signature, AS = seal)" },
    .{ .k = "CAT", .v = "AMP", .m = "Anti-malware policy" },
    .{ .k = "CAT", .v = "BIMP", .m = "Brand impersonation" },
    .{ .k = "CAT", .v = "BULK", .m = "Bulk mail" },
    .{ .k = "CAT", .v = "DIMP", .m = "Domain impersonation" },
    .{ .k = "CAT", .v = "FTBP", .m = "Anti-malware common attachments filter (file type blocked)" },
    .{ .k = "CAT", .v = "GIMP", .m = "Mailbox intelligence impersonation" },
    .{ .k = "CAT", .v = "HPHSH", .m = "High confidence phishing" },
    .{ .k = "CAT", .v = "HPHISH", .m = "High confidence phishing" },
    .{ .k = "CAT", .v = "HSPM", .m = "High confidence spam" },
    .{ .k = "CAT", .v = "INTOS", .m = "Intra-organisation phishing" },
    .{ .k = "CAT", .v = "MALW", .m = "Malware" },
    .{ .k = "CAT", .v = "NONE", .m = "No category (not spam/phish)" },
    .{ .k = "CAT", .v = "OSPM", .m = "Outbound spam" },
    .{ .k = "CAT", .v = "PHSH", .m = "Phishing" },
    .{ .k = "CAT", .v = "SAP", .m = "Safe Attachments" },
    .{ .k = "CAT", .v = "SPM", .m = "Spam" },
    .{ .k = "CAT", .v = "SPOOF", .m = "Spoofing" },
    .{ .k = "CAT", .v = "UIMP", .m = "User impersonation" },
    .{ .k = "CAT", .m = "Protection policy category applied" },
    .{ .k = "CIP", .m = "Connecting IP address (the server that handed the message to Microsoft 365)" },
    .{ .k = "CTRY", .m = "Country of the connecting IP" },
    .{ .k = "DIR", .v = "INB", .m = "Inbound message" },
    .{ .k = "DIR", .v = "OUT", .m = "Outbound message" },
    .{ .k = "DIR", .v = "INT", .m = "Intra-organisation message" },
    .{ .k = "DIR", .m = "Message direction" },
    .{ .k = "H", .m = "HELO/EHLO name the connecting server announced" },
    .{ .k = "IPV", .v = "CAL", .m = "Connecting IP on an IP Allow List - spam filtering skipped" },
    .{ .k = "IPV", .v = "NLI", .m = "Connecting IP not listed on any IP reputation list" },
    .{ .k = "IPV", .m = "IP reputation verdict" },
    .{ .k = "LANG", .m = "Language the message is written in" },
    .{ .k = "PTR", .m = "Reverse DNS (PTR) of the connecting IP" },
    .{ .k = "SCL", .m = "Spam confidence level" },
    .{ .k = "SFS", .m = "Spam filter rules matched (internal IDs)" },
    .{ .k = "SFTY", .v = "9.19", .m = "Phishing safety tip: domain impersonation" },
    .{ .k = "SFTY", .v = "9.20", .m = "Phishing safety tip: user impersonation" },
    .{ .k = "SFTY", .m = "Phishing safety tip category" },
    .{ .k = "SFV", .v = "BLK", .m = "Filtering skipped: sender on the recipient's Blocked Senders list" },
    .{ .k = "SFV", .v = "NSPM", .m = "Not spam" },
    .{ .k = "SFV", .v = "SFE", .m = "Filtering skipped: sender on the recipient's Safe Senders list" },
    .{ .k = "SFV", .v = "SKA", .m = "Filtering skipped: sender allowed by anti-spam policy" },
    .{ .k = "SFV", .v = "SKB", .m = "Marked spam: sender blocked by anti-spam policy" },
    .{ .k = "SFV", .v = "SKI", .m = "Filtering skipped: intra-organisation message" },
    .{ .k = "SFV", .v = "SKN", .m = "Marked non-spam before filtering (e.g. mail flow rule)" },
    .{ .k = "SFV", .v = "SKQ", .m = "Released from quarantine" },
    .{ .k = "SFV", .v = "SKS", .m = "Marked spam before filtering (e.g. mail flow rule)" },
    .{ .k = "SFV", .v = "SPM", .m = "Spam" },
    .{ .k = "SFV", .m = "Spam filtering verdict" },
    .{ .k = "SRV", .v = "BULK", .m = "Identified as bulk mail (BCL above threshold)" },
    .{ .k = "X-CustomSpam", .m = "Advanced Spam Filter (ASF) option matched" },
    .{ .k = "PCL", .m = "Phishing confidence level (legacy)" },
};

fn sclMeaning(v: []const u8) []const u8 {
    const n = std.fmt.parseInt(i32, std.mem.trim(u8, v, " "), 10) catch return "Spam confidence level";
    return switch (n) {
        -1 => "SCL -1: filtering skipped (safe sender / internal / allow rule) - delivered to Inbox",
        0, 1 => "SCL 0-1: not spam - delivered to Inbox",
        5, 6 => "SCL 5-6: spam",
        7, 8, 9 => "SCL 7-9: high confidence spam",
        else => "Spam confidence level",
    };
}

fn bclMeaning(v: []const u8) []const u8 {
    const n = std.fmt.parseInt(i32, std.mem.trim(u8, v, " "), 10) catch return "Bulk complaint level";
    return switch (n) {
        0 => "BCL 0: not from a bulk sender",
        1, 2, 3 => "BCL 1-3: bulk sender with few complaints",
        4, 5, 6, 7 => "BCL 4-7: bulk sender with a mixed number of complaints",
        8, 9 => "BCL 8-9: bulk sender with many complaints",
        else => "Bulk complaint level",
    };
}

fn compauthMeaning(reason: []const u8) []const u8 {
    if (reason.len == 0) return "";
    return switch (reason[0]) {
        '0' => "Failed composite authentication (explicit or implicit fail)",
        '1', '7' => "Passed composite authentication",
        '2' => "Soft-passed implicit authentication",
        '3' => "Not checked for composite authentication",
        '4', '9' => "Composite authentication bypassed",
        '6' => "Failed implicit authentication (sending domain is an accepted domain)",
        else => "",
    };
}

fn forefrontMeaning(key: []const u8, val: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(key, "SCL")) return sclMeaning(val);
    var generic: []const u8 = "";
    for (forefront) |f| {
        if (!std.ascii.eqlIgnoreCase(f.k, key)) continue;
        if (f.v.len == 0) {
            if (generic.len == 0) generic = f.m;
        } else if (std.ascii.eqlIgnoreCase(f.v, std.mem.trim(u8, val, " "))) return f.m;
    }
    return generic;
}

/// Microsoft 365 / Exchange Online organisation headers.
const ms_headers = [_]Meaning{
    .{ .k = "X-MS-Exchange-Organization-AuthAs", .v = "Anonymous", .m = "Sender not authenticated (external / internet mail)" },
    .{ .k = "X-MS-Exchange-Organization-AuthAs", .v = "Internal", .m = "Sender authenticated as a user of this organisation" },
    .{ .k = "X-MS-Exchange-Organization-AuthAs", .v = "Partner", .m = "Sender authenticated as a partner organisation" },
    .{ .k = "X-MS-Exchange-Organization-AuthAs", .m = "How the sender was authenticated" },
    .{ .k = "X-MS-Exchange-Organization-AuthSource", .m = "Server that evaluated sender authentication" },
    .{ .k = "X-MS-Exchange-Organization-AuthMechanism", .m = "Authentication mechanism code" },
    .{ .k = "X-MS-Exchange-Organization-MessageDirectionality", .v = "Incoming", .m = "Received from outside the organisation" },
    .{ .k = "X-MS-Exchange-Organization-MessageDirectionality", .v = "Originating", .m = "Sent from inside the organisation" },
    .{ .k = "X-MS-Exchange-Organization-Network-Message-Id", .m = "Message ID inside the tenant (use with message trace)" },
    .{ .k = "X-MS-Exchange-Organization-OriginalArrivalTime", .m = "When the message first arrived in the tenant" },
    .{ .k = "X-MS-Exchange-Organization-OriginalClientIPAddress", .m = "IP of the client that submitted the message" },
    .{ .k = "X-MS-Exchange-Organization-OriginalServerIPAddress", .m = "IP of the server that first accepted the message" },
    .{ .k = "X-MS-Exchange-Organization-SCL", .m = "Spam confidence level stamped by Exchange" },
    .{ .k = "X-MS-Exchange-Organization-PCL", .m = "Phishing confidence level (legacy)" },
    .{ .k = "X-MS-Exchange-Organization-ExpirationStartTime", .m = "Start of the transport expiry window" },
    .{ .k = "X-MS-Exchange-Organization-MessageLatency", .m = "Transport latency details" },
    .{ .k = "X-MS-Exchange-CrossTenant-Id", .m = "Microsoft 365 tenant ID that processed the message" },
    .{ .k = "X-MS-Exchange-CrossTenant-OriginalArrivalTime", .m = "First arrival time in the tenant" },
    .{ .k = "X-MS-Exchange-CrossTenant-FromEntityHeader", .v = "Internet", .m = "Message came from the internet" },
    .{ .k = "X-MS-Exchange-CrossTenant-FromEntityHeader", .v = "Hosted", .m = "Message came from a mailbox in Microsoft 365" },
    .{ .k = "X-MS-Exchange-CrossTenant-FromEntityHeader", .m = "Origin of the message" },
    .{ .k = "X-MS-Exchange-CrossTenant-AuthAs", .m = "Cross-tenant authentication state" },
    .{ .k = "X-MS-Exchange-CrossTenant-AuthSource", .m = "Server that evaluated cross-tenant authentication" },
    .{ .k = "X-MS-Exchange-CrossTenant-Network-Message-Id", .m = "Network message ID (message trace)" },
    .{ .k = "X-MS-Exchange-CrossTenant-UserPrincipalName", .m = "Sending user (UPN) for outbound mail" },
    .{ .k = "X-MS-Exchange-CrossTenant-MailboxType", .m = "Mailbox type of the sender" },
    .{ .k = "X-MS-Exchange-Transport-CrossTenantHeadersStamped", .m = "Server that stamped the cross-tenant headers" },
    .{ .k = "X-MS-Office365-Filtering-Correlation-Id", .m = "Correlation ID for Microsoft support / message trace" },
    .{ .k = "X-MS-TrafficTypeDiagnostic", .m = "Transport routing diagnostic" },
    .{ .k = "X-MS-PublicTrafficType", .m = "Traffic type" },
    .{ .k = "X-MS-Has-Attach", .m = "Outlook: message had attachments when sent" },
    .{ .k = "X-MS-TNEF-Correlator", .m = "Outlook rich-text (TNEF) correlator" },
    .{ .k = "X-Originating-IP", .m = "IP of the client that composed/sent the message" },
    .{ .k = "X-MS-Exchange-Organization-RecordReviewCfmType", .m = "Retention / records review type" },
};

fn msMeaning(name: []const u8, val: []const u8) []const u8 {
    var generic: []const u8 = "";
    for (ms_headers) |f| {
        if (!std.ascii.eqlIgnoreCase(f.k, name)) continue;
        if (f.v.len == 0) {
            if (generic.len == 0) generic = f.m;
        } else if (std.ascii.eqlIgnoreCase(f.v, std.mem.trim(u8, val, " "))) return f.m;
    }
    if (generic.len == 0 and std.ascii.eqlIgnoreCase(name, "X-MS-Exchange-Organization-SCL")) return sclMeaning(val);
    return generic;
}

/// Other filtering products recognisable by header prefix.
const vendor_prefixes = [_]struct { p: []const u8, vendor: []const u8 }{
    .{ .p = "X-Mimecast-", .vendor = "Mimecast" },                      .{ .p = "X-MC-Unique", .vendor = "Mimecast" },
    .{ .p = "X-Proofpoint-", .vendor = "Proofpoint" },                  .{ .p = "X-Barracuda-", .vendor = "Barracuda" },
    .{ .p = "X-IronPort-", .vendor = "Cisco Secure Email (IronPort)" }, .{ .p = "X-IPAS-", .vendor = "Cisco Secure Email (IronPort)" },
    .{ .p = "X-Inky", .vendor = "INKY" },                               .{ .p = "X-Sophos-", .vendor = "Sophos" },
    .{ .p = "X-TM-AS-", .vendor = "Trend Micro" },                      .{ .p = "X-TMASE-", .vendor = "Trend Micro" },
    .{ .p = "X-SpamExperts-", .vendor = "SpamExperts" },                .{ .p = "X-MailGuard-", .vendor = "MailGuard" },
    .{ .p = "X-SEG-", .vendor = "Secure email gateway" },               .{ .p = "X-Gm-", .vendor = "Gmail" },
    .{ .p = "X-Google-", .vendor = "Gmail" },                           .{ .p = "X-Forefront-", .vendor = "Microsoft 365" },
    .{ .p = "X-Spam-", .vendor = "SpamAssassin / filter" },             .{ .p = "X-Rspamd-", .vendor = "Rspamd" },
};

fn decodeFields(a: Allocator, hs: []const Header, out: *std.ArrayList(Field)) void {
    for (hs) |h| {
        const n = h.name;
        if (std.ascii.eqlIgnoreCase(n, "X-Forefront-Antispam-Report") or std.ascii.eqlIgnoreCase(n, "X-Forefront-Antispam-Report-Untrusted")) {
            for (splitTop(a, h.value, ';')) |item| {
                const c = std.mem.indexOfScalar(u8, item, ':') orelse continue;
                const k = std.mem.trim(u8, item[0..c], " ");
                const v = std.mem.trim(u8, item[c + 1 ..], " ");
                out.append(a, .{ .group = n, .key = k, .value = v, .meaning = forefrontMeaning(k, v) }) catch {};
            }
        } else if (std.ascii.eqlIgnoreCase(n, "X-Microsoft-Antispam") or std.ascii.eqlIgnoreCase(n, "X-Microsoft-Antispam-Untrusted")) {
            for (splitTop(a, h.value, ';')) |item| {
                const c = std.mem.indexOfScalar(u8, item, ':') orelse continue;
                const k = std.mem.trim(u8, item[0..c], " ");
                const v = std.mem.trim(u8, item[c + 1 ..], " ");
                const m: []const u8 = if (std.ascii.eqlIgnoreCase(k, "BCL")) bclMeaning(v) else if (std.ascii.eqlIgnoreCase(k, "PCL")) "Phishing confidence level (legacy)" else if (std.ascii.eqlIgnoreCase(k, "RULEID")) "Anti-spam rule IDs" else if (std.ascii.eqlIgnoreCase(k, "ARA")) "Anti-spam rule actions (internal)" else "";
                out.append(a, .{ .group = n, .key = k, .value = v, .meaning = m }) catch {};
            }
        } else if (std.ascii.startsWithIgnoreCase(n, "X-MS-Exchange-") or std.ascii.startsWithIgnoreCase(n, "X-MS-Office365-") or
            std.ascii.eqlIgnoreCase(n, "X-MS-Has-Attach") or std.ascii.eqlIgnoreCase(n, "X-MS-TNEF-Correlator") or
            std.ascii.eqlIgnoreCase(n, "X-MS-TrafficTypeDiagnostic") or std.ascii.eqlIgnoreCase(n, "X-MS-PublicTrafficType") or
            std.ascii.eqlIgnoreCase(n, "X-Originating-IP"))
        {
            if (std.ascii.endsWithIgnoreCase(n, "-Message-Info") or std.ascii.findIgnoreCase(n, "AntiSpam-MessageData") != null) continue; // opaque blobs
            out.append(a, .{ .group = "Microsoft 365 / Exchange", .key = n, .value = h.value, .meaning = msMeaning(n, h.value) }) catch {};
        } else if (std.ascii.eqlIgnoreCase(n, "X-Spam-Status")) {
            // SpamAssassin: "Yes, score=7.2 required=5.0 tests=A,B autolearn=no"
            const verdict = std.mem.trim(u8, h.value[0 .. std.mem.indexOfAny(u8, h.value, ", ") orelse h.value.len], " ");
            out.append(a, .{ .group = "SpamAssassin", .key = "Verdict", .value = verdict, .meaning = if (std.ascii.startsWithIgnoreCase(verdict, "yes")) "Classified as spam" else "Not classified as spam" }) catch {};
            for ([_][]const u8{ "score", "hits", "required", "tests", "autolearn", "version" }) |key| {
                var v = kv(h.value, key, '=', " \t");
                if (std.mem.eql(u8, key, "tests") and v.len > 0) {
                    // a folded test list continues until the next "name=" token
                    const p = std.ascii.findIgnoreCase(h.value, "tests=").? + 6;
                    var joined: std.ArrayList(u8) = .empty;
                    var it = std.mem.tokenizeAny(u8, h.value[p..], " \t");
                    while (it.next()) |tok| {
                        if (joined.items.len > 0 and std.mem.indexOfScalar(u8, tok, '=') != null) break;
                        joined.appendSlice(a, tok) catch break;
                    }
                    v = joined.items;
                }
                if (v.len > 0) out.append(a, .{ .group = "SpamAssassin", .key = key, .value = v, .meaning = if (std.mem.eql(u8, key, "required")) "Score at which mail is spam" else if (std.mem.eql(u8, key, "tests")) "Rules that matched" else "" }) catch {};
            }
        } else {
            for (vendor_prefixes) |vp| {
                if (std.ascii.eqlIgnoreCase(vp.vendor, "Microsoft 365")) continue;
                if (std.ascii.startsWithIgnoreCase(n, vp.p)) {
                    if (std.ascii.findIgnoreCase(n, "DKIM-Signature") != null) break;
                    out.append(a, .{ .group = vp.vendor, .key = n, .value = h.value }) catch {};
                    break;
                }
            }
        }
    }
}

// ---------------------------------------------------------------- indicators

const IocSet = struct {
    a: Allocator,
    list: std.ArrayList(Ioc) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,

    fn add(self: *IocSet, kind: IocKind, value_in: []const u8, source: []const u8) void {
        const value = std.mem.trim(u8, value_in, " \t<>[]()\"'.,;");
        if (value.len < 3) return;
        switch (kind) {
            .host => if (std.mem.indexOfScalar(u8, value, '.') == null or looksLikeIp(value) or std.mem.indexOfScalar(u8, value, '@') != null) return,
            .email => if (std.mem.indexOfScalar(u8, value, '@') == null or std.mem.indexOfScalar(u8, value, ' ') != null) return,
            .ip => if (!looksLikeIp(value)) return,
            .url => {},
        }
        const lower = std.ascii.allocLowerString(self.a, value) catch return;
        const key = std.fmt.allocPrint(self.a, "{d}:{s}", .{ @intFromEnum(kind), lower }) catch return;
        if (self.seen.contains(key)) return;
        self.seen.put(self.a, key, {}) catch return;
        self.list.append(self.a, .{ .kind = kind, .value = value, .source = source, .private = kind == .ip and isPrivateIp(value) }) catch {};
    }

    fn addAddrs(self: *IocSet, v: []const u8, source: []const u8) void {
        for (mime.parseAddresses(self.a, v)) |ad| {
            self.add(.email, ad.email, source);
            self.add(.host, domainOf(ad.email), source);
        }
    }

    fn addUrls(self: *IocSet, v: []const u8, source: []const u8) void {
        var i: usize = 0;
        while (std.ascii.findIgnoreCasePos(v, i, "http")) |p| {
            i = p + 4;
            if (!(std.ascii.startsWithIgnoreCase(v[p..], "http://") or std.ascii.startsWithIgnoreCase(v[p..], "https://"))) continue;
            const e = std.mem.indexOfAnyPos(u8, v, p, " \t<>\",;") orelse v.len;
            self.add(.url, v[p..e], source);
            i = e;
        }
        var j: usize = 0;
        while (std.ascii.findIgnoreCasePos(v, j, "mailto:")) |p| {
            const e = std.mem.indexOfAnyPos(u8, v, p, " \t<>\",;?") orelse v.len;
            self.add(.email, v[p + 7 .. e], source);
            j = e;
        }
    }
};

fn collectIocs(a: Allocator, an: *const Analysis, hs: []const Header, auth: []const AuthResult, sigs: []const Signature, fields: []const Field) []Ioc {
    var s: IocSet = .{ .a = a };
    for (an.hops) |h| {
        s.add(.ip, h.ip, h.header);
        s.add(.host, h.from, h.header);
        s.add(.host, h.by, h.header);
        // reverse DNS / HELO names inside the from comment
        var it = std.mem.tokenizeAny(u8, h.from_detail, " \t()[],;=");
        while (it.next()) |tok| s.add(.host, std.mem.trimEnd(u8, tok, "."), h.header);
        s.addAddrs(h.for_addr, h.header);
    }
    for (fields) |f| {
        if (std.ascii.eqlIgnoreCase(f.key, "CIP") or std.ascii.endsWithIgnoreCase(f.key, "IPAddress") or std.ascii.eqlIgnoreCase(f.key, "X-Originating-IP")) s.add(.ip, f.value, f.group);
        if (std.ascii.eqlIgnoreCase(f.key, "PTR") or std.ascii.eqlIgnoreCase(f.key, "H")) s.add(.host, f.value, f.group);
    }
    for (auth) |r| {
        const src = r.header;
        s.add(.ip, prop(r.props, "client-ip"), src);
        if (std.ascii.findIgnoreCase(r.detail, "sender IP is ")) |p| {
            const e = std.mem.indexOfAnyPos(u8, r.detail, p + 13, " ;)") orelse r.detail.len;
            s.add(.ip, r.detail[p + 13 .. e], src);
        }
        if (std.ascii.findIgnoreCase(r.detail, "designates ")) |p| {
            const e = std.mem.indexOfAnyPos(u8, r.detail, p + 11, " ;)") orelse r.detail.len;
            s.add(.ip, r.detail[p + 11 .. e], src);
        }
        for ([_][]const u8{ "smtp.mailfrom", "envelope-from", "header.from", "header.d", "header.i", "smtp.helo", "helo" }) |k| {
            const v = prop(r.props, k);
            if (std.mem.indexOfScalar(u8, v, '@') != null) {
                s.add(.email, v, src);
                s.add(.host, domainOf(v), src);
            } else s.add(.host, v, src);
        }
    }
    for (sigs) |g| s.add(.host, g.domain, g.header);
    for ([_][]const u8{ "From", "Sender", "Reply-To", "Return-Path", "To", "Cc", "Delivered-To", "X-Original-To", "Errors-To", "Disposition-Notification-To", "Return-Receipt-To", "X-Sender", "X-Envelope-From" }) |name| {
        for (hs) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) s.addAddrs(h.value, h.name);
    }
    for (hs) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Message-ID") or std.ascii.eqlIgnoreCase(h.name, "In-Reply-To") or std.ascii.eqlIgnoreCase(h.name, "References")) {
            var it = std.mem.tokenizeAny(u8, h.value, " \t<>");
            while (it.next()) |id| s.add(.host, domainOf(id), h.name);
        }
        if (std.ascii.eqlIgnoreCase(h.name, "X-Sender-IP") or std.ascii.eqlIgnoreCase(h.name, "X-Originating-IP") or std.ascii.eqlIgnoreCase(h.name, "X-Source-IP")) s.add(.ip, h.value, h.name);
        if (std.ascii.startsWithIgnoreCase(h.name, "DKIM-") or std.ascii.startsWithIgnoreCase(h.name, "ARC-") or std.ascii.findIgnoreCase(h.name, "Signature") != null) continue;
        s.addUrls(h.value, h.name);
    }
    return s.list.items;
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

/// Input for a block of raw headers alone (pasted text, .eml/.txt file).
pub fn inputFromHeaders(a: Allocator, raw: []const u8) Input {
    const hs = parseHeaders(a, raw);
    var addrs: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "To", "Cc", "Delivered-To" }) |n| for (mime.parseAddresses(a, first(hs, n))) |ad| addrs.append(a, ad.email) catch {};
    const from = parseMailbox(a, first(hs, "From"));
    return .{ .headers = raw, .sender_name = from.name, .sender_email = from.addr, .recipient_addrs = addrs.items };
}

/// The header block of a saved message or of pasted headers (a BOM, leading blank lines and an
/// mbox "From " separator are skipped; everything up to the first empty line).
pub fn headerBlock(data: []const u8) []const u8 {
    var d = data;
    if (std.mem.startsWith(u8, d, "\xEF\xBB\xBF")) d = d[3..];
    d = std.mem.trimStart(u8, d, "\r\n \t");
    if (std.mem.startsWith(u8, d, "From ")) d = d[(std.mem.indexOfScalar(u8, d, '\n') orelse d.len - 1) + 1 ..];
    return mime.splitMessage(d).head;
}

/// Fast triage analysis (risk, findings, key fields, delivery path).
pub fn analyse(a: Allocator, in: Input, ctx: Context) Analysis {
    return analyseOpts(a, in, ctx, false);
}

/// Everything a header analyser shows: all authentication results, signatures, decoded
/// anti-spam fields, indicators and the full header list (in addition to `analyse`).
pub fn analyseDetailed(a: Allocator, in: Input, ctx: Context) Analysis {
    return analyseOpts(a, in, ctx, true);
}

fn analyseOpts(a: Allocator, in: Input, ctx: Context, detail: bool) Analysis {
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
    an.subject = decodeWords(a, first(hs, "Subject"));
    an.sender = decodeWords(a, first(hs, "Sender"));
    an.to = decodeWords(a, first(hs, "To"));
    an.cc = decodeWords(a, first(hs, "Cc"));
    an.delivered_to = first(hs, "Delivered-To");
    if (an.delivered_to.len == 0) an.delivered_to = first(hs, "X-Original-To");
    an.return_path = parseMailbox(a, first(hs, "Return-Path")).addr;
    an.reply_to = parseMailbox(a, first(hs, "Reply-To")).addr;
    an.message_id = first(hs, "Message-ID");
    an.in_reply_to = first(hs, "In-Reply-To");
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
        an.compauth_reason = kv(ar, "reason", '=', " ;(");
        // domains for alignment (from the same first-arrival result)
        {
            var tmp: std.ArrayList(AuthResult) = .empty;
            parseAuthResults(a, "Authentication-Results", ar, &tmp);
            for (tmp.items) |r| {
                if (std.ascii.eqlIgnoreCase(r.method, "spf") and an.spf_domain.len == 0) {
                    const mf = prop(r.props, "smtp.mailfrom");
                    an.spf_domain = if (std.mem.indexOfScalar(u8, mf, '@') != null) domainOf(mf) else mf;
                }
                if (std.ascii.eqlIgnoreCase(r.method, "dkim") and an.dkim_domain.len == 0) {
                    an.dkim_domain = prop(r.props, "header.d");
                    if (an.dkim_domain.len == 0) an.dkim_domain = domainOf(prop(r.props, "header.i"));
                }
            }
            if (an.spf_domain.len == 0 and an.spf.len > 0) an.spf_domain = domainOf(an.return_path);
            if (std.ascii.eqlIgnoreCase(an.dkim_domain, "none")) an.dkim_domain = "";
            if (std.ascii.eqlIgnoreCase(an.spf_domain, "none")) an.spf_domain = "";
            an.spf_alignment = aligned(an.spf_domain, an.from_domain);
            an.dkim_alignment = aligned(an.dkim_domain, an.from_domain);
        }
        if (count(hs, "Authentication-Results") > 1 or count(hs, "X-Forefront-Antispam-Report") > 1) {
            var gw: []const u8 = "";
            for (hs) |h| if (std.ascii.eqlIgnoreCase(h.name, "Received")) for (gateways) |g| {
                if (gw.len == 0 and std.ascii.findIgnoreCase(h.value, g) != null) gw = g;
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
        for (hs) |h| if (std.ascii.eqlIgnoreCase(h.name, "Received") or std.ascii.eqlIgnoreCase(h.name, "X-Received"))
            hops.append(a, parseReceived(a, h.name, h.value)) catch {};
        std.mem.reverse(Hop, hops.items); // origin first
        var prev_t: ?i64 = null;
        var first_t: ?i64 = null;
        var last_t: ?i64 = null;
        for (hops.items) |*h| if (h.time) |t| {
            if (prev_t) |p| h.delay = t - p;
            prev_t = t;
            if (first_t == null) first_t = t;
            last_t = t;
        };
        if (first_t != null and last_t != null) an.transit = last_t.? - first_t.?;
        an.hops = hops.items;
        // the very first hop often names the sender's own computer and IP (e.g. "from LAPTOP.local ([1.2.3.4]) by smtp.gmail.com")
        for (an.hops) |h0| {
            if (!std.ascii.eqlIgnoreCase(h0.header, "Received")) continue;
            if (h0.ip.len > 0 and !isPrivateIp(h0.ip)) {
                an.origin_device = h0.from;
                an.origin_ip = h0.ip;
                add(a, &findings, .info, "Earliest recorded origin: \"{s}\" at IP {s} (accepted by {s})", .{ h0.from, h0.ip, orDash(h0.by) });
            }
            break;
        }

        // --- authentication
        if (std.ascii.startsWithIgnoreCase(an.dmarc, "fail")) add(a, &findings, .high, "DMARC failed for {s} - sender not authorised to use this domain", .{an.from_domain});
        if (std.ascii.startsWithIgnoreCase(an.compauth, "fail")) add(a, &findings, .high, "Microsoft composite authentication failed (compauth=fail)", .{});
        if (std.ascii.startsWithIgnoreCase(an.spf, "fail")) add(a, &findings, .medium, "SPF failed - sending server not permitted by the domain", .{});
        if (std.ascii.startsWithIgnoreCase(an.spf, "softfail")) add(a, &findings, .medium, "SPF softfail - sending server not clearly permitted", .{});
        if (std.ascii.startsWithIgnoreCase(an.dkim, "fail")) add(a, &findings, .medium, "DKIM signature failed - content may have been altered", .{});
        if (std.ascii.startsWithIgnoreCase(an.spf, "none") and (an.dkim.len == 0 or std.ascii.startsWithIgnoreCase(an.dkim, "none")))
            add(a, &findings, .low, "No SPF or DKIM authentication for the sender", .{});
        if (an.dmarc.len == 0 and (an.spf.len > 0 or an.dkim.len > 0) and an.spf_alignment != .aligned and an.dkim_alignment != .aligned and
            (an.spf_domain.len > 0 or an.dkim_domain.len > 0))
            add(a, &findings, .info, "Not DMARC-aligned: neither SPF ({s}) nor DKIM ({s}) matches the From domain {s}", .{ orDash(an.spf_domain), orDash(an.dkim_domain), an.from_domain });

        // --- Microsoft 365 verdicts
        const cats = [_]struct { c: []const u8, s: Severity, t: []const u8 }{
            .{ .c = "HPHSH", .s = .high, .t = "high-confidence phishing" }, .{ .c = "PHSH", .s = .high, .t = "phishing" },
            .{ .c = "SPOOF", .s = .high, .t = "spoofing" },                 .{ .c = "UIMP", .s = .high, .t = "user impersonation" },
            .{ .c = "DIMP", .s = .high, .t = "domain impersonation" },      .{ .c = "GIMP", .s = .high, .t = "mailbox-intelligence impersonation" },
            .{ .c = "MALW", .s = .high, .t = "malware" },                   .{ .c = "HSPM", .s = .medium, .t = "high-confidence spam" },
            .{ .c = "SPM", .s = .medium, .t = "spam" },                     .{ .c = "BULK", .s = .info, .t = "bulk mail" },
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
        if (an.date != null) for (an.hops) |h| {
            if (h.time) |t0| {
                const diff = @abs(t0 - an.date.?);
                if (diff > 2 * 3600) add(a, &findings, .low, "Date header differs from first relay time by {d} h", .{@divTrunc(diff, 3600)});
                break;
            }
        };
        for (an.hops) |h| if (h.delay) |d| {
            if (d > 3600) add(a, &findings, .info, "Delivery delay of {d} min at {s}", .{ @divTrunc(d, 60), orDash(h.by) });
            if (d < -300) add(a, &findings, .info, "Clock skew: {s} recorded a time {d} min before the previous hop", .{ orDash(h.by), @divTrunc(-d, 60) });
        };
    }

    // --- impersonation (works with or without internet headers)
    if (an.from_name.len > 0 and std.mem.indexOfScalar(u8, an.from_name, '@') != null) {
        const inner = std.mem.trim(u8, an.from_name, " \"'<>");
        if (!std.ascii.eqlIgnoreCase(inner, an.from_addr) and std.ascii.findIgnoreCase(an.from_name, an.from_addr) == null)
            add(a, &findings, .high, "Display name contains a different e-mail address (\"{s}\" sent from {s})", .{ an.from_name, an.from_addr });
    }
    const via_platform = isNotificationPlatform(an.from_domain) or std.ascii.findIgnoreCase(an.from_name, " via ") != null;
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

    if (detail and an.has_headers) {
        var auth: std.ArrayList(AuthResult) = .empty;
        var sigs: std.ArrayList(Signature) = .empty;
        for (hs) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Authentication-Results") or std.ascii.eqlIgnoreCase(h.name, "Authentication-Results-Original") or
                std.ascii.eqlIgnoreCase(h.name, "ARC-Authentication-Results"))
            {
                parseAuthResults(a, h.name, h.value, &auth);
            } else if (std.ascii.eqlIgnoreCase(h.name, "Received-SPF")) {
                parseReceivedSpf(a, h.value, &auth);
            } else if (std.ascii.eqlIgnoreCase(h.name, "DKIM-Signature") or std.ascii.eqlIgnoreCase(h.name, "X-Google-DKIM-Signature") or
                std.ascii.eqlIgnoreCase(h.name, "ARC-Message-Signature") or std.ascii.eqlIgnoreCase(h.name, "ARC-Seal"))
            {
                sigs.append(a, parseSignature(a, h.name, h.value)) catch {};
            }
        }
        var fields: std.ArrayList(Field) = .empty;
        decodeFields(a, hs, &fields);
        // one block per source, in order of first appearance (Microsoft headers are interleaved)
        {
            var grouped: std.ArrayList(Field) = .empty;
            var done: std.StringHashMapUnmanaged(void) = .empty;
            for (fields.items) |g| {
                if (done.contains(g.group)) continue;
                done.put(a, g.group, {}) catch {};
                for (fields.items) |f| if (std.mem.eql(u8, f.group, g.group)) grouped.append(a, f) catch {};
            }
            fields = grouped;
        }
        an.auth = auth.items;
        an.signatures = sigs.items;
        an.fields = fields.items;
        an.iocs = collectIocs(a, &an, hs, auth.items, sigs.items, fields.items);
        an.all = hs;
        if (an.compauth_reason.len > 0) {
            const m = compauthMeaning(an.compauth_reason);
            if (m.len > 0) {
                const extra = [_]Field{.{ .group = "Authentication", .key = "compauth reason", .value = an.compauth_reason, .meaning = m }};
                an.fields = std.mem.concat(a, Field, &.{ an.fields, &extra }) catch an.fields;
            }
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
    out.print(a, "  Auth: SPF={s} ({s} {s})  DKIM={s} ({s} {s})  DMARC={s}  compauth={s}\n", .{ orDash(an.spf), orDash(an.spf_domain), an.spf_alignment.label(), orDash(an.dkim), orDash(an.dkim_domain), an.dkim_alignment.label(), orDash(an.dmarc), orDash(an.compauth) }) catch {};
    if (an.origin_ip.len > 0) out.print(a, "  Sender device: {s}  IP: {s}\n", .{ orDash(an.origin_device), an.origin_ip }) catch {};
    out.print(a, "  Connecting IP: {s}  Country: {s}  Direction: {s}  Auth-as: {s}  M365 verdict: SFV={s} CAT={s} SCL={s} BCL={s}\n", .{ orDash(an.client_ip), orDash(an.country), orDash(an.direction), orDash(an.auth_as), orDash(an.sfv), orDash(an.cat), orDash(an.scl), orDash(an.bcl) }) catch {};
    if (an.mailer.len > 0) out.print(a, "  Mailer: {s}\n", .{an.mailer}) catch {};
    if (an.transit) |t| out.print(a, "  Delivery path (origin first), total {s}:\n", .{fmtDuration(&tb, t)}) catch {} else out.appendSlice(a, "  Delivery path (origin first):\n") catch {};
    for (an.hops, 0..) |h, i| {
        var db: [32]u8 = undefined;
        const d = if (h.delay) |dv| fmtDuration(&db, dv) else "";
        var tb2: [96]u8 = undefined;
        const ip_part = if (h.ip.len > 0) (std.fmt.allocPrint(a, "[{s}] ", .{h.ip}) catch "") else "";
        const tls_part = if (h.tls.len == 0) "" else if (std.mem.eql(u8, h.tls, "TLS")) " (TLS)" else (std.fmt.allocPrint(a, " ({s})", .{h.tls}) catch "");
        out.print(a, "   {d:>2}. {s}  {s} -> {s}  {s}{s}{s}\n", .{ i + 1, fmt_time(&tb2, h.time), orDash(h.from), orDash(h.by), ip_part, h.with, tls_part }) catch {};
        if (d.len > 0) out.print(a, "       +{s}\n", .{d}) catch {};
    }
    if (an.hops.len == 0) out.appendSlice(a, "   (no Received headers)\n") catch {};
    return out.items;
}

/// "4 s", "12 min 3 s", "2 h 5 min", "3 d 4 h" (negative values keep their sign).
pub fn fmtDuration(buf: []u8, secs: i64) []const u8 {
    const neg = secs < 0;
    const s: u64 = @abs(secs);
    const sign: []const u8 = if (neg) "-" else "";
    if (s < 60) return std.fmt.bufPrint(buf, "{s}{d} s", .{ sign, s }) catch "";
    if (s < 3600) return std.fmt.bufPrint(buf, "{s}{d} min {d} s", .{ sign, s / 60, s % 60 }) catch "";
    if (s < 86400) return std.fmt.bufPrint(buf, "{s}{d} h {d} min", .{ sign, s / 3600, (s % 3600) / 60 }) catch "";
    return std.fmt.bufPrint(buf, "{s}{d} d {d} h", .{ sign, s / 86400, (s % 86400) / 3600 }) catch "";
}

pub fn orDash(s: []const u8) []const u8 {
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

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "Received parsing: hosts, IP, protocol, TLS, id, for" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = parseReceived(a, "Received", "from mail-sor-f41.google.com (mail-sor-f41.google.com. [209.85.220.41]) by mx.google.com with SMTPS id a1sor123 for <bob@example.com> (Google Transport Security); Tue, 01 Jul 2003 10:52:37 -0700 (PDT)");
    try testing.expectEqualStrings("mail-sor-f41.google.com", g.from);
    try testing.expectEqualStrings("209.85.220.41", g.ip);
    try testing.expectEqualStrings("mx.google.com", g.by);
    try testing.expectEqualStrings("SMTPS", g.with);
    try testing.expectEqualStrings("a1sor123", g.id);
    try testing.expectEqualStrings("bob@example.com", g.for_addr);
    try testing.expectEqualStrings("TLS", g.tls);
    try testing.expectEqual(@as(?i64, 1057081957), g.time);
    const m = parseReceived(a, "Received", "from SY4PR01MB1234.ausprd01.prod.outlook.com (2603:10c6:10:5::20) by ME3PR01MB5678.ausprd01.prod.outlook.com with Microsoft SMTP Server (version=TLS1_2, cipher=TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384) id 15.20.7270.31; Thu, 5 Nov 2026 08:24:07 +0000");
    try testing.expectEqualStrings("2603:10c6:10:5::20", m.ip);
    try testing.expectEqualStrings("TLS1_2 TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384", m.tls);
    try testing.expectEqualStrings("15.20.7270.31", m.id);
    const p = parseReceived(a, "Received", "from unknown (HELO laptop) (10.0.0.5) by smtp.example.org (Postfix) with ESMTPSA id 4Q2; Mon, 1 Jan 2024 00:00:00 +0000");
    try testing.expectEqualStrings("10.0.0.5", p.ip);
    try testing.expectEqualStrings("TLS", p.tls);
}

test "Authentication-Results: Microsoft (no authserv-id), Google and ARC" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(AuthResult) = .empty;
    parseAuthResults(a, "Authentication-Results", "spf=pass (sender IP is 40.107.1.2) smtp.mailfrom=contoso.com; dkim=pass (signature was verified) header.d=contoso.com;dmarc=pass action=none header.from=contoso.com;compauth=pass reason=100", &out);
    try testing.expectEqual(@as(usize, 4), out.items.len);
    try testing.expectEqualStrings("spf", out.items[0].method);
    try testing.expectEqualStrings("pass", out.items[0].result);
    try testing.expectEqualStrings("sender IP is 40.107.1.2", out.items[0].detail);
    try testing.expectEqualStrings("smtp.mailfrom=contoso.com", out.items[0].props);
    try testing.expectEqualStrings("reason=100", out.items[3].detail);
    out.clearRetainingCapacity();
    parseAuthResults(a, "ARC-Authentication-Results", "i=1; mx.google.com; dkim=pass header.i=@example.com header.s=s1 header.b=AbC; spf=pass (google.com: domain of a@example.com designates 1.2.3.4 as permitted sender) smtp.mailfrom=a@example.com; dmarc=pass (p=NONE sp=NONE dis=NONE) header.from=example.com", &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("1", out.items[0].instance);
    try testing.expectEqualStrings("mx.google.com", out.items[0].authserv);
    try testing.expectEqualStrings("header.i=@example.com header.s=s1 header.b=AbC", out.items[0].props);
}

test "detailed analysis: alignment, decoded Forefront fields, indicators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw =
        "Received: from mx.contoso.com (mx.contoso.com [203.0.113.9]) by BN1.protection.outlook.com with Microsoft SMTP Server (version=TLS1_2, cipher=X) id 15.1; Thu, 5 Nov 2026 08:00:10 +0000\r\n" ++
        "Authentication-Results: spf=pass (sender IP is 203.0.113.9) smtp.mailfrom=bounce.esp.example; dkim=pass (signature was verified) header.d=contoso.com; dmarc=pass action=none header.from=contoso.com;compauth=pass reason=100\r\n" ++
        "X-Forefront-Antispam-Report: CIP:203.0.113.9;CTRY:AU;LANG:en;SCL:1;SRV:;IPV:NLI;SFV:NSPM;H:mx.contoso.com;PTR:mx.contoso.com;CAT:NONE;SFS:(13230031);DIR:INB;\r\n" ++
        "DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed; d=contoso.com; s=sel1;\r\n h=From:To:Subject; t=1793001600; bh=xx; b=yy\r\n" ++
        "Received: from laptop.local ([198.51.100.7]) by mx.contoso.com with ESMTPSA id 1; Thu, 5 Nov 2026 08:00:00 +0000\r\n" ++
        "List-Unsubscribe: <https://contoso.com/u?x=1>, <mailto:unsub@contoso.com>\r\n" ++
        "From: \"Ann\" <ann@contoso.com>\r\nTo: bob@fabrikam.com\r\nSubject: Hello\r\n";
    const an = analyseDetailed(a, inputFromHeaders(a, raw), .{});
    try testing.expectEqualStrings("Hello", an.subject);
    try testing.expectEqual(Alignment.not_aligned, an.spf_alignment);
    try testing.expectEqual(Alignment.aligned, an.dkim_alignment);
    try testing.expectEqualStrings("pass (aligned SPF or DKIM)", an.dmarcComputed());
    try testing.expectEqual(@as(usize, 2), an.hops.len);
    try testing.expectEqual(@as(?i64, 10), an.hops[1].delay);
    try testing.expectEqual(@as(?i64, 10), an.transit);
    try testing.expectEqualStrings("198.51.100.7", an.origin_ip);
    var found_sfv = false;
    for (an.fields) |f| if (std.mem.eql(u8, f.key, "SFV")) {
        found_sfv = true;
        try testing.expectEqualStrings("Not spam", f.meaning);
    };
    try testing.expect(found_sfv);
    try testing.expectEqual(@as(usize, 1), an.signatures.len);
    try testing.expectEqualStrings("From:To:Subject", an.signatures[0].signed_headers);
    var ips: usize = 0;
    var urls: usize = 0;
    for (an.iocs) |i| switch (i.kind) {
        .ip => ips += 1,
        .url => urls += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), ips);
    try testing.expectEqual(@as(usize, 1), urls);
}
