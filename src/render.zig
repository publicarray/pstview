//! Safe, self-contained HTML rendering of a message (portable - no OS dependencies).
//!
//! Safety layers:
//!  1. Sanitiser: drops <script>, <iframe>, <object>, <embed>, <svg>, <form> controls, <meta>, <base>,
//!     <link>, comments, all on* event attributes and javascript:/vbscript: URLs.
//!  2. Remote resources (http/https images, CSS url()) are replaced and counted - no tracking pixels.
//!  3. cid: inline images are embedded from the message's attachments as data: URIs.
//!  4. A strict Content-Security-Policy blocks all script and all network loads even if
//!     something slipped through the sanitiser.
//!  5. The mail cannot restyle or cover pstview's own header block (sender, dates, safe-view
//!     note): its CSS is re-scoped to the mail container, which also clips and contains it.

const std = @import("std");
const pst = @import("pst.zig");
const Allocator = std.mem.Allocator;
const List = std.ArrayList(u8);

pub const csp = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; form-action 'none'; base-uri 'none'";

const drop_with_content = [_][]const u8{ "script", "iframe", "object", "embed", "applet", "frame", "frameset", "svg", "math", "template", "noembed", "noframes" };
const drop_tag_only = [_][]const u8{ "meta", "base", "link", "form", "input", "button", "textarea", "select", "option", "html", "head", "title", mail_tag };

/// The element the mail body is shown in. It is a direct child of <body> and the last thing in
/// the document, and the sanitiser removes this tag name (and html / body) from the mail, so no
/// end tag in the mail can close it: whatever the mail's markup does, it stays inside.
const mail_tag = "pstview-mail";
/// Stands in for the mail's own <body> inside `mail_tag` (takes its colours and `body {}` rules).
const body_class = "pv-body";

fn inList(name: []const u8, list: []const []const u8) bool {
    for (list) |n| if (std.ascii.eqlIgnoreCase(name, n)) return true;
    return false;
}

fn dropIndex(name: []const u8) ?usize {
    for (drop_with_content, 0..) |n, i| if (std.ascii.eqlIgnoreCase(name, n)) return i;
    return null;
}

pub const SanitizeStats = struct {
    blocked_remote: usize = 0,
    removed_active: usize = 0,
    inlined_images: usize = 0,
    /// CSS declarations taken from the mail's <body> tag (bgcolor, text, style).
    body_style: []const u8 = "",
};

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

/// A URL whose scheme is not one of the harmless ones. The value is still entity-encoded here
/// ("&#106;avascript:", "javascript&colon;"), so a "&" where the scheme would be is refused too.
fn isDangerousUrl(v: []const u8) bool {
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    for (v) |c| {
        if (c <= ' ') continue; // browsers ignore whitespace/control chars inside schemes
        if (c == '/' or c == '?' or c == '#') return false; // relative: no scheme
        if (c == '&') return true;
        if (c == ':') {
            const scheme = buf[0..n];
            for ([_][]const u8{ "http", "https", "mailto", "tel", "ftp", "cid", "sms", "callto", "news" }) |ok| if (std.mem.eql(u8, scheme, ok)) return false;
            if (std.mem.eql(u8, scheme, "data")) return !isImageData(v);
            return true;
        }
        if (n >= buf.len) return false; // too long for a scheme
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    return false;
}

/// "data:image/..." other than SVG (which can carry script).
fn isImageData(v: []const u8) bool {
    const t = std.mem.trim(u8, v, " \t\r\n");
    return std.ascii.startsWithIgnoreCase(t, "data:image/") and !std.ascii.startsWithIgnoreCase(t, "data:image/svg");
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
            if (!isImageData(inner)) {
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

/// Text that is safe to copy into the stylesheet between the braces pstview writes itself:
/// nothing in it can open or close a block, a comment or a string that runs on.
fn plainCss(s: []const u8) bool {
    var q: u8 = 0;
    for (s) |c| {
        switch (c) {
            '{', '}', ';', '\\', '<', '\n', '\r', 0x0c => if (q != 0 or c > ' ') return false,
            else => {},
        }
        if (q != 0) {
            if (c == q) q = 0;
        } else if (c == '"' or c == '\'') q = c;
    }
    return q == 0 and std.mem.indexOf(u8, s, "/*") == null;
}

/// The declarations of one rule (or of a style attribute of the mail's <body>), one by one;
/// anything that is not a plain "name: value" is left out.
fn cleanDeclarations(a: Allocator, out: *List, block: []const u8, st: *SanitizeStats) !void {
    if (std.mem.indexOfAny(u8, block, "{}") != null) return; // nested rules: not in mail
    var it = std.mem.splitScalar(u8, block, ';');
    while (it.next()) |raw| {
        const d = std.mem.trim(u8, raw, " \t\r\n\x0c");
        if (d.len == 0 or std.mem.indexOfScalar(u8, d, ':') == null) continue;
        var flat: List = .empty; // a value may be wrapped over lines
        for (d) |c| try flat.append(a, if (c == '\n' or c == '\r' or c == 0x0c) ' ' else c);
        if (!plainCss(flat.items)) continue;
        if (std.ascii.findIgnoreCase(flat.items, "image-set(") != null) {
            st.blocked_remote += 1;
            continue;
        }
        try cleanCss(a, out, flat.items, st);
        try out.append(a, ';');
    }
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c >= 0x80;
}

/// One selector of the mail, confined to the mail container. `html`, `body` and `:root` mean the
/// stand-in for the mail's body. False: the selector cannot match anything (dropped).
fn scopeSelector(a: Allocator, out: *List, sel: []const u8) !bool {
    const start = out.items.len;
    try out.appendSlice(a, mail_tag);
    var i: usize = 0;
    var first = true;
    var prev_root = false;
    while (i < sel.len) {
        const cs = i;
        while (i < sel.len and (std.ascii.isWhitespace(sel[i]) or sel[i] == '>' or sel[i] == '+' or sel[i] == '~')) i += 1;
        const comb = std.mem.trim(u8, sel[cs..i], " \t\r\n\x0c");
        const s = i;
        var depth: usize = 0;
        var q: u8 = 0;
        while (i < sel.len) : (i += 1) {
            const c = sel[i];
            if (q != 0) {
                if (c == q) q = 0;
            } else if (c == '"' or c == '\'') {
                q = c;
            } else if (c == '(' or c == '[') {
                depth += 1;
            } else if (c == ')' or c == ']') {
                depth -|= 1;
            } else if (depth == 0 and (std.ascii.isWhitespace(c) or c == '>' or c == '+' or c == '~')) break;
        }
        var comp = sel[s..i];
        if (comp.len == 0) continue;
        var root = false;
        inline for (.{ "html", "body", ":root" }) |r| {
            if (!root and std.ascii.startsWithIgnoreCase(comp, r) and (comp.len == r.len or !isIdentChar(comp[r.len]))) {
                root = true;
                comp = comp[r.len..];
            }
        }
        if (root) {
            // body.dark, body#x, body[lang]: the mail's <body> attributes are not kept
            if (comp.len > 0 and comp[0] != ':') {
                out.shrinkRetainingCapacity(start);
                return false;
            }
            if (prev_root) continue; // "html body": one element here
        }
        if (first or comb.len == 0) try out.append(a, ' ') else try out.appendSlice(a, comb);
        if (root) try out.appendSlice(a, "." ++ body_class);
        try out.appendSlice(a, comp);
        first = false;
        prev_root = root;
    }
    if (first) {
        out.shrinkRetainingCapacity(start);
        return false;
    }
    return true;
}

fn scopeRules(a: Allocator, out: *List, css: []const u8, st: *SanitizeStats, depth: usize) Allocator.Error!void {
    var i: usize = 0;
    while (i < css.len) {
        const ps = i;
        while (i < css.len and css[i] != '{' and css[i] != ';' and css[i] != '}') i += 1;
        const prelude = std.mem.trim(u8, css[ps..i], " \t\r\n\x0c");
        if (i >= css.len) break;
        if (css[i] != '{') { // "@import ...;", "@charset ...;" or a stray brace
            if (std.ascii.startsWithIgnoreCase(prelude, "@import")) st.blocked_remote += 1;
            i += 1;
            continue;
        }
        i += 1;
        const bs = i;
        var open: usize = 1;
        while (i < css.len and open > 0) : (i += 1) {
            if (css[i] == '{') open += 1 else if (css[i] == '}') open -= 1;
        }
        const block = css[bs..if (open == 0) i - 1 else i];
        var flat: List = .empty; // a selector list may be wrapped over lines
        for (prelude) |c| try flat.append(a, if (c == '\n' or c == '\r' or c == 0x0c) ' ' else c);
        if (flat.items.len == 0 or !plainCss(flat.items)) continue;
        if (flat.items[0] == '@') {
            // conditional groups keep their condition; @font-face, @keyframes, @page are dropped
            const group = std.ascii.startsWithIgnoreCase(flat.items, "@media") or std.ascii.startsWithIgnoreCase(flat.items, "@supports");
            if (!group or depth >= 4) continue;
            try out.appendSlice(a, flat.items);
            try out.append(a, '{');
            try scopeRules(a, out, block, st, depth + 1);
            try out.append(a, '}');
            continue;
        }
        var sels: List = .empty;
        var s: usize = 0;
        var nest: usize = 0;
        var q: u8 = 0;
        for (flat.items, 0..) |c, k| {
            if (q != 0) {
                if (c == q) q = 0;
            } else if (c == '"' or c == '\'') {
                q = c;
            } else if (c == '(' or c == '[') {
                nest += 1;
            } else if (c == ')' or c == ']') {
                nest -|= 1;
            }
            const last = k + 1 == flat.items.len;
            if ((c == ',' and nest == 0 and q == 0) or last) {
                const one = std.mem.trim(u8, flat.items[s..if (c == ',' and nest == 0 and q == 0) k else k + 1], " \t");
                s = k + 1;
                const mark = sels.items.len;
                if (mark > 0) try sels.append(a, ',');
                if (one.len == 0 or !try scopeSelector(a, &sels, one)) sels.shrinkRetainingCapacity(mark);
            }
        }
        if (sels.items.len == 0) continue;
        try out.appendSlice(a, sels.items);
        try out.append(a, '{');
        try cleanDeclarations(a, out, block, st);
        try out.append(a, '}');
    }
}

/// A <style> block of the mail, rewritten so that every rule applies inside the mail container
/// only. The rules are re-serialised rule by rule and declaration by declaration, so the braces
/// in the result are pstview's own: the mail cannot end a rule early to start an unscoped one.
fn scopeCss(a: Allocator, out: *List, raw: []const u8, st: *SanitizeStats) !void {
    var css: List = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        var skip: usize = 0;
        if (std.mem.startsWith(u8, raw[i..], "/*")) {
            skip = if (std.mem.indexOfPos(u8, raw, i + 2, "*/")) |e| e + 2 - i else raw.len - i;
        } else if (std.mem.startsWith(u8, raw[i..], "<!--")) {
            skip = 4;
        } else if (std.mem.startsWith(u8, raw[i..], "-->")) {
            skip = 3;
        }
        if (skip > 0) {
            try css.append(a, ' ');
            i += skip;
        } else {
            try css.append(a, raw[i]);
            i += 1;
        }
    }
    try scopeRules(a, out, css.items, st, 0);
}

const Attr = struct { name: []const u8, val: []const u8, has_val: bool };

/// The attributes of one tag, read the lenient way browsers do.
const AttrIter = struct {
    s: []const u8,
    p: usize = 0,

    fn next(it: *AttrIter) ?Attr {
        const attrs = it.s;
        var p = it.p;
        defer it.p = p;
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
            return .{ .name = an, .val = val, .has_val = has_val };
        }
        return null;
    }
};

/// <body bgcolor=... text=... style=...> as CSS for the element that stands in for it.
fn bodyStyle(a: Allocator, attrs: []const u8, st: *SanitizeStats) ![]const u8 {
    var css: List = .empty;
    var it: AttrIter = .{ .s = attrs };
    while (it.next()) |at| {
        const prop: []const u8 = if (std.ascii.eqlIgnoreCase(at.name, "bgcolor")) "background-color" else if (std.ascii.eqlIgnoreCase(at.name, "text")) "color" else {
            if (std.ascii.eqlIgnoreCase(at.name, "style")) try cleanDeclarations(a, &css, at.val, st);
            continue;
        };
        const v = std.mem.trim(u8, at.val, " ");
        if (v.len == 0 or v.len > 32) continue;
        var hex = v.len == 6 or v.len == 3;
        var ok = true;
        for (v) |c| {
            if (!std.ascii.isHex(c)) hex = false;
            if (!std.ascii.isAlphanumeric(c) and c != '#') ok = false;
        }
        if (!ok) continue;
        try css.print(a, "{s}:{s}{s};", .{ prop, if (hex) "#" else "", v }); // bgcolor=FFFFFF is a colour too
    }
    return css.items;
}

/// Sanitise an email HTML body. `m` is used to resolve cid: images.
pub fn sanitize(a: Allocator, html: []const u8, m: *const pst.Message, st: *SanitizeStats) ![]u8 {
    var out: List = .empty;
    try out.ensureTotalCapacity(a, html.len);
    var unclosed: [drop_with_content.len]bool = @splat(false);
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

        if (dropIndex(name)) |di| {
            st.removed_active += 1;
            // skip to the matching close tag; once there is none, there is none further on
            // either (a mail of 100,000 unclosed <script> tags must not be searched 100,000 times)
            if (!closing and !unclosed[di]) {
                var close_buf: [24]u8 = undefined;
                const close = std.fmt.bufPrint(&close_buf, "</{s}", .{name}) catch "";
                if (std.ascii.findIgnoreCasePos(html, next, close)) |ce| {
                    i = (std.mem.indexOfScalarPos(u8, html, ce, '>') orelse html.len - 1) + 1;
                    continue;
                }
                unclosed[di] = true;
            }
            i = next;
            continue;
        }
        if (inList(name, &drop_tag_only)) {
            i = next;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "body")) {
            if (!closing and st.body_style.len == 0) st.body_style = try bodyStyle(a, attrs, st);
            i = next;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "style") and !closing) {
            // keep inline <style> blocks but clean their CSS
            const ce = std.ascii.findIgnoreCasePos(html, next, "</style") orelse html.len;
            try out.appendSlice(a, "<style>");
            try scopeCss(a, &out, html[next..ce], st);
            try out.appendSlice(a, "</style>");
            i = if (ce < html.len) (std.mem.indexOfScalarPos(u8, html, ce, '>') orelse html.len - 1) + 1 else html.len;
            continue;
        }

        // rebuild tag with filtered attributes
        try out.append(a, '<');
        if (closing) try out.append(a, '/');
        for (name) |ch| try out.append(a, std.ascii.toLower(ch));
        var it: AttrIter = .{ .s = attrs };
        while (it.next()) |at| {
            const an = at.name;
            const val = at.val;
            const has_val = at.has_val;
            // filter
            const name_ok = for (an) |ch| {
                if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != ':' and ch != '.') break false;
            } else true;
            if (!name_ok) continue; // quotes, "<" and the like: debris of broken markup
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
                } else if (!isImageData(tv)) out_val = "";
            }
            if (std.ascii.eqlIgnoreCase(an, "style")) {
                // quotes around font names arrive as entities; a ";" inside one would split the value
                var plain: []const u8 = val;
                inline for (.{ .{ "&quot;", "\"" }, .{ "&#34;", "\"" }, .{ "&#39;", "'" }, .{ "&apos;", "'" }, .{ "&amp;", "&" } }) |e| {
                    if (std.ascii.findIgnoreCase(plain, e[0]) != null) plain = try std.mem.replaceOwned(u8, a, plain, e[0], e[1]);
                }
                var css: List = .empty;
                try cleanDeclarations(a, &css, plain, st);
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
    // HTML mail is written for a white page and often sets only one of text and background
    // colour: it is always shown on white (black text on a dark theme would be unreadable).
    // Plain text follows the theme.
    const is_html = html_utf8.len > 0;
    if (is_html) {
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
        \\.mail,.pv-body{padding:14px 18px;overflow-wrap:anywhere}
        \\pstview-mail{display:block;background:#fff;color:#000;color-scheme:light;position:relative;contain:layout;isolation:isolate;overflow:auto}
        \\pstview-mail img[data-blocked-src]{outline:1px dashed #c33;min-width:20px;min-height:12px}
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
    // The mail goes last, in an element it cannot close (see `mail_tag`).
    if (is_html) {
        try out.appendSlice(a, "<" ++ mail_tag ++ "><div class=\"" ++ body_class ++ "\" style=\"");
        try escAttr(a, &out, st.body_style);
        try out.appendSlice(a, "\">");
        try out.appendSlice(a, body_html);
        try out.appendSlice(a, "</div></" ++ mail_tag ++ "></body></html>\n");
    } else {
        try out.appendSlice(a, "<div class=\"mail\">");
        try out.appendSlice(a, body_html);
        try out.appendSlice(a, "</div></body></html>\n");
    }
    return out.toOwnedSlice(a);
}

const testing = std.testing;
const no_mail: pst.Message = .{ .nid = 0, .node = null, .pc = .{ .props = &.{} }, .recipients = &.{}, .attachments = &.{} };

fn testSanitize(a: Allocator, html: []const u8, st: *SanitizeStats) ![]u8 {
    return sanitize(a, html, &no_mail, st);
}

test "mail CSS is confined to the mail container" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: SanitizeStats = .{};
    // the mail that showed the bug: its body colour reached pstview's own header block
    try testing.expectEqualStrings(
        "<style>pstview-mail .pv-body{background-color: #9999CC;}</style>",
        try testSanitize(a, "<style type=\"text/css\">\n<!--\nbody {\n\tbackground-color: #9999CC;\n}\n-->\n</style>", &st),
    );
    const cases = [_][2][]const u8{
        .{ "p{color:red}", "pstview-mail p{color:red;}" },
        .{ "html, body { margin:0 }", "pstview-mail .pv-body,pstview-mail .pv-body{margin:0;}" },
        .{ "html body > p.x , td{a:b}", "pstview-mail .pv-body>p.x,pstview-mail td{a:b;}" },
        .{ ":root{--c:1}", "pstview-mail .pv-body{--c:1;}" },
        .{ "bodyguard{a:b}", "pstview-mail bodyguard{a:b;}" },
        .{ "body.dark{a:b}", "" }, // the mail's body classes are not kept
        .{ "*{a:b} .hdr,.note{display:none}", "pstview-mail *{a:b;}pstview-mail .hdr,pstview-mail .note{display:none;}" },
        .{ "a:is(.x, .y)[href=\"a,b\"]{a:b}", "pstview-mail a:is(.x, .y)[href=\"a,b\"]{a:b;}" },
        .{ "@media (max-width:600px){ td{a:b} }", "@media (max-width:600px){pstview-mail td{a:b;}}" },
        .{ "@import url(http://x/y.css); p{a:b}", "pstview-mail p{a:b;}" },
        .{ "@font-face{font-family:x;src:url(http://x)} p{a:b}", "pstview-mail p{a:b;}" },
        // attempts to end a rule early and start an unscoped one
        .{ "p{a:b} } .hdr{display:none}", "pstview-mail p{a:b;}pstview-mail .hdr{display:none;}" },
        .{ "p{content:\"}\"} .hdr{display:none}", "pstview-mail p{}pstview-mail .hdr{display:none;}" },
        .{ "p{a:\"\n} .hdr{display:none} x{b:\"}", "pstview-mail p{}pstview-mail .hdr{display:none;}pstview-mail x{}" },
        .{ "p /* {a:b} .hdr{display:none} */ {c:d}", "pstview-mail p{c:d;}" },
        .{ "p{a:b} /* .hdr{display:none}", "pstview-mail p{a:b;}" },
        .{ "p\\7b a:b} .hdr{c:d}", "pstview-mail .hdr{c:d;}" },
        .{ "p{background:url(http://x/t.gif);color:red}", "pstview-mail p{background:none;color:red;}" },
        .{ "p{background:image-set(\"http://x/t.gif\" 1x)}", "pstview-mail p{}" },
    };
    for (cases) |c| {
        var out: List = .empty;
        try scopeCss(a, &out, c[0], &st);
        try testing.expectEqualStrings(c[1], out.items);
        // whatever comes in, every brace in the result is balanced
        var depth: isize = 0;
        for (out.items) |ch| {
            if (ch == '{') depth += 1 else if (ch == '}') depth -= 1;
            try testing.expect(depth >= 0);
        }
        try testing.expectEqual(@as(isize, 0), depth);
    }
}

test "sanitiser removes active content and remote loads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "a<script>alert(1)</script>b", "ab" },
        .{ "<p onclick=\"x()\" ONLOAD=y>t</p>", "<p>t</p>" },
        .{ "<img src=\"http://t.example/p.gif\" width=1>", "<img data-blocked-src=\"http://t.example/p.gif\" src=\"\" width=\"1\">" },
        .{ "<a href=\"javascript:alert(1)\">x</a>", "<a>x</a>" },
        .{ "<a href=\" java\tscript:alert(1)\">x</a>", "<a>x</a>" },
        .{ "<a href=\"&#106;avascript:alert(1)\">x</a>", "<a>x</a>" },
        .{ "<a href=\"javascript&colon;alert(1)\">x</a>", "<a>x</a>" },
        .{ "<a href=\"data:text/html,x\">x</a>", "<a>x</a>" },
        .{ "<a href=\"https://a.example/?b=1&c=2\">x</a>", "<a href=\"https://a.example/?b=1&c=2\" rel=\"noopener noreferrer\" target=\"_blank\">x</a>" },
        .{ "<a href=\"/rel?x=1\">x</a>", "<a href=\"/rel?x=1\" rel=\"noopener noreferrer\" target=\"_blank\">x</a>" },
        .{ "<img src=\"data:image/svg+xml,<svg/>\">", "<img>" },
        .{ "<img src=\"data:image/png;base64,AA==\">", "<img src=\"data:image/png;base64,AA==\">" },
        // nothing in the mail may close, or pose as, pstview's containers
        .{ "</pstview-mail><PSTVIEW-MAIL>x</body></html>", "x" },
        .{ "<div style=\"font-family:&quot;A;B&quot;,serif;position:fixed\">", "<div style=\"position:fixed;\">" },
        .{ "<div style='font-family:\"Calibri\",sans-serif;color:red'>", "<div style=\"font-family:&quot;Calibri&quot;,sans-serif;color:red;\">" },
        .{ "<iframe src=x></iframe><object></object><form action=x><input name=q></form>ok", "ok" },
        .{ "<!-- c --><meta http-equiv=refresh content=0><base href=x>ok", "ok" },
    };
    for (cases) |c| {
        var st: SanitizeStats = .{};
        try testing.expectEqualStrings(c[1], try testSanitize(a, c[0], &st));
    }
    var st: SanitizeStats = .{};
    _ = try testSanitize(a, "<html><body bgcolor=000000 text=\"#fff\" style=\"margin:0;x:url(http://t)\" onload=x><p>t</body>", &st);
    try testing.expectEqualStrings("background-color:#000000;color:#fff;margin:0;x:none;", st.body_style);
    try testing.expectEqual(@as(usize, 1), st.blocked_remote);
}

test "sanitiser survives truncated and hostile markup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        // linear in the size of the mail: this test ran for minutes when every tag searched to the end
        var big: List = .empty;
        for (0..150_000) |_| try big.appendSlice(a, "<script>x<svg>");
        var st: SanitizeStats = .{};
        _ = try testSanitize(a, big.items, &st);
        try testing.expectEqual(@as(usize, 300_000), st.removed_active);
    }
    const seeds = [_][]const u8{
        "<", "<a", "<a href=", "<a href=\"", "<style>", "<style>p{", "<script>", "<!--", "<!", "</", "<a b='c\" d>", "<body style=\"", "<style>@media x{@media y{p{a:b}",
        "<table><tr><td style=\"background:url(\">x<img src=cid:>",
    };
    for (seeds) |s| {
        var st: SanitizeStats = .{};
        _ = try testSanitize(a, s, &st);
        // every prefix and every single-byte damage of a longer document
        const doc = try std.mem.concat(a, u8, &.{ "<html><style>body{color:red} @media x{p{a:url(http://x)}}</style><body bgcolor=red><a href=\"http://x\" onclick=y>l</a>", s, "<img src=\"cid:a\"></body>" });
        for (0..doc.len) |n| {
            _ = try testSanitize(a, doc[0..n], &st);
            const d = try a.dupe(u8, doc);
            for ([_]u8{ '<', '>', '"', '\'', '{', '}', 0 }) |ch| {
                d[n] = ch;
                const out = try testSanitize(a, d, &st);
                try testing.expect(std.ascii.findIgnoreCase(out, "<script") == null);
                try testing.expect(std.ascii.findIgnoreCase(out, "pstview-mail>") == null);
                try testing.expect(std.ascii.findIgnoreCase(out, "<body") == null);
            }
        }
    }
}
