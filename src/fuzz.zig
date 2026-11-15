//! Coverage-guided fuzz targets for everything that reads untrusted content.
//!
//!   zig build fuzz            run every target once over its seed inputs (part of CI)
//!   zig build fuzz --fuzz     keep mutating the inputs, guided by coverage, until stopped
//!
//! A target fails on a crash (out-of-bounds index, integer overflow, unreachable code - the
//! safety checks of a Debug / ReleaseSafe build), on a leak, or when one of the properties
//! checked here does not hold: nothing active survives the sanitiser, and no mail can end or
//! pose as the container pstview shows it in.

const std = @import("std");
const pst = @import("pst.zig");
const mime = @import("mime.zig");
const mbox = @import("mbox.zig");
const render = @import("render.zig");
const exp = @import("export.zig");
const headers = @import("headers.zig");
const hreport = @import("headerreport.zig");
const search = @import("search.zig");
const rtfcp = @import("rtfcp.zig");
const Smith = std.testing.Smith;

fn fmtTime(buf: []u8, t: ?i64) []const u8 {
    return pst.fmtTime(buf, t, 0);
}

/// Is there a tag of this name ("<script") in `html`? "<scripts" and "<body-x" are other elements.
fn hasTag(html: []const u8, comptime open: []const u8) bool {
    var at: usize = 0;
    while (std.ascii.findIgnoreCasePos(html, at, open)) |i| {
        at = i + open.len;
        if (at >= html.len) return true;
        const c = html[at];
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != ':') return true;
    }
    return false;
}

/// What must hold for any page pstview builds around a mail.
fn checkDocument(doc: []const u8) !void {
    inline for (.{ "<script", "<iframe", "<object", "<embed", "<base", "<form", "<link", "<svg" }) |bad| {
        try std.testing.expect(!hasTag(doc, bad));
    }
    // exactly one mail container at most, opened and closed by pstview
    try std.testing.expect(std.mem.count(u8, doc, "<pstview-mail") <= 1);
    try std.testing.expect(std.mem.count(u8, doc, "</pstview-mail") <= 1);
    try std.testing.expect(hasTag(doc, "<body") and !hasTag(doc[(std.mem.indexOf(u8, doc, "<body>") orelse 0) + 6 ..], "<body"));
    try std.testing.expect(std.mem.endsWith(u8, doc, "</body></html>\n"));
}

fn oneMessage(_: void, smith: *Smith) anyerror!void {
    var buf: [48 * 1024]u8 = undefined;
    return oneMessageBytes(buf[0..smith.slice(&buf)]);
}

pub fn oneMessageBytes(raw: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m = try mbox.messageFromRaw(a, raw);
    try checkDocument(try render.messageDocument(a, &m, fmtTime));
    _ = try m.bodyText(a);
    _ = exp.buildEml(a, &m, 0) catch |e| if (e == error.OutOfMemory) return e;
    _ = exp.buildMsg(a, &m) catch |e| if (e == error.OutOfMemory) return e;
    const an = headers.analyseDetailed(a, headers.inputFromMessage(a, &m), .{});
    _ = try hreport.html(a, an, "fuzz", fmtTime);
    _ = try hreport.text(a, an, fmtTime);
    _ = try exp.safeName(a, "", try m.subject(a), "eml");
    for (m.attachments) |att| {
        const name = try exp.safeFileName(a, "01", att.filename);
        try std.testing.expect(std.mem.indexOfAny(u8, name, "/\\:") == null and name.len <= 255);
    }
}

fn oneHeaderBlock(_: void, smith: *Smith) anyerror!void {
    var buf: [16 * 1024]u8 = undefined;
    return oneHeaderBlockBytes(buf[0..smith.slice(&buf)]);
}

pub fn oneHeaderBlockBytes(raw: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const an = headers.analyseDetailed(a, headers.inputFromHeaders(a, headers.headerBlock(raw)), .{});
    _ = try hreport.html(a, an, "fuzz", fmtTime);
    _ = try hreport.text(a, an, fmtTime);
    _ = mime.parseDate(raw);
    _ = mime.parseAddresses(a, raw);
    _ = mime.decodeHeader(a, raw);
    _ = search.parse(a, raw[0..@min(raw.len, 512)]);
}

fn oneHtmlBody(_: void, smith: *Smith) anyerror!void {
    var buf: [16 * 1024]u8 = undefined;
    return oneHtmlBodyBytes(buf[0..smith.slice(&buf)]);
}

pub fn oneHtmlBodyBytes(html: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const none: pst.Message = .{ .nid = 0, .node = null, .pc = .{ .props = &.{} }, .recipients = &.{}, .attachments = &.{} };
    var st: render.SanitizeStats = .{};
    const out = try render.sanitize(a, html, &none, &st);
    // a "<" that is not a tag pstview kept is written as "&lt;", so none of these can be text
    inline for (.{ "<script", "<iframe", "<object", "<embed", "<meta", "<base", "<form", "<link", "<svg", "<body", "<html", "<pstview-mail", "</pstview-mail" }) |bad| {
        try std.testing.expect(!hasTag(out, bad));
    }
    // every <style> the sanitiser writes holds balanced braces of its own
    var rest: []const u8 = out;
    while (std.mem.indexOf(u8, rest, "<style>")) |s| {
        const e = std.mem.indexOfPos(u8, rest, s, "</style>") orelse return error.StyleNotClosed;
        var depth: isize = 0;
        for (rest[s + 7 .. e]) |c| {
            if (c == '{') depth += 1 else if (c == '}') depth -= 1;
            try std.testing.expect(depth >= 0);
        }
        try std.testing.expectEqual(@as(isize, 0), depth);
        rest = rest[e + 8 ..];
    }
}

fn oneRtf(_: void, smith: *Smith) anyerror!void {
    var buf: [16 * 1024]u8 = undefined;
    return oneRtfBytes(buf[0..smith.slice(&buf)]);
}

pub fn oneRtfBytes(raw: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = rtfcp.body(a, raw) catch {};
    _ = rtfcp.decompress(a, raw) catch {};
    _ = rtfcp.extract(a, raw) catch {};
}

const seed_mail =
    "From: \"Accounts Payable\" <accounts@harbourline.example>\r\nTo: =?UTF-8?B?QXZh?= <ava@northwind.example>\r\n" ++
    "Subject: =?utf-8?Q?Invoice_=E2=82=AC?=\r\nDate: Wed, 21 Oct 2026 15:40:02 +0000\r\nMessage-ID: <1@vps.example.net>\r\n" ++
    "Received: from vps.example.net (vps.example.net [192.0.2.77]) by mx1.northwind.example with ESMTPS id 1; Wed, 21 Oct 2026 15:41:19 +0000\r\n" ++
    "Authentication-Results: mx1.northwind.example; spf=fail smtp.mailfrom=x.example; dkim=none; dmarc=fail header.from=harbourline.example\r\n" ++
    "Reply-To: ap@payments.example.net\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"b1\"\r\n\r\n" ++
    "--b1\r\nContent-Type: multipart/alternative; boundary=b2\r\n\r\n--b2\r\nContent-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nPay=20now =E9\r\n" ++
    "--b2\r\nContent-Type: text/html; charset=utf-8\r\n\r\n" ++ seed_html ++ "\r\n--b2--\r\n" ++
    "--b1\r\nContent-Type: image/png; name=\"a.png\"\r\nContent-ID: <img1>\r\nContent-Transfer-Encoding: base64\r\nContent-Disposition: inline; filename*=utf-8''a%20b.png\r\n\r\niVBORw0KGgo=\r\n" ++
    "--b1\r\nContent-Type: message/rfc822\r\n\r\nSubject: inner\r\n\r\nhi\r\n--b1--\r\n";

const seed_html =
    "<html><head><style type=\"text/css\"><!--\nbody { background-color: #9999CC; } @media (max-width:600px){ td.x, a:hover{color:red;background:url(http://t.example/p.gif)} }\n--></style></head>" ++
    "<body bgcolor=\"#ffffff\" text=black onload=\"x()\"><table width=600><tr><td style='font-family:\"Arial\";position:fixed'><a href=\"http://a.example/?b=1&amp;c=2\" onclick=y>l</a>" ++
    "<img src=\"cid:img1\"><img src=http://t.example/p.gif width=1><script>alert(1)</script><iframe src=x></iframe></td></tr></table></div></body></html>";

const seed_headers =
    "Return-Path: <bounce@x.example>\r\nReceived: from a.example (a.example [203.0.113.5]) by b.example (Postfix) with ESMTP id 1 for <c@d.example>; Mon, 1 Jan 2024 00:00:00 -0500 (EST)\r\n" ++
    "Received: from [10.0.0.1] (unknown [198.51.100.7]) by a.example; Mon, 01 Jan 2024 04:59:58 +0000\r\nDKIM-Signature: v=1; a=rsa-sha256; d=x.example; s=s1; h=from:to; bh=AA==; b=AA==\r\n" ++
    "ARC-Authentication-Results: i=1; mx.example; dkim=pass header.i=@x.example; spf=pass smtp.mailfrom=bounce@x.example\r\nFrom: \"A, B\" <a@x.example>, c@y.example (C)\r\nX-Mailer: m\r\n\r\n";

test "fuzz: one raw message through parsing, rendering, export and header analysis" {
    try std.testing.fuzz({}, oneMessage, .{ .corpus = &.{ seed_mail, "Subject: s\n\nplain\n", "Content-Type: text/html\n\n" ++ seed_html } });
}

test "fuzz: header block analysis, dates, addresses, encoded words, search queries" {
    try std.testing.fuzz({}, oneHeaderBlock, .{ .corpus = &.{ seed_headers, "from:*@x.example subject:\"a b\" risk:high -c", "=?utf-8?B?QQ==?= =?iso-2022-jp?Q?=1B?=", "Mon, 1 Jan 2024 00:00:00 +0000" } });
}

test "fuzz: HTML sanitiser output never carries active content or leaves its container" {
    try std.testing.fuzz({}, oneHtmlBody, .{ .corpus = &.{ seed_html, "<style>p{a:\"}\"} .hdr{display:none}</style></pstview-mail><li><div></li></div>" } });
}

test "fuzz: compressed RTF and RTF bodies" {
    try std.testing.fuzz({}, oneRtf, .{ .corpus = &.{ "\x10\x00\x00\x00\x08\x00\x00\x00LZFu\x00\x00\x00\x00{\\rtf1 a}", "{\\rtf1\\ansi\\fromhtml1 {\\*\\htmltag <p>}x\\u8364?\\'e9\\par}" } });
}

test "every target takes every input of up to two bytes, and the seeds cut short anywhere" {
    const targets = [_]*const fn ([]const u8) anyerror!void{ oneMessageBytes, oneHeaderBlockBytes, oneHtmlBodyBytes, oneRtfBytes };
    const interesting = "\x00\n\r \t\"'<>=:;,@()[]{}\\/?&%-+*.a1\x7f\x80\xff";
    for (targets) |target| {
        try target("");
        for (interesting) |c1| {
            try target(&.{c1});
            for (interesting) |c2| try target(&.{ c1, c2 });
        }
        for ([_][]const u8{ seed_mail, seed_html, seed_headers }) |seed| {
            for (0..seed.len) |n| try target(seed[0..n]);
        }
    }
}
