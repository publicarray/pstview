//! Safe, self-contained HTML rendering of a message (portable - no OS dependencies).
//!
//! Safety layers:
//!  1. Sanitiser: drops <script>, <iframe>, <object>, <embed>, <svg>, <form> controls, <meta>, <base>,
//!     <link>, comments, all on* event attributes and javascript:/vbscript: URLs.
//!  2. Remote resources (http/https images, CSS url()) are replaced and counted - no tracking pixels.
//!  3. cid: inline images are embedded from the message's attachments as data: URIs.
//!  4. A strict Content-Security-Policy blocks all script and all network loads even if
//!     something slipped through the sanitiser.

const std = @import("std");
const pst = @import("pst.zig");
const Allocator = std.mem.Allocator;
const List = std.ArrayList(u8);

pub const csp = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; form-action 'none'; base-uri 'none'";

const drop_with_content = [_][]const u8{ "script", "iframe", "object", "embed", "applet", "frame", "frameset", "svg", "math", "template", "noembed", "noframes" };
const drop_tag_only = [_][]const u8{ "meta", "base", "link", "form", "input", "button", "textarea", "select", "option", "html", "head", "body", "title" };

fn inList(name: []const u8, list: []const []const u8) bool {
    for (list) |n| if (std.ascii.eqlIgnoreCase(name, n)) return true;
    return false;
}

pub const SanitizeStats = struct { blocked_remote: usize = 0, removed_active: usize = 0, inlined_images: usize = 0 };

pub fn mimeForName(name: []const u8) []const u8 {
    const ext = if (std.mem.lastIndexOfScalar(u8, name, '.')) |d| name[d + 1 ..] else "";
    const map = [_]struct { e: []const u8, m: []const u8 }{
        .{ .e = "png", .m = "image/png" },   .{ .e = "jpg", .m = "image/jpeg" }, .{ .e = "jpeg", .m = "image/jpeg" },
        .{ .e = "gif", .m = "image/gif" },   .{ .e = "bmp", .m = "image/bmp" },  .{ .e = "webp", .m = "image/webp" },
        .{ .e = "tif", .m = "image/tiff" },  .{ .e = "tiff", .m = "image/tiff" }, .{ .e = "ico", .m = "image/x-icon" },
        .{ .e = "svg", .m = "image/svg+xml" },
    };
    for (map) |x| if (std.ascii.eqlIgnoreCase(ext, x.e)) return x.m;
    return "application/octet-stream";
}

pub fn isImage(att: *const pst.Attachment) bool {
    if (att.mime.len > 0 and std.ascii.startsWithIgnoreCase(att.mime, "image/") and !std.ascii.eqlIgnoreCase(att.mime, "image/svg+xml")) return true;
    const m = mimeForName(att.filename);
    return std.mem.startsWith(u8, m, "image/") and !std.mem.eql(u8, m, "image/svg+xml");
}

fn dataUri(a: Allocator, mime: []const u8, data: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, 5 + mime.len + 8 + enc.calcSize(data.len));
    var o: usize = 0;
    for ([_][]const u8{ "data:", mime, ";base64," }) |p| {
        @memcpy(out[o..][0..p.len], p);
        o += p.len;
    }
    _ = enc.encode(out[o..], data);
    return out;
}

fn findCid(m: *const pst.Message, cid_raw: []const u8) ?*const pst.Attachment {
    var cid = std.mem.trim(u8, cid_raw, " <>");
    if (std.ascii.startsWithIgnoreCase(cid, "cid:")) cid = cid[4..];
    cid = std.mem.trim(u8, cid, " <>");
    for (m.attachments) |*att| {
        const c = std.mem.trim(u8, att.content_id, " <>");
        if (c.len > 0 and std.ascii.eqlIgnoreCase(c, cid)) return att;
    }
    // some mailers reference by file name
    for (m.attachments) |*att| if (att.filename.len > 0 and std.ascii.eqlIgnoreCase(att.filename, cid)) return att;
    return null;
}

fn isDangerousUrl(v: []const u8) bool {
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    for (v) |c| {
        if (n >= buf.len) break;
        if (c <= ' ') continue; // browsers ignore whitespace/control chars inside schemes
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    const s = buf[0..n];
    return std.mem.startsWith(u8, s, "javascript:") or std.mem.startsWith(u8, s, "vbscript:") or
        std.mem.startsWith(u8, s, "data:text/html") or std.mem.startsWith(u8, s, "data:image/svg");
}

fn isRemote(v: []const u8) bool {
    const t = std.mem.trim(u8, v, " \t\r\n");
    return std.ascii.startsWithIgnoreCase(t, "http:") or std.ascii.startsWithIgnoreCase(t, "https:") or
        std.ascii.startsWithIgnoreCase(t, "//") or std.ascii.startsWithIgnoreCase(t, "ftp:") or
        std.ascii.startsWithIgnoreCase(t, "file:") or std.ascii.startsWithIgnoreCase(t, "\\\\");
}

fn escAttr(a: Allocator, out: *List, v: []const u8) !void {
    for (v) |c| switch (c) {
        '"' => try out.appendSlice(a, "&quot;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        else => try out.append(a, c),
    };
}

pub fn escText(a: Allocator, out: *List, v: []const u8) !void {
    for (v) |c| switch (c) {
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '&' => try out.appendSlice(a, "&amp;"),
        '"' => try out.appendSlice(a, "&quot;"),
        else => try out.append(a, c),
    };
}

/// Neutralise url(...) references to remote resources inside inline CSS.
fn cleanCss(a: Allocator, out: *List, css: []const u8, st: *SanitizeStats) !void {
    var i: usize = 0;
    while (i < css.len) {
        if (i + 4 <= css.len and std.ascii.eqlIgnoreCase(css[i .. i + 4], "url(")) {
            const end = std.mem.indexOfScalarPos(u8, css, i, ')') orelse css.len;
            const inner = std.mem.trim(u8, css[i + 4 .. @min(end, css.len)], " '\"");
            if (!std.ascii.startsWithIgnoreCase(inner, "data:image/")) {
                st.blocked_remote += 1;
                try out.appendSlice(a, "none");
            } else try out.appendSlice(a, css[i..@min(end + 1, css.len)]);
            i = @min(end + 1, css.len);
            continue;
        }
        if (i + 7 <= css.len and std.ascii.eqlIgnoreCase(css[i .. i + 7], "@import")) {
            st.blocked_remote += 1;
            const end = std.mem.indexOfScalarPos(u8, css, i, ';') orelse css.len;
            i = @min(end + 1, css.len);
            continue;
        }
        if (i + 11 <= css.len and std.ascii.eqlIgnoreCase(css[i .. i + 11], "expression(")) {
            st.removed_active += 1;
            i += 11;
            continue;
        }
        try out.append(a, css[i]);
        i += 1;
    }
}

/// Sanitise an email HTML body. `m` is used to resolve cid: images.
pub fn sanitize(a: Allocator, html: []const u8, m: *const pst.Message, st: *SanitizeStats) ![]u8 {
    var out: List = .empty;
    try out.ensureTotalCapacity(a, html.len);
    var i: usize = 0;
    while (i < html.len) {
        const c = html[i];
        if (c != '<') {
            try out.append(a, c);
            i += 1;
            continue;
        }
        // comments / doctype / CDATA
        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            const e = std.mem.indexOfPos(u8, html, i + 4, "-->") orelse html.len;
            i = @min(e + 3, html.len);
            continue;
        }
        if (i + 1 < html.len and (html[i + 1] == '!' or html[i + 1] == '?')) {
            const e = std.mem.indexOfScalarPos(u8, html, i, '>') orelse html.len;
            i = @min(e + 1, html.len);
            continue;
        }
        // tag name
        var j = i + 1;
        const closing = j < html.len and html[j] == '/';
        if (closing) j += 1;
        const ns = j;
        while (j < html.len and (std.ascii.isAlphanumeric(html[j]) or html[j] == ':' or html[j] == '-')) j += 1;
        const name = html[ns..j];
        if (name.len == 0) {
            try out.appendSlice(a, "&lt;");
            i += 1;
            continue;
        }
        // find end of tag, respecting quotes
        var k = j;
        var q: u8 = 0;
        while (k < html.len) : (k += 1) {
            const ch = html[k];
            if (q != 0) {
                if (ch == q) q = 0;
            } else if (ch == '"' or ch == '\'') q = ch else if (ch == '>') break;
        }
        const tag_end = @min(k, html.len);
        const attrs = html[j..tag_end];
        const next = @min(tag_end + 1, html.len);

        if (inList(name, &drop_with_content)) {
            st.removed_active += 1;
            if (!closing) {
                // skip to matching close tag
                var close_buf: [24]u8 = undefined;
                const close = std.fmt.bufPrint(&close_buf, "</{s}", .{name}) catch "";
                if (std.ascii.findIgnoreCasePos(html, next, close)) |ce| {
                    i = (std.mem.indexOfScalarPos(u8, html, ce, '>') orelse html.len - 1) + 1;
                    continue;
                }
            }
            i = next;
            continue;
        }
        if (inList(name, &drop_tag_only)) {
            i = next;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "style") and !closing) {
            // keep inline <style> blocks but clean their CSS
            const ce = std.ascii.findIgnoreCasePos(html, next, "</style") orelse html.len;
            try out.appendSlice(a, "<style>");
            try cleanCss(a, &out, html[next..ce], st);
            try out.appendSlice(a, "</style>");
            i = if (ce < html.len) (std.mem.indexOfScalarPos(u8, html, ce, '>') orelse html.len - 1) + 1 else html.len;
            continue;
        }

        // rebuild tag with filtered attributes
        try out.append(a, '<');
        if (closing) try out.append(a, '/');
        for (name) |ch| try out.append(a, std.ascii.toLower(ch));
        var p: usize = 0;
        while (p < attrs.len) {
            while (p < attrs.len and (std.ascii.isWhitespace(attrs[p]) or attrs[p] == '/')) p += 1;
            const an_s = p;
            while (p < attrs.len and !std.ascii.isWhitespace(attrs[p]) and attrs[p] != '=' and attrs[p] != '>' and attrs[p] != '/') p += 1;
            const an = attrs[an_s..p];
            if (an.len == 0) {
                p += 1;
                continue;
            }
            while (p < attrs.len and std.ascii.isWhitespace(attrs[p])) p += 1;
            var val: []const u8 = "";
            var has_val = false;
            if (p < attrs.len and attrs[p] == '=') {
                has_val = true;
                p += 1;
                while (p < attrs.len and std.ascii.isWhitespace(attrs[p])) p += 1;
                if (p < attrs.len and (attrs[p] == '"' or attrs[p] == '\'')) {
                    const qc = attrs[p];
                    const vs = p + 1;
                    const ve = std.mem.indexOfScalarPos(u8, attrs, vs, qc) orelse attrs.len;
                    val = attrs[vs..ve];
                    p = @min(ve + 1, attrs.len);
                } else {
                    const vs = p;
                    while (p < attrs.len and !std.ascii.isWhitespace(attrs[p])) p += 1;
                    val = attrs[vs..p];
                }
            }
            // filter
            if (std.ascii.startsWithIgnoreCase(an, "on")) {
                st.removed_active += 1;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(an, "srcset") or std.ascii.eqlIgnoreCase(an, "formaction") or std.ascii.eqlIgnoreCase(an, "xmlns") or std.ascii.eqlIgnoreCase(an, "ping")) continue;
            const is_src = std.ascii.eqlIgnoreCase(an, "src") or std.ascii.eqlIgnoreCase(an, "background") or std.ascii.eqlIgnoreCase(an, "poster") or std.ascii.eqlIgnoreCase(an, "lowsrc") or std.ascii.eqlIgnoreCase(an, "dynsrc");
            const is_href = std.ascii.eqlIgnoreCase(an, "href") or std.ascii.eqlIgnoreCase(an, "action") or std.ascii.eqlIgnoreCase(an, "xlink:href");
            if ((is_src or is_href) and isDangerousUrl(val)) {
                st.removed_active += 1;
                continue;
            }
            var out_val: []const u8 = val;
            if (is_src) {
                const tv = std.mem.trim(u8, val, " ");
                if (std.ascii.startsWithIgnoreCase(tv, "cid:")) {
                    if (findCid(m, tv)) |att| {
                        const mime = if (att.mime.len > 0) att.mime else mimeForName(att.filename);
                        out_val = try dataUri(a, mime, att.data());
                        st.inlined_images += 1;
                    } else out_val = "";
                } else if (isRemote(tv)) {
                    st.blocked_remote += 1;
                    try out.appendSlice(a, " data-blocked-src=\"");
                    try escAttr(a, &out, tv);
                    try out.append(a, '"');
                    out_val = "";
                } else if (!std.ascii.startsWithIgnoreCase(tv, "data:image/")) out_val = "";
            }
            if (std.ascii.eqlIgnoreCase(an, "style")) {
                var css: List = .empty;
                try cleanCss(a, &css, val, st);
                out_val = css.items;
            }
            try out.append(a, ' ');
            for (an) |ch| try out.append(a, std.ascii.toLower(ch));
            if (has_val or is_src) {
                try out.appendSlice(a, "=\"");
                try escAttr(a, &out, out_val);
                try out.append(a, '"');
            }
            if (std.ascii.eqlIgnoreCase(name, "a") and is_href) try out.appendSlice(a, " rel=\"noopener noreferrer\" target=\"_blank\"");
        }
        try out.append(a, '>');
        i = next;
    }
    return out.toOwnedSlice(a);
}

pub const TimeFmt = *const fn (buf: []u8, t: ?i64) []const u8;

/// Full standalone HTML document: header block, attachment gallery, sanitised body.
pub fn messageDocument(a: Allocator, m: *const pst.Message, fmt_time: TimeFmt) ![]u8 {
    var st: SanitizeStats = .{};
    const html_utf8 = try m.bodyHtmlUtf8(a);
    var body_html: []const u8 = "";
    if (html_utf8.len > 0) {
        body_html = try sanitize(a, html_utf8, m, &st);
    } else {
        var tmp: List = .empty;
        try tmp.appendSlice(a, "<pre class=\"plain\">");
        try escText(a, &tmp, try m.bodyText(a));
        try tmp.appendSlice(a, "</pre>");
        body_html = tmp.items;
    }

    var out: List = .empty;
    try out.print(a,
        \\<!doctype html><html><head><meta charset="utf-8">
        \\<meta http-equiv="Content-Security-Policy" content="{s}">
        \\<meta name="referrer" content="no-referrer"><title>
    , .{csp});
    try escText(a, &out, try m.subject(a));
    try out.appendSlice(a,
        \\</title><style>
        \\:root{color-scheme:light dark}
        \\body{margin:0;font:14px/1.45 "Segoe UI",system-ui,-apple-system,Arial,sans-serif;background:Canvas;color:CanvasText}
        \\.hdr{padding:14px 18px;border-bottom:1px solid #8884;background:#8881}
        \\.hdr h1{font-size:18px;margin:0 0 8px}
        \\.hdr table{border-collapse:collapse;font-size:13px}
        \\.hdr td{padding:1px 12px 1px 0;vertical-align:top}
        \\.hdr td:first-child{color:#888;white-space:nowrap}
        \\.note{margin:8px 0 0;padding:6px 10px;border-radius:4px;background:#f5b70033;font-size:12px}
        \\.atts{display:flex;flex-wrap:wrap;gap:10px;padding:10px 18px;border-bottom:1px solid #8884}
        \\.att{border:1px solid #8886;border-radius:4px;padding:6px;font-size:12px;max-width:260px}
        \\.att img{display:block;max-width:240px;max-height:180px;margin-bottom:4px}
        \\.mail{padding:14px 18px;overflow-wrap:anywhere}
        \\.mail img[data-blocked-src]{outline:1px dashed #c33;min-width:20px;min-height:12px}
        \\pre.plain{white-space:pre-wrap;font:13px/1.4 Consolas,ui-monospace,monospace}
        \\</style></head><body><div class="hdr"><h1>
    );
    try escText(a, &out, try m.subject(a));
    try out.appendSlice(a, "</h1><table>");
    try out.appendSlice(a, "<tr><td>From</td><td>");
    try escText(a, &out, try m.senderName(a));
    try out.appendSlice(a, " &lt;");
    try escText(a, &out, try m.senderEmail(a));
    try out.appendSlice(a, "&gt;</td></tr>");
    inline for (.{ .{ 1, "To" }, .{ 2, "Cc" }, .{ 3, "Bcc" } }) |kv| {
        var first = true;
        for (m.recipients) |r| {
            if (r.kind != kv[0]) continue;
            if (first) try out.appendSlice(a, "<tr><td>" ++ kv[1] ++ "</td><td>") else try out.appendSlice(a, "; ");
            first = false;
            try escText(a, &out, r.name);
            if (r.email.len > 0) {
                try out.appendSlice(a, " &lt;");
                try escText(a, &out, r.email);
                try out.appendSlice(a, "&gt;");
            }
        }
        if (!first) try out.appendSlice(a, "</td></tr>");
    }
    var tb: [64]u8 = undefined;
    inline for (.{ .{ pst.Tag.delivery_time, "Received" }, .{ pst.Tag.client_submit_time, "Sent" }, .{ pst.Tag.last_modified, "Modified" } }) |kv| {
        if (m.pc.time(kv[0])) |t| try out.print(a, "<tr><td>{s}</td><td>{s}</td></tr>", .{ kv[1], fmt_time(&tb, t) });
    }
    for (@import("itemview.zig").rows(a, m, fmt_time)) |row| {
        try out.appendSlice(a, "<tr><td>");
        try escText(a, &out, row.label);
        try out.appendSlice(a, "</td><td>");
        try escText(a, &out, row.value);
        try out.appendSlice(a, "</td></tr>");
    }
    try out.print(a, "<tr><td>PST NID</td><td>0x{x:0>8}</td></tr></table>", .{m.nid});
    if (st.blocked_remote > 0 or st.removed_active > 0) {
        try out.print(a, "<div class=\"note\">Safe view: {d} remote resource(s) blocked (no tracking pixels loaded), {d} active element(s) removed. Scripts and network access are disabled for this page.</div>", .{ st.blocked_remote, st.removed_active });
    }
    try out.appendSlice(a, "</div>");

    // attachment gallery (images shown inline as previews)
    if (m.attachments.len > 0) {
        try out.appendSlice(a, "<div class=\"atts\">");
        for (m.attachments) |*att| {
            try out.appendSlice(a, "<div class=\"att\">");
            if (isImage(att) and att.data().len > 0 and att.data().len < 25 * 1024 * 1024) {
                const mime = if (att.mime.len > 0) att.mime else mimeForName(att.filename);
                try out.appendSlice(a, "<img alt=\"\" src=\"");
                try out.appendSlice(a, try dataUri(a, mime, att.data()));
                try out.appendSlice(a, "\">");
            }
            try escText(a, &out, if (att.filename.len > 0) att.filename else "(embedded item)");
            try out.print(a, "<br><small>{d} KB{s}</small></div>", .{ @divTrunc(att.size + 1023, 1024), if (att.content_id.len > 0) " - inline" else "" });
        }
        try out.appendSlice(a, "</div>");
    }
    try out.appendSlice(a, "<div class=\"mail\">");
    try out.appendSlice(a, body_html);
    try out.appendSlice(a, "</div></body></html>\n");
    return out.toOwnedSlice(a);
}
